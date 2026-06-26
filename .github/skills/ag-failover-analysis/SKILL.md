---
name: ag-failover-analysis
description: >-
  Analyze AG failover events by cross-referencing AlwaysOn.OUT, ERRORLOG, and
  AlwaysOn_health XEvent data. Classifies each database into one of three
  categories based on where it got stuck in the DatabaseSwitchRoles pipeline.
  Use when databases are stuck in RESOLVING after AG failover, or when the user
  says "analyze AG failover", "AG databases stuck", "分析 AG failover".
context: fork
---

# AG Failover Analysis

## Overview

After an AG failover, each database independently executes `DatabaseSwitchRoles` to
transition roles (e.g. PRIMARY → RESOLVING → SECONDARY). The AG layer dispatches all
databases in parallel via a thread pool — one database getting stuck does NOT block others.

This skill cross-references three data sources to:
1. Build a per-database comparison table showing transition progress
2. **Classify each stuck database** into a diagnostic category (see §5)
3. **Map ERRORLOG evidence to source code steps** to pinpoint where each DB is blocked

## Source Code Reference — `DatabaseSwitchRoles` Pipeline

Understanding this pipeline is essential. Every ERRORLOG message maps to a specific step:

```
DatabaseSwitchRoles(HADR_ROLE_RESOLVING)     [HadrDbMgrApi.cpp]
│
├─ Step 1-5:   Internal locks, state checks
├─ Step 6:     ★ ERRORLOG "is changing roles from PRIMARY to RESOLVING"
│              (printed BEFORE any real work — NOT a progress indicator)
├─ Step 7-10:  Hekaton prep, set sub-manager target states
│
├─ Step 11:    m_userMgr.Stop(Immediate)     ← CAN BLOCK
├─ Step 12:    m_scanMgr.Stop(Immediate)     ← CAN BLOCK
├─ Step 13:    m_redoMgr.Stop(Clean)         ← CAN BLOCK
├─ Step 14-15: m_fullTextMgr / m_filestreamMgr Stop
│
├─ Step 16-19: Signal undo, reset quorum, close XEvent/Broker
├─ Step 20:    StopDtcForDb() — release DTC resource manager
│              (ERRORLOG: "MS DTC resource manager [db] has been released")
│
├─ Step 21:    ★★★ AcquireXDbLockWithKill(INFINITE) ★★★
│              [HadrDbMgrControl.cpp]
│              do {
│                lck_KillSpecificOwners()     → kill all sessions
│                CleanupDTCXact()             → clean DTC transactions
│                Acquire(LCK_M_X)            → try exclusive DB lock
│                if TIMEDOUT → print Error 35299 "Nonqualified...100%"
│              } while (true)                ← INFINITE timeout = never exits
│
├─ Step 22-23: Release DTC states, deregister transport
├─ Step 24:    SetRole(HADR_ROLE_RESOLVING)  ← role actually changes here
└─ Step 25:    CleanupPartners()
```

After Step 24 completes → RESOLVING→SECONDARY → Starting up → Reverting → Resync.

### Why Error 35299 Reports "100%" But Never Completes

`lck_GetRollBackProgress()` [lckmgr.cpp] only checks tasks marked `FKill()`.
System threads (Ghost cleanup, QDS, Checkpoint) are **never marked FKill** →
they are skipped → progress starts at 100% and stays at 100%.
But these system threads still hold shared DB locks → `Acquire(LCK_M_X)` times out → infinite loop.

## Required Inputs

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `case_dir` | string | **Yes** | Directory containing collected logs (see Phase 0) |
| `investigation_time` | string | No | Specific time to focus on (server local time, `YYYY-MM-DD HH:MM`) |
| `case_id` | string | No | Case identifier for output naming. Default: directory name |

## Workflow

### Phase 0: Log Collection Checklist

Before analysis can begin, collect the following information and logs.

#### Step 0: Ask the User for Environment Info

Prompt the user for:

| Item | Example | Why |
|------|---------|-----|
| **Old primary hostname** | `HKAZEPWDB0031` | The node that was PRIMARY before failover (now stuck in RESOLVING) |
| **New primary hostname** | `HKAZEPWDB0011` | The node that took over as PRIMARY |
| **Log file path(s)** | `D:\Cases\2605110030000091\` | Local path where logs are stored or will be downloaded |
| **Incident time** | `2026-05-11 07:53` (server local) | Approximate time of the failover event |

These are needed to correctly identify which ERRORLOG belongs to which replica
and to set the investigation time window.

#### Must Have (Minimum) — From Old Primary

| # | Data | Source | How to Collect |
|---|------|--------|----------------|
| 1 | **ERRORLOG** (current + .1) | SQL Server | Copy from ERRORLOG path (`SELECT SERVERPROPERTY('ErrorLogFileName')`) |
| 2 | **AlwaysOn.OUT** | SQLDIAG / Pssdiag | Usually in SQLDIAG output; contains AG/DB/replica mapping |
| 3 | **AlwaysOn_health XEL** | SQL Server | Default session; copy from `LOG\` folder next to ERRORLOG |

#### Strongly Recommended

| # | Data | Source | Why |
|---|------|--------|-----|
| 4 | **New primary ERRORLOG** | Partner replica | Compare DTC RM GUIDs, confirm new primary recovered successfully → proves issue is isolated to old primary |
| 5 | **system_health XEL** | SQL Server | `wait_info`, `scheduler_monitor`, `sp_server_diagnostics` during stuck period |
| 6 | **Windows Cluster log (BOTH nodes)** | `Get-ClusterLog` on each node | WSFC heartbeat/communication failure details (Error 1722 etc.). Required by `cluster-review` if the trigger is a cluster error — collect from **both** nodes. |
| 6b | **Cluster registry hive** | `%SystemRoot%\Cluster\CLUSDB` or a collected `*_reg_Cluster.hiv` | Authoritative quorum/vote-weight/witness/fault-domain config. Needed by `cluster-review` Phase 2 to prove a config root cause. |

#### If Issue Is Still Active (Not Yet Restarted)

| # | Data | Source | Why |
|---|------|--------|-----|
| 7 | **Memory dump** | `DBCC STACKDUMP WITH NO_CHANGE_TRACKING;` | **Critical** — thread call stacks reveal exact deadlock chain. This is the ONLY way to confirm root cause. Collect BEFORE restart (adds zero extra downtime since restart is already required). |
| 8 | **DMV snapshot** | T-SQL | `sys.dm_exec_requests`, `sys.dm_tran_locks`, `sys.dm_os_waiting_tasks` for stuck SPIDs |

#### File Naming Conventions

| Pattern | Description |
|---------|-------------|
| `*_AlwaysOn.OUT` | AlwaysOn diagnostic output |
| `ERRORLOG`, `ERRORLOG.1`, ... | SQL Server error logs |
| `*AlwaysOn_health*.xel` | AlwaysOn health session XEvent files |
| `system_health*.xel` | System health session XEvent files |

If logs arrive as `.zip`, extract to `case_dir` before starting Phase 1.

### Phase 1: Parse AlwaysOn.OUT — Build AG → DB Mapping

1. Locate `*_MSSQLSERVER_1033_AlwaysOn.OUT` files in both replica subdirectories:
   - `{case_dir}/{old_primary_host}/` (e.g. `HKAZEPWDB0031/`)
   - `{case_dir}/{new_primary_host}/` (e.g. `HKAZEPWDB0011/`)

   Use the old primary's AlwaysOn.OUT as the primary source (it has the pre-failover
   database_id mapping). The new primary's can be used for cross-validation.

2. Handle encoding — file may be UTF-16LE with BOM or UTF-8.

3. The file contains several sections delimited by `===` header lines. The key sections
   are formatted as SQL Server fixed-width DMV output (column headers + `---` separator + data rows).

#### Section 1: AG State — `AlwaysOn Availability Group State, Identification and Configuration`

Parse the fixed-width table to extract:

| Column | Description |
|--------|-------------|
| `availability_group` | AG name (e.g. `sybasehk-prod-intl-ag`) |
| `group_id` | AG group GUID |
| `primary_replica` | Current primary replica name (post-failover snapshot) |

#### Section 2: Replica State — `AlwaysOn Availability Replica State, Identification and Configuration`

Parse to identify replicas and their roles:

| Column | Description |
|--------|-------------|
| `group_name` | AG name |
| `replica_server_name` | Replica hostname |
| `is_local` | 1 = this node |
| `role_desc` | Current role (PRIMARY / SECONDARY / RESOLVING) |
| `availability_mode_Desc` | SYNCHRONOUS_COMMIT / ASYNCHRONOUS_COMMIT |
| `failover_mode_desc` | AUTOMATIC / MANUAL |
| `replica_id` | Replica GUID |
| `group_id` | AG group GUID |

#### Section 3: Database State — `AlwaysOn Availability Database Identification, Configuration, State and Performance`

Parse to build the AG → DB mapping:

| Column | Description |
|--------|-------------|
| `database_name` | Database name |
| `database_id` | Database ID (needed to match ABORT_AFTER_WAIT messages) |
| `group_id` | AG group GUID (join key to AG State) |
| `replica_id` | Replica GUID |
| `is_local` | 1 = this replica |
| `synchronization_state_desc` | SYNCHRONIZED / NOT SYNCHRONIZING / etc. |
| `database_state_desc` | ONLINE / RECOVERY_PENDING / etc. |

#### Parsing Fixed-Width Format

The AlwaysOn.OUT uses SQL Server's fixed-width output format:
```
column_1                       column_2    column_3
------------------------------ ----------- ------------------------------------
value_1                                  5 B148AAAF-0CDB-4802-B716-CF85B09BF8A0
```

**Parsing approach:**
1. Find the `---` separator line below the header
2. Use the dash groups to determine column boundaries (start/end positions)
3. Split each data row at those positions and trim whitespace
4. Stop at the next blank line or `===` section header

#### Output: `agDbMap`

Join AG State (`group_id` → `availability_group`) with Database State
(`group_id` + `is_local = 1`) to produce:

```json
{
  "sybasehk-prod-intl-ag": [
    { "name": "aes", "id": 5 },
    { "name": "aidcconfig", "id": 10 },
    ...
  ],
  "sybasehk-prod-batch-ag": [...],
  "sybasehk-prod-ext-ag": [...]
}
```

Also record the AG-level metadata:
- `primary_replica` — who is currently PRIMARY (per AlwaysOn.OUT snapshot)
- `availability_mode` — SYNC or ASYNC per replica
- `failover_mode` — AUTOMATIC or MANUAL

### Phase 2: Extract ERRORLOG AG Events

Script: `scripts/ag-failover-analysis/extract_ag_errorlog.js`

```
node scripts/ag-failover-analysis/extract_ag_errorlog.js <case_dir> <target_date>
```

Prereq: ag_schema.json (Phase 1). Auto-discovers ERRORLOG files from ag_schema.json.
Output: `ag_errorlog_events.json`, `ag_timeline.txt`

This script extracts all AG-related events from both hosts' ERRORLOGs on the target date,
categorizes them, and also detects DTC_SUPPORT from per-DB DTC RM init events
(updates ag_schema.json with DTC info).

#### Categories extracted:

| Category | ERRORLOG Pattern |
|----------|-----------------|
| ag_role_change | `availability replica ... has changed from` |
| db_role_change | `database "X" is changing roles from` |
| wsfc_cluster | WSFC errors (41005, 41034, 41143, 41144, 41161, CRC, Error 1722) |
| dtc | DTC RM init/release/recovery |
| abort_kill | `ABORT_AFTER_WAIT = BLOCKERS` |
| nonqual_rollback | `Nonqualified transactions are being rolled back` |
| remote_harden | `Remote harden of transaction ... failed` |
| starting_up | `Starting up database` |
| recovery_completed | `Recovery completed for database` |
| recovery_progress | `Recovery of database ... is N% complete` |
| resync | `restarted to resynchronize` |
| conn_established | `connection with ... database established` |
| conn_terminated | `connection with ... database terminated` |

### Phase 2b: Detect Failover Incidents

Script: `scripts/ag-failover-analysis/build_failover_timeline.js`

```
node scripts/ag-failover-analysis/build_failover_timeline.js <case_dir>
```

Prereq: ag_schema.json, ag_errorlog_events.json (Phase 1 & 2).
Output: `failover_incidents.json`

This script:
- Detects failover incidents from AG role change events
- Clusters AG→RESOLVING events within 120 seconds into one incident
- Classifies SQL Server shutdown (within 10s of "terminating" message) as SHUTDOWN event
- For each incident: gathers events, builds per-DB status, identifies NQ rollback, kills, DTC

### Phase 2c: Merge ERRORLOG + XEvent Timeline

Script: `scripts/ag-failover-analysis/merge_timeline.js`

```
node scripts/ag-failover-analysis/merge_timeline.js <case_dir> <sql_server> <utc_offset>
```

Prereq: ag_schema.json, ag_errorlog_events.json, ag_{case_id} database (Phase 1, 2, 3).
Output: `merged_timeline.json`, `merged_timeline.txt`

This script:
- Queries XEvent tables from SQL Server, converts UTC → local time
- Merges with ERRORLOG events (already in local time)
- Includes: hadr_replica_state, hadr_manager_state, hadr_sync_state (with db_id→name),
  hadr_trace (Reverting), hadr_ddl, sqldiag_info, sqldiag_ag_state, diagnostics transitions

### Phase 3: Import XEvent into SQL Server

Script: `scripts/ag-failover-analysis/import_ag_xevent.sql`

```
sqlcmd -S localhost -E -v case_id="{case_id}" host="{hostname}" xel_path="{case_dir}/{host}/AlwaysOn_health*.xel" -i scripts/ag-failover-analysis/import_ag_xevent.sql
```

Run once per host. This creates database `ag_{case_id}` with shredded tables:

| Table | XEvent Source | Key Columns | What It Tells Us |
|-------|-------------|-------------|-----------------|
| `xe.hadr_trace` | `hadr_trace_message` | `hadr_message` | Reverting begin/finished, internal AG messages |
| `xe.hadr_sync_state` | `hadr_db_partner_set_sync_state` | `database_id, sync_state, commit_policy` | DB sync state changes during failover |
| `xe.hadr_replica_state` | `availability_replica_state_change` | `ag_name, previous_state, current_state` | AG-level role transitions (cross-validates ERRORLOG) |
| `xe.hadr_manager_state` | `availability_replica_manager_state_change` | `current_state` | AG manager ONLINE/OFFLINE/PENDING_WSFC |
| `xe.hadr_ddl` | `alwayson_ddl_executed` | `ddl_action, statement` | AG DDL operations |

**Important:** XEvent timestamps are **UTC**. ERRORLOG timestamps are **server local time**.
Apply UTC offset when correlating (e.g. UTC+8: ERRORLOG 07:53 = XEvent 23:53 previous day).

### Phase 3b: Import system_health and SQLDIAG XEvent

In addition to AlwaysOn_health, import system_health and SQLDIAG XEvent for performance
analysis (needed for Phase 4b trigger classification).

**system_health** (per host):
```
sqlcmd -S localhost -E -v case_id="{case_id}" host="{hostname}" xel_path="{case_dir}/{host}/system_health*.xel" -i scripts/ag-failover-analysis/import_ag_xevent.sql
```

**SQLDIAG** (per host — check TWO locations):
```
# Location 1: Direct in host directory
sqlcmd -S localhost -E -v case_id="{case_id}" host="{hostname}" xel_path="{case_dir}/{host}/*SQLDIAG*.xel" -i scripts/ag-failover-analysis/import_ag_xevent.sql

# Location 2: FailoverCluster_health_XeLogs subdirectory (often has MORE files with longer history)
sqlcmd -S localhost -E -v case_id="{case_id}" host="{hostname}" xel_path="{case_dir}/{host}/*FailoverCluster_health_XeLogs*/*.xel" -i scripts/ag-failover-analysis/import_ag_xevent.sql
```

**Why both locations?** The SQLDIAG files in the host directory are often the latest
rollover files only (covering the last few hours). The `FailoverCluster_health_XeLogs`
directory (from PSSDIAG/SQLLogScout collection) may contain older rollover files with
data covering the incident time.

**Note on event names and XML format differences:**

| Source | Event Name | Component XML Path | State XML Path |
|--------|-----------|-------------------|---------------|
| system_health | `sp_server_diagnostics_component_result` | `(/event/data[@name="component"]/text)` | `(/event/data[@name="state"]/text)` |
| SQLDIAG (FailoverCluster) | `component_health_result` | `(/event/data[@name="component"]/value)` | `(/event/data[@name="state_desc"]/value)` |

The component values in SQLDIAG are **lowercase** (e.g. `system`, `query_processing`,
`resource`, `io_subsystem`, `events`) vs system_health which uses **uppercase**
(e.g. `SYSTEM`, `QUERY_PROCESSING`).

Both can be queried via the `import_ag_xevent.sql` script — it loads raw XML into
`xe.raw_events`. The XML parsing queries in Phase 4b must use the correct XPath
based on which event source they are querying.

### Phase 4: XEvent Analysis Checklist

For each failover incident, query these XEvent tables and check the following:

#### Check 1: `xe.hadr_replica_state` — AG-Level Transitions

Query:
```sql
SELECT host, event_time, ag_name, previous_state, current_state
FROM xe.hadr_replica_state
WHERE event_time BETWEEN @start_utc AND @end_utc
ORDER BY event_time
```

**What to verify:**
- Should match ERRORLOG AG role changes exactly (same AG, same direction, same timestamp)
- Look for the full lifecycle: `SECONDARY_NORMAL → RESOLVING_NORMAL → PRIMARY_PENDING → PRIMARY_NORMAL` (new primary) and `PRIMARY_NORMAL → RESOLVING_NORMAL → SECONDARY_NORMAL` (old primary)
- If `RESOLVING_NORMAL → SECONDARY_NORMAL` happens quickly (< 1 min), AG-level recovery succeeded
- If `RESOLVING_NORMAL → SECONDARY_NORMAL` but individual DBs are stuck → problem is at DB-level, not AG-level

#### Check 2: `xe.hadr_manager_state` — AG Manager Lifecycle

Query:
```sql
SELECT host, event_time, current_state
FROM xe.hadr_manager_state
WHERE event_time BETWEEN @start_utc AND @end_utc
ORDER BY event_time
```

**What to verify:**
- Normal failover cycle: `OFFLINE → PENDING_WSFC_COMMUNICATION → ONLINE`
- If stays `OFFLINE` → WSFC communication not restored
- `OFFLINE → PENDING → ONLINE` with recovery = normal restart sequence
- `OFFLINE → OFFLINE` at the end = SQL Server shutdown

#### Check 3: `xe.hadr_trace` — Reverting Events (Critical)

Query:
```sql
SELECT host, event_time,
  SUBSTRING(hadr_message, CHARINDEX('[', hadr_message)+1,
    CHARINDEX(']', hadr_message)-CHARINDEX('[', hadr_message)-1) AS db_name,
  CASE WHEN hadr_message LIKE '%begin%' THEN 'begin' ELSE 'finished' END AS phase
FROM xe.hadr_trace
WHERE event_time BETWEEN @start_utc AND @end_utc
  AND hadr_message LIKE '%Reverting%'
ORDER BY event_time
```

**What to verify:**
- Each recovered DB should have both `Reverting begin` and `Reverting finished` events
- `Total logs to revert [N]` indicates undo work volume — larger N = longer reverting
- **Stuck DBs will have ZERO Reverting events** — they never completed the `DatabaseSwitchRoles` pipeline
- Compare the list of DBs with Reverting vs the total DB list → missing DBs = stuck

**Diagnostic value:**
- Reverting present → DB completed `AcquireXDbLockWithKill` (Step 21) and entered undo phase
- Reverting absent → DB stuck before Step 21 (sub-manager Stop or AcquireXDbLock loop)
- Only `Reverting begin` without `Reverting finished` → undo phase itself is stuck (rare)

#### Check 4: `xe.hadr_sync_state` — Per-DB Sync State Changes (Critical)

Query:
```sql
SELECT host, event_time, database_id, sync_state, commit_policy
FROM xe.hadr_sync_state
WHERE event_time BETWEEN @start_utc AND @end_utc
ORDER BY event_time
```

**What to verify on the old primary (demoted node):**
- Look for `sync_state=NOT, commit_policy=KillAll` events
- On the demoted node, only DBs that reached `AcquireXDbLockWithKill` will fire this event
- Very few events from the old primary during a stuck failover → most DBs never got that far

**What to verify on the new primary:**
- Normal pattern: `LOG/WaitForHarden` → `NOT/WaitForHarden` → `LOG/WaitForHarden` as each DB transitions
- All DBs should eventually show `LOG/WaitForHarden` (synchronized with new secondary)
- The sequence of DBs appearing here shows the order each DB completed its role transition on the new primary

**Cross-host comparison:**
- If new primary shows all DBs recovered (`LOG/WaitForHarden`) while old primary shows almost no `hadr_sync_state` events → problem is isolated to old primary's internal state

#### Check 5: `xe.hadr_trace` — Non-Reverting Messages

Query:
```sql
SELECT TOP 50 event_time, LEFT(hadr_message, 200) AS msg
FROM xe.hadr_trace
WHERE host = @old_primary_host
  AND event_time BETWEEN @start_utc AND @end_utc
  AND hadr_message NOT LIKE '%Reverting%'
ORDER BY event_time
```

**What to look for:**
- `Cleaning up conversations for [GUID]` — AG cleanup during failover (normal)
- `CHadrArProxy::Offline` — AG going offline (normal during failover)
- Any error-level messages or unexpected patterns
- Messages mentioning specific database names may indicate where processing stalled

### Phase 4b: Classify Failover Trigger — Lease Timeout vs Health Check vs Cluster Error

For each failover incident, determine **WHY** the AG went offline. This is a critical
first step before analyzing individual database behavior. The trigger type determines
the investigation path.

#### Step 1: Check ERRORLOG Error Numbers

Search ERRORLOG for the specific error that triggered the failover:

| Error | Message | Direction | Meaning |
|-------|---------|-----------|---------|
| **19419** | "WSFC did not receive a process event signal from **SQL Server**" | SQL → WSFC | **SQL Lease renewal timeout** — SQL Server failed to send the lease signal to WSFC. SQL was too busy (CPU/worker exhaustion) to schedule the lease thread. |
| **19421** | "**SQL Server** did not receive a process event signal from the **WSFC**" | WSFC → SQL | **Diagnostics heartbeat lost** — WSFC health worker could not get sp_server_diagnostics results from SQL Server. Often caused by the same CPU pressure affecting both sides. |
| **19407** | "The lease between AG and WSFC has expired" | — | Generic lease expiration message. Always accompanies 19419 or 19421. Not diagnostic on its own. |
| **41005** | "WSFC cluster event notification operation failed" | — | **Cluster communication error** — WSFC internal issue, not SQL performance related. |
| **1135** | "Cluster node was evicted from the WSFC cluster" | — | **Node eviction** — WSFC determined the node is unhealthy. May be network, storage, or OS-level issue. |
| **41144** | "WSFC lease could not be renewed" | — | Lease could not be renewed — similar to 19419 but from a different code path. |

**Important:** 19419 and 19421 can BOTH appear simultaneously. Check which one appears
first — that indicates the primary failure direction.

#### Step 2: Confirm with Cluster Log

Cross-reference with the cluster log. The cluster log records the WSFC-side trigger:

| Cluster Log Message | Trigger Type |
|---------------------|-------------|
| `[hadrag] Lease renewal failed with timeout error` | **SQL Lease renewal timeout** — SQL did not renew the lease in time |
| `[hadrag] Lease renewal failed because the existing lease is no longer valid` | **SQL Lease renewal timeout** — lease already expired |
| `[hadrag] Failure detected, diagnostics heartbeat is lost` | **Diagnostics heartbeat lost** — health worker could not get sp_server_diagnostics response |
| `[hadrag] Availability Group is not healthy with given HealthCheckTimeout and FailureConditionLevel` | **Health check timeout** — sp_server_diagnostics returned unhealthy state |
| `Node was removed from the active failover cluster membership` | **Node eviction (Error 1135)** — cluster-level issue |

**The cluster log is the authoritative source** for trigger type classification.
ERRORLOG error numbers alone can be ambiguous (19419 and 19421 may both appear).

#### Step 3: Branch Based on Trigger Type

```
Trigger Type?
│
├─ Step 4: Extract perf counter from cluster log (ALL trigger types)
│
├─ SQL Lease renewal timeout (19419) ──────────┐
├─ Diagnostics heartbeat lost (19421) ─────────┤
├─ Health check timeout ───────────────────────┤
│                                              │
│                    ┌─────────────────────────┘
│                    ▼
│          *** Performance Investigation ***
│          → Step 5: Analyze sp_server_diagnostics data
│          → Step 6: Import SQLDIAG 5-sec data (if available)
│          → Step 7: Detect sp_server_diagnostics gaps
│          → Step 8: Classify CPU pattern (SQL vs OS vs Worker)
│
├─ Cluster error (1135 node eviction) ─────────┐
├─ Cluster error (41005 WSFC comm failure) ─────┤
│                                              │
│                    ┌─────────────────────────┘
│                    ▼
│          *** Cluster / Infrastructure Investigation ***
│          → INVOKE the `cluster-review` skill (see Phase 6c)
│          → Check perf counter: if CPU/IO normal, confirms not performance related
│          → Check WSFC network, quorum, storage
│          → Check cluster log for node heartbeat failures
│          → Check Windows Event Log (System, FailoverCluster)
│
└─ Other / Unknown ────────────────────────────→ Investigate both paths
```

#### Step 4: Extract Perf Counter Data from Cluster Log

**(For ALL trigger types — always do this step)**

When any AG resource failure occurs, WSFC automatically dumps perf counter history
(10-second sampling). This data is critical for ALL trigger types:
- **Lease/health check timeout:** CPU% reveals whether it was SQL CPU, OS CPU, or IO
- **Cluster errors (1135, 41005):** If CPU/IO are normal, confirms the issue is
  infrastructure-related (network, quorum), not performance

Search for these lines near the FO timestamp:

```
[hadrag] Lease timeout detected, logging perf counter data collected so far
[hadrag] AG health check failed, logging perf counter data collected so far
[hadrag] Date/Time, Processor time(%), Available memory(bytes), Avg disk read(secs), Avg disk write(secs)
[hadrag] 5/19/2026 20:20:39.0, 100.000000, 973680615424.000000, 0.000235, 0.000183
```

Extract the CPU%, available memory, and disk latency values for every FO.
This data is available for all trigger types, not just lease/health check.

**Include perf counter CPU detail in the report.** For each FO, list the 10-second
CPU trend in a table. This is the most direct evidence of system state at the moment
of failure. Example format:

| # | Local Time | CPU Samples (10s intervals before FO) |
|---|-----------|--------------------------------------|
| 1 | 05-19 04:21 | `04:20:39→100% | 04:20:49→100% | 04:21:01→100% | 04:21:14→100% | 04:21:24→100%` |
| 2 | 05-19 06:50 | `06:50:02→5%` (only 1 sample) |

**Key patterns to highlight:**
- **Sustained 97-100%** for 30+ seconds — classic CPU spike, lease thread starved
- **Rapid climb** from moderate to >90% within 30-40 seconds — sudden workload burst
- **Low CPU at sampling point** (e.g. 48%) — spike occurred between samples, need SQLDIAG 5s data
- **SQLDIAG gaps** (100-125 seconds with no data) — proves SQL Server completely frozen

#### Step 5: Analyze sp_server_diagnostics Component Data

**(Only for lease timeout / health check timeout triggers)**

Query `sp_server_diagnostics_component_result` (from system_health XEvent, typically
5-min interval) around each FO time (FO time ± 10 minutes, convert to UTC).

Key fields to extract from each component's XML `<data>` element:

| Component | XML Path | Key Fields | What to Look For |
|-----------|----------|-----------|-----------------|
| **SYSTEM** | `/system/@systemCpuUtilization`, `@sqlCpuUtilization` | sysCPU vs sqlCPU | **sysCPU high + sqlCPU high** = SQL CPU intensive. **sysCPU high + sqlCPU low** = OS process consuming CPU. |
| **QUERY_PROCESSING** | `/queryProcessing/@maxWorkers`, `@workersCreated`, `@workersIdle`, `@pendingTasks` | Worker usage ratio | If `workersCreated` approaches `maxWorkers` (e.g. >80%), worker exhaustion risk. `pendingTasks > 0` = tasks waiting for workers. |
| **IO_SUBSYSTEM** | `/ioSubsystem/@ioLatchTimeouts`, `@intervalLongIos`, `@totalLongIos` | IO pressure | Non-zero = IO bottleneck contributing to timeout |
| **RESOURCE** | `/resource/@lastNotification` | Memory state | `RESOURCE_MEM_STEADY` = OK. `RESOURCE_MEMPHYSICAL_LOW` = memory pressure |

#### Step 6: Import SQLDIAG 5-Second Data (if available)

**(Only for lease timeout / health check timeout triggers)**

Check for `FailoverCluster_health_XeLogs` directory or SQLDIAG XEL files containing
`component_health_result` events (5-second interval, much finer than system_health's 5-min).

**Note:** SQLDIAG XEL uses a different XML format than system_health:
- Component name: lowercase (e.g. `system`, `query_processing`, `resource`)
- XML path: `(/event/data[@name="component"]/value)` instead of `(/event/data[@name="component"]/text)`
- State: `(/event/data[@name="state_desc"]/value)` instead of `(/event/data[@name="state"]/text)`

Import with the same `import_ag_xevent.sql` script, then query with adjusted XPath.

#### Step 7: Detect sp_server_diagnostics Gaps

**(Only for lease timeout / health check timeout triggers)**

If SQLDIAG 5-second data is available, calculate the interval between consecutive
events for the same component. Normal interval = ~5 seconds.

**Gaps > 7 seconds prove SQL Server thread scheduling was blocked** — the exact same
mechanism that prevents the lease thread from renewing. The gap duration directly
correlates with how long SQL Server was "frozen."

Example query:
```sql
;WITH sys AS (
  SELECT event_time, ROW_NUMBER() OVER (ORDER BY event_time) AS rn
  FROM xe.raw_events
  WHERE event_name = 'component_health_result'
    AND CAST(event_data AS XML).value(
      '(/event/data[@name="component"]/value)[1]','varchar(30)') = 'system'
    AND event_time BETWEEN @start_utc AND @end_utc
)
SELECT DATEADD(HOUR, @utc_offset, a.event_time) AS local_time,
  DATEDIFF(MILLISECOND, b.event_time, a.event_time) AS gap_ms,
  CASE WHEN DATEDIFF(MILLISECOND, b.event_time, a.event_time) > 7000
    THEN '*** GAP ***' ELSE '' END AS flag
FROM sys a LEFT JOIN sys b ON a.rn = b.rn + 1
ORDER BY a.event_time;
```

#### Step 8: Classify Each FO's Root Cause Pattern

**(Only for lease timeout / health check timeout triggers)**

Combine all evidence (cluster log perf counter + sp_server_diagnostics + gap detection)
to classify each failover into one of these patterns:

| Pattern | sysCPU | sqlCPU | Workers | Trigger | Root Cause |
|---------|--------|--------|---------|---------|-----------|
| **SQL CPU Intensive** | High (>90%) | **High (>80%)** | Normal | SQL Lease timeout | SQL queries/jobs consuming CPU → lease thread starved |
| **OS CPU Occupied** | High (>90%) | **Low (<10%)** | Normal | SQL Lease timeout or Heartbeat lost | Non-SQL OS process consuming CPU → everything starved |
| **Worker Exhaustion** | Low-Medium | Low | **>80% of max** | SQL Lease timeout | Worker pool near limit → lease thread cannot be scheduled |
| **IO Bottleneck** | Normal | Normal | Normal | Heartbeat lost | Long IO stalls → sp_server_diagnostics blocked |
| **Mixed** | Variable | Variable | Variable | Either | Combination of factors |

### Phase 5: Classify Each Database

Combine ERRORLOG (Phase 2) and XEvent (Phase 4) evidence to classify each database.

#### Evidence Matrix

For each DB on the **demoted node** (old primary, PRIMARY→RESOLVING), collect:

| Evidence Source | Field | Recovered DB | Stuck DB (Category B) | Stuck DB (Category C) |
|----------------|-------|-------------|----------------------|----------------------|
| ERRORLOG | Nonqualified Rollback | 0 or 1 occurrence | Thousands (loop) | 0 (absent) |
| ERRORLOG | ABORT Kill | 0 or few | May have late kills | 0 (absent) |
| ERRORLOG | Release DTC | Present (if DTC AG) | Absent | Absent |
| ERRORLOG | Starting up | Present | Absent | Absent |
| ERRORLOG | Resync | Present | Absent | Absent |
| ERRORLOG | RESOLVING→SECONDARY | Within minutes | Only at shutdown | Only at shutdown |
| ERRORLOG | Remote harden failed | Stops quickly | Continues throughout | Continues throughout |
| XEvent | Reverting begin/finished | **Both present** | **Absent** | **Absent** |
| XEvent | `hadr_sync_state` (old primary) | — | **May have** NOT/KillAll | **Absent** |
| XEvent | `hadr_sync_state` (new primary) | LOG/WaitForHarden | LOG/WaitForHarden | LOG/WaitForHarden |

#### Category A: Recovered ✅

All ERRORLOG + XEvent steps present. Full pipeline completed.

#### Category B: Stuck at `AcquireXDbLockWithKill` ❌

Key distinguisher: **Nonqualified Rollback loop** in ERRORLOG (Error 35299, repeating every ~2s, always "100%").
XEvent: may have `hadr_sync_state` event with `NOT/KillAll` on the old primary.
No Reverting events.

#### Category C: Stuck at Sub-manager Stop (Silent) ❌

Key distinguisher: **No Nonqualified Rollback, no ABORT Kill** — completely silent.
XEvent: no `hadr_sync_state` event on old primary, no Reverting events.
Only evidence is continued `Remote harden failed` messages.

**Category B vs C:** The key differentiator is whether Nonqualified Rollback messages appear in ERRORLOG. If yes → B. If no → C.

### Phase 6: Per-Failover Analysis Report

For each failover incident, write an analysis section following this structure.

#### Report Skeleton — mirror the reference report (`2606230030003998_ag_failover_report.md`)

The final report MUST follow this top-level layout. The detailed per-FO specs
(6.1–6.5 below) are the **building blocks** that feed these sections; for a
multi-flap incident, MERGE the flaps into ONE unified timeline/evidence list
rather than repeating per-FO.

| § | Section | Built from | Mandatory? |
|---|---------|-----------|-----------|
| 1 | **执行摘要** (executive summary) | new — see §6.0 below | **Always** |
| 2 | **环境与拓扑** (environment & topology) | Phase 1 + Server/AG summary | Always |
| 3 | **根本原因（含权威证据）** (root cause + verbatim evidence) | 6.1 trigger + cluster-review §C | Always |
| 4 | **完整时间线** (numbered unified timeline) | new — see §6.A below | Always |
| 5 | **时间线逐步证据** (verbatim, one raw log per step) | new — see §6.B below | Always |
| 6 | **为什么没有自动 failover** (why no auto-failover) | new — see §6.C below | When the AG did NOT auto-fail-over |
| 7 | **隔离 (Quarantine) 分析** | cluster-review | When node quarantine (5985) seen |
| 8 | **数据丢失分析** (data loss) | new — see §6.D below | Always (even if "no loss") |
| 9 | **逐库状态** (per-DB status) | 6.4 per-DB table | Always |
| 10 | **建议** (recommendations) | Phase 7 / docs-lookup | Always |
| 11 | **Cluster 配置总结（来自注册表 hive 权威枚举）** | cluster-review Phase 1 (§F) | When cluster-review ran |

> ⚠️ **Trigger ≠ enabling root cause.** Keep the two layers distinct in EVERY
> section. The **trigger** is the immediate event (WSFC heartbeat flap / quorum
> loss / lease timeout). The **enabling root cause** is the configuration state
> that turned a transient trigger into a stuck/loss outage — and it may live in a
> **different layer**: WSFC config (zero-weight node / no witness / site
> misconfig → `cluster-review`) OR the AG/DDL layer (e.g. `FAILOVER_MODE = MANUAL`
> blocking auto-failover → confirm from `alwayson_ddl_executed`). Never collapse
> "what knocked the primary down" with "why it stayed down / didn't fail over."

**ANALYSIS WORKFLOW:**

Step A: Use `failover_incidents.json` to get each FO's time range and affected AGs.

Step B: Use per-FO timeline files (`fo1_timeline.txt` etc.) as an **index/summary**.
        These files provide:
        - Per-host structure (which host played which role)
        - Event category counts and summaries
        - system_health errors and waits (queried from SQL)
        - Collapsed NQ rollback / remote harden counts
        - Per-DB status comparison table

        **Limitations of timeline files:**
        - They are FILTERED extracts — only AG-related messages were extracted
        - Some messages may have been miscategorized or missed by the extraction regex
        - Nonqualified Rollback and Remote Harden Failed are collapsed (only count shown)
        - They do NOT contain the full ERRORLOG text
        - Use them to identify time ranges and patterns, NOT as the sole data source

Step C: **Go back to the ORIGINAL ERRORLOG files** and read the COMPLETE raw text
        for each FO's time range (FO start - 5 minutes to FO end) on BOTH hosts.
        The timeline files are filtered/categorized extracts — they may have missed
        messages. The ERRORLOG is the ground truth.

        **IMPORTANT — Trigger window timing:**
        The FO start time in `failover_incidents.json` is the timestamp of the FIRST
        host to react. The OTHER host may log its WSFC/trigger events 30-90 seconds
        later. For example:
        - FO2 start=07:01:40 (HKAZEPWDB0031 goes RESOLVING) but HKAZEPWDB0011's
          WSFC errors (41144, 41005, 1722) appear at 07:02:43 — 63 seconds later.
        - FO3 start=07:52:52 (HKAZEPWDB0011 goes RESOLVING) but HKAZEPWDB0031's
          connection timeouts start at 07:53:29 and lease termination at 07:53:53.
        Therefore, use at least **FO start - 1 min to FO start + 2 min** for trigger
        evidence collection from BOTH hosts.

        Read: `{case_dir}/{host}/{host}_MSSQLSERVER_1033_ERRORLOG*`

Step D: **Query the XEvent SQL database** (`ag_{case_id}`) for the same time range
        (convert to UTC) to get hadr_trace, hadr_sync_state, errors, waits.

Step E: Write analysis based on the complete original data from Steps C and D,
        citing verbatim messages from the original ERRORLOG and XEvent.

**MANDATORY ANALYSIS RULES:**

1. **The ERRORLOG is the primary source.** The timeline files are indexes — always
   verify against the original ERRORLOG when writing the report. Read the actual
   ERRORLOG file for the FO time range to catch anything the extraction scripts missed.

2. **Every conclusion MUST be accompanied by the original log evidence.**
   - Do NOT write any conclusion without pasting the raw ERRORLOG/XEvent message that supports it.
   - Do NOT summarize or paraphrase log messages. Copy them verbatim.
   - If you cannot find log evidence for a claim, state "No evidence found" instead of guessing.

3. **Do NOT omit unfamiliar messages.** If you see a log message you don't recognize,
   include it in the evidence and note "Unknown — needs further investigation."

4. **Analyze BOTH hosts.** Each FO has two sides. Read ERRORLOG from both hosts
   for the FO time range.

Format for each observation:
```
Evidence:
  [raw log line copied verbatim from the timeline file]
  [raw log line copied verbatim from the timeline file]

Conclusion: [your interpretation of the evidence above]
```

#### FO Header

Each failover section MUST state clearly in the header:
- **Which AG(s)** failovered
- **From which host to which host** (old PRIMARY → new PRIMARY)
- Per-AG direction if multiple AGs behave differently

Example:
```
FO2 — 07:01:40
  intl-ag: PRIMARY moved from HKAZEPWDB0011 → HKAZEPWDB0031
  batch-ag: stayed on HKAZEPWDB0031 (no role change)
  ext-ag: PRIMARY stayed on HKAZEPWDB0011 (HKAZEPWDB0031 was secondary, went RESOLVING→SECONDARY)
```

Derive the direction from:
- `connection with primary database terminated ... on the availability replica 'X'` → X was the old PRIMARY
- AG role change messages: `PRIMARY_NORMAL → RESOLVING_NORMAL` = this host lost PRIMARY
- AG role change messages: `RESOLVING_NORMAL → PRIMARY_PENDING → PRIMARY_NORMAL` = this host gained PRIMARY

#### 6.1 Trigger — Raw Evidence

List the original ERRORLOG/XEvent messages that show WHY this failover happened.
Copy the actual messages verbatim, do NOT summarize them.

**Important messages to include in Trigger Evidence:**
- `connection with primary database terminated for secondary database 'X' on the availability replica 'Y'`
  → This reveals who was PRIMARY before the failover (replica Y = the PRIMARY that was lost)
- `A connection timeout has occurred on a previously established connection to availability replica`
  → Shows which replicas lost connectivity and when
- `Lease Thread terminated` / `Health worker was asked to terminate` (SQLDIAG info_message)
  → Shows WSFC health determination caused the failover
- `availability_group_state_change target=Failed failure=SYSTEM_UNHEALTHY` (SQLDIAG)
- AG role change messages (both ERRORLOG and XEvent `hadr_replica_state`)
- `ASYNC_IO_COMPLETION` / long waits from system_health (if present before FO)
- Error 41005/41144/41143/41161 (WSFC errors) if present

**CRITICAL — Correctly identifying OLD PRIMARY vs NEW PRIMARY in trigger analysis:**

Connection timeout messages list the TARGET replica, NOT the source. Multiple replicas
may appear in connection timeout targets, but they have DIFFERENT roles:

- The **OLD PRIMARY** is the node that was PRIMARY before the failover and went down.
  Identify it from: `connection with primary database terminated ... on replica 'X'`
  → X was the PRIMARY. Or from `ag_directions` in `failover_incidents.json`.
- The **NEW PRIMARY** is the node promoted to PRIMARY after the failover.
  It will show `RESOLVING → PRIMARY_PENDING → PRIMARY_NORMAL` in XEvent/ERRORLOG.
- **Other replicas** (DR secondaries, read-only replicas) may also appear in connection
  timeout targets — they are collateral, NOT the cause.

Common mistake: collecting ALL connection timeout targets and listing them as
"the PRIMARY node becoming unreachable." This is WRONG when multiple replicas
time out simultaneously. Example:

```
WRONG: "Root Cause: PRIMARY node (HKAZEPWDB0015, HKAZEPWDB0011) became unreachable"
  → HKAZEPWDB0015 was the old PRIMARY; HKAZEPWDB0011 was promoted to new PRIMARY.
     Listing both as "becoming unreachable" is contradictory and confusing.

RIGHT: "Root Cause: ext-ag PRIMARY node HKAZEPWDB0015 became unreachable.
        Connection timeouts to HKAZEPWDB0015 detected at 05:18:10 on both
        HKAZEPWDB0031 and HKAZEPWDB0011 (both SECONDARY for ext-ag).
        HKAZEPWDB0011 was promoted to new PRIMARY at 05:18:31."
```

To determine the old PRIMARY:
1. Check `ag_directions` — find the host with `PRIMARY_NORMAL → RESOLVING_NORMAL`
2. Check `connection with primary database terminated` messages — the replica named is the old PRIMARY
3. If the old PRIMARY is a 3rd host not in our 2-host analysis set (e.g. HKAZEPWDB0015),
   it won't have AG direction data — identify it from the connection terminated messages

Example format:
```
Evidence (ERRORLOG, HKAZEPWDB0031):
  05:18:26.74 spid2685s  Always On Availability Groups connection with primary database
              terminated for secondary database 'db_work_e' on the availability replica
              'HKAZEPWDB0015' with Replica ID: {8612424b-...}
  → This tells us HKAZEPWDB0015 was the PRIMARY for ext-ag before this failover.

  07:53:29.28 spid2714s  A connection timeout has occurred on a previously established
              connection to availability replica 'HKAZEPWDB0011' with id [...]
  07:53:30.35 spid2685s  A connection timeout has occurred on ... 'HKAZEPWDB0015'

Evidence (SQLDIAG XEvent, HKAZEPWDB0031):
  07:53:31.33 [hadrag] SQL Server component 'query_processing' health state has been
              changed from 'clean' to 'warning'
  07:53:53.77 [hadrag] Lease Thread terminated
  07:53:53.77 [hadrag] Lease Thread terminated
  07:53:53.77 [hadrag] Health worker was asked to terminate

Evidence (system_health XEvent, HKAZEPWDB0031):
  07:53:40   ASYNC_IO_COMPLETION  1813s (30 min)
  07:53:45   ASYNC_IO_COMPLETION  784s (13 min)

Conclusion: Failover triggered by WSFC lease thread termination on HKAZEPWDB0031.
Connection timeouts to all secondary replicas started 24 seconds before lease termination.
System was under IO stress (30-minute ASYNC_IO_COMPLETION waits).
```

#### 6.2 AG-Level Flow — Raw Evidence

List the AG state change messages from both ERRORLOG and XEvent.
**MUST include evidence from BOTH hosts.** Each host has its own section in the
timeline file — read and cite from both.

For each host, show:
- AG role changes (with timestamps)
- Connection terminated/established messages
- SQLDIAG events (if any)
- Key errors

**Do NOT skip a host even if it "just recovered normally".** The new primary's timeline
shows when it became PRIMARY, when it started up databases, and when connections were
re-established. This is essential for understanding the full picture.

#### 6.3 Per-Host Analysis

**MANDATORY: Analyze EVERY host that has events in the timeline file.**

The timeline file has sections like:
```
################################################################################
# HKAZEPWDB0031 (demoted from PRIMARY)
################################################################################
...

################################################################################
# HKAZEPWDB0011 (promoted to PRIMARY)
################################################################################
...
```

You MUST read and cite evidence from EACH host section. For each host:
1. What role did this host have before the FO?
2. What happened during the FO? (connection terminated, AG role change, DB role change)
3. What was the outcome? (all DBs recovered? any stuck?)
4. Any errors or unusual events?

#### 6.4 Per-DB Status Table

Build a per-node, per-AG table showing EVERY database's transition timeline.
**Generate one table per node.** Each column = one step in the recovery pipeline.
Use actual timestamps from the log. Use `-` for "not present in log".

**Required columns:**

| Column | Source | Description |
|--------|--------|-------------|
| AG Name | ag_schema.json | Which AG this DB belongs to |
| DB Name | ag_schema.json | Database name |
| ID | ag_schema.json | database_id on this node |
| Init DTC | ERRORLOG | `Initializing MS DTC resource manager [...] for database 'X'` timestamp |
| Release DTC | ERRORLOG | `MS DTC resource manager [...] has been released` timestamp |
| PRIMARY→RESOLVING | ERRORLOG | `database "X" is changing roles from "PRIMARY" to "RESOLVING"` timestamp |
| RESOLVING→SEC | ERRORLOG | `database "X" is changing roles from "RESOLVING" to "SECONDARY"` timestamp |
| Starting up | ERRORLOG | `Starting up database 'X'` timestamp |
| Resync | ERRORLOG | `is being restarted to resynchronize` timestamp |
| Revert Begin | XEvent hadr_trace | `Database [X] - Reverting begin: Total logs to revert [N]` timestamp |
| Revert End | XEvent hadr_trace | `Database [X] - Reverting finished` timestamp |
| ABORT Kill | ERRORLOG | `killed by an ABORT_AFTER_WAIT = BLOCKERS DDL statement on database_id = N` — count and first timestamp |
| NQ Rollback | ERRORLOG | `Nonqualified transactions are being rolled back in database X` — first timestamp, last timestamp, count |

**Example table (Node: HKAZEPWDB0031, FO3):**

| AG | DB | ID | Init DTC | Release DTC | PRI→RESOLV | RESOLV→SEC | Starting up | Resync | Revert Begin | Revert End | ABORT Kill | NQ Rollback |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| intl-ag | aes | 5 | - | - | 07:53:53.85 | 07:54:26.15 | 07:54:29 | 07:55:03 | 07:54:56 | 07:55:00 | ×1 07:53:53 | - |
| intl-ag | aidcconfig | 10 | - | - | 07:53:53.85 | 09:09:12 | - | - | - | - | ×1 09:00:02 | 07:53:55—09:09:10 ×2225 |
| intl-ag | db_aadmin | 11 | - | - | 07:53:53.85 | 09:09:12 | - | - | - | - | - | - |
| batch-ag | db_ebiz | 9 | - | 07:53:54.24 | 07:53:54.23 | 07:54:26.00 | 07:55:15 | 07:55:13 | 07:55:07 | 07:55:10 | - | - |

**Rules:**
- `-` means "not present in log" — this is evidence of absence, not a guess
- RESOLV→SEC at shutdown time (e.g. 09:09:12) = DB was stuck until forced shutdown
- Init DTC only appears on the NEW primary side (DB becoming PRIMARY initializes DTC)
- Release DTC only appears on the OLD primary side (DB leaving PRIMARY releases DTC)
- A separate table is needed for each node that has DB events in this FO

#### 6.4 Key Observations

Derived from the evidence above. **Each observation MUST cite the specific log evidence:**

Bad example (DO NOT write like this):
  "25 intl-ag DBs were stuck in RESOLVING"  ← no evidence cited

Good example:
  "Evidence: Per-DB table shows 25 intl-ag DBs have `-` for all columns 
   (Starting up, Recovery, Revert, Resync) after →RESOLVING.
   Only →SECONDARY timestamp is 09:09:12 (= shutdown time).
   Conclusion: These 25 DBs never progressed past the initial →RESOLVING step."

#### 6.5 Cross-FO Comparison

For cases with multiple failovers, compare:
- Why did FO2 succeed (same DBs, same host) but FO3 fail?
- What was different about the system state?

---

### Phase 6 — Report-Level Sections (mirror reference §§1, 4, 5, 6, 8)

These cross-cutting sections sit ABOVE the per-FO detail and are what make the
report audit-grade. Build them from the same verbatim evidence you already
collected — do NOT paraphrase.

#### 6.0 Executive Summary (§1) — Trigger vs Root Cause

One table at the very top, columns:

| Field | What to fill |
|-------|-------------|
| **触发器 (Trigger)** | The immediate event (e.g. "WSFC 跨站点心跳闪断 3 次 → SH 失去仲裁") |
| **根本原因 (enabling root cause)** | The config that made it stick / blocked failover — name the layer (WSFC: zero-weight + no witness / site misconfig; **or** AG/DDL: `FAILOVER_MODE = MANUAL`). If it belongs to the cluster layer, point to §11; if AG/DDL, cite the `alwayson_ddl_executed` evidence. |
| **闪断次数 (flap count)** | N — count **only the failure/flap incidents**. A user-initiated `ALTER…FAILOVER` (the planned recovery) is **NOT** a flap; report it separately as the recovery, not as an (N+1)th failure. |
| **为什么卡住 (~Xh)** | quarantine window / manual-failover wait |
| **为什么没有自动 failover** | one line → §6 |
| **数据丢失** | yes/no + boundary LSN → §8 |
| **恢复方式/耗时** | how it recovered (manual failover, link heal) + duration |

#### 6.A Unified Numbered Timeline (§4)

ONE table merging BOTH nodes across ALL flaps + quarantine + recovery. Columns:
**序号 ｜ 本地时间(UTC+8) ｜ 节点 ｜ 事件 ｜ 含义 ｜ 来源**. Convert cluster.log (UTC)
to server-local; tag each row's source (cluster.log / ERRORLOG / XEvent). This is
the single chronological spine of the incident.

> **Incident vs recovery in the count:** `failover_incidents.json` may yield e.g.
> 4 "incidents" while operators think of it as "3 flaps + 1 manual recovery".
> Classify each row: a transition driven by quorum loss / heartbeat flap is a
> **failure (flap)**; a transition driven by a user-initiated `ALTER…FAILOVER`
> (no `FORCE_FAILOVER_ALLOW_DATA_LOSS`, target SYNCHRONIZED) is the **planned
> recovery**. The §1 flap count and the §4 timeline must agree with the operator
> framing — label the recovery row as recovery, do not inflate the failure count.

#### 6.B Verbatim Per-Step Evidence (§5)

For EACH numbered step in §6.A, a `证据 N — 步骤X 时间 节点 …` block containing the
**actual raw log line(s)** (cluster.log UTC / ERRORLOG / XEvent local), labelled
with step #, time, node, source. One raw line per step; the full causal chain
(trigger → quorum loss → AG offline → quarantine → recovery → revert/loss
boundary) must appear verbatim. This section is mandatory — it is the difference
between "too brief" and audit-grade.

#### 6.C Why No Auto-Failover (§6) — only if the AG did NOT auto-fail-over

When the AG stayed on the dead/old primary or required a manual failover, prove
WHY the automatic failover did not happen. Walk the conditions in order, each
with verbatim evidence:

1. **availability_mode** — was it `SYNCHRONOUS_COMMIT`? (auto-failover requires
   sync commit on BOTH the failed and target replica). Cite the AG config snapshot
   (`*.rpt` / `sys.availability_replicas`).
2. **failover_mode** — was it `AUTOMATIC` or `MANUAL`? `MANUAL` statically removes
   the replica from WSFC PossibleOwners → **no auto-failover**. Confirm from
   `alwayson_ddl_executed` (XEvent) — the DDL that set/reverted it, with timestamps.
3. **Was the target replica actually behind?** Show the **LSN evidence** (hardened
   / end-of-log LSN on the survivor was current, not lagging) to rule out
   "secondary too far behind" as the reason.
4. **Did WSFC ever try to online the AG on the survivor?** Cross-reference
   `cluster-review` checkpoint 7 (PossibleOwnerFilter / `IsPossibleOwner:false` /
   ban code 5016 / group `Orphaned→Offline`). Watch for **either** fingerprint:
   (a) the survivor is **explicitly banned** (`IsPossibleOwner:false` / ban 5016),
   or (b) the survivor is **simply absent from the placement candidates** — e.g.
   `[RCM-plcmt] Group <AG> allowed to move to node <N>` lists only the down/old
   owner, with no `IsPossibleOwner:false` line for the survivor at all (it was
   removed from PossibleOwners earlier, often a static state). If WSFC never
   attempted placement on the survivor → the exclusion is the cause.
5. **AlwaysOn_health role machine (both nodes)** — quote the verbatim role
   transitions showing the promotion was **user-initiated**, with no prior
   automatic-promotion attempt.

State explicitly whether the block was a **static config state** (MANUAL mode) or
a **dynamic** sync-state removal — do not assert the SQL-layer cause from
cluster.log alone.

#### 6.D Data Loss Analysis (§8)

Always include, even to state "no committed data lost." Identify the
**recovery / revert boundary LSN** on the node that came back as the new
secondary (`Recovery LSN` / `Reverting begin: Total logs to revert [N]`), compare
against the survivor's hardened LSN, and conclude whether any **committed**
transaction was lost. Cite the verbatim `Reverting` / `Recovery` ERRORLOG lines
and the hardened-LSN XEvent rows.

---

### Phase 6b: Invoke stuck-db-analysis (Conditional)

**Trigger condition:** Any FO has databases that did NOT recover (Category B or C).

Check `failover_incidents.json`: for each FO, if any DB on the demoted host has
`to_resolving` from PRIMARY but no `starting_up` → that DB is stuck.

**When to invoke:**
- At least 1 DB stuck at `AcquireXDbLockWithKill` (NQ rollback present) → Cat B
- At least 1 DB stuck silently (no NQ rollback, no starting_up) → Cat C
- All DBs recovered → **do NOT invoke** (skip to Phase 7)

**How to invoke:**
Read the stuck-db-analysis skill from `.github/skills/stuck-db-analysis/SKILL.md`.
Before running analysis, read the pre-cached source code KB:
- `.github/skills/stuck-db-analysis/reference/database_switch_roles_pipeline.md`
- `.github/skills/stuck-db-analysis/reference/lock_dependency.md`

**What it produces:**
- Side-by-side comparison table: Cat A (recovered) vs Cat B vs Cat C representative DBs
- Pipeline mapping: each ERRORLOG/XEvent line → source code step + line number
- Background writer analysis: Ghost/QDS/CtCleanup LSN progression
- Classification rationale with raw evidence
- Dump collection recommendation

Save to: `reports/{case_id}_fo{N}_stuck_analysis.md`

### Phase 6c: Invoke cluster-review (Conditional)

**Trigger condition:** The failover was caused by a **cluster-side** problem
(quorum loss / node eviction / WSFC communication), NOT a SQL lease/health/CPU
timeout. Invoke when ANY of these hold:

- Phase 4b Step 3 routed to the **Cluster / Infrastructure** branch.
- **ERRORLOG contains AG / WSFC error numbers** (the usual entry signal — the
  investigation begins from AG failover, so these ERRORLOG errors are where the
  cluster-side cause first surfaces):
  `1135` (node evicted), `19407`/`19419`/`19421` (lease / heartbeat), `41005`
  (WSFC event notification failed), `41009`, `41034` (AG/WSFC resource online /
  cluster op error), `41048`, `41049`, `41066`, `41091` (WSFC lost quorum),
  `41142`, `41143`, `41144`, `41160`, `41161`, or any `The Cluster service ...` /
  `node ... was removed` text.
- cluster.log / System event log shows `5925` (lost quorum), `5985` (quarantined),
  `1177` (quorum-loss shutdown), `1564` (FSW failure), `1069` (resource failed).
- The **same node loses every flap** (structural asymmetry suspected).

**When NOT to invoke:** trigger was SQL lease/health/CPU timeout with no quorum
loss → stay in the performance path (Phase 4b Steps 5–8).

**How to invoke:**
Read the cluster-review skill from `.github/skills/cluster-review/SKILL.md`.
Before scanning, read the signature catalog KB:
- `.github/skills/cluster-review/reference/cluster_log_signatures.md`

**cluster-review starts with a Phase 0 Input Gate:** it STOPS and scans the case
dir for the Windows **event logs** (`*.evtx`) and the **cluster registry hive**
(`*_reg_Cluster.hiv` / `CLUSDB`) plus cluster.log from BOTH nodes. These are
often NOT in the initial AG-failover collection — if missing, it asks the user to
provide them (with the exact `Get-ClusterLog` / `reg save` / `wevtutil` commands)
before continuing.

Provide it: cluster.log from **both** nodes, the Cluster registry hive
(`*_reg_Cluster.hiv` / `CLUSDB`), the Windows event logs (`System.evtx`,
`*FailoverClustering*.evtx`), both ERRORLOGs, the incident time + UTC offset,
and the node→site mapping.

**What it produces:**
- A **dual artifact**: (a) a single NUMBERED unified UTC→local cluster.log
  timeline across BOTH nodes (10 checkpoints, including #0 last-good-heartbeat and
  #7 AG group placement / PossibleOwner), and (b) a **verbatim per-step evidence**
  list (one raw cluster.log line per checkpoint).
- Authoritative config audit from the hive (witness?, per-node NodeWeight,
  fault domains, networks, tunables) — the **§11 "Cluster 配置总结"** section,
  sub-sections 11.1–11.9 (cluster body, quorum/witness, node votes, site fault
  domain, networks, heartbeat thresholds, resources, root-cause conclusion,
  remediation steps).
- A **trigger vs enabling-root-cause** split: the heartbeat flap is the trigger;
  the hive config (zero-weight node / missing witness / site misconfig) is the
  enabling root cause.
- Root-cause classification (zero-weight node / missing witness / site misconfig /
  single heartbeat path) backed by the exact hive value + cluster.log line.
- A parameterized remediation command template.

> ⚠️ **cluster.log provenance gate:** cluster-review validates each cluster.log
> header (`Current node` / `Build Number` / time-zone offset) against the case's
> AG nodes, OS build, and site. If a `node1_Cluster.log` / `node2_Cluster.log`
> belongs to a DIFFERENT cluster (wrong node names / OS / TZ), it is DISCARDED and
> NOT used. Only validated per-node logs feed the timeline.

**Integrate cluster-review's output into the final report:**
- Its §11 hive-config audit → the report's **§11 (Cluster 配置总结)** verbatim.
- Its numbered timeline → merged into the report's **§4 unified timeline** (§6.A).
- Its verbatim per-step lines → folded into **§5 逐步证据** (§6.B).
- Its quarantine finding → the report's **§7 (隔离分析)**.
- If it concludes the enabling root cause is cluster-layer, the report's **§1
  执行摘要** root-cause cell points to §11; the WSFC flap stays labelled as the
  trigger.

> ⚠️ **§11 hive enumeration OVERRIDES any narrative §2.** The Cluster registry
> hive (`*_reg_Cluster.hiv` / `CLUSDB`) is the **authoritative** source for
> witness presence, per-node `NodeWeight`, fault domains, and tunables. If a
> narrative / customer description in §2 disagrees with the hive (e.g. §2 says
> "FSW, weights=(2)" but the hive shows **no witness, NodeWeight 0/1**), use the
> **hive values** everywhere and add an explicit **reconciliation note** in §11
> flagging the conflict and which source you trust (the hive) and why. Never let
> a stale narrative override the enumerated config.

Save to: `reports/{case_id}_cluster_review.md`

### Phase 7: Generate HTML Report

Generate an HTML report using the Catppuccin Mocha dark theme.
The report MUST mirror the reference report's §1–§11 layout (see the **Report
Skeleton** table in Phase 6). Render these top-level sections in order:

1. **§1 执行摘要** — exec-summary table with the explicit **Trigger vs enabling
   Root Cause** split (plus flap count, why-stuck, why-no-auto-failover, data
   loss, recovery). Put this first, above everything.
2. **§2 环境与拓扑** — version, AG config, DTC, replica topology, node→site map.
3. **§3 根本原因** — verbatim causal-chain evidence (cluster.log / ERRORLOG).
4. **§4 完整时间线** — ONE numbered cross-node table
   (序号｜本地时间(UTC+8)｜节点｜事件｜含义｜来源).
5. **§5 时间线逐步证据** — `证据 N` blocks, one raw log line per timeline step.
6. **§6 为什么没有自动 failover** — only if the AG did not auto-fail-over
   (availability_mode / failover_mode=MANUAL / LSN-not-behind / WSFC
   PossibleOwner exclusion / AlwaysOn_health role machine).
7. **§7 隔离 (Quarantine) 分析** — when node quarantine (5985) was seen.
8. **§8 数据丢失分析** — boundary LSN + committed-loss verdict (always present).
9. **§9 逐库状态** — the per-DB status table(s) (Phase 6.4); one per FO if needed.
10. **§10 建议** — dump collection, WSFC/AG remediation (from docs-lookup).
11. **§11 Cluster 配置总结** — cluster-review's hive audit (11.1–11.9), when it ran.

Keep the per-FO detail (6.1 Trigger / 6.2 AG Flow / 6.4 Per-DB / 6.5 Cross-FO) as
collapsible sub-blocks feeding §3–§5 and §9 — do not duplicate the timeline.

Save to: `reports/{case_id}_ag_failover_report.html`

### Phase 8: Search TSG Wiki, KB Articles, and Bug Work Items

After reports are generated, invoke the `docs-lookup` agent to search for related
technical knowledge. This step runs **automatically** when stuck DBs are found or
when specific errors are identified.

#### What to Search

| Search Target | When | What to Look For |
|---------------|------|-----------------|
| **CSS Wiki TSG** | Always | AG stuck RESOLVING TSGs, latch timeout TSGs, WSFC troubleshooting |
| **Microsoft Learn KB** | Always | Known fixes for errors found (e.g. Error 35299, 41144, 22006) |
| **Bug Work Items** | When stuck DBs found | Existing bugs for `AcquireXDbLockWithKill`, `DatabaseSwitchRoles` stuck |
| **CU Fix Lists** | When version is known | Check if customer's CU has relevant fixes |

#### Search Queries (run in parallel via docs-lookup sub-agents)

1. **CSS Wiki**: Search for AG-specific TSGs
   - `"AG database stuck RESOLVING"` or `"AG failover stuck"`
   - `"AcquireXDbLockWithKill"` or `"Nonqualified rollback 100%"`
   - `"Error 41144"` / `"Error 1722"` / `"WSFC lease timeout"`
   - The specific error codes found in the case

2. **Microsoft Learn**: Search for KB and docs
   - `"AG database stuck RESOLVING state"`
   - `"KB3139534"` (known AG RESOLVING issue)
   - `"availability group failover troubleshooting"`
   - Error numbers from ERRORLOG (e.g. `"error 35299"`, `"error 22006"`)

3. **Bug/Work Items**: Search ADO for existing bugs
   - `"DatabaseSwitchRoles stuck"` or `"AcquireXDbLockWithKill infinite"`
   - `"AG RESOLVING Ghost cleanup"` or `"AG RESOLVING QDS"`

#### Output

Save search results to: `reports/{case_id}_docs/`
- One markdown file per search source (e.g. `csswiki_AG_stuck_resolving_TSGs.md`)
- Include in the final report's Recommendations section

## Dump Collection Guidance

### Why Dump Is Essential

ERRORLOG tells us **where** each DB is stuck (Step 21 vs Step 11-15).
Only thread call stacks in a dump can tell us **why** — which specific resource
deadlock prevents progress.

### Arguing for Dump Collection

**The mitigation for stuck RESOLVING is restarting SQL Server.**
Since a restart is already required, collecting a dump before restart adds zero
additional downtime — the databases are already inaccessible.

Recommended procedure when issue recurs:
1. Confirm databases stuck in RESOLVING (service already degraded)
2. Collect filtered dump (1-3 minutes):
   ```sql
   DBCC STACKDUMP WITH NO_CHANGE_TRACKING;
   ```
   Or via sqldumper:
   ```
   "C:\Program Files\Microsoft SQL Server\150\Shared\SqlDumper.exe" <PID> 0 0x8100 0 "C:\Temp\dumps"
   ```
3. Immediately restart SQL Server

### What to Look for in the Dump

1. **Per-DB worker thread call stacks** — confirm stuck at `AcquireXDbLockWithKill` or sub-manager Stop
2. **DB shared lock holders** — identify which system thread (Ghost/QDS/Checkpoint) blocks exclusive lock
3. **Sub-manager internal state** — if Category C, which Stop() call is blocked and on what resource

## DTC Analysis

### Check DTC Configuration

Search ERRORLOG for per-database DTC resource manager events:

| Pattern | Meaning |
|---------|---------|
| `Initializing MS DTC resource manager [GUID] for database 'X'` | DTC_SUPPORT=PER_DB |
| `MS DTC resource manager [X] has been released` | DTC_SUPPORT=PER_DB |
| No per-DB DTC events for an AG | DTC_SUPPORT NOT configured |

**Do NOT assume DTC is involved** just because databases are stuck and no "DTC released"
message appears. Confirm by checking for per-DB DTC RM init events. If none exist,
DTC_SUPPORT is not configured and DTC is not the cause.

### Cross-Server DTC Comparison

When both old and new primary ERRORLOGs are available, compare DTC RM GUIDs.
Same GUIDs on both sides = DTC correctly transferred. New primary completing
successfully while old primary is stuck = problem isolated to old primary's internal state.

## Notes

- ERRORLOG timestamps are in server local time; XEvent timestamps are in UTC
- AlwaysOn.OUT is a snapshot at collection time, not incident time
- `database_id` in ABORT_AFTER_WAIT messages must be mapped via AlwaysOn.OUT
- Remote harden failed messages continuing = system threads still writing to the DB
  (proves the DB is not exclusively locked, confirming Step 21 not yet acquired)
- Error 22006 (ADR VersionCleaner aborted) = confirms exclusive DB lock waiter exists
- Some databases may have zero ERRORLOG messages (Category C) — most concerning
- KB3139534 — AG database stuck in RESOLVING due to internal threads
