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

## Step 4: XEvent Analysis (.xel files)

XEvent analysis uses a two-phase pipeline: PowerShell extracts binary XEL → JSON,
then Node.js analyzes the JSON. This runs **in parallel with** or **after** ERRORLOG
parsing (Steps 1-3).

### 4.0 Check Inputs

If the user provides `.xel` file paths (local or UNC), proceed to Step 4.1.
Detect file type by name:
- `system_health*.xel` → system_health session (default, richest data)
- `AlwaysOn_health*.xel` → AG health session
- Other `*.xel` → custom session

### 4.1 Extract XEL → JSON (PowerShell)

#### Script Location
```
C:\Users\lduan\.claude\sql-csi\scripts\extract_xel.ps1
```

#### Prerequisites
The script auto-installs the `SqlServer` PowerShell module if not present.
To install manually:
```powershell
Install-Module SqlServer -Scope CurrentUser -Force
```

#### Usage
```bash
# Single file
powershell -File sql-csi/scripts/extract_xel.ps1 -Path "system_health_0_xxx.xel" -Output events.json

# Multiple files (glob)
powershell -File sql-csi/scripts/extract_xel.ps1 -Path "system_health*.xel" -Output events.json

# With time filter
powershell -File sql-csi/scripts/extract_xel.ps1 -Path "*.xel" -Days 3 -Output events.json

# UNC path
powershell -File sql-csi/scripts/extract_xel.ps1 -Path "\\server\share\system_health*.xel" -Output events.json
```

#### Output Format
The script produces a JSON file with this structure:
```json
{
  "extraction_date": "2021-05-07T23:11:15Z",
  "source_files": ["system_health_0_xxx.xel", "system_health_0_yyy.xel"],
  "total_events": 12345,
  "events": [
    {
      "name": "error_reported",
      "timestamp": "2021-05-02T03:05:42.04+00:00",
      "fields": { "error_number": 19432, "severity": 16, "state": 0, "message": "..." },
      "actions": { "session_id": 55, "database_name": "ICADB" }
    }
  ]
}
```

### 4.2 Analyze XEvent JSON (Node.js)

#### Script Location
```
C:\Users\lduan\.claude\sql-csi\scripts\parse_xevent.js
```

#### Usage
```bash
# Console summary
node sql-csi/scripts/parse_xevent.js events.json

# With time filter + JSON output
node sql-csi/scripts/parse_xevent.js events.json --days 3 --json --output xevent_findings.json

# Cross-correlate with ERRORLOG findings
node sql-csi/scripts/parse_xevent.js events.json --errorlog errorlog_findings.json --json --output xevent_findings.json
```

#### What the Script Analyzes

| Event Category | XEvent Names | Extracted Data |
|---------------|-------------|----------------|
| **Errors** | `error_reported` | error_number, severity, state, message |
| **Waits** | `wait_info`, `wait_info_external` | wait_type, duration_ms, signal_ms |
| **Scheduler** | `scheduler_monitor_*` | non-yielding, CPU %, idle %, I/O pending |
| **Memory** | `memory_broker_ring_buffer_recorded`, `sp_server_diagnostics_component_result` | memory_ratio, target, notifications |
| **Deadlocks** | `xml_deadlock_report` | deadlock XML graph |
| **Connectivity** | `connectivity_ring_buffer_recorded`, `login_failed` | connection events |

#### Output JSON Structure
```json
{
  "analysis_type": "sql-csi-xevent",
  "source": "system_health",
  "time_range": { "first": "...", "last": "..." },
  "error_summary": { "total_unique": N, "total_occurrences": M, "fatal_count": F },
  "errors": [ { "error_number": 19432, "severity": 16, "count": 42, "subsystem": "HADR_ERROR2", ... } ],
  "wait_analysis": {
    "top_waits": [ { "wait_type": "HADR_LOGCAPTURE_SYNC", "total_duration_ms": 98234, "count": 42, "avg_ms": 2339, "category": "HADR" } ],
    "wait_categories": { "HADR": 98234, "IO": 45000 }
  },
  "scheduler_events": { "non_yielding_count": 2, "non_yielding": [...] },
  "memory_events": { "total": 10, "events": [...] },
  "deadlocks": { "count": 1, "events": [...] },
  "patterns": [...],
  "timeline": [...],
  "code_search_targets": [...],
  "correlation": { "errors_in_both": [19432], "xevent_only_errors": [8645], "errorlog_only_errors": [1222] }
}
```

### 4.3 Review XEvent Findings

After the script runs, review:

#### Error Events
- Errors from XEvent may include errors **not logged** to ERRORLOG (lower severity, filtered by trace flags)
- XEvent captures exact timestamp with microsecond precision vs ERRORLOG's centisecond

#### Wait Analysis
The script classifies waits into categories and shows top waits by total duration:

| Wait Category | Wait Types | Indicates |
|--------------|------------|-----------|
| **CPU** | `SOS_SCHEDULER_YIELD`, `THREADPOOL`, `SOS_WORK_DISPATCHER` | CPU pressure or worker exhaustion |
| **I/O** | `PAGEIOLATCH_*`, `WRITELOG`, `IO_COMPLETION`, `ASYNC_IO_COMPLETION` | Disk I/O bottleneck |
| **Locking** | `LCK_M_*` | Lock contention |
| **Latch** | `PAGELATCH_*`, `LATCH_*` | Page or non-page latch contention |
| **Network** | `ASYNC_NETWORK_IO`, `NET_WAITFOR_PACKET` | Client-side network delay |
| **Memory** | `RESOURCE_SEMAPHORE`, `CMEMTHREAD` | Memory grant waits |
| **HADR** | `HADR_*`, `PWAIT_HADR_*` | AG synchronization/transport |
| **Backup** | `BACKUP*`, `BACKUPIO` | Backup operations |
| **Preemptive** | `PREEMPTIVE_OS_*` | External OS calls (AD, file system, etc.) |
| **CLR** | `CLR_*`, `SQLCLR_*` | CLR execution |

#### Scheduler Events
Non-yielding scheduler events indicate a thread held a scheduler too long (> 5 seconds).
Multiple non-yielding events in a short window suggest severe CPU or I/O pressure.

#### Deadlocks
`xml_deadlock_report` events contain the full deadlock graph XML. The script extracts
timestamps and raw XML for detailed analysis.

### 4.4 Merge with ERRORLOG Findings

When both ERRORLOG and XEvent data are available, use `--errorlog` to cross-correlate:

```bash
node sql-csi/scripts/parse_xevent.js events.json --errorlog errorlog_7days_findings.json
```

The correlation output shows:
- **errors_in_both** — high confidence, confirmed by two independent sources
- **xevent_only_errors** — may be lower severity or suppressed from ERRORLOG
- **errorlog_only_errors** — may not be captured by XEvent session configuration

Merge strategy for `code_search_targets`:
1. Errors in both → boost priority (if MEDIUM, promote to HIGH)
2. XEvent-only errors → add to investigation list
3. Wait patterns → correlate with ERRORLOG timeline gaps (gaps may be caused by heavy waits)

### 4.5 Fallback — SQL Queries (When PowerShell Not Available)

If the `SqlServer` PowerShell module cannot be installed, generate SQL queries for the
user to run on a SQL Server instance with access to the .xel files:

**Query A: Error events**
```sql
SELECT
    DATEADD(mi, DATEDIFF(mi, GETUTCDATE(), GETDATE()),
        event_data.value('(event/@timestamp)[1]', 'datetime2')) AS local_time,
    event_data.value('(event/data[@name="error_number"]/value)[1]', 'int') AS error_number,
    event_data.value('(event/data[@name="severity"]/value)[1]', 'int') AS severity,
    event_data.value('(event/data[@name="state"]/value)[1]', 'int') AS state,
    event_data.value('(event/data[@name="message"]/value)[1]', 'nvarchar(max)') AS message
FROM (
    SELECT CAST(event_data AS xml) AS event_data
    FROM sys.fn_xe_file_target_read_file(N'{xel_path}', NULL, NULL, NULL)
    WHERE object_name = 'error_reported'
) x
WHERE event_data.value('(event/data[@name="severity"]/value)[1]', 'int') >= 11
ORDER BY local_time DESC;
```

**Query B: Wait info**
```sql
SELECT
    DATEADD(mi, DATEDIFF(mi, GETUTCDATE(), GETDATE()),
        event_data.value('(event/@timestamp)[1]', 'datetime2')) AS local_time,
    event_data.value('(event/data[@name="wait_type"]/text)[1]', 'nvarchar(100)') AS wait_type,
    event_data.value('(event/data[@name="duration"]/value)[1]', 'bigint') AS duration_ms,
    event_data.value('(event/data[@name="signal_duration"]/value)[1]', 'bigint') AS signal_duration_ms
FROM (
    SELECT CAST(event_data AS xml) AS event_data
    FROM sys.fn_xe_file_target_read_file(N'{xel_path}', NULL, NULL, NULL)
    WHERE object_name IN ('wait_info', 'wait_info_external')
) x
WHERE event_data.value('(event/data[@name="duration"]/value)[1]', 'bigint') > 5000
ORDER BY local_time DESC;
```

**Query C: Scheduler monitor**
```sql
SELECT
    DATEADD(mi, DATEDIFF(mi, GETUTCDATE(), GETDATE()),
        event_data.value('(event/@timestamp)[1]', 'datetime2')) AS local_time,
    event_data.value('(event/data[@name="scheduler_id"]/value)[1]', 'int') AS scheduler_id,
    event_data.value('(event/data[@name="process_utilization"]/value)[1]', 'int') AS cpu_pct,
    event_data.value('(event/@name)[1]', 'nvarchar(100)') AS event_name
FROM (
    SELECT CAST(event_data AS xml) AS event_data
    FROM sys.fn_xe_file_target_read_file(N'{xel_path}', NULL, NULL, NULL)
    WHERE object_name LIKE 'scheduler_monitor%'
) x
ORDER BY local_time DESC;
```

---


### 5.3 Merge ERRORLOG + XEvent into Combined Report

When both ERRORLOG and XEvent data are available, generate a merged HTML report:

#### 5.3.1 Run XEvent Analysis with ERRORLOG Cross-Correlation

Use the same `--days` value from Step 0 for both ERRORLOG and XEvent:

```bash
# Step 1: ERRORLOG parsing (already done in Step 1)
node parse_errorlog.js <errorlog_files> --days {N} --json --output {case_id}_errorlog_findings.json

# Step 2: Extract XEL files from same directory
powershell -File extract_xel.ps1 -Path "{xel_dir}\system_health*.xel" -Days {N} -Output {case_id}_xevent_extract.json

# Step 3: XEvent analysis with cross-correlation
node parse_xevent.js {case_id}_xevent_extract.json --errorlog {case_id}_errorlog_findings.json --json --output {case_id}_xevent_findings.json

# Step 4: Generate merged HTML report
node gen_merged_report.js {case_id}_errorlog_findings.json {case_id}_xevent_findings.json {case_id}_merged_report.html
```

#### 5.3.2 Merged Report Script

```
C:\Users\lduan\.claude\sql-csi\scripts\gen_merged_report.js
```

Usage:
```bash
node gen_merged_report.js <errorlog_findings.json> <xevent_findings.json> <output.html>
```

The merged report includes 8 sections:
1. **ERRORLOG Top Errors** — prioritized error table + patterns
2. **XEvent Wait Analysis** — all wait events with timeline + summary by type
3. **XEvent sp_server_diagnostics** — WARNING/ERROR state alerts only
4. **XEvent Scheduler Monitor** — CPU>75% or Memory<80% alerts only
5. **XEvent error_reported** — errors as ERRORLOG complement
6. **Cross-Correlation** — errors in both / XEvent-only / ERRORLOG-only
7. **Microsoft Docs Research** — KB fixes, wait type analysis, recommendations
8. **Conclusions & Recommendations** — root cause chain + action items

#### 5.3.3 Auto-Detect XEL Files

When the user provides an ERRORLOG directory, automatically look for `system_health*.xel`
in the same directory:

```bash
# Check for XEL files alongside ERRORLOG
ls {errorlog_dir}/system_health*.xel 2>/dev/null
```

If found, inform the user and include in analysis automatically.

#### 5.3.4 Microsoft Docs Integration in Report

During Step 7 (Microsoft Docs Lookup), the following research is performed and
embedded in section 7 of the merged report:

For **top ERRORLOG errors** (from `code_search_targets`):
- Search for KB fixes and CU applicability
- Official error description from errors reference docs
- Known fix status (FIX_NOT_APPLIED / FIX_ALREADY_APPLIED / NO_KB_FOUND)

For **top XEvent waits** (from `wait_analysis.wait_summary`):
- Official wait type description from [I/O troubleshooting guide](https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/troubleshoot-sql-io-performance)
- Common causes and resolution steps
- Threshold comparison (10-15ms normal, flag values above)

Results are inserted into the HTML report as section 7 with links to source docs.

### 5.4 Return to Orchestrator (Workflow 4)

When called from Full CSI, the JSON output provides `code_search_targets` directly:

```json
{
  "code_search_targets": [
    { "error_number": 19432, "priority": "HIGH", "subsystem": "HADR_ERROR2", "severity": 16, "count": 52 },
    { "error_number": 17836, "priority": "HIGH", "subsystem": "SERVICE", "severity": 20, "count": 56 }
  ]
}
```

The orchestrator proceeds to:
1. **Step 6** → ask user which error to investigate
2. **Step 7** → Microsoft Docs lookup (KB fixes, diagnostic queries)
3. **Workflow 3** → source code search (if user requests deeper investigation)

