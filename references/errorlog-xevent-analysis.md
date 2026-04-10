# Errorlog + XEvent Analysis Skill

## Overview

This skill parses SQL Server ERRORLOG files and default XEvent traces (system_health)
to extract errors, build timelines, identify wait patterns, and produce structured
findings. After parsing, it uses Microsoft Learn MCP tools (`microsoft_docs_search`,
`microsoft_code_sample_search`, `microsoft_docs_fetch`) to look up official documentation,
known KB fixes, and diagnostic queries for each high-priority error.

## Activation Triggers

Activate this skill when the user:
- Says "analyze errorlog", "parse errorlog", "分析 errorlog"
- Provides a path to an ERRORLOG file
- Says "analyze xevent", "parse xel", "分析 XEvent"
- Provides system_health XEL data or file paths
- Says "what errors are in this log"

## Required Inputs

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `errorlog_path` | string | **Yes** | Path to ERRORLOG file(s). Supports `ERRORLOG`, `ERRORLOG.1`, etc. |
| `xel_path` | string | No | Path to system_health XEL files (glob pattern OK: `system_health*.xel`) |
| `time_range` | string | No | Time filter: "last 2 hours", "2026-03-22 02:00 to 03:00", etc. |
| `case_id` | string | No | Case identifier for output file naming |

## Required MCP Servers

| Server | Purpose | Required |
|--------|---------|----------|
| `microsoft-learn` | Search docs, KB articles, diagnostic queries (Step 7) | **Yes** for Step 7 |

If `microsoft-learn` MCP is not connected, skip Step 7 and fall back to Workflow 3 directly.

---

## Step 0: Interactive — Ask Focus Period (MANDATORY)

Before parsing, **always ask the user** how many days of logs to focus on.

### 0.1 Why This Step Is Required

ERRORLOG files can span weeks or months. Analyzing everything produces noisy results with
hundreds of errors that obscure the actual incident. The user typically cares about a
specific time window (e.g., "the outage happened last Tuesday").

### 0.2 How to Ask

Use `AskUserQuestion` with these options:

```
Question: "ERRORLOG 中最新的条目是 {latest_timestamp}。你想重点分析最近几天的日志？"
Header: "Focus Period"
Options:
  - "1 天" — Only the most recent 24 hours
  - "3 天" — Last 3 days
  - "7 天 (推荐)" — Last 7 days, good default for most investigations
  - "全部" — Analyze all records (may be noisy for large logs)
```

To determine the latest timestamp **before** asking, do a quick scan:
```bash
# Quick scan: read last 20 lines to find latest timestamp
node -e "
const fs=require('fs');
const b=fs.readFileSync(process.argv[1]);
const t=b.toString(b[0]===0xFF?'utf16le':'utf8');
const lines=t.split(/\r?\n/);
for(let i=lines.length-1;i>=0;i--){
  const m=lines[i].match(/^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})/);
  if(m){console.log(m[1]);break;}
}" <errorlog_path>
```

### 0.3 Pass to Script

Map the user's answer to `--days`:
- 1 天 → `--days 1`
- 3 天 → `--days 3`
- 7 天 → `--days 7`
- 全部 → (no `--days` flag)

---

## Step 1: Run the Parser Script (Primary Method)

Use the `parse_errorlog.js` script for structured parsing. It handles encoding detection,
multi-line messages, pattern detection, and priority assignment automatically.

### 1.1 Script Location

```
C:\Users\lduan\.claude\sql-csi\scripts\parse_errorlog.js
```

### 1.2 Usage

```bash
# Single file
node sql-csi/scripts/parse_errorlog.js <errorlog_path>

# Multiple files (oldest first — script auto-sorts by number)
node sql-csi/scripts/parse_errorlog.js ERRORLOG ERRORLOG.1 ERRORLOG.2 ... ERRORLOG.12

# With JSON output saved to file
node sql-csi/scripts/parse_errorlog.js <files> --json --output findings.json

# With time range filter
node sql-csi/scripts/parse_errorlog.js <files> --from "2021-05-02 03:00" --to "2021-05-02 04:00"
```

### 1.3 What the Script Does

The script performs Steps 1-5 of this skill automatically:

1. **Encoding detection** — auto-detects UTF-16LE (with/without BOM), UTF-16BE, UTF-8
2. **Multi-line parsing** — timestamp lines start new records, continuation lines are appended
3. **Record classification** — errors, AG state changes, server start/stop, I/O warnings, memory pressure, login failures
4. **Error grouping** — unique errors with count, first/last seen, severity, subsystem
5. **Pattern detection** — error cascades, repeating errors, paired errors, LSN progression
6. **Timeline building** — chronological events with gap analysis
7. **Priority assignment** — HIGH/MEDIUM/LOW based on severity, cascade position, occurrence count

### 1.4 Script Output Formats

**Console output** (default): human-readable summary with error table, timeline, patterns, code search targets.

**JSON output** (`--json`): structured data for downstream workflows:

```json
{
  "analysis_type": "sql-csi-errorlog",
  "server_info": { "instance": "...", "version": "...", "ram": ..., "cpus": ... },
  "error_summary": { "total_unique": N, "total_occurrences": M, "fatal_count": F },
  "errors": [ { "error_number": 19432, "severity": 16, "count": 52, "subsystem": "HADR_ERROR2", ... } ],
  "patterns": [ { "type": "PAIRED_ERRORS", ... }, { "type": "LSN_ADVANCING", ... } ],
  "timeline": [ { "timestamp": "...", "icon": "[ERROR]", "description": "..." } ],
  "gaps": [ { "after": "...", "before": "...", "duration_seconds": 120 } ],
  "code_search_targets": [ { "error_number": 19432, "priority": "HIGH", "priority_reasons": [...] } ]
}
```

### 1.5 Handling UNC Paths and Network Shares

SQL Server ERRORLOG files are often on network shares (UNC paths like `\\server\share\ERRORLOG`).
The script reads files directly via Node.js `fs.readFileSync`, which supports UNC paths on Windows.

If UNC access is slow, copy files locally first:
```bash
cp //server/share/ERRORLOG* /tmp/errorlogs/
node parse_errorlog.js /tmp/errorlogs/ERRORLOG*
```

---

## Step 2: Review Script Output

After the script runs, review the output for:

### 2.1 Error Priority List

The `code_search_targets` section lists errors sorted by priority:

| Priority | Criteria |
|----------|----------|
| **HIGH** | Severity >= 20 (fatal), OR severity 16+ with 5+ occurrences, OR first error in a cascade chain |
| **MEDIUM** | Severity 16 with < 5 occurrences |
| **LOW** | Severity < 16, or known benign errors |

### 2.2 Pattern Alerts

| Pattern | What It Means | Action |
|---------|---------------|--------|
| `ERROR_CASCADE` | Multiple different errors within 30 seconds | Focus on `root_error` — it's likely the cause |
| `REPEATING_ERROR` | Same error > 5 times | Check if it's a retry loop or ongoing condition |
| `PAIRED_ERRORS` | Same error appearing 2x at identical timestamp | May indicate two code paths or a loop in the engine |
| `LSN_ADVANCING` | LSN progresses despite errors | Data is flowing intermittently — not a total disconnect |

### 2.3 Timeline Gaps

Gaps > 60 seconds between significant events may indicate:
- Server hang / non-yielding scheduler
- I/O stall
- Network partition
- Cause of the incident (event before the gap triggered it)

---

## Step 3: Fallback — Manual Parsing (When Script Unavailable)

If `parse_errorlog.js` is not available, fall back to manual parsing using the Read tool.

### 3.1 Encoding Handling

SQL Server ERRORLOG is typically **UTF-16LE** encoded. If the Read tool shows spaced-out
characters (`M i c r o s o f t`), the file is UTF-16. Options:

```bash
# Option A: Node.js one-liner to convert
node -e "const fs=require('fs'); const b=fs.readFileSync('ERRORLOG'); fs.writeFileSync('ERRORLOG.utf8', b.toString('utf16le'))"

# Option B: PowerShell (if accessible)
powershell -Command "[IO.File]::ReadAllText('ERRORLOG', [Text.Encoding]::Unicode) | Set-Content 'ERRORLOG.utf8' -Encoding UTF8"

# Option C: bash (strip null bytes — lossy but works for ASCII content)
sed 's/\x00//g' ERRORLOG > ERRORLOG.utf8
```

### 3.2 Line Format Recognition

SQL Server ERRORLOG has these line formats:

**Format A — Timestamp line (new record):**
```
YYYY-MM-DD HH:MM:SS.ff <source>  <message>
```
Where `<source>` is: `spidNNNN`, `spidNNNNs`, `Server`, `Logon`, `Backup`, `Recovery`, `AppDomain`

**Format B — Continuation line:**
```
         <continued message text>
```
Lines starting with spaces/tabs belong to the previous timestamp line.

**Format C — Error line:**
```
YYYY-MM-DD HH:MM:SS.ff spidNNNN  Error: NNNNN, Severity: NN, State: NN.
```

**Format D — Stack dump:**
```
YYYY-MM-DD HH:MM:SS.ff spidNNNN  * Stack Dump being sent to ...
```

### 3.3 Key Regex Patterns

```regex
# Error line
Error:\s*(\d+),\s*Severity:\s*(\d+),\s*State:\s*(\d+)

# AG state change
availability group '([^']+)'.*changed from '([^']+)' to '([^']+)'

# Database role change
database "([^"]+)" is changing roles from "([^"]+)" to "([^"]+)"

# Login failure
Login failed for user '([^']+)'

# I/O stall
I\/O requests taking longer than

# Memory pressure
insufficient.*memory|process memory has been paged out

# LSN in message
LSN[:\s]*\(?(\d+:\d+:\d+)\)?
```

---

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

## Step 5: Generate Findings Report

### 5.1 If Script Was Used

The script outputs a complete findings report. Save it:

```bash
# JSON for programmatic use by downstream workflows
node parse_errorlog.js <files> --json --output C:\Users\lduan\.claude\sql-csi\reports\{case_id}_errorlog_findings.json

# Console for human review
node parse_errorlog.js <files> 2>/dev/null
```

### 5.2 If Manual Parsing Was Used

Compile findings into this format:

```markdown
# SQL-CSI Errorlog Analysis Findings

## Case: {case_id}
## Time Range: {first_timestamp} to {last_timestamp}

## Summary
- **Total Errors**: {N} unique errors, {M} total occurrences
- **High Severity (>=16)**: {count}
- **Fatal (>=20)**: {count}

## High Priority Errors
| Error | Severity | Count | Subsystem | Message |
|-------|----------|-------|-----------|---------|
| ...   | ...      | ...   | ...       | ...     |

## Timeline
[chronological events]

## Patterns Detected
[cascades, repeating, paired, LSN progression]

## Code Search Targets (ordered by priority)
- [HIGH] Error XXXXX (reasons)
- [MEDIUM] Error YYYYY (reasons)
```

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

---

## Step 6: Interactive — Ask Which Error to Investigate (MANDATORY)

After generating the report, **always ask the user** which error(s) to deep-dive into.

### 6.1 Present Options

Use `AskUserQuestion` to present the top errors from `code_search_targets`:

```
Question: "报告已生成。你想深入研究哪个错误？"
Header: "Next Step"
multiSelect: true     ← allow multiple selections
Options (from code_search_targets, max 4):
  - "Error {XXXX} — {subsystem}, Sev {severity}, {count}x (Recommended)"
  - "Error {YYYY} — {subsystem}, Sev {severity}, {count}x"
  - "Error {ZZZZ} — {subsystem}, Sev {severity}, {count}x"
  - "全部高优先级错误一起查"
```

### 6.2 Rules for Building Options

1. **First option** = highest priority error, append "(Recommended)"
2. **Sort by**: priority DESC, then severity DESC, then count DESC
3. **Max 4 options** (AskUserQuestion limit) — pick top 3 errors + "all HIGH" option
4. **Skip benign errors** — never suggest searching a benign error
5. **Include context** — show subsystem tag, severity, and occurrence count

### 6.3 After User Responds

After the user selects error(s), proceed to **Step 7** (Microsoft Docs Lookup) first,
then optionally to Workflow 3 (source code search) if deeper engine-level investigation
is needed.

- Single error selected → Step 7 for that error
- Multiple errors selected → Step 7 for each sequentially
- "全部高优先级" → Step 7 for all HIGH priority errors

### 6.4 Example Interaction

```
Agent: 报告已生成并在浏览器中打开。
       在分析的 7 天内，检测到 3 个高优先级错误：

       [选择你想深入研究的错误]
       ☐ Error 19432 — HADR_ERROR2, Sev 16, 42次 (Recommended)
       ☐ Error 17836 — SERVICE, Sev 20, 22次
       ☐ Error 9642 — FULLTEXT, Sev 16, 88次
       ☐ 全部高优先级错误一起查

User: [选择 Error 19432]

Agent: → Step 7: 查询 Microsoft Learn 文档和 KB fix
       → Step 7 完成后询问是否需要 Workflow 3 (源码搜索)
```

---

## Step 7: Microsoft Docs Lookup (MANDATORY after Step 6)

After the user selects error(s) to investigate, use the Microsoft Learn MCP tools to
search for official documentation, known fixes (KB articles), and diagnostic queries.

### 7.1 Parallel Search — Docs + Code Reference

For each selected error, run **two parallel searches**:

**Search A — Conceptual docs (microsoft_docs_search):**
```
Query 1: "SQL Server Error {error_number} {error_message_keywords}"
Query 2: "SQL Server {subsystem_keyword} troubleshoot {symptom_keywords}"
```
Where:
- `{error_message_keywords}` = key phrases from the error message (e.g., "missing log block", "transport")
- `{subsystem_keyword}` = human-readable subsystem (e.g., "Always On Availability Groups" for HADR errors)
- `{symptom_keywords}` = observable behavior (e.g., "data movement secondary replica")

**Search B — KB fix + CU (microsoft_docs_search):**
```
Query 3: "SQL Server {version_short} cumulative update fix {error_number} {subsystem_keyword}"
Query 4: "KB {error_number} {error_message_keyword} fix cumulative update"
```
Where `{version_short}` comes from `server_info.version_short` in the JSON findings.

**Search C — Diagnostic queries (microsoft_code_sample_search):**
```
microsoft_code_sample_search(
  query: "{dmv_or_diagnostic_topic} {subsystem_keyword}",
  language: "sql"
)
```
DMV topic mapping by subsystem:

| Subsystem | DMV / Diagnostic Topic |
|-----------|----------------------|
| HADR_ERROR* | `sys.dm_hadr_database_replica_states log_send_queue_size redo_queue_size` |
| LOCKING | `sys.dm_tran_locks sys.dm_exec_requests blocking` |
| MEMORY | `sys.dm_os_memory_clerks sys.dm_os_process_memory` |
| LOG | `sys.dm_db_log_info sys.dm_db_log_stats transaction log` |
| SERVICE | `sys.dm_server_services sys.dm_os_sys_info` |
| LOGIN* | `sys.dm_exec_sessions login failed audit` |
| FULLTEXT | `sys.dm_fts_index_population fulltext catalog` |
| BACKUP | `sys.dm_exec_requests backup restore progress` |
| STORAGE_PAGE | `sys.dm_db_index_physical_stats sys.dm_io_virtual_file_stats` |

### 7.2 Analyze KB Fix Applicability

After finding KB articles, determine if the fix applies to the current server:

```
1. Extract KB number and the CU that contains the fix
2. Compare fix CU build number against server_info.build
3. Determine:
   - FIX_NOT_APPLIED: server build < fix build → recommend upgrade
   - FIX_ALREADY_APPLIED: server build >= fix build → fix didn't resolve, investigate further
   - NO_KB_FOUND: no known fix → may be a configuration/environment issue
```

### 7.3 Fetch Deep Content (Conditional)

If search results reference a highly relevant troubleshooting page, use `microsoft_docs_fetch`
to get the full page content. Fetch when:

- The search excerpt mentions the exact error number but is truncated
- A troubleshooting guide with step-by-step resolution is found
- A KB article has detailed workaround or trace flag information

### 7.4 Compile Analysis Report

After gathering docs, KB info, and diagnostic queries, present a structured summary:

```markdown
## Error {XXXX} — Microsoft Docs Analysis

### 错误含义
{1-2 sentence explanation from official docs}

### 已知 Fix
| 项目 | 详情 |
|------|------|
| KB | {KB number and title, or "未找到已知 KB"} |
| 修复版本 | {CU version that contains the fix} |
| 当前版本 | {server_info.version_short} ({server_info.build}) |
| 状态 | {FIX_NOT_APPLIED / FIX_ALREADY_APPLIED / NO_KB_FOUND} |

### 根因分析
{Based on docs + errorlog patterns, list likely causes with evidence}

### 诊断查询
{SQL queries from microsoft_code_sample_search, ready to run}

### 建议修复方案
1. {Priority action items based on KB status and root cause}
2. ...
```

### 7.5 Ask Next Step

After presenting the analysis, ask the user:

```
Question: "Microsoft Docs 分析完成。接下来你想怎么做？"
Header: "Next Step"
Options:
  - "搜索源码 (Workflow 3)" — 在 SQL Server 源码中搜索 Error {XXXX} 的代码路径
  - "查看其他错误" — 返回 Step 6 选择另一个错误
  - "分析完成" — 结束分析
```

### 7.6 Example Interaction

```
Agent: [并行调用 microsoft_docs_search × 2 + microsoft_code_sample_search × 1]

       ## Error 19432 — Microsoft Docs Analysis

       ### 错误含义
       HADR transport 层在 secondary 副本接收 log block 时检测到不连续的
       LSN gap，触发 log scan 重启自我修复。

       ### 已知 Fix
       | 项目 | 详情 |
       |------|------|
       | KB | KB4541309 — "Missing log block may occur with Always On AG" |
       | 修复版本 | SQL Server 2016 SP2 CU12 (13.0.5698.0) |
       | 当前版本 | SQL Server 2016 SP2-CU15-GDR (13.0.5865.1) |
       | 状态 | FIX_ALREADY_APPLIED — CU15 > CU12 |

       ### 根因分析
       - KB4541309 已包含，但错误仍出现 → 非该 KB 修复的场景
       - Error 9642 同期出现 → 副本间版本不匹配
       - 4 副本跨 SGA/SGB 数据中心 → 网络延迟可能导致 transport gap

       ### 诊断查询
       [DMV queries for log_send_queue_size, redo_queue_size, etc.]

       ### 建议修复方案
       1. 统一所有副本到相同 CU 版本 (消除 Error 9642)
       2. 升级到 SQL Server 2016 SP3
       3. 检查跨数据中心网络质量

       [接下来你想怎么做？]

User: 执行诊断查询

Agent: → 通过 MSSQL MCP 执行 DMV 查询...
```

---

## Appendix A: Subsystem Classification by Error Range

| Error Range | Subsystem Tag | Description |
|------------|---------------|-------------|
| 1-100 | `GENERAL` | General / System |
| 101-299 | `METADATA` | Metadata / Catalog |
| 301-499 | `DATATYPE` | Data Types / Conversion |
| 501-599 | `DBCC` | DBCC |
| 601-699 | `STORAGE_PAGE` | Page / Allocation |
| 701-899 | `MEMORY` | Memory Manager |
| 901-999 | `RESOURCE` | Resource Manager |
| 1001-1099 | `ENGINE` | General SQL Engine |
| 1101-1299 | `LOCKING` | Locking / Deadlock |
| 1401-1499 | `MIRRORING` | Database Mirroring |
| 1501-1599 | `REPLICATION` | Replication |
| 2001-2399 | `CHECKDB` | DBCC CHECKDB |
| 2501-2599 | `TABLE_INDEX` | Table / Index |
| 3001-3999 | `BACKUP` | Backup / Restore |
| 4001-4999 | `PARSER` | SQL Syntax / Parser |
| 5001-5499 | `DDL` | ALTER / Server DDL |
| 5501-5999 | `DBCC` | DBCC / Consistency |
| 7001-7999 | `LINKEDSERVER` | Linked Server / OLEDB |
| 8001-8099 | `NETWORK` | Network / TDS |
| 8101-8199 | `OPTIMIZER` | Optimizer |
| 8601-8699 | `QUERYPROC` | Query Processor |
| 9001-9100 | `LOG` | Transaction Log |
| 9501-9999 | `FULLTEXT` | Full-Text Search |
| 10001-10999 | `SERVER` | Server Messages |
| 14001-14999 | `SECURITY` | Security / Audit |
| 15001-15999 | `CATALOG` | Catalog / Procedures |
| 17001-17999 | `SERVICE` | Server / Service |
| 18001-18449 | `LOGIN` | Login / Authentication |
| 18450-18499 | `LOGIN_AUDIT` | Login Audit |
| 19001-19399 | `HADR_ERROR1` | HADR Group 1 |
| 19400-19499 | `HADR_ERROR2` | HADR Group 2 |
| 19500-19599 | `HADR_ERROR3` | HADR Group 3 |
| 21001-21999 | `REPL_AGENT` | Replication Agents |
| 22001-22999 | `SSIS` | SSIS |
| 25001-25999 | `SPATIAL` | Spatial |
| 33001-33999 | `FILETABLE` | FileTable |
| 35001-35999 | `HADR_ADDITIONAL` | HADR Additional |
| 41001-41399 | `HEKATON` | In-Memory OLTP |
| 41401-41499 | `HEKATON_XTP` | In-Memory OLTP XTP |

## Appendix B: Known Benign Errors (Auto-Deprioritized)

| Error | Message Pattern | Why Benign |
|-------|----------------|------------|
| 17054 | Event not reported to Windows log | Informational only |
| 5701 | Changed database context | Normal operation |
| 5703 | Changed language setting | Normal operation |
| 8153 | Null value eliminated by aggregate | Warning only |
| 15457 | Configuration option changed | Normal admin operation |
| 17830 | Network error establishing connection | Transient connectivity |
| 4014 | Fatal error reading input stream | Client disconnect |
| 35262 | Database startup skipped (AG managed) | AG normal behavior |
| 33204 | Online index checking (startup) | Startup routine |

## Appendix C: Error Pattern Reference

### HADR Failover Sequence
```
Error 19406 → AG role changing
Error 35206 → Timeout waiting for hardening
Error 19407 → AG going offline
Error 35264 → Connection timeout
```

### Memory Pressure Sequence
```
Error 701  → Insufficient memory
Error 8645 → Timeout waiting for memory grant
Error 17300 → Out of memory
```

### I/O Stall Sequence
```
Error 833  → I/O requests taking longer than 15 seconds
Error 9001 → Log not available for database
Error 3414 → Recovery failed
```

### HADR Transport Failure (discovered in case 2105060060003672)
```
Error 9642  → Remote endpoint has lower software version
Error 17836 → Could not establish connection to primary (Sev 20)
Error 17832 → Connection handshake failed / duplicate (Sev 20)
Error 19432 → Missing log block detected → log scan restart
```

## Appendix D: Edge Cases

### Large ERRORLOG Files
The script handles large files natively. For manual parsing with the Read tool, use
`offset` and `limit` parameters to read in chunks of 1000 lines.

### Multiple ERRORLOG Files
The script auto-sorts files by number (ERRORLOG.12 → ERRORLOG.1 → ERRORLOG) and
processes oldest first. For manual parsing, process in the same order.

### Non-English ERRORLOG
Error numbers, severity, and timestamps are always in English format regardless of
server language. Message text may be localized — extract numbers but note the language.

### Corrupted or Truncated Lines
The script silently skips unparseable lines. For manual parsing, skip lines that don't
match any known pattern and note the count.

### UTF-16 Encoding
SQL Server ERRORLOG defaults to UTF-16LE. The script auto-detects encoding. For manual
parsing, see Step 3.1 for conversion options.
