---
name: ag-failover-analysis
description: >-
  Analyze AG failover events by cross-referencing AlwaysOn.OUT, ERRORLOG, and
  AlwaysOn_health XEvent data. Builds per-database comparison table showing each
  step of the AG role transition pipeline. Use when databases are stuck in
  RESOLVING after AG failover, or when the user says "analyze AG failover",
  "AG databases stuck", "分析 AG failover".
tools: [execute, read, edit, search, agent, todo, web, msdata/*, microsoft-learn/*, csswiki/*, bluebird-mcp-sql/*, bluebird-mcp-2022/*, bluebird-mcp-2025/*, bluebird-mcp-2019/*, bluebird-mcp-2017/*, bluebird-mcp-2016/*, icm-prod/*, enghub/*, azure-mcp/*]
agents: [docs-lookup, source-search, import-xevent, analyze-xevent]
---

# AG Failover Analysis Agent

Orchestrates AG failover investigation by running the skill phases in sequence.

## Skill Reference

Read the full methodology from:
[.github/skills/ag-failover-analysis/SKILL.md](../skills/ag-failover-analysis/SKILL.md)

## Orchestration Steps

### Phase 0: Collect Environment Info & Logs

Ask the user for:

| Item | Example | Why |
|------|---------|-----|
| **Old primary hostname** | `HKAZEPWDB0031` | The node that was PRIMARY before failover |
| **New primary hostname** | `HKAZEPWDB0011` | The node promoted to PRIMARY |
| **Log file path(s)** | `D:\Cases\2605110030000091\` | Local path where logs are stored |
| **Incident time** | `2026-05-11 07:53` (server local) | Approximate time of the failover |

Verify required files exist in `case_dir`:
- ERRORLOG (current + .1) from both hosts
- `*_AlwaysOn.OUT` from at least the old primary
- `*AlwaysOn_health*.xel` from at least the old primary

### Phase 1: Parse AlwaysOn.OUT — Build AG→DB Mapping

```
node scripts/ag-failover-analysis/parse_alwayson_out.js <case_dir>
```

Output: `ag_schema.json` in `case_dir`.
Builds AG→DB mapping with database_id, replica info, DTC support.

### Phase 2: Extract ERRORLOG AG Events

```
node scripts/ag-failover-analysis/extract_ag_errorlog.js <case_dir> <target_date>
```

Prereq: `ag_schema.json` (Phase 1).
Output: `ag_errorlog_events.json`, `ag_timeline.txt`.
Extracts and categorizes all AG-related ERRORLOG events from both hosts.

### Phase 2b: Detect Failover Incidents

```
node scripts/ag-failover-analysis/build_failover_timeline.js <case_dir>
```

Prereq: `ag_schema.json`, `ag_errorlog_events.json`.
Output: `failover_incidents.json`.
Clusters events into failover incidents, classifies each, builds per-DB status.

### Phase 3: Import AlwaysOn_health XEvent into SQL Server

Run once per host:
```
sqlcmd -S localhost -E -v case_id="{case_id}" host="{hostname}" xel_path="{case_dir}/{host}/AlwaysOn_health*.xel" -i scripts/ag-failover-analysis/import_ag_xevent.sql
```

Creates database `ag_{case_id}` with shredded tables:
- `xe.hadr_trace` — Reverting begin/finished, internal AG messages
- `xe.hadr_sync_state` — Per-DB sync state changes (critical for classification)
- `xe.hadr_replica_state` — AG-level role transitions
- `xe.hadr_manager_state` — AG manager ONLINE/OFFLINE
- `xe.hadr_ddl` — AG DDL operations

**XEvent timestamps are UTC. ERRORLOG timestamps are server local time.**

### Phase 2c: Merge ERRORLOG + XEvent Timeline

```
node scripts/ag-failover-analysis/merge_timeline.js <case_dir> <sql_server> <utc_offset>
```

Prereq: `ag_schema.json`, `ag_errorlog_events.json`, `ag_{case_id}` database.
Output: `merged_timeline.json`, `merged_timeline.txt`.
Merges XEvent (UTC→local) with ERRORLOG events into unified timeline.

### Phase 4: Per-FO Timeline Generation

```
node scripts/ag-failover-analysis/gen_per_fo_report.js <case_dir>
```

Prereq: `failover_incidents.json`, `merged_timeline.json`.
Output: Per-FO timeline files (`fo1_timeline.txt`, `fo2_timeline.txt`, etc.).
These serve as an index/summary for analysis — but always go back to original ERRORLOG.

### Phase 4b: Classify Failover Trigger — Lease Timeout vs Health Check vs Cluster Error

For each FO, determine **WHY** the AG went offline. The trigger type determines the
investigation path:

1. **Check ERRORLOG Error Numbers:**
   - Error **19419** = "WSFC did not receive signal from SQL" → **SQL Lease renewal timeout**
   - Error **19421** = "SQL did not receive signal from WSFC" → **Diagnostics heartbeat lost**
   - Error **19407** = generic lease expired (accompanies 19419 or 19421)
   - Error **1135** = node eviction → **Cluster error** (not SQL performance)
   - Error **41005** = WSFC comm failure → **Cluster error**

2. **Confirm with Cluster Log** (authoritative source):
   - `Lease renewal failed with timeout error` → SQL Lease renewal timeout
   - `Failure detected, diagnostics heartbeat is lost` → Diagnostics heartbeat lost
   - `Node was removed from the active failover cluster membership` → Node eviction

3. **Branch based on trigger type:**

   **For ALL trigger types:**
   - Extract perf counter from cluster log (CPU/memory/disk at FO moment)
   - If CPU/IO normal for cluster errors → confirms infrastructure issue, not performance

   **If Lease timeout / Health check timeout** → Performance investigation path:
   - Analyze sp_server_diagnostics from system_health XEvent (5-min: SYSTEM sysCPU/sqlCPU,
     QUERY_PROCESSING workers/pendingTasks, IO_SUBSYSTEM, RESOURCE)
   - Import SQLDIAG 5-sec data from FailoverCluster_health_XeLogs (if available)
   - Detect sp_server_diagnostics gaps >7s (proves thread scheduling stall)
   - Classify CPU pattern: SQL CPU intensive / OS CPU occupied / Worker exhaustion / IO bottleneck

   **If Cluster error (1135, 41005, etc.)** → Infrastructure investigation path:
   - Not SQL Server performance related
   - Check WSFC network, quorum, storage
   - Check cluster log for node heartbeat failures
   - Check Windows Event Log (System, FailoverCluster)

See full methodology in SKILL.md §4b.

### Phase 5: Classify Each Database

Use the evidence matrix from the skill (§5) to classify each DB:

| Category | Key Evidence |
|----------|-------------|
| **A: Recovered** ✅ | All ERRORLOG + XEvent steps present |
| **B: Stuck at AcquireXDbLockWithKill** ❌ | Nonqualified Rollback loop (Error 35299, "100%") |
| **C: Stuck at Sub-manager Stop** ❌ | Silent — no NQ rollback, no ABORT Kill, no Reverting |

**Category B vs C:** NQ Rollback in ERRORLOG → B. No NQ Rollback → C.

### Phase 6: Per-Failover Analysis Report

For each FO incident, follow the skill's analysis workflow:

1. **Use `failover_incidents.json`** for time ranges and affected AGs
2. **Use per-FO timeline files** as an index/summary
3. **Read ORIGINAL ERRORLOG files** for each FO's time range on BOTH hosts
   (FO start − 1 min to FO start + 2 min minimum — the other host may react later)
4. **Query the XEvent SQL database** (`ag_{case_id}`) in UTC for the same range
5. **Write analysis with verbatim ERRORLOG/XEvent evidence** — never summarize

Report sections per FO:
- **6.1 Trigger** — raw evidence of WHY failover happened
- **6.2 AG-Level Flow** — state changes from both hosts
- **6.3 Per-Host Analysis** — analyze EVERY host
- **6.4 Per-DB Status Table** — full table with actual timestamps per node per AG
- **6.5 Key Observations** — each citing specific log evidence
- **6.6 Cross-FO Comparison** — if multiple FOs

### Phase 6b: Invoke stuck-db-analysis (Conditional)

**Trigger:** Any FO has databases stuck in RESOLVING (Category B or C).

Read the stuck-db-analysis skill and source code KB:
- `.github/skills/stuck-db-analysis/SKILL.md`
- `.github/skills/stuck-db-analysis/reference/database_switch_roles_pipeline.md`
- `.github/skills/stuck-db-analysis/reference/lock_dependency.md`

Output: `reports/{case_id}_fo{N}_stuck_analysis.md`

**Skip if all DBs recovered.**

### Phase 7: Generate HTML Report

Generate HTML report using Catppuccin Mocha dark theme (see copilot-instructions.md).
Structure mirrors Phase 6 analysis. Save to: `reports/{case_id}_ag_failover_report.html`

### Phase 8: Invoke docs-lookup Agent

After reports are generated, invoke `docs-lookup` agent to search for:
- **CSS Wiki TSG**: AG stuck RESOLVING, WSFC troubleshooting
- **Microsoft Learn KB**: Known fixes for errors found (35299, 41144, 22006, etc.)
- **Bug Work Items**: Existing bugs for `AcquireXDbLockWithKill`, `DatabaseSwitchRoles`
- **CU Fix Lists**: Relevant fixes for the customer's SQL Server version

Save results to: `reports/{case_id}_docs/`
