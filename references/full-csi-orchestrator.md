# Full CSI Orchestrator Skill

## Overview

This skill coordinates the three analysis phases (Errorlog, Dump, Source Code) into
a unified investigation. It collects evidence from all available sources, prioritizes
findings, runs source code searches, cross-references results, and generates a
comprehensive HTML report.

## Activation Triggers

Activate this skill when the user:
- Says "full analysis", "investigate case", "完整分析", "full CSI"
- Provides multiple data sources (errorlog + dump, errorlog + error numbers, etc.)
- Asks for a comprehensive investigation

## Required Inputs

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `case_id` | string | No | Case/SR number for report naming (auto-generated if not provided) |
| `errorlog_path` | string | No | Path to ERRORLOG file |
| `xel_path` | string | No | Path to system_health XEL files |
| `dump_path` | string | No | Path to dump file |
| `error_numbers` | int[] | No | Known error numbers to investigate |
| `sql_version` | string | No | SQL version (default: SQL2022) |

> At least ONE of `errorlog_path`, `dump_path`, or `error_numbers` must be provided.

---

## Step 1: Collect Evidence — Determine Available Data Sources

Check what inputs the user provided and plan the analysis:

```
Input Assessment:
  ☐ Errorlog path → will run Workflow 1 (errorlog-xevent-analysis)
  ☐ XEL path      → will include in Workflow 1
  ☐ Dump path     → will run Workflow 2 (dump-analysis)
  ☐ Error numbers → will run Workflow 3 directly (source-code-search)
  ☐ Call stack     → will include in Workflow 3
```

If no `case_id` provided, generate one: `csi_{YYYYMMDD}_{HHMMSS}`

---

## Step 2: Execute Analysis Workflows (Sequential)

Run workflows in this order — each workflow's output feeds the next:

### Phase 1: Evidence Collection

**2.1 — If errorlog provided → Run Workflow 1**

Execute the errorlog analysis skill (see [errorlog-xevent-analysis.md](errorlog-xevent-analysis.md)).

Capture output:
- `errorlog_errors[]` — prioritized error list
- `errorlog_timeline` — chronological event timeline
- `errorlog_patterns` — detected error patterns (cascade, repeating, etc.)
- `errorlog_waits[]` — wait type summary (if XEL analyzed)

**2.2 — If dump provided → Run Workflow 2**

Execute the dump analysis skill (see [dump-analysis.md](dump-analysis.md)).

If Workflow 1 produced errors, use them to focus the dump analysis:
- Pass `error_numbers` from Workflow 1 to Workflow 2
- Workflow 2 generates targeted Mirrors commands

Capture output:
- `dump_errors[]` — errors from exception ring buffer
- `dump_call_stacks{}` — error → function call stack mapping
- `dump_server_state{}` — memory, scheduler, HADR state

**2.3 — If only error numbers provided → Skip to Step 3**

---

## Step 3: Compile Code Search Targets

Merge findings from Workflows 1 and 2 into a prioritized search list:

### 3.1 Priority Rules

```
PRIORITY HIGH (search first):
  1. Errors with severity >= 17 (resource/fatal errors)
  2. First error in the timeline (likely root cause, not cascade effect)
  3. Errors found in BOTH errorlog AND dump exception ring
  4. Errors with call stack functions available from dump

PRIORITY MEDIUM:
  5. Errors with severity 16 (user-level errors)
  6. Errors with multiple occurrences (> 3 times)
  7. Errors in HADR/Memory/Scheduler subsystems

PRIORITY LOW (search last, or skip if time-constrained):
  8. Informational errors (severity < 16)
  9. Known benign errors (see benign list)
  10. Errors with only 1 occurrence and low severity
```

### 3.2 Deduplication

If the same error number appears in both errorlog and dump findings, merge into one entry
with evidence from both sources.

### 3.3 Cascade Detection

If multiple errors occurred within a 30-second window:
- Mark the FIRST error as `cascade_root: true`
- Mark subsequent errors as `cascade_effect: true`
- Prioritize the root error for code search

Output:
```
CODE_SEARCH_TARGETS (ordered by priority):
  1. [HIGH] Error 19433 (Sev 16, first in cascade, has call stack)
     - Errorlog: 3 occurrences, first at 02:59:09
     - Dump: found in exception ring, call stack: WsfcIsAgIntactInWsfc → ComputeInitialStateInWsfc
  2. [MEDIUM] Error 35206 (Sev 16, cascade effect)
     - Errorlog: 1 occurrence at 02:59:11
     - Dump: found in exception ring
```

---

## Step 4: Execute Source Code Searches

### 4.1 Sequential Search (Default)

For each target in priority order, execute Workflow 3 (see [source-code-search.md](source-code-search.md)):

```
For target in code_search_targets (ordered by priority):
    Run source-code-search with:
      error_number = target.error
      sql_version = {user_specified or SQL2022}
      call_stack_functions = target.call_stack (if available from dump)

    Collect:
      error_definition, code_snippets, function_logic, xevents, mirrors_commands
```

### 4.2 Parallel Search (When Multiple Independent Errors)

If there are 2+ HIGH priority errors that are NOT in the same cascade chain,
use the **Task tool** for parallel execution:

```
Task A: source-code-search for error {A}
Task B: source-code-search for error {B}
Task C: source-code-search for error {C}
→ Wait for all tasks to complete
→ Merge results
```

> **NOTE**: Each Task can use `msdata-repo_get_file_content` directly since the MCP
> calls are independent. Do NOT parallelize if errors share the same source file.

---

## Step 5: Cross-Reference and Correlate

After all code searches complete, perform correlation analysis:

### 5.1 Error Cascade Chain

Map the timeline to source code:
```
02:59:09 Error 19433 → WsfcIsAgIntactInWsfc() detects group ID mismatch
                     → returns false → m_fAgInWsfc = false
                     → AG state changes to RESOLVING
02:59:11 Error 35206 → Log hardening timeout (cascade from AG state change)
                     → AG cannot sync logs while resolving
```

### 5.2 Common Code Path Detection

Check if multiple errors share:
- Same source file → same subsystem, likely related
- Same caller function → same code path, cascade
- Same class → same component, architectural issue

### 5.3 State Correlation (if dump available)

Compare dump state with expected state from source analysis:
- If source says "error fires when AG state is RESOLVING" and dump shows HADR state = RESOLVING → confirmed
- If source says "error fires when memory < threshold" and dump shows memory pressure = true → confirmed

### 5.4 Timeline ↔ Source Code Mapping

Create a unified timeline that maps errorlog events to source code functions:
```
TIME        | EVENT           | SOURCE CODE
02:59:09.18 | Error 19433     | WsfcIsAgIntactInWsfc() line 1023 → scierrlog
02:59:09.20 | AG → RESOLVING  | ComputeInitialStateInWsfc() → m_fAgInWsfc = false
02:59:11.45 | Error 35206     | (cascade) HadrLogCaptureManager → timeout
```

---

## Step 6: Generate Root Cause Analysis

Based on all evidence, formulate:

### 6.1 Primary Root Cause
The single most likely cause, supported by evidence from multiple sources:
```
ROOT CAUSE: AG group ID stored in WSFC cluster registry has diverged from
SQL Server local metadata, causing WsfcIsAgIntactInWsfc() to fail the
integrity check at line 1023 of HadrAvailabilityGroupObjectModel.cpp.
This triggered a cascade: AG state → RESOLVING → log hardening timeout → Error 35206.

EVIDENCE:
  - Errorlog: Error 19433 is the first error, 2 seconds before Error 35206
  - Source: scierrlog at line 1023 fires when hadrAgGroupId != tempGroupId
  - Dump: Exception ring confirms call stack WsfcIsAgIntactInWsfc → ComputeInitialStateInWsfc
```

### 6.2 Contributing Factors
Secondary conditions that enabled or worsened the issue.

### 6.3 Error Cascade Chain
Visual representation of the error propagation.

---

## Step 7: Generate Final HTML Report

Save to: `C:\Users\lduan\.claude\sql-csi\reports\{case_id}_full_report.html`

### Report Structure

```
1. HEADER
   - Case ID, SQL version, analysis date
   - Data sources: errorlog ✓, XEvent ✓, dump ✓/✗
   - Errors analyzed: {list}

2. EXECUTIVE SUMMARY
   - 3-5 bullet points
   - Primary root cause in one sentence
   - Severity assessment
   - Recommended immediate action

3. TIMELINE
   - Chronological view with icons
   - Gap analysis
   - Source code function mapping (if available)

4. ERROR ANALYSIS (one section per error, ordered by priority)
   a. Error Definition (from sqlerrorcodes.h)
   b. Error Group (major/minor calculation)
   c. Code That Raises It
      - File path with Azure DevOps link
      - Function name
      - Code snippet with syntax highlighting
   d. Function Logic
      - Purpose, trigger condition, error handling, root cause
   e. Evidence
      - Errorlog: occurrence count, timestamps
      - Dump: call stack, ring buffer position
   f. XEvent Diagnostics
      - Related XEvents, suggested session SQL
   g. WinDbg Commands
      - Mirrors commands for this specific error

5. ROOT CAUSE ANALYSIS
   a. Primary cause (with evidence)
   b. Contributing factors
   c. Error cascade chain (visual diagram)
   d. State correlation (dump state vs expected state)

6. RECOMMENDATIONS
   a. Immediate actions (what to do now)
   b. Long-term fixes (prevent recurrence)
   c. Monitoring (XEvent sessions to deploy)
   d. Related KBs or documentation

7. APPENDIX
   a. Full function source code (collapsible)
   b. Complete WinDbg Mirrors script (copy-pasteable)
   c. All errorlog entries for analyzed errors
   d. Related error numbers and trace flags
   e. Analysis metadata (files fetched, MCP calls made)
```

### HTML Styling

Use the dark theme defined in the main agent file (Catppuccin Mocha):
- Background: `#1e1e2e`
- Surface: `#252538`
- Accent: `#89b4fa` (blue)
- Errors: `#f38ba8` (red)
- Success: `#a6e3a1` (green)
- Warning: `#fab387` (orange)
- Code: syntax highlighted with keyword/function/string/comment colors

---

## Step 8: Open Report

```powershell
Start-Process 'C:\Users\lduan\.claude\sql-csi\reports\{case_id}_full_report.html'
```

---

## Edge Cases

### Only Errorlog Provided (No Dump)
- Run Workflow 1 → Workflow 3 for each error
- Dump Analysis section in report shows "No dump available"
- Generate Mirrors command script as "recommended for further investigation"

### Only Dump Provided (No Errorlog)
- Run Workflow 2 → Workflow 3 for errors found in exception ring
- Errorlog section in report shows "No errorlog available"

### Only Error Numbers Provided
- Skip Workflows 1 and 2
- Run Workflow 3 directly for each error
- Report shows only source code analysis sections

### No Errors Found in Errorlog
- Report the finding: "No significant errors detected"
- If XEvent data available, focus on wait type analysis
- Suggest checking ERRORLOG.1 for earlier events
- Suggest common non-error issues: performance (waits), connectivity, etc.

### Too Many Errors (> 10 unique errors)
- Analyze top 5 by priority
- List remaining errors in "Other Errors" appendix
- Suggest focusing on the first error in the timeline

### Error Not Found in sqlerrorcodes.h
- May be a dynamic error (generated at runtime)
- Search for the error number directly in source code: `msdata-search_code` with the number
- Report as "error definition not found — may be runtime-generated"
