---
name: xevent-analysis
description: >-
  Parse SQL Server system_health XEvent (.xel) files to extract waits, errors,
  scheduler pressure, and sp_server_diagnostics alerts. Cross-correlate with ERRORLOG
  findings. Use when the user says "analyze xevent", "parse xel", "分析 XEvent",
  provides .xel file paths, or when system_health*.xel files are found alongside ERRORLOG.
context: fork
---

# XEvent Analysis (system_health)

## Overview

Two analysis paths are available. Choose based on environment:

| Path | Method | Speed | When to use |
|------|--------|-------|-------------|
| **A — SQL Server import** | `fn_xe_file_target_read_file` → physical tables → T-SQL queries | **Seconds** (200 MB XEL → ~30s) | Local SQL Server available (`sqlcmd`) |
| **B — PowerShell + Node.js** | `extract_xel.ps1` → JSON → `parse_xevent.js` | **Minutes** (200 MB XEL → 5-15 min) | No local SQL Server |

**Always prefer Path A** when a SQL Server instance is accessible.

## Step 0: Check Inputs

1. Detect XEL session type by filename:
   - `system_health*.xel` → system_health (default, richest data)
   - `AlwaysOn_health*.xel` → AG health session
   - `*SQLDIAG*.xel` → sqldiag / component_health (different event names — see Known Limitations)
   - Other `*.xel` → custom session

2. Determine if a local SQL Server is available:
   - Test `sqlcmd -S localhost -E -Q "SELECT 1"`
   - If yes → Path A. If no → Path B.

---

## Path A: SQL Server Import (Recommended)

### A.1 Run Import Script

```
scripts/import_xel_to_sql.sql
```

The script creates database `[xevent_analyze]` with schema `[xe]` and these physical tables:

| Table | Contents | Key columns |
|-------|----------|-------------|
| `xe.raw_events` | All events with full XML | `case_id`, `event_name`, `event_time`, `event_data` (XML) |
| `xe.errors` | Shredded `error_reported` | `error_number`, `severity`, `state`, `message`, `database_name`, `session_id` |
| `xe.waits` | Shredded `wait_info` / `wait_info_external` | `wait_type`, `duration_ms`, `signal_duration_ms`, `wait_resource` |
| `xe.diagnostics` | Shredded `sp_server_diagnostics_component_result` | `component`, `state_desc`, `data_xml` |
| `xe.scheduler` | Shredded `scheduler_monitor_*` | `sql_cpu_pct`, `system_idle_pct`, `nonyielding_count` |
| `xe.deadlocks` | Shredded `xml_deadlock_report` | `deadlock_xml` |
| `xe.connectivity` | Shredded `connectivity_ring_buffer_recorded` | `error_code`, `conn_type` |

**Usage:**
```bash
# Edit @xel_path, @days, @case_id at top of script, then:
sqlcmd -S localhost -E -i scripts/import_xel_to_sql.sql
```

Configuration variables (lines 27-29 of script):
```sql
DECLARE @xel_path NVARCHAR(500) = N'C:\Temp\system_health_0_*.xel';
DECLARE @days INT = 7;      -- 0 = all data
DECLARE @case_id NVARCHAR(50) = N'{case_id}';
```

The script is **idempotent** — re-running with the same `case_id` deletes old rows first.
Multiple cases can coexist in the same database (filtered by `case_id`).

### ⚠ CRITICAL: UTC → Local Time Conversion (During Analysis)

XEL files store `@timestamp` in **UTC**. ERRORLOG uses **source SQL Server local time**.
The import script stores timestamps **as-is in UTC**. You MUST convert to the source
server's local time **during analysis queries** to align with ERRORLOG.

**How to determine the offset:**
1. Check the source server's timezone from ERRORLOG server info or `SELECT SYSDATETIMEOFFSET()`.
2. Common offsets: China (UTC+8), US Eastern (UTC-5/-4), US Pacific (UTC-8/-7).
3. If unknown, compare a known event that appears in both ERRORLOG and XEL to calculate the delta.

**Apply offset in every analysis query:**
```sql
-- Example: source server is UTC+8 (China)
SELECT DATEADD(HOUR, 8, event_time) AS local_time, ...
FROM xe.errors WHERE ...

-- Or create a view for convenience:
CREATE OR ALTER VIEW xe.v_errors AS
SELECT *, DATEADD(HOUR, 8, event_time) AS local_time FROM xe.errors;
```

**Never compare raw XEL UTC timestamps directly with ERRORLOG local times.**
Always apply the offset first, or you will get wrong cross-correlation results.

### A.2 Run Analysis Queries

After import, query via `sqlcmd`. Since database is per-case (`[xevent_{case_id}]`),
use `-d xevent_{case_id}` or `USE [xevent_{case_id}]` — no three-part names needed.

**Top errors:**
```sql
SELECT error_number, severity, COUNT(*) AS cnt,
       MIN(event_time) AS first_seen, MAX(event_time) AS last_seen
FROM xe.errors WHERE case_id = '{case_id}'
GROUP BY error_number, severity ORDER BY cnt DESC
```

**Top waits by total duration:**
```sql
SELECT wait_type, COUNT(*) AS cnt,
       SUM(duration_ms) AS total_ms, AVG(duration_ms) AS avg_ms, MAX(duration_ms) AS max_ms,
       SUM(signal_duration_ms) AS total_signal_ms
FROM xe.waits WHERE case_id = '{case_id}'
GROUP BY wait_type ORDER BY total_ms DESC
```

**sp_server_diagnostics WARNING/ERROR states:**
```sql
SELECT component, state_desc, COUNT(*) AS cnt,
       MIN(event_time) AS first_seen, MAX(event_time) AS last_seen
FROM xe.diagnostics
WHERE case_id = '{case_id}' AND state_desc IN ('warning','error')
GROUP BY component, state_desc ORDER BY cnt DESC
```

**Non-yielding and high-CPU scheduler events:**
```sql
SELECT event_name, event_time, sql_cpu_pct, system_idle_pct, scheduler_id, nonyielding_count
FROM xe.scheduler
WHERE case_id = '{case_id}'
  AND (event_name LIKE '%non_yielding%' OR sql_cpu_pct > 75 OR nonyielding_count > 0)
ORDER BY event_time
```

**Deadlocks:**
```sql
SELECT event_time, deadlock_xml FROM xe.deadlocks
WHERE case_id = '{case_id}' ORDER BY event_time
```

**Connectivity summary:**
```sql
SELECT error_code, conn_type, COUNT(*) AS cnt
FROM xe.connectivity WHERE case_id = '{case_id}'
GROUP BY error_code, conn_type ORDER BY cnt DESC
```

**Ad-hoc: shred any event from raw XML** (example — `security_error_ring_buffer_recorded`):
```sql
SELECT event_time,
       event_data.value('(event/data[@name="error_code"]/value)[1]', 'int') AS error_code,
       event_data.value('(event/data[@name="api_name"]/value)[1]', 'nvarchar(100)') AS api_name
FROM xe.raw_events
WHERE case_id = '{case_id}' AND event_name = 'security_error_ring_buffer_recorded'
ORDER BY event_time DESC
```

### A.3 Interpret Results

#### Wait Analysis — Red Flag Thresholds

See full reference: [.github/references/wait-types.md](../../references/wait-types.md) for benign/ignorable waits and the decision tree.

| Wait type | Red flag | Root cause |
|-----------|----------|-----------|
| `RESOURCE_SEMAPHORE` | avg > 5000 ms or any occurrence | Queries waiting for memory grant — server memory pressure |
| `LATCH_EX` / `LATCH_SH` | total > 10M ms | Non-buffer latch contention (ACCESS_METHODS_*, HOBT, etc.) |
| `LCK_M_*` | max > 60000 ms | Long lock waits — blocking chains |
| `PAGEIOLATCH_*` | avg > 15 ms | Storage I/O latency |
| `ASYNC_IO_COMPLETION` | max > 60000 ms | Severe storage stall |
| `WRITELOG` | avg > 5 ms | Transaction log write latency |
| `THREADPOOL` | any occurrence | Worker thread exhaustion |
| `PREEMPTIVE_OS_*` | avg > 5000 ms | External OS calls slow (AD, file system, etc.) |

#### sp_server_diagnostics States

| State | Meaning |
|-------|---------|
| clean | Healthy |
| warning | Component under pressure — **investigate** |
| error | Component failing — **critical, usually triggers AG failover** |

#### Non-yielding Scheduler Events

- Non-yielding with **low CPU** (< 30%) → thread stuck on I/O, latch, or memory grant (not CPU starvation)
- Non-yielding with **high CPU** (> 75%) → CPU starvation, runaway query, or spinlock contention
- **Multiple non-yielding in a short window** (< 5 min) → severe systemic issue

---

## Analysis Methodology (Path A)

After importing data to `[xevent_analyze].[xe].*`, follow this structured analysis path.

### Phase 1: Overview — What event types exist and how many?

```sql
SELECT event_name, COUNT(*) AS cnt FROM xe.raw_events
WHERE case_id = '{case_id}' GROUP BY event_name ORDER BY cnt DESC
```

This tells you which tables will have data and which will be empty.
If `security_error_ring_buffer_recorded` or `memory_broker_ring_buffer_recorded`
dominate, they may be the key signal (not just noise).

### Phase 2: Per-Table Analysis

Analyze each shredded table in this order (highest signal first):

#### 2.1 xe.errors — Error Landscape

```sql
-- Top errors by count
SELECT error_number, severity, COUNT(*) AS cnt,
       MIN(event_time) AS first_seen, MAX(event_time) AS last_seen
FROM xe.errors WHERE case_id = '{case_id}'
GROUP BY error_number, severity ORDER BY cnt DESC

-- Hourly distribution (baseline vs event?)
SELECT CAST(event_time AS DATE) AS day, DATEPART(HOUR, event_time) AS hr,
       COUNT(*) AS cnt, SUM(CASE WHEN severity >= 20 THEN 1 ELSE 0 END) AS fatal
FROM xe.errors WHERE case_id = '{case_id}'
GROUP BY CAST(event_time AS DATE), DATEPART(HOUR, event_time) ORDER BY day, hr
```

**Look for:** Is error rate constant (baseline problem) or spiking at specific hours (event-driven)?

#### 2.2 xe.waits — Wait Profile

```sql
-- Top waits by total duration (NOT by count)
SELECT wait_type, COUNT(*) AS cnt,
       SUM(duration_ms) AS total_ms, AVG(duration_ms) AS avg_ms,
       MAX(duration_ms) AS max_ms, SUM(signal_duration_ms) AS total_signal_ms
FROM xe.waits WHERE case_id = '{case_id}'
GROUP BY wait_type ORDER BY total_ms DESC

-- Hourly pattern for top wait type
SELECT CAST(event_time AS DATE) AS day, DATEPART(HOUR, event_time) AS hr,
       COUNT(*) AS cnt, SUM(duration_ms) AS total_ms
FROM xe.waits WHERE case_id = '{case_id}' AND wait_type = '{top_wait}'
GROUP BY CAST(event_time AS DATE), DATEPART(HOUR, event_time) ORDER BY day, hr

-- Per-session distribution (1 big query or many concurrent?)
SELECT session_id, COUNT(*) AS cnt, SUM(duration_ms) AS total_ms,
       AVG(duration_ms) AS avg_ms, MAX(duration_ms) AS max_ms
FROM xe.waits WHERE case_id = '{case_id}' AND wait_type = '{top_wait}'
GROUP BY session_id ORDER BY total_ms DESC
```

**Look for:**
- Total duration matters more than count (1 wait of 1M ms > 1000 waits of 100 ms)
- signal_duration_ms / total_ms ratio — if signal is high proportion, CPU scheduling is slow
- Hourly spikes vs flat → periodic job vs persistent issue
- Session distribution → 1-2 sessions = single bad query; 20+ sessions = systemic pressure

#### 2.3 xe.diagnostics — Health State + Embedded Data

```sql
-- State distribution
SELECT component, state_desc, COUNT(*) AS cnt,
       MIN(event_time) AS first_seen, MAX(event_time) AS last_seen
FROM xe.diagnostics WHERE case_id = '{case_id}'
GROUP BY component, state_desc ORDER BY component, state_desc

-- WARNING/ERROR records with data_xml
SELECT event_time, component, state_desc, LEFT(data_xml, 3000) AS data_preview
FROM xe.diagnostics
WHERE case_id = '{case_id}' AND state_desc IN ('warning','error')
ORDER BY event_time
```

**For QUERY_PROCESSING WARNING:** The `data_xml` contains `<blockingTasks>` with actual
SQL text of blocking queries. This is direct evidence of what's causing pressure.

**For RESOURCE WARNING:** See Memory Verification below.

**For SYSTEM WARNING:** Check timing — if it starts *after* an AG failure, it's a symptom, not a cause.

#### 2.4 xe.scheduler — CPU and Non-Yielding

```sql
SELECT event_name, event_time, sql_cpu_pct, system_idle_pct, nonyielding_count
FROM xe.scheduler
WHERE case_id = '{case_id}'
  AND (event_name LIKE '%non_yielding%' OR sql_cpu_pct > 75 OR nonyielding_count > 0)
ORDER BY event_time

-- Hourly CPU trend
SELECT CAST(event_time AS DATE) AS day, DATEPART(HOUR, event_time) AS hr,
       AVG(sql_cpu_pct) AS avg_cpu, MAX(sql_cpu_pct) AS max_cpu,
       SUM(CASE WHEN event_name LIKE '%non_yielding%' THEN 1 ELSE 0 END) AS ny_cnt
FROM xe.scheduler WHERE case_id = '{case_id}'
GROUP BY CAST(event_time AS DATE), DATEPART(HOUR, event_time) ORDER BY day, hr
```

**Look for:** Non-yielding events with low CPU → thread stuck (I/O, memory grant, latch), not CPU starvation.

#### 2.5 xe.connectivity — Connection Errors

```sql
-- Error pattern
SELECT sni_consumer_error, os_error, conn_type, tds_flags, COUNT(*) AS cnt
FROM xe.connectivity WHERE case_id = '{case_id}'
GROUP BY sni_consumer_error, os_error, conn_type, tds_flags ORDER BY cnt DESC

-- Top source IPs
SELECT remote_host, COUNT(*) AS cnt,
       MIN(event_time) AS first_seen, MAX(event_time) AS last_seen
FROM xe.connectivity WHERE case_id = '{case_id}' AND sni_consumer_error > 0
GROUP BY remote_host ORDER BY cnt DESC
```

**Look for:**
- `os_error = 10054` (connection reset by peer) → network/client issue
- `os_error = 10060` (connection timeout) → network latency
- `os_error = 109` (pipe ended) → named pipe disconnect
- Concentrated on 1-2 IPs → client-specific problem; many IPs → server-side cause

#### 2.6 xe.security_errors — Security API Failures

```sql
SELECT error_code, api_name, calling_api, COUNT(*) AS cnt
FROM xe.security_errors WHERE case_id = '{case_id}'
GROUP BY error_code, api_name, calling_api ORDER BY cnt DESC
```

**⚠️ CRITICAL: Always verify error_code meaning before assuming OOM:**
```powershell
[ComponentModel.Win32Exception]::new(<error_code>).Message
```

Common error codes in this table:
| error_code | Actual meaning | NOT |
|------------|---------------|-----|
| 5023 | `ERROR_INVALID_STATE` — resource not in correct state | ~~ERROR_OUTOFMEMORY~~ |
| 1332 | `ERROR_NO_SUCH_MEMBER` — AD account/group not found | — |
| 0x8009030C | `SEC_E_LOGON_DENIED` — SSPI logon denied | — |
| 0x80090301 | `SEC_E_INSUFFICIENT_MEMORY` — **this one IS memory** | — |

#### 2.7 xe.memory_broker — Memory Trend

```sql
SELECT CAST(event_time AS DATE) AS day, DATEPART(HOUR, event_time) AS hr,
       AVG(memory_ratio) AS avg_ratio, MIN(memory_ratio) AS min_ratio, COUNT(*) AS samples
FROM xe.memory_broker WHERE case_id = '{case_id}'
GROUP BY CAST(event_time AS DATE), DATEPART(HOUR, event_time)
HAVING MIN(memory_ratio) < 90 ORDER BY day, hr
```

**Look for:** Periodic dips in memory_ratio correlating with RESOURCE_SEMAPHORE spikes.

#### 2.8 xe.ag_events — AG State Changes (if sqldiag imported)

```sql
SELECT event_name, event_time, ag_name, reason, target_state, failure_condition
FROM xe.ag_events WHERE case_id = '{case_id}' ORDER BY event_time
```

**Look for:** `reason = LEASEEXPIRED` → AG lease worker couldn't be scheduled in time.

### Phase 3: Memory Verification (RESOURCE WARNING Deep-Dive)

When `xe.diagnostics` shows RESOURCE WARNING, extract the embedded memory report
from `xe.raw_events` XML to verify whether real OOM occurred.

**Step 1 — Extract memory report:**
```sql
SELECT event_time,
    event_data.value('(event/data[@name="data"]/value/resource/@lastNotification)[1]', 'nvarchar(50)') AS last_notification,
    event_data.value('(event/data[@name="data"]/value/resource/@outOfMemoryExceptions)[1]', 'int') AS oom_exceptions,
    event_data.value('(event/data[@name="data"]/value/resource/@isAnyPoolOutOfMemory)[1]', 'int') AS pool_oom,
    event_data.value('(event/data[@name="data"]/value/resource/@processOutOfMemoryPeriod)[1]', 'int') AS oom_period
FROM xe.raw_events
WHERE case_id = '{case_id}' AND event_name LIKE '%diagnostics_component_result'
  AND event_data.value('(event/data[@name="component"]/text)[1]', 'nvarchar(50)') = 'RESOURCE'
  AND event_data.value('(event/data[@name="state"]/text)[1]', 'nvarchar(20)') = 'WARNING'
ORDER BY event_time
```

If XPath extraction returns NULL (sqldiag uses `/value` instead of `/text`), read full XML:
```sql
SELECT event_time, CAST(event_data AS NVARCHAR(MAX)) AS full_xml
FROM xe.raw_events
WHERE case_id = '{case_id}' AND event_name = 'component_health_result'
  AND event_data.value('(event/data[@name="component"]/value)[1]', 'nvarchar(50)') = 'resource'
  AND event_data.value('(event/data[@name="state_desc"]/value)[1]', 'nvarchar(20)') = 'warning'
ORDER BY event_time ASC
```

**Step 2 — Verify: OS-level or SQL-level pressure?**

| Indicator | Value=1 means | Check |
|-----------|--------------|-------|
| `System physical memory low` | OS has low physical memory | OS-level problem |
| `System physical memory high` | OS has plenty of memory | OS is fine |
| `Process physical memory low` | SQL Server **process** sees low memory | SQL-internal pressure |
| `Process virtual memory low` | VA space low (rare on 64-bit) | Usually not relevant |

**Step 3 — Verify: SQL Server internal state**

| Indicator | What to check |
|-----------|--------------|
| `Target Committed` vs `Current Committed` | Equal → SQL used all of max server memory |
| `Locked Pages Allocated` | Large value → LPIM in use |
| `Pages Free` | Trend over time: declining → pressure worsening |
| `Available Physical Memory` | OS-level free — if large but Process low=1 → SQL hogging |

**Step 4 — Verify: Did actual OOM happen?**

| Indicator | If 0 | If > 0 |
|-----------|------|--------|
| `outOfMemoryExceptions` | No actual OOM in SQL process | Confirmed OOM |
| `isAnyPoolOutOfMemory` | No pool exhausted | A memory pool ran out |
| `processOutOfMemoryPeriod` | Not in OOM state | Duration of OOM state |
| `Last OOM Factor` | No recent OOM | OOM occurred (check factor value) |

**Step 5 — Decision:**
```
outOfMemoryExceptions = 0 AND isAnyPoolOutOfMemory = 0?
├── YES → Memory pressure exists but NO actual OOM failure
│   └── Look for RESOURCE_SEMAPHORE waits as the real symptom of memory pressure
└── NO  → Confirmed OOM
    └── Check which clerk/pool ran out, check max server memory vs physical RAM
```

**⚠️ Common Pitfall:** Do NOT assume `lastNotification = RESOURCE_MEMPHYSICAL_LOW`
means "out of memory". It means the memory broker detected pressure, but the OOM
counters tell you whether allocations actually **failed**. Also verify any
`security_error` error codes — they may not be OOM-related (e.g. 5023 = invalid state).

### Phase 4: Time-Axis Cross-Correlation

Overlay all event types on the same hourly time axis:

```sql
SELECT day, hr,
       MAX(rs_cnt) AS resource_sem, MAX(err_cnt) AS errors,
       MAX(conn_cnt) AS conn_errors, MAX(sec_cnt) AS sec_errors,
       MAX(avg_cpu) AS avg_cpu, MAX(ny_cnt) AS non_yielding,
       MAX(warn_cnt) AS diag_warnings, MAX(min_ratio) AS mem_ratio_min
FROM (
    SELECT CAST(event_time AS DATE) day, DATEPART(HOUR,event_time) hr,
           COUNT(*) rs_cnt, NULL err_cnt, NULL conn_cnt, NULL sec_cnt,
           NULL avg_cpu, NULL ny_cnt, NULL warn_cnt, NULL min_ratio
    FROM xe.waits WHERE case_id='{case_id}' AND wait_type='RESOURCE_SEMAPHORE'
    GROUP BY CAST(event_time AS DATE), DATEPART(HOUR,event_time)
    UNION ALL
    SELECT CAST(event_time AS DATE), DATEPART(HOUR,event_time),
           NULL, COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL
    FROM xe.errors WHERE case_id='{case_id}'
    GROUP BY CAST(event_time AS DATE), DATEPART(HOUR,event_time)
    -- ... add more UNION ALL for each table
) x GROUP BY day, hr ORDER BY day, hr
```

**Look for:**
- Patterns that **correlate** in time → likely same root cause
- Patterns that are **constant** while others spike → independent baseline issue
- Events that start **after** a failure → symptoms, not causes

### Phase 5: Causal Chain Construction

Work **backwards** from the final symptom:

```
1. What was the final symptom? (e.g. AG LEASEEXPIRED)
2. What could cause lease expiry? → Lease worker not scheduled
3. What blocks scheduling? → Non-yielding? CPU starvation? Memory grant wait?
4. Is there evidence of that blocker? → Check xe.scheduler, xe.waits
5. What caused the blocker? → Check xe.diagnostics data_xml for blocking queries
6. Is it periodic or constant? → Check hourly distribution
7. Are there independent baseline issues? → Check constant-rate events separately
```

**For each conclusion, record:**
- **Evidence source** (which table, which query)
- **Strength**: ✅ Direct evidence / ⚠️ Inference / ❌ Assumption
- If inference, note what data would confirm or refute it

---

## Path B: PowerShell + Node.js (Fallback)

Use when no local SQL Server is available.

### B.1 Extract XEL → JSON (PowerShell)

```
scripts/extract_xel.ps1
```

Supports `-EventName` filter to skip irrelevant events (major performance improvement):

```bash
# Filtered extraction (recommended — 3-5x faster)
powershell -File scripts/extract_xel.ps1 `
  -Path "C:\Temp\system_health*.xel" `
  -Days 7 `
  -EventName error_reported,wait_info,wait_info_external,sp_server_diagnostics_component_result,scheduler_monitor_system_health_ring_buffer_recorded,scheduler_monitor_non_yielding_ring_buffer_recorded,xml_deadlock_report,connectivity_ring_buffer_recorded `
  -Output reports/{case_id}_xevent_extract.json

# Unfiltered (all events — slower, larger JSON)
powershell -File scripts/extract_xel.ps1 -Path "*.xel" -Days 7 -Output reports/{case_id}_xevent_extract.json
```

**Note on `-EventName`:** When invoked via `powershell -File`, comma-separated values
are passed as a single string. The script splits on commas internally — this is by design.

### B.2 Analyze XEvent JSON (Node.js)

```
scripts/parse_xevent.js
```

```bash
# With ERRORLOG cross-correlation
node scripts/parse_xevent.js reports/{case_id}_xevent_extract.json \
  --errorlog reports/{case_id}_errorlog_findings.json \
  --json --output reports/{case_id}_xevent_findings.json
```

Output JSON contains: `errors`, `wait_analysis`, `scheduler_events`, `deadlocks`,
`patterns`, `timeline`, `correlation`.

### B.3 Cross-Correlation

The `--errorlog` flag produces:
- **errors_in_both** — confirmed by two independent sources (high confidence)
- **xevent_only_errors** — may be lower severity or suppressed from ERRORLOG
- **errorlog_only_errors** — not captured by XEvent session configuration

---

## Known Limitations

### sqldiag / component_health sessions

Sessions named `*SQLDIAG*` or `*hadr_health*` use different event names than
`system_health`. Notably:
- `component_health_result` instead of `sp_server_diagnostics_component_result`
- No `error_reported`, `wait_info`, `scheduler_monitor_*` events
- Rich data (topWaits, blockingTasks, AG state) is embedded as **XML inside the
  `data` field** of `component_health_result` events

For these sessions:
1. Path A with `xe.raw_events` is superior — you can write custom XQuery to shred
   the embedded XML
2. Path B's `parse_xevent.js` will return empty results for waits/errors/scheduler
   (parser does not parse embedded XML payloads)

### Event name inventory

Before filtering, discover what events exist in the XEL:
```sql
-- Path A
SELECT event_name, COUNT(*) AS cnt FROM xe.raw_events
WHERE case_id = '{case_id}' GROUP BY event_name ORDER BY cnt DESC
```
```bash
# Path B (quick sample)
powershell -Command "Import-Module SqlServer; Read-SqlXEvent -FileName 'file.xel' | Select-Object -First 500 | Group-Object Name | Sort-Object Count -Descending | Select-Object Name, Count"
```

---

## Auto-Detect XEL Files

When the user provides an ERRORLOG directory, automatically probe for:
```
{errorlog_dir}/system_health*.xel
{errorlog_dir}/AlwaysOn_health*.xel
{errorlog_dir}/*SQLDIAG*.xel
```
If found, inform the user and include in analysis.

---

## Output to Orchestrator

When called from the `sql-csi` full-analysis pipeline, return:

1. **Absolute paths** of output files (JSON findings, or note that data is in `[xevent_analyze]` database)
2. **Top errors** with cross-correlation flags
3. **Top waits** by total duration with red-flag annotations
4. **sp_server_diagnostics** WARNING/ERROR summary
5. **Non-yielding** event count + cluster timestamps
6. **Deadlock** count
7. **Anomalies** (session type mismatch, empty event categories, etc.)

