---
name: wpr-cpu-comparison
description: >
  Compare two WPR/ETL traces (baseline vs problem) for SQL Server CPU regression
  analysis. Uses WPA MCP query tools — queries each trace independently, then
  computes diff at the agent layer.
  USE FOR: "CPU 对比", "compare traces", "regression", "baseline vs candidate".
  DO NOT USE FOR: single trace CPU analysis (use wpr-cpu-analysis), GC, allocation.
---

# SQL Server CPU Comparison Skill

Compare baseline vs problem WPR/ETL traces to identify CPU regressions or improvements
in SQL Server (`sqlservr.exe`).

**Prerequisites**: Both ETL files must be opened in WPA GUI simultaneously (WPA supports
multiple traces). Symbols must be loaded. WPA MCP server must be running.

## Language Policy

- **Chat replies**: Match the user's input language (Chinese → Chinese, English → English).
- **Report language**: Before generating the final report, ask the user which
  language they prefer (English or Chinese). Do not assume.

## Inputs

- `case_id` (optional) — for cross-reference with ERRORLOG/XEvent findings

All other inputs (traceIds, process names, PIDs) are discovered automatically from WPA.

## WPA MCP Tools Used

| Tool | Purpose |
|------|---------|
| `list_traces` | List loaded traces — **must return exactly 2 traces** |
| `start_new_query` | Start a new query on a specific trace's table |
| `add_condition` | Add filter (Process, Module, Function, Thread_ID) |
| `add_grouping` | Add group-by field |
| `add_aggregation` | Add aggregation (Sum on Weight for CPU) |
| `perform_query` | Execute the query |

### Core Query Pattern (reused in every phase)

Every comparison query follows a **mirror pattern** — same query template executed
against both traceIds, then results merged at the agent layer:

```
# For EACH trace (baseline and problem):
start_new_query(traceId="{traceId}", tableName="CPU Usage (Sampled)",
                targetCollection="Rows", logicalOperator="And")
add_condition(queryId, condition={"operator": "Equal", "property": "Process",
              "value": "{target_process}"})
add_grouping(queryId, grouping={"property": "<GroupByField>"})
add_aggregation(queryId, aggregation={"name": "CpuMs", "property": "Weight", "type": "Sum"})
perform_query(queryId, allowQueryingAllData=true)
```

**Parallelization**: The two queries for baseline and problem are **independent** —
always launch both `start_new_query` calls in parallel, then both `add_condition` calls
in parallel, etc. This halves wall-clock time.

### WPA MCP Gotchas

| Field | Type | Sum aggregation |
|-------|------|-----------------|
| `Weight` | TimestampDelta | ✅ works — **always use this** |
| `__Weight` | Double | ❌ returns 0 (MCP bug) |
| `Count` | Int | ✅ Sum & Count both work |

- `Function` filter uses **bare name only** — no `module!` prefix
- `Stack` is slash-delimited: `[Root]/frame1/frame2/.../leaf`
- MCP only supports flat group + aggregate — no tree/butterfly view

---

## Phase 0 — Discover Traces & Identify Target Process

### 0a — List traces

```
Call list_traces()
```

**Expect exactly 2 traces**. If fewer, tell user to open both ETL files in WPA.
If more than 2, list all and ask user to identify which two to compare.

Record:
- `baseline_traceId`, `problem_traceId` — assign by filename convention, timestamp,
  or ask user: **"哪个是 baseline (好的)？哪个是 problem (差的)？"**
- Both must have `CPU Usage (Sampled)` in `processedTables`

### 0b — Top 5 processes by CPU

Query top processes by CPU on **both traces** (mirror pattern, group by `Process`).
Exclude `Idle (0)`. Sort by CPU descending, take top 5 per trace.

Present side-by-side (merge by process name, match across traces):

| # | Process | Baseline CPU (ms) | Baseline % | Problem CPU (ms) | Problem % | Delta |
|---|---------|-------------------|------------|------------------|-----------|-------|
| 1 | sqlservr.exe (23128) | 294,434 | 45.3% | 185,197 | 20.6% | -37.1% |
| 2 | OneDrive.exe (5196) | 120,958 | 18.6% | 68,198 | 7.6% | -43.6% |
| 3 | SearchIndexer.exe (13516) | 11,547 | 1.8% | 271,926 | 30.3% | +2254% |
| ... | | | | | | |

Ask user: **"请选择要调查的进程（输入序号或进程名）："**

Record `{baseline_process}` and `{problem_process}` (full Process string including PID).
If same PID in both traces → same instance. If different PIDs → flag it.

### 0c — Top 10 threads by CPU

After user selects the target process, query **both traces** for thread-level CPU:

```
Process = {target_process}
Group by: Thread_ID
Aggregate: Sum(Weight) as CpuMs
```

Sort by CPU descending, take top 10 per trace. Present side-by-side:

**Baseline — {process_name} Top 10 Threads:**

| Rank | Thread ID | CPU (ms) | % of process |
|------|-----------|----------|--------------|
| 1 | 12340 | 85,200 | 28.9% |
| 2 | 12342 | 72,100 | 24.5% |
| ... | | | |
| | **Total (all threads)** | **294,434** | **100%** |

**Problem — {process_name} Top 10 Threads:**

| Rank | Thread ID | CPU (ms) | % of process |
|------|-----------|----------|--------------|
| 1 | 12340 | 62,800 | 33.9% |
| 2 | 12342 | 41,500 | 22.4% |
| ... | | | |
| | **Total (all threads)** | **185,197** | **100%** |

**Quick observations** (present before asking next step):
- Thread count comparison: baseline has N active threads, problem has M
- Same PID → thread IDs can be matched across traces
- Highlight threads that appear in one trace but not the other

### 0d — Compute trace context

From the process query aggregates, extract:
- **Total trace CPU** (all processes) — the top-level `aggregates.CpuMs`
- **Target process CPU** — from the matching groupAggregate
- **Trace duration** — from the top-level aggregate `CpuMs.toTimeSpan` (total CPU
  across all cores; for wall-clock duration, check `Traces` table or use Idle CPU)

**Duration normalization**: If the two traces differ in duration by >10%, all
subsequent comparisons must normalize CPU to **rate** (CPU ms per second of trace):

```
rate = process_cpu_ms / trace_wall_clock_seconds
```

This prevents a 2-hour trace from appearing "worse" than a 1-hour trace simply
because it ran longer.

**How to estimate wall-clock duration**:
```
wall_clock_seconds ≈ total_trace_cpu_ms / num_logical_processors
```
Or query the `Traces` table for actual duration if available.

Present trace context:

```
Trace Context:
  Baseline: {filename}, Duration ~{HH:MM:SS}, sqlservr CPU {N} ms ({rate} ms/s)
  Problem:  {filename}, Duration ~{HH:MM:SS}, sqlservr CPU {N} ms ({rate} ms/s)
  CPU Rate Delta: +/-{X} ms/s (+/-{Y}%)
  ⚠️ Duration differs by Z% — all comparisons normalized to CPU rate
```

### 0e — Check symbol status

Query both traces: `Process = target, Module = sqlmin.dll, group by Function`.
If all Function = `"?"` → symbols not loaded, stop and ask user to load symbols.

---

## Comparison Method Selection

After Phase 0c (top 10 threads visible), choose the comparison method:

**"选择对比方法：**
- **Method 1: Thread-scoped** — 选定热线程，在线程内对比函数 %（适合单线程或少数线程主导的场景）
- **Method 2: Process-level** — 在进程级别对比函数 %（适合多线程 CPU 均匀分布的场景）

**建议选哪个？"**

### Auto-detect from Phase 0c thread data

| Thread distribution | Recommended method |
|--------------------|--------------------|
| 1 个线程占 >80% CPU | **Method 1** — 选该热线程 |
| 2-3 个热线程，每个 >20% | **Method 1** — 对每个热线程分别跑一次 |
| 多线程均匀分布（无单线程 >20%） | **Method 2** — process-level |
| 不同 PID（不同实例） | **Method 2** — thread ID 跨实例无意义 |

---

## Method 1 — Thread-Scoped Function Comparison

适用场景：单线程主导或少数热线程，需要锁定具体线程分析。

### Phase 2M1 — Thread Function % Diff

用户选定对比线程后（问题 trace 的 thread X vs 参考 trace 的 thread Y），
查询两个线程的 function breakdown：

```
Thread_ID = {selected_thread}
Group by: Function
Aggregate: Sum(Weight) as CpuMs
```

**用 % of thread CPU 对比**（消除 trace 时长差异）：

| Function | A % | B % | Delta (pp) |
|----------|-----|-----|------------|

Sort by `|delta|` descending. Show top 20.

### Phase 3M1 — Stack Tree & Inclusive CPU

对 top regression 函数执行 3 个子步骤：

#### 3M1.1 — Call stack tree extraction

查两个 trace 中 regression 函数的 stack（限定到选定线程）：
```
Thread_ID = {thread}, Function = {regressed_func}
Group by: Stack
```
分别展示两个 trace 的 stack tree。

#### 3M1.2 — Inclusive CPU side-by-side

查两个线程的全量 stack（不限 function），计算 inclusive CPU：
```
Thread_ID = {thread}
Group by: Stack
```
Agent 层对每个 key frame 做 string contains 匹配，计算 inclusive %。
展示 side-by-side tree，标注 divergence point。

#### 3M1.3 — Stack tree comparison summary

综合 3M1.1 和 3M1.2 的结果，输出对比总结表：

| | Trace A (problem) | Trace B (reference) |
|---|---|---|
| **Hotspot function total CPU** | {N} ms ({%} of thread) | {N} ms ({%} of thread) |
| **Path 1: {description}** | {N} ms | {N} ms |
| **Path 2: {description}** | {N} ms | {N} ms |
| **Path 3 (if exists)** | — | {N} ms |
| **代码路径** | {same/different} | {same/different} |
| **差异本质** | {description} | {description} |

Key observations:
- 代码路径是否相同？
- Regression 是同一路径变慢还是走了不同路径？
- 是否有某条 path 只在一个 trace 中出现？

**Do NOT draw conclusions about root cause here** — that belongs in Phase 4
(Interpretation) and Phase 6 (Source Code). This section only presents
the factual comparison.

After Method 1 Phase 3, proceed to Phase 4 (Interpretation).

---

## Method 2 — Process-Level Function Comparison

适用场景：多线程 CPU 均匀分布，或不同实例（不同 PID）对比。
不锁定特定线程，直接在进程级别对比函数分布。

### Phase 2M2 — Process Function % Diff

Query both traces (mirror pattern, scoped to process, **not** to thread):

```
Process = {target_process}
Group by: Function
Aggregate: Sum(Weight) as CpuMs
```

**用 % of process CPU 对比**（消除 trace 时长差异）：

| Function | A % | B % | Delta (pp) |
|----------|-----|-----|------------|

Sort by `|delta|` descending. Show top 20.

**与 Method 1 的区别**：
- Method 1 的 % = function CPU / thread CPU（一个线程的自画像）
- Method 2 的 % = function CPU / process CPU（整个进程的自画像）
- Method 2 会自然包含多线程的汇总效果

### Phase 3M2 — Stack & Inclusive CPU

对 top regression 函数执行 3 个子步骤。**注意：不限定 thread**。

#### 3M2.1 — Call stack tree extraction

查两个 trace 中 regression 函数的 stack（进程级别）：
```
Process = {target_process}, Function = {regressed_func}
Group by: Stack
```

多线程场景下，同一个函数可能从不同线程产生不同的 stack path。
Tree 展示时标注每条 path 的 CPU 和（如果有）线程分布。

**可选补充查询**：对 regression 函数查 thread 分布
```
Process = {target_process}, Function = {regressed_func}
Group by: Thread_ID
```
确认 regression 是集中在少数线程还是分散在多线程。

#### 3M2.2 — Inclusive CPU side-by-side

查两个 trace 的进程级全量 stack：
```
Process = {target_process}
Group by: Stack
```

⚠️ **Token budget warning**: 进程级 full stack 查询可能返回几万个 unique stacks
（比单线程查询大很多）。如果结果超过 token 限制：
- 先查 **Module-level** inclusive（group by Module，轻量）
- 再对 regressed module 做 **filtered stack** 查询
  （add_condition Module = regressed_module）

Agent 层计算 inclusive CPU per key frame，展示 side-by-side tree。

#### 3M2.3 — Thread distribution of regression

对 regression 函数，查两个 trace 的 thread 分布：
```
Process = {target_process}, Function = {regressed_func}
Group by: Thread_ID
```

| | Trace A | Trace B |
|---|---|---|
| Thread count | N | M |
| Top thread CPU | X ms (Y%) | X' ms (Y'%) |
| Distribution | 均匀/集中 | 均匀/集中 |

这一步帮助判断 regression 是：
- **全局性** — 分散在所有线程（配置/版本差异）
- **局部性** — 集中在少数线程（特定 query/session）

#### 3M2.4 — Stack tree comparison summary

综合 3M2.1-3M2.3 的结果，输出对比总结表：

| | Trace A (problem) | Trace B (reference) |
|---|---|---|
| **Hotspot function total CPU** | {N} ms ({%} of process) | {N} ms ({%} of process) |
| **Path 1: {description}** | {N} ms | {N} ms |
| **Path 2: {description}** | {N} ms | {N} ms |
| **Path 3 (if exists)** | — | {N} ms |
| **涉及线程** | {N} 个（集中/分散） | {N} 个（集中/分散） |
| **代码路径** | {same/different} | {same/different} |
| **差异本质** | {description} | {description} |

Key observations:
- 代码路径是否相同？
- Regression 是同一路径变慢还是走了不同路径？
- Regression 是全局性（多线程均匀）还是局部性（集中在少数线程）？
- 是否有某条 path 只在一个 trace 中出现？

**Do NOT draw conclusions about root cause here** — that belongs in Phase 4
(Interpretation) and Phase 6 (Source Code). This section only presents
the factual comparison.

After Method 2 Phase 3, proceed to Phase 4 (Interpretation).

> **Method 1 和 Method 2 互斥** — 根据 Phase 0c 的线程分布选择一个执行，
> 不需要两个都跑。选定后按该 method 的 Phase 2→3 完整执行即可。

## Session Output Rule

> **Every phase's results MUST be printed to the chat session immediately after
> completion.** Do not silently process data and move on. The user must see each
> step's output (tables, trees, summaries) in the conversation before proceeding
> to the next phase.
>
> This serves two purposes:
> 1. The user can validate results and redirect the investigation at any point
> 2. The conversation becomes the working log — all key data is visible

---

## Phase 4 — SQL Server Interpretation

Apply SQL Server domain knowledge to classify the comparison.
Refer to the **wpr-cpu-analysis** skill for complete mapping tables:
- Module → Subsystem mapping
- Function pattern → likely cause tables (Scheduler, Storage Engine, Query Processing,
  In-Memory OLTP, HADR patterns)

### Comparison-Specific Patterns

| Regression pattern | Likely root cause |
|-------------------|-------------------|
| `sqlmin` up, `sqllang` stable | Storage engine bottleneck — workload hitting more I/O or different tables |
| `sqllang` up, `sqlmin` stable | Query compilation/optimization regression — plan change |
| `sqllang` down, `sqlmin` up | Workload shift: fewer compilations, more data scanning |
| `hkengine` appeared or increased | In-Memory OLTP activated or workload shifted to memory-optimized tables |
| `sqldk` spinlock functions up | Spinlock contention — concurrency regression |
| `ntoskrnl` / `ntdll` up | OS-level regression — kernel lock, I/O driver issue |
| Same functions, more threads | Parallelism increase — DOP change or more concurrent queries |
| Same functions, same threads, more CPU | Per-call regression — data volume increase or algorithm change |
| Entirely different top functions | Workload change, not a code regression |

---

## Phase 5 — Decision

Classify the comparison result. Use **normalized rates** if trace durations differ.

| Decision | Criteria |
|----------|---------|
| **Regression** | CPU rate increase >5% OR any single SQL Server function >10% increase |
| **Improvement** | CPU rate decrease >5% AND no significant regressions |
| **Workload Change** | Different modules/functions dominate — different query mix |
| **No Material Change** | CPU rate change <5%, differences within noise |
| **Inconclusive** | Traces too different in duration/workload; or symbols missing |

---

## Phase 6 — Source Code Lookup (optional)

If the regression call chain involves SQL Server internal functions and deeper
understanding is needed, route to the `source-search` agent.

**When to use**: The inclusive CPU tree from Phase 3 clearly shows where
the divergence is, but the **why** requires understanding the code logic.

**What to search**: Each function in the regression call chain, from the
divergence point down to the leaf. Focus on:
- What data structure is being traversed (determines iteration count)
- What conditions control the loop bounds
- Whether there are amplification factors (e.g. per-entry callbacks)
- Whether trace flags or config settings affect the code path

**Present to session**: Annotated call chain with one sentence per layer
explaining what the function does and why it could be slow. Include key
code snippets (not full source). Highlight the amplification mechanism.

---

## Phase 7 — Documentation & KB Lookup (optional)

Route to the `docs-lookup` agent to search for:
- Known bugs / KB articles / CU fixes related to the regression pattern
- Trace flags that affect the regressed code path
- Configuration recommendations
- Diagnostic queries to run on the live SQL Server

**Present to session**: Summary table of findings:

| Solution | Effect | When to use |
|----------|--------|-------------|
| TF XXX | ... | ... |
| Config change | ... | ... |
| KB / CU fix | ... | ... |

Plus diagnostic queries the customer should run.

---

## Output Format

The final report preserves ALL key outputs from each phase. Structure follows
the analysis flow so the reader can trace the logic.

### 1. Trace Context

```
Baseline (problem):  {filename}, sqlservr CPU: {N} ms, Thread: {tid}
Reference (normal):  {filename}, sqlservr CPU: {N} ms, Thread: {tid}
Same PID: Yes/No
```

### 2. Top Process & Thread Summary

**Top 5 processes** (side-by-side, exclude Idle):

| # | Process | Baseline CPU (ms) | Baseline % | Problem CPU (ms) | Problem % |
|---|---------|-------------------|------------|------------------|-----------|

**Selected process top 10 threads** (per trace):

| Rank | Thread ID | CPU (ms) | % of process |
|------|-----------|----------|--------------|

Brief note: single-thread dominated / multi-thread / thread count change.

### 3. Function CPU % Diff Table

Per-thread function comparison using **% of thread CPU** (not absolute ms):

| Function | Trace A % | Trace B % | Delta (pp) |
|----------|-----------|-----------|------------|
| CCompPlan::StepOnStatements | 60.98% | 0.01% | -60.97 |
| ... | | | |

Sort by `|delta|` descending. Show top 20.

### 4. Call Stack Trees

For each regression hotspot function, present the **merged call tree** from
the problem trace. If a function has multiple call paths that converge
(e.g. same callee `StepOnStatements` from two callers), show them as branches:

```
[Root]
└─ ...common prefix...
   └─ ExecuteStmts<1,1>
      │
      ├─── [Path 1: {N} ms ─ {description}]
      │    └─ ...
      │       └─ CacheClockHand::Move → MoveInternal
      │          └─ SteppedOnEntry
      │             └─ CCompPlan::StepOnStatements ── {self ms}
      │                └─ PStmtCurSelectNext ─── {self ms}
      │
      └─── [Path 2: {N} ms ─ {description}]
           └─ ...same convergence point...
```

Also show the **reference trace** tree for the same functions (usually much
simpler/shorter because the function is near-zero).

**Merging rule**: If a callee function (e.g. `PStmtCurSelectNext`) is always
called from the same parent (e.g. `StepOnStatements`), merge them into one
logical unit rather than showing as separate trees.

### 5. Inclusive CPU Call Tree — Side-by-Side

The most important comparison view. Shows every level of the call chain with
inclusive CPU (ms + % of thread) for both traces:

```
                                              Trace A (problem)       Trace B (normal)
                                              ─────────────────       ────────────────
Thread Total                                  {N} ms  100%           {N} ms  100%
│
└─ process_request                            {N} ms  {%}            {N} ms  {%}
   └─ ExecuteStmts                            {N} ms  {%}            {N} ms  {%}
      └─ ExecuteSql                           {N} ms  {%}            {N} ms  {%}
         └─ CreateMemoryObject                {N} ms  {%}            {N} ms  {%}
            └─ CacheClockHand::Move           {N} ms  {%}            {N} ms  {%}
               └─ MoveInternal                {N} ms  {%}            {N} ms  {%}
                  └─ SteppedOnEntry           {N} ms  {%}            {N} ms  {%}
                     └─ StepOnStatements      {N} ms  {%}            {N} ms  {%}
```

**How to compute**: Query full stacks (group by Stack, sum Weight) for each
trace's selected thread. Then for each key frame name, sum CPU across all
stacks that **contain** that frame (string match on stack elements).
This gives inclusive CPU per frame.

### 6. Root Cause Analysis

If `source-search` agent was used, include:
- Annotated call chain: each layer's function, what it does (one sentence)
- Key code snippets (only the critical logic, not full source)
- Amplification factors or complexity analysis
- Why the problem trace is slower (specific mechanism)

### 7. Related KB / Trace Flags / Recommendations

| Solution | Effect | When to use |
|----------|--------|-------------|
| TF XXX | ... | ... |
| Config change | ... | ... |

Diagnostic queries to run on the SQL Server instance.
Action items for the customer.

### Output Files

| File | Purpose |
|------|---------|
| `reports/<case_id>_cpu_comparison.md` | Full comparison report |
