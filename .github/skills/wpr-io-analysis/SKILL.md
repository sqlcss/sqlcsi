---
name: wpr-io-analysis
description: >
  Disk / File I/O investigation for SQL Server using WPR/ETL traces and the WPA
  MCP server. Broad→Narrow workflow: per-file/database aggregation → I/O latency
  distribution → by process/thread → SQL Server interpretation.
  USE FOR: "IO analysis", "IO 分析", "slow IO", "disk latency", "PAGEIOLATCH",
  "WRITELOG", "which file does the most IO".
  DO NOT USE FOR: CPU analysis (use wpr-cpu-analysis), CPU comparison
  (use wpr-cpu-comparison), GC/allocation analysis.
---

# SQL Server Disk / File I/O Investigation Skill

Analyze disk and file I/O in a WPR/ETL trace for SQL Server (`sqlservr.exe`).
Uses WPA MCP query tools with SQL Server domain knowledge. The primary goal is to
answer: **which database file does the most I/O, is it read- or write-bound, and how
slow is each I/O?**

**Prerequisites**: User must open the ETL file in WPA GUI. The trace must have been
recorded with the **Disk I/O** WPR profile so the `Disk Usage` table is populated.
WPA MCP server must be running.

## Language Policy

- **Chat replies**: If the user's input language is Chinese, reply in Chinese.
  Otherwise reply in English.
- **Report language**: Before generating the final report, ask the user which
  language they prefer (English or Chinese). Do not assume.

## Inputs

- `sub_focus` (optional) — "slow IO" | "throughput" | "by file" (default: "by file")
- `case_id` (optional) — for cross-reference with ERRORLOG/XEvent (PAGEIOLATCH/WRITELOG)

## WPA MCP Tools Used

| Tool | Purpose |
|------|---------|
| `list_traces` | List loaded traces and available tables |
| `get_schema` | Get table schema (fields, filters, aggregations) |
| `start_new_query` | Start a new query on a table |
| `add_condition` | Add filter condition |
| `add_grouping` | Add group-by field |
| `add_aggregation` | Add aggregation (Sum, Count, Average, Min, Max) |
| `perform_query` | Execute the query |
| `cancel_query` | Cancel a running query |

## WPA MCP Query Pattern Reference

Every query follows this pattern:

```
1. start_new_query(traceId, tableName, targetCollection="Rows", logicalOperator="And")
2. add_condition(queryId, condition={"operator": "Equal|Contains|...", "property": "...", "value": "..."})  // optional, repeatable
3. add_grouping(queryId, grouping={"property": "..."})  // repeatable
4. add_aggregation(queryId, aggregation={"name": "UniqueAlias", "property": "...", "type": "Sum|Count|Average|..."})  // repeatable
5. perform_query(queryId, allowQueryingAllData=true)
```

**Key rules**:
- Each aggregation must have a unique `name`
- `condition.operator` must match the field's `supportedFilters` from `get_schema`
- Results contain `.toMilliseconds` / `.toMicroseconds` for time fields and raw byte
  counts for size fields

### `Disk Usage` table — key columns (verified via get_schema)

> Column names below are **verified** on a real WPR Disk I/O trace. If `get_schema`
> returns different names on your version, re-map accordingly.

| Logical field | Actual property | Type | Notes |
|---------------|-----------------|------|-------|
| Process | `Process` | String | `"sqlservr.exe (PID)"` — **filter/group only, Sum NOT supported** |
| Process name | `Process_Name` | String | bare image name |
| File path | `Path_Name` | String | full file path (`.mdf`/`.ndf`/`.ldf`) — group/filter |
| File extension | `File_Extension` | String | ⭐ filter directly by `mdf`/`ndf`/`ldf` |
| I/O type | `IO_Type` | String | `Read` / `Write` / `Flush` |
| Disk | `Disk` | UInt32 | physical disk number |
| Bytes | `Size` | Bytes | bytes transferred — **Sum** for throughput |
| Per-I/O latency | `Disk_Service_Time` | TimestampDelta | ⭐ **Average / Max / Sum** — the latency metric |
| Storport latency | `Storport_Disk_Service_Time` | TimestampDelta | hardware-side latency (check `Is_Storport_Duration_Reliable`) |
| I/O outstanding time | `IO_Time` | TimestampDelta | total time the I/O was outstanding |
| Count | `Count` | Int32 | number of I/O operations — **Sum** |
| Thread | `Thread_ID` | Int32 | issuing thread |
| Priority | `Priority` | String | I/O priority |
| Queue depth @ init | `QD_I___Queue_Depth_at_Init_Time` | UInt32 | disk queue depth when issued |
| Queue depth @ complete | `QD_C___Queue_Depth_at_Complete_Time` | UInt32 | disk queue depth when completed |
| Offset (start) | `Min_Offset` | Address | ⭐ I/O start offset (disk-absolute) — parse `.toBytes`. **No single `Offset` column!** |
| Offset (end) | `Max_Offset` | Address | I/O end offset (disk-absolute) — parse `.toBytes` |
| Init call stack | `IO_Init_Stack` | DecodedSymbol | ⭐ **stack of who issued the I/O** (group/filter) |

### WPA MCP Gotchas (verified)

- **`Process` / `Process_Name` / `Path_Name` / `IO_Type` only support `Count` aggregation**
  — to rank by throughput you Sum **`Size`**, not the string field. Group by the string,
  aggregate Sum on `Size` / `Count` / `Disk_Service_Time`.
- Use **`Disk_Service_Time`** (TimestampDelta) for latency — supports Sum/Average/Max.
  Results carry `.toMilliseconds` / `.toMicroseconds`.
- `Size` is typed **Bytes** — Sum gives total bytes; convert to MB/GB for tables.
- `File_Extension` lets you filter SQL files directly: `Equal "mdf"`, `"ndf"`, `"ldf"`.
- `IO_Init_Stack` carries the **issuing call stack** — use it to attribute I/O to a code
  path (checkpoint / log writer / read-ahead) without leaving this table.
- MCP only supports **flat group + aggregate** — no tree/butterfly view.
- Always **group** before aggregating; an ungrouped per-I/O query can be enormous.

---

## Phase 1 — Discover Traces & Check Disk Usage Table

```
Call list_traces()
```

From the result:
- Record `traceId` for subsequent queries.
- Check `processedTables` for **`"Disk Usage"`** (required).
  - If absent → the ETL was not recorded with the Disk I/O profile. Stop and tell the
    user: "This trace has no Disk Usage table — re-record with WPR Disk I/O profile
    enabled (`wpr -start DiskIO`)."
- Optionally call `get_schema(traceId, "Disk Usage")` to confirm column names match the
  verified table above. The queries below use the verified names directly.

## Phase 2 — Top Processes by I/O

Goal: confirm `sqlservr.exe` is the dominant I/O issuer (and pick the PID if multiple).

```
start_new_query(traceId, "Disk Usage", "Rows", "And")
add_grouping     property=Process
add_aggregation  name=Bytes,  type=Sum, property=Size
add_aggregation  name=IOs,    type=Sum, property=Count
add_aggregation  name=SvcMs,  type=Sum, property=Disk_Service_Time
perform_query    allowQueryingAllData=true
```

Present top processes by **Bytes** as a markdown table. Extract PID from `Process`
(`"name.exe (PID)"`):

| Process | PID | Bytes (MB) | IOs | Total Svc (ms) | % Bytes |
|---------|-----|-----------|-----|----------------|---------|

Record the SQL Server `Process` value as `{target_process}`. If several `sqlservr.exe`
instances exist, ask the user which PID to investigate. Use
`add_condition(operator="Equal", property="Process", value="{target_process}")` for all
later queries.

## Phase 3 — Per-File Aggregation (primary: which database file does the most I/O)

Goal: rank files by I/O for the target process, split by read vs write.

```
start_new_query(traceId, "Disk Usage", "Rows", "And")
add_condition    property=Process, operator=Equal, value="{target_process}"
add_grouping     property=Path_Name
add_grouping     property=IO_Type
add_aggregation  name=Bytes,  type=Sum,     property=Size
add_aggregation  name=IOs,    type=Sum,     property=Count
add_aggregation  name=SvcMs,  type=Sum,     property=Disk_Service_Time
add_aggregation  name=AvgSvc, type=Average, property=Disk_Service_Time
perform_query    allowQueryingAllData=true
```

Present top 20 files (top-level group = `Path_Name`, nested = `IO_Type`):

| File | Type | Bytes (MB) | IOs | Avg Latency (ms) | Total Svc (ms) |
|------|------|-----------|-----|------------------|----------------|
| E:\Data\MyDB.mdf | Read | 12,480 | 1,560,000 | 0.8 | 124,800 |
| L:\Log\MyDB.ldf | Write | 2,310 | 198,000 | 4.2 | 831,600 |

**SQL Server interpretation by extension**:
- `.mdf` / `.ndf` — data files → reads = buffer pool misses (PAGEIOLATCH_SH/EX),
  writes = checkpoint / lazy writer
- `.ldf` — log file → writes = transaction log flush (WRITELOG); should be **low latency,
  sequential**. High `.ldf` write latency directly explains WRITELOG waits.
- `tempdb` files — version store / spills / worktables
- Read-dominant + high latency on data files → storage or buffer pool pressure
- Write-dominant + high latency on `.ldf` → log disk bottleneck

### Phase 3b — I/O size distribution (access-pattern fingerprint)

For the top 1–2 hot files, break down I/O **by `Size`** to fingerprint the access pattern
(random single-page vs sequential large-block). Group by `IO_Type` + `Size`:

```
start_new_query(traceId, "Disk Usage", "Rows", "And")
add_condition    property=Path_Name, operator=Contains, value="<hotfile>"
add_grouping     property=IO_Type
add_grouping     property=Size
add_aggregation  name=IOs,    type=Sum,     property=Count
add_aggregation  name=AvgSvc, type=Average, property=Disk_Service_Time
perform_query    allowQueryingAllData=true
```

Present per file as `Size | IOs | % | Avg latency | pattern`. SQL Server size signatures:

| I/O size | Typical meaning |
|----------|-----------------|
| **8 KB** | single page — random read (buffer-pool miss) or single dirty-page write |
| **16–64 KB** | read-ahead / small coalesced write |
| **512 KB** | checkpoint **coalesced** dirty-page write (adjacent pages merged) |
| **1 MB** | backup block (`CopyFileToBackupSet` read / backup-medium write), or large read-ahead |

- **Bimodal `.mdf` read** (8 KB + 1 MB) → mixed query random reads + backup sequential reads.
- **Uniform 1 MB writes** on `.bak` → ideal sequential backup; latency jitter then comes
  from disk contention, not I/O size.
- **Mostly 8 KB + some 512 KB** on `.mdf` write → checkpoint coalescing — the 512 KB bursts
  are the queueing source seen in Phase 4b.

## Phase 4 — I/O Latency Distribution (slow I/O)

Goal: characterize how slow individual I/Os are, beyond the average.

```
start_new_query(traceId, "Disk Usage", "Rows", "And")
add_condition    property=Process, operator=Equal, value="{target_process}"
add_grouping     property=IO_Type
add_aggregation  name=IOs,    type=Sum,     property=Count
add_aggregation  name=AvgSvc, type=Average, property=Disk_Service_Time
add_aggregation  name=MaxSvc, type=Max,     property=Disk_Service_Time
add_aggregation  name=SumSvc, type=Sum,     property=Disk_Service_Time
perform_query    allowQueryingAllData=true
```

Present per-type latency summary:

| Type | IOs | Avg (ms) | Max (ms) | Total Svc (ms) |
|------|-----|---------|---------|----------------|

**Latency thresholds (SQL Server rule of thumb)**:
- Data file read/write avg > **15–20 ms** → storage latency problem
- Log file write avg > **5 ms** → log disk too slow (WRITELOG)
- Max ≫ Avg (e.g. Max 500 ms vs Avg 2 ms) → intermittent stalls / queueing

### Phase 4b — Service time vs Queue time, **per file** (REQUIRED, not optional)

`Disk_Service_Time` alone only tells you how fast the **device** served each I/O — it
hides **queueing**. A file can show 0.1 ms service time yet 7 ms total latency because
the I/Os piled up in the disk queue. **Always** split service vs queue, grouped by file:

```
start_new_query(traceId, "Disk Usage", "Rows", "And")
add_condition    property=Process, operator=Equal, value="{target_process}"
add_grouping     property=Path_Name
add_grouping     property=IO_Type
add_aggregation  name=IOs,    type=Sum,     property=Count
add_aggregation  name=AvgSvc, type=Average, property=Disk_Service_Time   # device service
add_aggregation  name=AvgIO,  type=Average, property=IO_Time             # init→complete (incl. queue)
add_aggregation  name=MaxIO,  type=Max,     property=IO_Time
add_aggregation  name=MaxQDc, type=Max,     property=QD_C___Queue_Depth_at_Complete_Time
perform_query    allowQueryingAllData=true
```

Compute and present **per file**:

| File | Type | IOs | Svc (ms) | IO_Time (ms) | **Queue (ms)** | Max IO (ms) | Peak QD |
|------|------|----:|---------:|-------------:|---------------:|------------:|--------:|

where **Queue ≈ IO_Time − Disk_Service_Time**.

**How each column is derived** (be precise when explaining to the user):
- **Svc (ms)** = WPA field `Disk_Service_Time`, aggregation `Average`. ETW meaning:
  device-only service time (issued to disk → disk completes), **excludes** upstream queue.
- **IO_Time (ms)** = WPA field `IO_Time`, aggregation `Average`. ETW meaning:
  `Complete_Time − Init_Time` end-to-end residency = **queue wait + device service**.
- **Queue (ms)** = **agent-computed**, `AvgIO − AvgSvc`. WPA has **no** direct queue field.
- Aggregation values come back as `{toMicroseconds, toMilliseconds, ...}` — divide
  `toMicroseconds` by 1000 for ms.

> ⚠️ **Precision caveat**: this Queue is `Average(IO_Time) − Average(Disk_Service_Time)`,
> because MCP only does grouped aggregation (no per-row access). That equals the true mean
> per-I/O queue (means are linear), so the magnitude is correct — but you **cannot** derive
> a per-I/O queue **distribution** (p95/max queue) this way; `MaxIO` is end-to-end, not max
> queue. Always **cross-check with `QD_C` (peak queue depth)**: deep queue + large
> `IO_Time−Svc` gap = genuine queueing; shallow queue = the gap is measurement noise.

**Interpretation**:
- **Queue ≈ 0, Svc dominates** → device-bound. If Svc also high → real storage latency.
- **Queue ≫ Svc** (e.g. Svc 0.1 ms, IO_Time 7 ms, Peak QD 110) → **queueing**, not slow
  storage. Classic cause: **checkpoint** issuing a burst of async dirty-page writes that
  pile up in the disk queue — normal SQL Server burst behavior, NOT a disk bottleneck.
- High `QD_C` confirms queue depth at completion. Correlate the queueing file with its
  `IO_Init_Stack` (Phase 6) to name the subsystem (checkpoint / lazy writer / backup).

> ⚠️ For **async** I/O (checkpoint, read-ahead, backup), high IO_Time / queue is expected
> by design — many I/Os are deliberately in flight at once. Only flag it as a problem when
> the **device service time** (`Disk_Service_Time`) itself is high, or queueing stalls a
> latency-sensitive **synchronous** path (e.g. log writer / WRITELOG).

### Phase 4c — Per-offset drill-down (which exact offsets are slow / queued)

When a file is the latency/queue hot spot, drill into **individual I/Os by file offset**
to confirm whether specific offsets are device-slow vs merely queued. The `Disk Usage`
table (NOT `File I/O`) carries both timings + offset:

```
start_new_query(traceId, "Disk Usage", "Rows", "And")
add_condition    property=Path_Name, operator=Contains, value="<hotfile>.mdf"
add_condition    property=IO_Type,   operator=Equal,    value="Write"   # or Read
add_grouping     property=Min_Offset
add_aggregation  name=IOs,    type=Sum,     property=Count
add_aggregation  name=AvgSvc, type=Average, property=Disk_Service_Time
add_aggregation  name=AvgIO,  type=Average, property=IO_Time
add_aggregation  name=MaxQDc, type=Max,     property=QD_C___Queue_Depth_at_Complete_Time
perform_query    allowQueryingAllData=true
```

- If each offset has `IOs=1`, the grouped rows ARE the per-I/O detail (no aggregation loss).
- Sort by `AvgSvc` desc → offsets where the **device** was slow (real storage hot blocks).
- Sort by `AvgIO` desc with low `AvgSvc` → offsets that only **queued** (async burst).
- Contiguous offsets with deep `QD_C` → sequential checkpoint / backup flush, expected.

> **`File I/O` table vs `Disk Usage`**: `File I/O` is the **logical** file-system layer —
> it has `Offset` and a single `Duration`, but **no** `Disk_Service_Time`, `IO_Time`, or
> queue depth, and it includes cache-hit operations. For per-offset **device service time
> + IO time + queue**, you MUST use `Disk Usage` (physical disk layer).
>
> ⚠️ Parsing `Min_Offset`: it is an `Address`-typed group key → read **`.toBytes`** (not
> `.totalBytes`). Format as hex for readability.

### Phase 4d — Single-file dual-table per-offset correlation (logical vs physical)

When the user picks one file and wants the **full per-offset picture**, run **both** tables
for that file and join by offset. This shows logical (`File I/O.Duration`) vs physical
(`Disk Usage` service / IO / queue) side by side — the strongest evidence for "the app saw
slow I/O but it was queueing, not the device".

**Query A — physical layer (`Disk Usage`, per offset):**
```
start_new_query(traceId, "Disk Usage", "Rows", "And")
add_condition    property=Path_Name, operator=Contains, value="<file>"
add_condition    property=IO_Type,   operator=Equal,    value="Write"   # or Read
add_grouping     property=Min_Offset
add_aggregation  name=IOs,    type=Sum,     property=Count
add_aggregation  name=AvgSvc, type=Average, property=Disk_Service_Time
add_aggregation  name=AvgIO,  type=Average, property=IO_Time
add_aggregation  name=MaxQDc, type=Max,     property=QD_C___Queue_Depth_at_Complete_Time
perform_query    allowQueryingAllData=true
```

**Query B — logical layer (`File I/O`, per offset):**
```
start_new_query(traceId, "File I/O", "Rows", "And")
add_condition    property=File_Name,  operator=Contains, value="<file>"
add_condition    property=Event_Type, operator=Equal,    value="Write"   # or Read
add_grouping     property=Offset
add_aggregation  name=Ops,    type=Sum,     property=Count
add_aggregation  name=AvgDur, type=Average, property=Duration
add_aggregation  name=MaxDur, type=Max,     property=Duration
perform_query    allowQueryingAllData=true
```

**Joining the two (critical — different offset coordinate systems):**

| Table | Offset field | Parse via | Meaning |
|-------|-------------|-----------|---------|
| `Disk Usage` | `Min_Offset` | `.toBytes` | **absolute disk/volume** offset (e.g. 1.07 TB) |
| `File I/O` | `Offset` | `.totalBytes` | **logical file** offset (0-based within file) |

They are the **same I/Os in two coordinate systems**, related by:
`disk_offset = file_base_on_disk + file_offset`.
Compute the base once: `file_base = min(disk_offset) − min(file_offset)`, then join
`Disk Usage[file_base + file_offset]` to each `File I/O[file_offset]`. (Verified: 144/144
offsets matched this way.)

Present the merged per-offset table:

| File Offset (MB) | File Dur (ms) | Disk Svc (ms) | Disk IO_Time (ms) | Queue (ms) | Peak QD |
|-----------------:|--------------:|--------------:|------------------:|-----------:|--------:|

**Reading it**:
- `File Dur ≈ Disk IO_Time` (both end-to-end) while `Disk Svc` is tiny → the latency the
  application saw is **all queueing**, confirmed from both layers independently.
- `Disk Svc` high on specific offsets → genuine slow physical blocks (storage hot spots).
- Contiguous hot offsets → sequential checkpoint / backup region.

> 📐 **Offset correspondence cheat-sheet** (`Disk Usage` ⇄ `File I/O`):
> - `Disk Usage` has **`Min_Offset`** (I/O start) and **`Max_Offset`** (I/O end), both
>   `Address` type → parse **`.toBytes`**. There is **no single `Offset` column**. The
>   value is the **disk/volume-absolute** offset (e.g. ~1.07 TB).
> - `File I/O` has a single **`Offset`** column, `Bytes` type → parse **`.totalBytes`**.
>   The value is the **file-logical** offset (0-based, within the file).
> - Conversion: `disk_offset = file_base + file_offset`, where
>   `file_base = min(Min_Offset) − min(File I/O.Offset)` computed over the same file+direction.
>   `Max_Offset − Min_Offset + 1 ≈ Size` for that I/O.

### Phase 4e — Single slow I/O root-cause deep-dive

When the user points at **one specific slow I/O** (e.g. a `File I/O` row showing
Duration 121 ms), trace its root cause through these steps:

1. **Split service vs queue for that exact I/O.** Query `Disk Usage`, filter the file +
   direction, group by `Min_Offset`, and add `Min(Init_Time)` so you can match the row by
   its start timestamp (the `File I/O` row's `Start (s)` ≈ `Disk Usage` `Init_Time`):
   ```
   add_aggregation name=AvgSvc, type=Average, property=Disk_Service_Time
   add_aggregation name=AvgIO,  type=Average, property=IO_Time
   add_aggregation name=MaxQDc, type=Max,     property=QD_C___Queue_Depth_at_Complete_Time
   add_aggregation name=MinInit,type=Min,     property=Init_Time
   ```
   Classify: **Svc high** (e.g. 45 ms) → device genuinely slow; **Queue high** (IO_Time −
   Svc) → waited behind other I/O; both high → device slow *and* contended.

2. **Look at the time window for contention.** Filter `Init_Time` to a window around the
   slow I/O (e.g. ±150 ms), group by `Process` + `IO_Type`, aggregate `Count` / `Size` /
   `Avg(Disk_Service_Time)`. This reveals **who else hit the disk at that instant**.
   - Timestamp filter value MUST be `{"Nanoseconds": <int>}` (e.g. 106.4 s → 106400000000).
     A bare number is rejected.
   - Classic finding: backup **read side (`.mdf`) + write side (`.bak`) concurrent on the
     same disk** → read/write mixed burst drives device service up and queues the writes.

3. **Confirm the issuing path** with `IO_Init_Stack` (Phase 6) for that file/offset, and
   note the `Flags`: `IRP_NOCACHE` = direct/unbuffered I/O (no cache shielding, so the
   number reflects raw device latency).

**Root-cause patterns**:
| Observation | Root cause | Fix |
|-------------|-----------|-----|
| Svc tiny, Queue huge, deep QD | async burst (checkpoint/read-ahead) | benign; tune flush target if needed |
| Svc high, same-disk read+write burst | source & target on one disk (backup) | put `.bak` on a separate physical disk |
| Svc high, no contention | genuine storage latency / failing disk | investigate storage hardware |
| Queue high, foreign process in window | noisy-neighbor process | isolate workloads / separate volumes |

### Phase 4f — Is the delay in a kernel filter driver?

To check whether an I/O is delayed in a **kernel filter driver** (file-system minifilters
like `fileinfo.sys`, or disk/volume filters like BitLocker `fvevol.sys`, `volsnap.sys`,
`iorate.sys`, `rdyboost.sys`), use the methods below.

#### Phase 4f.0 — GATE: detect whether StorPort timing was captured (run FIRST)

**Always run this gate before attempting Method 1.** Method 1 (the StorPort three-layer
split) only works if the trace actually captured reliable StorPort events. Detect it up
front and branch — don't waste queries on a method that will return zeros.

Run a quick reliability check on the hot file (or all of `sqlservr.exe`):
```
start_new_query(traceId, "Disk Usage", "Rows", "And")
add_condition    property=Process, operator=StartWith, value="sqlservr.exe"
add_grouping     property=Is_Storport_Duration_Reliable
add_aggregation  name=IOs,        type=Sum,     property=Count
add_aggregation  name=AvgStorport,type=Average, property=Storport_Disk_Service_Time
perform_query    allowQueryingAllData=true
```

**Branch on the result:**
- **`Is_Storport_Duration_Reliable = true` group exists with IOs > 0 and AvgStorport > 0**
  → ✅ StorPort captured. **Run Method 1** (three-layer split) on the `true` subset, then
  corroborate with Methods 2–4.
- **Only a `false` group (or AvgStorport = 0 everywhere)**
  → ❌ StorPort NOT captured. **Skip Method 1 entirely** and go straight to Methods 2–4.
  State in the report: "StorPort timing unavailable in this trace (`Is_Storport_Duration_Reliable=false`)
  — device-vs-filter split via Method 1 not possible; using stack/dual-table evidence instead."

  > 💡 **If the latency is suspected to be in the disk/filter layer and you need the StorPort
  > three-layer split, RECOMMEND re-recording with StorPort enabled.** On a **physical disk**
  > the simplest verified way is the built-in WPR profiles (the built-in `DiskIO` profile
  > already enables the StorPort provider):
  > ```cmd
  > WPR.exe -start GeneralProfile -start CPU -start DiskIO -start FileIO -start Network -start minifilter
  > REM ... reproduce the slow I/O (e.g. run BACKUP DATABASE) ...
  > WPR.exe -stop C:\Temp\storport.etl
  > ```
  > Then re-open (`wpa.exe -i storport.etl -tti` if WPA complains about time inversion) and
  > re-run this gate — it should now show `Is_Storport_Duration_Reliable = true`. Tell the
  > user this is needed because the current trace lacks StorPort events. (Won't help on a VM
  > `Msft Virtual Disk` — see the root-cause list at the end of this phase.)

> **Optional deeper confirmation** (when you want to know *why* it's empty, or to confirm
> the provider truly produced events): query `Trace Statistics` (or `Generic Events`) for
> Provider GUID `c4636a1e-7986-4646-bf10-7bc3b4a76e8e`. A count of 0 means the StorPort
> provider never fired (VM virtual disk / wrong keyword / provider not enabled — see the
> root-cause list at the end of this phase). A non-zero count but
> `Is_Storport_Duration_Reliable=false` means events fired but couldn't be paired reliably.

Only if the gate passes (✅) do the following Method 1 queries return meaningful data.

**Method 1 — Storport vs disk service time gap (most direct; REQUIRES gate ✅):**
```
add_aggregation name=AvgSvc,      type=Average, property=Disk_Service_Time
add_aggregation name=AvgStorport, type=Average, property=Storport_Disk_Service_Time
```
`Disk_Service_Time − Storport_Disk_Service_Time` = time in the **disk port/class + disk
filter stack above storport**. A large gap → a disk-stack filter is adding latency.
> ⚠️ **ONLY valid when the Phase 4f.0 gate passed (`Is_Storport_Duration_Reliable = true`).**
> If the gate showed `false` / 0, `Storport_Disk_Service_Time` reads 0 (not captured) and this
> method is **unusable** for that trace — you should already have skipped to Methods 2–4.
>
> **Why `Is_Storport_Duration_Reliable = false`?** The storport service time comes from the
> `Microsoft-Windows-StorPort` ETW provider (per-I/O begin/end timestamps at the miniport,
> closest to hardware). It is false when those events aren't captured/pairable:
> 1. **Profile missing the StorPort provider** — the basic `wpr -start DiskIO` / Kernel-Disk
>    profile does NOT include storport miniport timing. **Fix**: record with a WPRP that adds
>    `<EventProvider Id="Microsoft-Windows-StorPort"/>` (or a profile that enables Storport).
> 2. **Storport per-I/O timing gated off** — on some systems storport IO timing must be
>    enabled (registry/miniport support) before begin/end events are emitted.
> 3. **I/O path doesn't traverse a timeable storport miniport** — VSS snapshot (`volsnap`),
>    Storage Spaces, virtual/file-backed disks, or BitLocker (`fvevol`) paths may not emit
>    reliable storport durations regardless of profile.
> 4. **Running on a VM / virtual disk (most common in dev/test)** — if the guest disk is a
>    `Msft Virtual Disk` (Hy-V/Azure synthetic storage, `storvsc`/`vhdmp`, BusType SAS), the
>    **virtual miniport never fires `IOPerfNotification`**, so the StorPort provider emits
>    **0 events** and every I/O stays `Is_Storport_Duration_Reliable = false` with
>    `Storport_Disk_Service_Time = 0` — no matter how correct the profile is. Verify with
>    `Get-PhysicalDisk | Select FriendlyName, BusType`; if it says virtual, StorPort timing is
>    **unobtainable on that box — test on a physical machine** (prefer SATA/SAS `storahci`
>    over NVMe `stornvme`, since some NVMe drivers also skip it). To confirm the provider
>    produced nothing, query **Trace Statistics** / **Generic Events** for Provider GUID
>    `c4636a1e-7986-4646-bf10-7bc3b4a76e8e` — a count of 0 means it never fired.
> This only disables Method 1; Methods 2–4 still fully answer the filter-driver question.
>
> **✅ Verified: StorPort timing works on a physical SATA HDD (storahci).** On a physical
> Win11 box, an I/O trace that enabled the StorPort provider captured **29,331**
> `Microsoft-Windows-StorPort` events — including the per-I/O timing pairs
> `Port/Dispatch` (Id 0xca/0xcb) + `Port/Completion` (Id 0xd0) plus `Port/Queue` (0xdc) and
> `Isr/Completion` (0xf8). The Dispatch↔Completion pair is exactly what makes
> `Is_Storport_Duration_Reliable = true`. So a physical SATA/storahci path DOES emit
> IOPerfNotification — confirming the earlier all-zero results were caused by the VM virtual
> disk, NOT by the profile itself.
>
> **Recording — how to capture StorPort timing:**
>
> The built-in WPR `DiskIO` profile already enables the StorPort miniport provider with the
> correct keywords. On a **physical disk** this command yields
> `Is_Storport_Duration_Reliable = true` with no custom profile needed:
> ```cmd
> WPR.exe -start GeneralProfile -start CPU -start DiskIO -start FileIO -start Network -start minifilter
> REM ... reproduce the slow I/O (e.g. run BACKUP DATABASE) ...
> WPR.exe -stop C:\Temp\out.etl
> ```
> This was verified to capture **29,331** `Microsoft-Windows-StorPort` events (Port/Dispatch
> + Port/Completion timing pairs) and produce **1,344** reliable IOs.
>
> **Caveats:**
> - Stacking many built-in profiles can produce **time inversion** or `0x80004005` when
>   opening in WPA GUI. The **data is still valid** — open with `-tti`:
>   `wpa.exe -i out.etl -tti`, or verify without the GUI via
>   `xperf -i out.etl -tti -o stats.txt -a tracestats -detail` then grep for StorPort GUID
>   `c4636a1e-7986-4646-bf10-7bc3b4a76e8e`.
> - Requires a **physical disk** (SATA/SAS/storahci preferred). On a VM `Msft Virtual Disk`
>   (`storvsc`/`vhdmp`) the virtual miniport never fires `IOPerfNotification`, so
>   `Is_Storport_Duration_Reliable` stays `false` regardless of profile — test on a physical
>   box. Some NVMe (`stornvme`) drivers also skip it; storahci is most reliable.
> - Verify with `Get-PhysicalDisk | Select FriendlyName, BusType` — must NOT be a virtual
>   disk. To confirm provider produced events, query `Trace Statistics` / `Generic Events`
>   for Provider GUID `c4636a1e-...` — count 0 = never fired.

**Method 2 — `IO_Init_Stack` (which filters are in the issue path):**
Group by `IO_Init_Stack`; the frames enumerate the filter chain the I/O traverses
(`FLTMGR.SYS` minifilter manager → `fileinfo.sys` etc. → `volsnap` → `fvevol` BitLocker →
`iorate` → `rdyboost` → `partmgr`/`volmgr`). Shows the **path**, not per-filter latency.

**Method 3 — `IO_CSwitch_Stack` (where the thread blocked / completion path):**
Group by `IO_CSwitch_Stack`. Read the leaf:
- Leaf = `Ntfs.sys!NtfsWaitOnIo` (or similar device-wait) → thread is **waiting on the
  device**, filters are pass-through → **delay is NOT in a filter**, it's device/queue.
- Leaf stuck **inside a specific minifilter callback** (e.g. an AV/encryption filter's
  pre/post-op) → that **filter** is on the critical path; investigate it.

**Method 4 — `File I/O.Duration` − `Disk Usage.IO_Time`:**
The gap = file-system + minifilter overhead **above the volume layer**. If `File Dur ≈
Disk IO_Time` (gap ≈ 0) → minifilters added negligible delay. A large positive gap →
overhead is above the volume (file system / minifilter), not the device.

> 📋 For **dedicated per-minifilter latency numbers**, the Disk Usage table is not enough —
> re-record with the **Minifilter WPRP** (`Microsoft-Windows-FileInfoMinifilter` / FLT
> provider). WPA then exposes a "Minifilter Delays" view with per-filter timings.

**Verdict logic**: if Method 3 blocks at a device-wait and Method 4 gap ≈ 0, the latency
is **device + queue**, not a filter driver — even when Method 1 is unavailable.

**Optional — outlier files**: re-run Phase 3 query but sort by `AvgSvc` desc instead of
`Bytes` to surface low-volume but high-latency files.

## Phase 5 — By Disk / Volume (optional)

Goal: identify which physical disk is the bottleneck and whether files share a disk.

```
start_new_query(traceId, "Disk Usage", "Rows", "And")
add_condition    property=Process, operator=Equal, value="{target_process}"
add_grouping     property=Disk
add_aggregation  name=Bytes,  type=Sum,     property=Size
add_aggregation  name=IOs,    type=Sum,     property=Count
add_aggregation  name=AvgSvc, type=Average, property=Disk_Service_Time
perform_query    allowQueryingAllData=true
```

Flag any disk hosting **both** a hot `.mdf` and the `.ldf` — log and data contending on
the same spindle is a classic misconfiguration.

## Phase 6 — By Thread / Call Stack (optional — who issues the I/O)

The `Disk Usage` table **does** carry the issuing call stack (`IO_Init_Stack`), so I/O
attribution can stay in this table — no need to jump to the CPU table.

**By thread:**
```
start_new_query(traceId, "Disk Usage", "Rows", "And")
add_condition    property=Process, operator=Equal, value="{target_process}"
add_grouping     property=Thread_ID
add_aggregation  name=Bytes, type=Sum, property=Size
add_aggregation  name=IOs,   type=Sum, property=Count
perform_query    allowQueryingAllData=true
```

**By init call stack** (attribute I/O to a code path — checkpoint / log writer / read-ahead):
```
start_new_query(traceId, "Disk Usage", "Rows", "And")
add_condition    property=Process, operator=Equal, value="{target_process}"
add_grouping     property=IO_Init_Stack
add_aggregation  name=Bytes, type=Sum, property=Size
add_aggregation  name=IOs,   type=Sum, property=Count
perform_query    allowQueryingAllData=true
```

> ⚠️ **Parsing `IO_Init_Stack` (verified pitfall)**: in the result, the group key is
> **not** a plain string — it is an object `{"IO_Init_Stack": {"elements": "[Root]/frame1/frame2/.../leaf"}}`.
> Read `key.IO_Init_Stack.elements`, then split on `/`. The string is **leaf-last** but the
> final frames are ETW stack-walk noise (`ntoskrnl.exe!EtwpTraceStackWalk` etc.) — the
> meaningful leaf is the last `sqlmin.dll!` / `sqldk.dll!` frame, not the literal last frame.
> Filter frames to `sql*`/`hkengine` modules to surface the SQL Server code path.

Map heavy I/O threads/stacks back to SQL Server workers (checkpoint, lazy writer, log
writer, read-ahead, query worker). For deeper symbol resolution of the stack frames,
cross-check with `wpr-cpu-analysis`.

## Phase 7 — Cross-Reference with ERRORLOG / XEvent (if case_id provided)

If `case_id` is provided, read existing findings under `reports/<case_id>/` and correlate:

| WPR I/O finding | Expected XEvent / ERRORLOG signal |
|-----------------|-----------------------------------|
| High `.mdf` read latency | `PAGEIOLATCH_SH` / `PAGEIOLATCH_EX` waits |
| High `.ldf` write latency | `WRITELOG` waits, "I/O taking longer than 15 seconds" (ERRORLOG 833) |
| tempdb file hot | `PAGELATCH_*` on tempdb, spill warnings |
| Single disk saturated | "SQL Server has encountered N occurrences of I/O requests taking longer than 15 seconds" |

If a top latency finding matches a known wait, optionally route to `docs-lookup` for the
wait type / error number, and `source-search` for the issuing function.

---

## Output Format

All intermediate results must be presented as markdown tables inline in chat.

### Result Narrative Template

When reporting back to the user, structure the conclusion as:

1. **What was the perceived problem?** (e.g. "slow queries", "WRITELOG waits")
2. **Which file/disk dominates I/O?** (path, read vs write, MB, IOs)
3. **How slow is it?** (avg/max latency vs SQL Server thresholds)
4. **Root-cause hypothesis** (storage latency / log disk / data+log contention / buffer
   pool pressure)
5. **Cross-reference** (matching PAGEIOLATCH/WRITELOG waits if case_id given)
6. **Concrete recommendations** (move log to dedicated low-latency disk, add data files,
   investigate storage, etc.)

### Executive Summary (≤5 bullets)
- Dominant I/O file + type + volume
- Latency vs threshold verdict
- Disk-level contention (if any)
- SQL Server interpretation (which subsystem: checkpoint / log flush / reads)
- Recommended action

### Output Files (all must be generated)

| File | Purpose |
|------|---------|
| `reports/<process>-io-analysis.md` | Full I/O analysis report (Phase 2–7 + conclusion) |
| `reports/<process>-io-by-file.tsv` | Phase 3 per-file table (Path, Type, Bytes, IOs, AvgMs, SumMs) |

If `case_id` is provided, write reports under `reports/<case_id>/` instead.

---

## WPA MCP Gotchas (verified)

- Sum CPU-style metrics on numeric fields only: `Size` (Bytes), `Count` (Int32),
  `Disk_Service_Time` / `IO_Time` (TimestampDelta). String fields (`Process`,
  `Path_Name`, `IO_Type`) only support `Count` aggregation.
- Use `Disk_Service_Time` (TimestampDelta) for latency — Sum/Average/Max all work.
- `Size` is typed **Bytes** — convert to MB/GB for human-readable tables.
- Always **group** before aggregating; an ungrouped per-I/O query can be enormous.
- `Path_Name` matching: use `Contains` with the bare filename; or filter
  `File_Extension Equal "mdf"/"ndf"/"ldf"` to target SQL files directly.
- `IO_Init_Stack` carries the issuing call stack — group by it to attribute I/O to a
  SQL Server code path without leaving the Disk Usage table.
- `IO_Init_Stack` group key is an object `{elements: "[Root]/a/b/.../leaf"}` — read
  `.elements` and split on `/`; trailing frames are ETW stack-walk noise, so the real
  leaf is the last `sql*` frame.

## Reference — SQL Server I/O call-stack signatures (verified)

Recognize these `IO_Init_Stack` patterns to name the SQL subsystem issuing the I/O:

| Code path (leaf-ward frames) | Subsystem |
|------------------------------|-----------|
| `BackupOperation::CopyFileToBackupSet → BackupIoRequest::StartDatabaseRead → FCB::AsyncRead` | BACKUP — read data file |
| `BackupThread::ThreadBase → BackupStream::DoFileBackup → BackupMedium::WriteDataStream → BackupIoRequest::StartDirectWrite` | BACKUP — write `.bak` |
| `BackupStream::DoLogicalLogBackup → BackupLogMediaWriter::WriteVLogData` | BACKUP — log tail |
| `BackupFile::Close → RequestDurableMedia → FlushFileBuffers` | BACKUP — final flush |
| `AsynchronousDiskWorker::ThreadRoutine → AsynchronousDiskPool::ProcessActions` | async I/O pool worker |
