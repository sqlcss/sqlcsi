# Source Code Search Skill

## Overview

This skill searches SQL Server source code in Azure DevOps repositories to find error
definitions, locate code that raises errors, analyze function logic, and generate
diagnostic recommendations. It uses the `msdata` MCP server to access the `Database Systems`
project in the `msdata` Azure DevOps organization.

## Activation Triggers

Activate this skill when the user:
- Says "search error XXXX", "查错误 XXXX", "look up error XXXX"
- Provides error numbers to investigate
- Asks about a specific SQL Server error constant or function
- Workflow 4 passes error numbers from Workflows 1/2

## Required Inputs

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `error_number` | int | **Yes** | SQL Server error number to search |
| `sql_version` | string | No | SQL version: `SQL2017`, `SQL2019`, `SQL2022` (default), `SQL2025` |
| `call_stack_functions` | string[] | No | Function names from dump call stacks (from Workflow 2) |
| `case_id` | string | No | Case identifier for report naming |

---

## Step 1: Determine Repository and Branch

| Version | Repository | Branch |
|---------|-----------|--------|
| SQL 2017 | `SQL2017` | `rel/box/sql2017/sql2017_rtm_qfe-cu` |
| SQL 2019 | `SQL2019` | `rel/box/sql2019/sql2019_rtm_qfe-cu` |
| SQL 2022 | `DsMainDev` | `rel/box/sql2022/sql2022_rtm_qfe-cu` |
| SQL 2025 | `DsMainDev` | `rel/box/sql2025/sql2025_rtm_qfe-cu` |

Default is **SQL2022** (`DsMainDev`, `rel/box/sql2022/sql2022_rtm_qfe-cu`).

---

## Step 2: Fetch Error Definition

Use `msdata-repo_get_file_content` with:
- `project`: `Database Systems`
- `repositoryId`: repo name from Step 1
- `path`: `/Sql/Ntdbms/include/sqlerrorcodes.h`
- `version`: branch name from Step 1
- `versionType`: `Branch`

Search the file content for `ErrorNumber: {XXXX}`.

### 2.1 Extract Error Definition Block

Starting from the matching line, extract the complete block:
```
// ErrorNumber: XXXX
// ErrorSeverity: ...
// ErrorFormat: ...
// ErrorCause: ...
// ErrorCorrectiveAction: ...
// ErrorInserts: ...
// ErrorBlameComponent: ...
// ErrorFirstProduct: ...
// ErrorExecImpact: ...
// ErrorOwner: ...
const int ERROR_CONSTANT_NAME = NN;
```

### 2.2 Extract Error Constant Name

From the `const int` line, extract the constant name (e.g., `HADR_AG_CLUSTER_INTEGRITY_CHECK_GROUP_ID_FAILURE`).

### 2.3 Identify Error Group

Determine the major error group from the section header comment above the block:
```
// Major: HADR_ERROR2 = 194
```

Calculate: `MajorValue × 100 + MinorValue = ErrorNumber`

---

## Step 3: Search for Code That Raises the Error

Use `msdata-search_code` with:
- `searchText`: the error constant name
- `project`: `["Database Systems"]`
- `repository`: `["{repo_name}"]`
- `path`: `["/Sql/Ntdbms"]`

This finds all files that reference the error constant.

---

## Step 4: Fetch and Analyze Source Files

For each `.cpp` file found in Step 3 (skip `.h` definition files):

### 4.1 Fetch Source File

Use `msdata-repo_get_file_content` with:
- `project`: `Database Systems`
- `repositoryId`: repo name
- `path`: file path from search results
- `version`: branch name
- `versionType`: `Branch`

### 4.2 Find Error References

Search the file content for all occurrences of the error constant name.

### 4.3 Extract Code Context

For each occurrence:
1. Extract **~25 lines before** and **~10 lines after** the match
2. Search **backwards** from the match for the function signature:
   - Pattern: `ClassName::FunctionName (` or `FunctionName (`
   - The function name is usually on the line starting with no indentation before `{`

### 4.4 Find XE_FIRE_EVENT Calls

Within the same function (from function start to function end):
1. Search for `XE_FIRE_EVENT` or `XE_FIRE_EVENT_PARAM` calls
2. Extract the XEvent name (first parameter after `XeSqlPkg::`)
3. Note the fields captured by the XEvent

### 4.5 Find Related Error Constants

Search for other error constants used in the same function — they may be sister errors
that fire in adjacent code paths. These help build the complete error picture.

---

## Step 5: Analyze Call Stack Functions (if provided)

When function names are provided from Workflow 2 (dump analysis):

### 5.1 Search for Each Function

Use `msdata-search_code` with:
- `searchText`: `ClassName::FunctionName`
- `project`: `["Database Systems"]`
- `repository`: `["{repo_name}"]`

### 5.2 Fetch and Extract Full Function Body

For each function found:
1. Fetch the source file
2. Locate the function definition
3. Extract the complete function body (from signature to closing `}`)
4. Analyze:
   - What does this function do?
   - How does it call the error-raising function?
   - What parameters does it pass?
   - What happens after the error (return, retry, abort)?

### 5.3 Build Call Chain

Connect the caller functions to the error-raising function:
```
Caller1::Method() → Caller2::Method() → ErrorRaisingFunction() → scierrlog(ERROR_CONSTANT)
```

---

## Step 6: Analyze Function Logic

For each function that raises the error, document:

### 6.1 Purpose
What the function does — from header comments or code analysis.

### 6.2 Error Triggering Condition
The exact `if` condition that leads to the error:
```cpp
if (condition_A && condition_B)
{
    scierrlog(EX_NUMBER(MAJOR, CONSTANT), ...);
    return false;
}
```

### 6.3 Error Mechanism

| Mechanism | Fatal? | Exception? | Description |
|-----------|--------|------------|-------------|
| `scierrlog` | No | No | Logs to errorlog only, continues execution |
| `ex_raise` / `ex_raisecontrol` | Yes | Yes | Throws exception, must be caught or session dies |
| `ex_callprint_error` | No | No | Sends message to client session, continues |
| `ex_raise_backup` | Yes | Yes | Throws backup-specific exception |
| `SOS_Task::Cancel()` | Yes | — | Cancels the task |

### 6.4 Error Handling
- Is the error caught by a `EX_TRY` / `EX_CATCH` block?
- Does the function return a value that propagates the failure?
- Is there a trace flag that bypasses this error?

### 6.5 Root Cause
What real-world situation triggers this code path?

### 6.6 XEvent Diagnostics
For each `XE_FIRE_EVENT` found:
- XEvent name
- Fields captured (data available for diagnosis)
- When it fires relative to the error
- Suggested XEvent session SQL

---

## Step 7: Generate WinDbg Mirrors Commands

For each error analyzed, generate targeted dump analysis commands:

```windbg
-- Exception ring for Error {error_number}
!evaluate (execute SOSRingBuffers.EnumerateExceptionRingRecords).Where(r => r.m_error == {error_number}).OrderByDescending(r => r.position)

-- Call stack expansion
!evaluate (execute SOSRingBuffers.EnumerateExceptionRingRecords).Where(r => r.m_error == {error_number}).Select(r => new {r.m_error, r.m_severity, r.stack_frames.Nested()})

-- {Subsystem-specific ring buffers based on error group}
```

Map error group to ring buffers:
- `HADR_ERROR*` → HADR ring buffers
- Error 701-899 → Memory ring buffers
- Error 17883-17888 → Scheduler ring buffers
- etc. (see dump-analysis.md for full mapping)

---

## Step 8: Present Results

### 8.1 Console Output

```
=== SQL Server Error {XXXX} ({SQL_VERSION}) ===

--- Error Definition ---
// ErrorNumber: XXXX
// ErrorSeverity: ...
// ErrorFormat: ...
const int ERROR_CONSTANT = NN;

--- Error Group ---
Major: MAJOR_CONSTANT = NNN
Minor: NN
Calculation: NNN × 100 + NN = XXXX

--- Code That Raises Error {XXXX} ---

📄 File: /Sql/Ntdbms/path/to/file.cpp
🔗 Link: https://msdata.visualstudio.com/Database%20Systems/_git/{repo}?path={path}&version=GB{branch}
📌 Function: ClassName::FunctionName()

    [code snippet]

--- Function Logic ---
**Purpose**: ...
**Trigger condition**: ...
**Error handling**: ...
**Root cause**: ...

--- XEvent Diagnostics ---
**XeSqlPkg::event_name** — captures [fields]
Suggested session:
    CREATE EVENT SESSION [...] ADD EVENT sqlserver.event_name ...

--- WinDbg Mirrors Commands ---
    [ready-to-paste WinDbg commands]
```

### 8.2 HTML Report

If `case_id` is provided, generate HTML report at:
```
C:\Users\lduan\.claude\sql-csi\reports\error_{XXXX}_{sql_version}.html
```

Follow the HTML styling rules defined in the main agent file.

Report sections:
1. Header (error number, version, repo, branch, date)
2. Error Definition
3. Error Group (major/minor calculation)
4. Code Search Results (files found)
5. Code Snippets (with syntax highlighting and Azure DevOps links)
6. Function Logic Analysis
7. XEvent Diagnostics
8. WinDbg Mirrors Commands
9. Appendix (full function source)

Open in browser after generation:
```powershell
Start-Process 'C:\Users\lduan\.claude\sql-csi\reports\error_{XXXX}_{sql_version}.html'
```

### 8.3 For Workflow 4 (Programmatic Return)

Return structured data:
```
CODE_FINDINGS:
  error: {XXXX}
  constant: {ERROR_CONSTANT_NAME}
  group: {MAJOR_CONSTANT}
  files: [{file_path, function_name, line_number}]
  root_cause: "{description}"
  xevents: [{event_name, fields}]
  related_errors: [{error_number, constant_name}]
```
