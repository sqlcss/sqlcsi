---
name: wpr-cpu-comparison
description: >
  Compare two WPR/ETL traces (baseline vs problem) for SQL Server CPU regression
  analysis. Uses diag-perf MCP cpu_compare_traces tool with SQL Server domain knowledge.
  USE FOR: "CPU 对比", "compare traces", "regression", "baseline vs candidate".
  DO NOT USE FOR: single trace CPU analysis (use wpr-cpu-analysis), GC, allocation.
---

# SQL Server CPU Comparison Skill

Compare baseline vs problem WPR/ETL traces to identify CPU regressions or improvements
in SQL Server (`sqlservr.exe`).

**Prerequisites**: Both traces must already be opened (`perf_open_trace`) and
`sqlservr.exe` PIDs must be identified before invoking this skill.

## Inputs

- `baseline_etl` — Path to the baseline (good) ETL file
- `problem_etl` — Path to the problem (bad) ETL file
- `baseline_pid` — sqlservr.exe PID in baseline trace
- `problem_pid` — sqlservr.exe PID in problem trace
- `case_id` (optional) — for cross-reference with ERRORLOG/XEvent

## MCP Tools Used

| Tool | Purpose |
|------|---------|
| `cpu_compare_traces` | Compare CPU between two traces |
| `cpu_get_grouped_stacks` | Module/function breakdown per trace |
| `cpu_get_frame_info` | Detailed metrics for regressed functions |
| `cpu_get_stack_info` | Call chain analysis for regressed functions |

## Phase 0 — Validate Traces

Before comparing, verify both traces are comparable:

1. **Check trace durations** — if they differ by >50%, flag prominently
2. **Check total CPU MSec** — note the ratio (e.g. problem = 2× baseline)
3. **Confirm both are sqlservr.exe** — same SQL Server version if possible

Present:
```
Trace Context:
  Baseline: Duration {HH:MM:SS}, CPU {N} ms, PID {pid}
  Problem:  Duration {HH:MM:SS}, CPU {N} ms, PID {pid}
  CPU Delta: +/-{X} ms (+/-{Y}%)
```

## Phase 1 — Module-Level Comparison

```
Call cpu_compare_traces(
    baselineTracePath = "{baseline_etl}",
    comparisonTracePath = "{problem_etl}",
    baselineProcessId = {baseline_pid},
    comparisonProcessId = {problem_pid},
    granularity = "module",
    topCount = 15
)
```

**Identify**:
- Which SQL Server modules (DLLs) changed the most?
- Map modules to SQL Server subsystems (see wpr-cpu-analysis skill for mapping)
- Is the change in engine code or Windows/kernel code?

## Phase 2 — Function-Level Comparison

```
Call cpu_compare_traces(
    baselineTracePath = "{baseline_etl}",
    comparisonTracePath = "{problem_etl}",
    baselineProcessId = {baseline_pid},
    comparisonProcessId = {problem_pid},
    granularity = "frame",
    topCount = 20
)
```

**Identify**:
- Top regressed functions (CPU increased the most)
- Top improved functions (CPU decreased)
- New functions that appeared only in the problem trace

## Phase 3 — Investigate Top Regressions

For each of the top 3 regressed functions:

### 3a — Get detail in problem trace

```
Call cpu_get_frame_info(
    filePath = "{problem_etl}",
    processId = {problem_pid},
    frameName = "<regressed_function>"
)
```

### 3b — Get call stack in problem trace

```
Call cpu_get_stack_info(
    filePath = "{problem_etl}",
    processId = {problem_pid},
    frameName = "<regressed_function>",
    maxCallers = 10,
    maxCallees = 10
)
```

### 3c — Compare with baseline call stack

```
Call cpu_get_stack_info(
    filePath = "{baseline_etl}",
    processId = {baseline_pid},
    frameName = "<regressed_function>",
    maxCallers = 10,
    maxCallees = 10
)
```

**Compare**:
- Did the callers change? (different query patterns triggering the function)
- Did the callees change? (function doing different work internally)
- Is the function new? (code change or new feature activated)

## Phase 4 — SQL Server Interpretation

Apply SQL Server domain knowledge to the regressions:

| Regression pattern | Likely root cause |
|-------------------|-------------------|
| `sqlmin` modules up, `sqllang` stable | Storage engine bottleneck — workload hit more I/O |
| `sqllang` up, `sqlmin` stable | Query compilation/optimization regression — plan change |
| `hkengine` appeared or increased | In-Memory OLTP activated or workload shifted |
| `sqldk` spinlock functions up | Spinlock contention — concurrency regression |
| `ntoskrnl` / `ntdll` up | OS-level regression — kernel lock, I/O driver issue |
| `LockManager::*` up | Lock contention increased — isolation level change or blocking |
| `LogWriter::*` up | Transaction log bottleneck — more writes or slower disk |
| `BPool::*` up | Buffer pool pressure — memory config change or larger dataset |

## Phase 5 — Decision

Classify the comparison result:

| Decision | Criteria |
|----------|---------|
| **Regression** | Total CPU increase >5% OR any single SQL Server function >10% increase |
| **Improvement** | Total CPU decrease >5% AND no significant regressions |
| **Workload Change** | Different modules active — likely different query mix, not a code regression |
| **No Material Change** | Total CPU change <5%, differences within noise |
| **Inconclusive** | Traces too different in duration/workload to compare meaningfully |

## Output Format

### Executive Summary (≤5 bullets)
- Overall CPU change: +/-X% (baseline → problem)
- Top regression: function + module + delta %
- Root cause classification: regression / workload change / inconclusive
- SQL Server interpretation: what subsystem regressed and probable why
- Recommended action

### Comparison Table

```
Function/Module         Baseline %   Problem %   Delta     Assessment
sqlmin!FunctionX          12.3%        28.5%     +16.2%    Storage engine regression
sqllang!FunctionY          8.1%         8.3%      +0.2%    Stable
hkengine!FunctionZ         0.0%        15.4%     +15.4%    NEW — Hekaton activated
```

### Top Regressions (≤5)
For each regressed function:
- **Function**: `module!FunctionName`
- **Baseline**: X% → **Problem**: Y% (delta: +Z%)
- **Callers changed?**: Yes/No — what changed
- **Callees changed?**: Yes/No — what changed
- **SQL Server interpretation**: what this means

### Top Improvements (≤3)
Same format as regressions.

### Decision
- **Classification**: Regression / Improvement / Workload Change / No Change
- **Confidence**: High / Medium / Low
- **Evidence**: Key data points supporting the decision

### Recommendations
1. **If regression**: what to investigate next (query plans, config changes, workload)
2. **If workload change**: how to normalize for fair comparison
3. **Additional data**: what to collect if inconclusive
