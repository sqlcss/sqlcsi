---
name: errorlog-analysis
description: >-
  Parse SQL Server ERRORLOG files to extract errors, build timelines, and detect patterns.
  Use when the user says "analyze errorlog", "parse errorlog", "分析 errorlog", provides
  a path to an ERRORLOG file, or says "what errors are in this log".
tools: ['terminal', 'readFile', 'editFile']
agents: [import-xevent, analyze-xevent]
---

# ERRORLOG Analysis

**Wait type classification reference**: [.github/references/wait-types.md](../references/wait-types.md) — use this to classify wait-related errors and filter benign waits.

## Overview

Parse SQL Server ERRORLOG files to extract errors, build timelines, identify patterns
(cascades, repeating, paired errors), and classify by subsystem. Outputs structured JSON
and HTML reports.

## Required Inputs

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `errorlog_path` | string | **Yes** | Path to ERRORLOG file(s). Supports `ERRORLOG`, `ERRORLOG.1`, etc. |
| `xel_path` | string | No | Path to system_health XEL files (glob pattern OK: `system_health*.xel`) |
| `time_range` | string | No | Time filter: "last 2 hours", "2026-03-22 02:00 to 03:00", etc. |
| `case_id` | string | No | Case identifier for output file naming |


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
scripts/parse_errorlog.js
```

### 1.2 Usage

```bash
# Single file
node scripts/parse_errorlog.js <errorlog_path>

# Multiple files (oldest first — script auto-sorts by number)
node scripts/parse_errorlog.js ERRORLOG ERRORLOG.1 ERRORLOG.2 ... ERRORLOG.12

# With JSON output saved to file
node scripts/parse_errorlog.js <files> --json --output findings.json

# With time range filter
node scripts/parse_errorlog.js <files> --from "2021-05-02 03:00" --to "2021-05-02 04:00"
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

---

## Step 4: Cross-Reference XEvent Data (RESOURCE / Memory Analysis)

If a `xel_path` was provided **OR** `system_health*.xel` files are found alongside the
ERRORLOG, automatically pull XEvent data — especially when ERRORLOG shows memory/resource
errors. The ERRORLOG only logs the symptom (701, 802, 17189, dumps); the XEvent
`sp_server_diagnostics` RESOURCE component holds the actual memory committed / target /
QE reservation / OOM-flag timeline that proves the root cause.

### 4.1 When to Trigger (MANDATORY)

Invoke this step automatically when **any** of these appear in the findings:

| Trigger | Subsystem / Error | Why XEvent is needed |
|---------|-------------------|----------------------|
| Error 701/802/8645 | `MEMORY` (701-899) | Confirm which clerk/grant consumed memory |
| Error 17189 | `SERVICE` | "failed to spawn thread" → worker exhaustion from OOM |
| Error 901-999 | `RESOURCE` | Resource governor / semaphore state |
| Stalled dispatcher / non-yield dump | — | sp_diag RESOURCE shows committed-vs-target |
| AG role change to RESOLVING | `HADR_*` | Correlate with memory_broker pressure |

### 4.2 How to Invoke

1. If a local SQL Server is available → `runSubagent("import-xevent")` to load the .xel
   into `[xevent_analyze]`, then `runSubagent("analyze-xevent")` with the same
   `{window_start}`/`{window_end}` as the ERRORLOG incident window.
2. If no local SQL Server → `runSubagent("analyze-xevent")` (Path B: PowerShell extract +
   `scripts/parse_xevent.js`).

### 4.3 Must-Extract Records

- `sp_server_diagnostics` **RESOURCE** — lastNotification, outOfMemoryExceptions, Target/Current Committed, Locked Pages, QE reservations
- `sp_server_diagnostics` **QUERY_PROCESSING** — maxWorkers, workersCreated, idleWorkers, pendingTasks
- `memory_broker_clerks` — currently_allocated, new_target, notification
- `scheduler_monitor` — memory_utilization, system_idle

Stitch these into the timeline so memory committed at each 5-min sample lines up with the
701/17189 ERRORLOG entries.

---

## Step 5: Generate Findings Report

### 5.1 If Script Was Used

The script outputs a complete findings report. Save it:

```bash
# JSON for programmatic use by downstream workflows
node parse_errorlog.js <files> --json --output reports/{case_id}_errorlog_findings.json

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
