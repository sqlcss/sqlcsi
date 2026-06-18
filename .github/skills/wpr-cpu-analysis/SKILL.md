---
name: wpr-cpu-analysis
description: >
  CPU hotspot investigation for SQL Server using WPR/ETL traces and the diag-perf
  MCP server. Broad→Narrow workflow: module overview → function drill-down →
  SQL Server–specific interpretation → source code lookup.
  USE FOR: "CPU 分析", "high CPU", "non-yielding", "spinlock contention".
  DO NOT USE FOR: CPU comparison (use cpu_compare_traces directly), GC analysis,
  allocation analysis.
---

# SQL Server CPU Investigation Skill

Analyze CPU usage in a WPR/ETL trace for SQL Server (`sqlservr.exe`).
Uses diag-perf MCP tools with SQL Server domain knowledge.

**Prerequisites**: Trace must already be opened (`perf_open_trace`) and `sqlservr.exe`
PID must be identified before invoking this skill.

## Inputs

- `etl_path` — Path to the opened ETL file
- `pid` — sqlservr.exe process ID
- `sub_focus` (optional) — "non-yielding" | "high CPU" (default: "high CPU")
- `case_id` (optional) — for cross-reference with ERRORLOG/XEvent

## MCP Tools Used

| Tool | Purpose |
|------|---------|
| `cpu_get_grouped_stacks` | Group CPU samples by module / namespace |
| `cpu_get_frame_info` | Exclusive/inclusive CPU % for a specific function |
| `cpu_get_stack_info` | Callers and callees of a function |

## Phase 1 — Module-Level Overview (Broad)

```
Call cpu_get_grouped_stacks(
    filePath = "{etl_path}",
    processId = {pid},
    groupBy = "module",
    maxGroups = 15
)
```

### Classify modules into SQL Server subsystems

| Module | Subsystem |
|--------|-----------|
| `sqldk.dll` | SQL OS — scheduler, memory nodes, task management |
| `sqllang.dll` | Query Processing — compilation, optimization, execution |
| `sqlmin.dll` | Storage Engine — buffer pool, lock manager, recovery |
| `sqltses.dll` | T-SQL Execution — expression evaluation, type conversion |
| `sqlaccess.dll` | Access Methods — B-tree, heap, LOB operations |
| `qds.dll` | Query Store |
| `hkengine.dll` | In-Memory OLTP (Hekaton) — core engine |
| `hkruntime.dll` | In-Memory OLTP — natively compiled procedure runtime |
| `hadrres.dll` | Always On — resource DLL |
| `hadrdbmgr.dll` | Always On — database manager |
| `xesqlpkg.dll` | XEvent — SQL package |
| `xesospkg.dll` | XEvent — SOS package |
| `ntoskrnl.exe` | Windows Kernel — context switches, syscalls |
| `ntdll.dll` | NT Runtime — heap, critical sections |
| `kernel32.dll` | Windows — thread/memory APIs |
| `clr.dll`, `coreclr.dll` | CLR / SQLCLR |

### Present summary table

```
Module           Exclusive %   Subsystem
sqlmin.dll       34.2%         Storage Engine
sqllang.dll      28.1%         Query Processing
sqldk.dll        15.3%         SQL OS
hkengine.dll      8.0%         In-Memory OLTP
ntoskrnl.exe      5.2%         Windows Kernel
...
```

**Key questions to answer**:
- Which subsystem dominates? (Storage Engine vs Query Processing vs SQL OS)
- Is there unexpected CPU in kernel/Windows modules? (→ possible I/O or lock contention)
- Is In-Memory OLTP (hkengine) active? (→ Hekaton workload)
- Is sqldk exclusive % high? (→ possible scheduler/spinlock issue)

## Phase 2 — Function-Level Deep Dive (Narrow)

For the **top 3 modules by exclusive CPU**, get function-level detail.

**Note**: `groupBy = "namespace"` does NOT work for native C++ modules (all functions
appear as "Global"). Use `cpu_get_frame_info` and `cpu_get_stack_info` instead.

### Step 2a — Get top functions in each hot module

For each hot module, use `includeFilter` with the module name:

```
Call cpu_get_grouped_stacks(
    filePath = "{etl_path}",
    processId = {pid},
    groupBy = "module",
    includeFilter = "<hot_module_name>",
    maxGroups = 10
)
```

If this returns only 1 group (the module itself), fall back to `cpu_get_stack_info`
on the module to see its internal call tree:

```
Call cpu_get_stack_info(
    filePath = "{etl_path}",
    processId = {pid},
    frameName = "<hot_module>",
    maxCallers = 5,
    maxCallees = 15
)
```

The **callees list** shows the hottest functions inside that module.

### Step 2b — Investigate individual hot functions

For the top 3-5 hottest functions (from Phase 1 or 2a):

```
Call cpu_get_frame_info(
    filePath = "{etl_path}",
    processId = {pid},
    frameName = "<function_name>"
)
```

Then trace the call chain:

```
Call cpu_get_stack_info(
    filePath = "{etl_path}",
    processId = {pid},
    frameName = "<function_name>",
    maxCallers = 10,
    maxCallees = 10
)
```

**Key questions**:
- Exclusive vs Inclusive: is CPU spent IN this function or in what it calls?
- Who calls it? (callers → what query pattern triggers this)
- What does it call? (callees → where does time go next)

## Phase 3 — SQL Server–Specific Interpretation

Map hot functions to known SQL Server patterns and root causes:

### Scheduler / SQL OS patterns

| Function pattern | Likely cause | Action |
|-----------------|-------------|--------|
| `SOS_Scheduler::SwitchContext` | High context switching | Check worker thread count, parallel queries |
| `SOS_Scheduler::*Yield*` | Scheduler yielding (normal) | Normal unless excessive |
| `SOS_Task::*` | Task management overhead | Check max worker threads |
| `SpinlockBase::Backoff` | Spinlock contention | Identify spinlock type from callers |
| `SpinlockBase::SpinToAcquire` | Spinlock spin loop | Source-search for the spinlock class |
| `SOS_UnfairMutex::*` | Unfair mutex contention | Check memory/buffer pool pressure |

### Storage Engine patterns

| Function pattern | Likely cause | Action |
|-----------------|-------------|--------|
| `BPool::Get`, `BPool::FetchBuffer` | Buffer pool read | Check PAGEIOLATCH waits, memory config |
| `BPool::*Lazy*` | Lazy writer active | Memory pressure — buffer pool too small |
| `LockManager::*`, `lck_*` | Lock contention | Check blocking chains, isolation level |
| `IndexPageManager::*` | Index page operations | Heavy scan/seek workload |
| `BTreeRow::*` | B-tree row operations | Index maintenance overhead |
| `PageRef::*Latch*` | Page latch contention | Hot page / last-page insert contention |
| `LogWriter::*`, `CLogMgr::*` | Transaction log writes | Disk I/O on log drive |

### Query Processing patterns

| Function pattern | Likely cause | Action |
|-----------------|-------------|--------|
| `CMsqlExecContext::Execute*` | Query execution | Check query plans |
| `CQScanHash::*` | Hash operations | Hash join/aggregate on large data |
| `CQScanSort::*` | Sort operations | Missing indexes, large ORDER BY |
| `CCompPlan::*`, `COptExpr::*` | Query compilation | Compilation storm, plan cache pressure |
| `CSQLSource::Execute` | Ad-hoc SQL execution | Parameterization issues |

### In-Memory OLTP patterns

| Function pattern | Likely cause | Action |
|-----------------|-------------|--------|
| `hk_*` | Hekaton operations | Memory-optimized table workload |
| `HkCheckpointCtxt::*` | Hekaton checkpoint | Checkpoint I/O overhead |
| `HkTxRun::*` | Hekaton transaction | Natively compiled procedure execution |

### HADR / Always On patterns

| Function pattern | Likely cause | Action |
|-----------------|-------------|--------|
| `HaDbMgr::*` | AG database manager | AG state changes, redo |
| `HadrArProxy::*` | AG availability replica | Replica communication |
| `LogBlock::MakeAvailable` | Log block for HADR | AG log send pressure |

### Non-Yielding Sub-Focus

When `sub_focus == "non-yielding"`:

1. **Look for long-running functions** — functions with very high exclusive %
   that don't call `SwitchContext` or `Yield`
2. **Check spinlock spins**:
   - `SpinlockBase::Backoff` / `SpinlockBase::SpinToAcquire` in callers
   - Trace upstream to identify the spinlock type
3. **Check hash/sort stalls**:
   - `CQScanHash::GetRowHelper` — hash build for large tables
   - `CQScanSort::GetSortedRow` — external sort spills
4. **Check compilation storms**:
   - `CCompPlan::FCompileQuery` — recompilation loop
   - `COptExpr::DeriveGroupProperties` — optimizer timeout
5. **Cross-reference with ERRORLOG** (if `case_id` linked):
   - Match non-yielding timestamp to the trace time window
   - Identify which scheduler/SPID was non-yielding
   - The hot function at that time IS what caused the non-yield

## Phase 4 — Source Code Lookup (Optional)

If hot functions are in SQL Server internal code and the user wants deeper understanding:

Route to `source-search` agent with the function name to find:
- The source file and function implementation
- What locks/latches it acquires
- Known issues or bug fixes in that code path

## Output Format

### Executive Summary (≤5 bullets)
- Total CPU pattern: sustained high / spiky / normal
- Top CPU consumer: module + function + % 
- Secondary consumers
- SQL Server interpretation: what subsystem is busy and why
- Recommended action

### Module Breakdown Table
```
Module           Exclusive %   Inclusive %   Subsystem
sqlmin.dll       34.2%         440.9%        Storage Engine
hkengine.dll     46.0%         292.2%        In-Memory OLTP
sqllang.dll       0.01%          0.14%       Query Processing
sqldk.dll         0.06%        585.2%        SQL OS (framework)
ntoskrnl.exe      0.35%          3.7%        Windows Kernel
```

### Top Functions (≤10)
For each hot function:
- **Function**: `module!FunctionName`
- **Exclusive CPU**: X% (N samples)
- **Inclusive CPU**: Y%
- **Callers**: top 3 callers
- **Callees**: top 3 callees
- **Assessment**: SQL Server interpretation of what this means

### Patterns Detected
- Scheduler contention / spinlock
- Buffer pool pressure
- Lock contention
- Compilation storm
- Non-yielding root cause
- Hekaton interop overhead

### Recommendations
1. **Primary**: What to fix first + why
2. **Secondary**: Other areas to investigate
3. **Data to collect**: If inconclusive, what additional data would help

### Cross-Reference (if case_id provided)
- ERRORLOG correlations (non-yielding times, dump triggers)
- XEvent correlations (wait types, scheduler pressure)
