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

## Phase 1 — Module-Level Comparison

Query both traces (mirror pattern):
```
Process = {target_process}
Group by: Module
Aggregate: Sum(Weight) as CpuMs
```

**Agent-layer diff**:
1. Collect all module names from both traces (union of keys)
2. For each module: `baseline_ms`, `problem_ms`, `delta_ms`, `delta_%`
3. If duration-normalized: use rates instead of raw ms
4. Sort by `|delta_ms|` descending (absolute change)
5. Map modules to SQL Server subsystems (see wpr-cpu-analysis skill for mapping table)

Present as markdown table:

| Module | Subsystem | Baseline (ms) | Problem (ms) | Delta (ms) | Delta % | Assessment |
|--------|-----------|---------------|--------------|------------|---------|------------|
| sqlmin.dll | Storage Engine | 23,956 | 57,168 | +33,212 | +138.7% | **Regression** |
| sqllang.dll | Query Processing | 242,650 | 75,517 | -167,133 | -68.9% | **Improvement** |
| sqldk.dll | SQL OS | 16,532 | 33,909 | +17,377 | +105.1% | **Regression** |

**Identify**:
- Which SQL Server subsystems changed the most?
- Is the change in engine code or Windows/kernel code?
- Direction: is problem trace heavier or lighter?

---

## Comparison Mode Selection

After Phase 0 (trace context) and Phase 1 (module overview), ask user:

**"对比维度选择：**
- **A) Function-first** — 直接按函数对比 CPU 差异（适合 workload 相同、线程拓扑没变的场景）
- **B) Thread-first** — 先按线程对比分布和角色，再钻入差异线程看函数变化（适合并行度可能变了、线程数或角色有变化的场景）

**建议选哪个？"**

### Auto-detect hints (if user says "你选" / "auto")

Based on Phase 0 data, auto-select:
- **Same PID** in both traces → same instance, likely same thread topology → **Path A**
- **Different PIDs** → different instances, thread IDs won't match → **Path A**
  (Thread IDs are meaningless across instances — use function comparison)
- **CPU rate change >50%** → major workload difference, thread roles may have
  shifted → **Path B** recommended
- **Module distribution fundamentally different** (e.g. hkengine NEW) →
  workload changed → **Path B** recommended

---

## Path A — Function-First Comparison

### Phase 2A — Function-Level Comparison

Query both traces (mirror pattern):
```
Process = {target_process}
Group by: Function
Aggregate: Sum(Weight) as CpuMs
```

**Agent-layer diff**:
1. Collect all function names from both traces
2. Compute delta for each function
3. Sort by delta descending → **top regressions** (CPU increased most)
4. Sort by delta ascending → **top improvements** (CPU decreased most)
5. Flag functions that appear in only one trace as **NEW** or **GONE**

Present **Top 10 Regressions**:

| Function | Baseline (ms) | Problem (ms) | Delta (ms) | Delta % | Module |
|----------|---------------|--------------|------------|---------|--------|
| FunctionX | 1,200 | 15,400 | +14,200 | +1183% | sqlmin.dll |
| FunctionY | 0 | 8,500 | +8,500 | NEW | hkengine.dll |

Present **Top 5 Improvements**:

| Function | Baseline (ms) | Problem (ms) | Delta (ms) | Delta % | Module |
|----------|---------------|--------------|------------|---------|--------|
| FunctionZ | 45,000 | 2,300 | -42,700 | -94.9% | sqllang.dll |

**Note**: Function names are bare (no module prefix). To determine which module a
function belongs to, run a supplementary query on one trace with `group by Module,
Function` filtered to that function name, or cross-reference with Phase 1 results.

### Phase 3A — Investigate Top Regressions

For the **top 3 regressed functions** from Phase 2A:

#### 3A.1 — Call stack comparison (parallel on both traces)

For each regressed function, query **both traces in parallel**:

```
add_condition(property="Process", operator="Equal", value="{target_process}")
add_condition(property="Function", operator="Equal", value="<regressed_function>")
add_grouping(property="Stack")
add_aggregation(name="CpuMs", property="Weight", type="Sum")
```

**Compare**:
- Did the **callers** change? (different query patterns triggering the function)
  → Extract caller frames from Stack strings, compare top callers between traces
- Did the **callees** change? (function doing different work internally)
  → Look at frames below the function in Stack strings
- Is the function **new** in the problem trace? (code change or new feature)
- Is the function called **more times** vs **more expensive per call**?
  → Compare sample counts (use `Count` aggregation alongside `Weight`)

#### 3A.2 — Per-thread distribution (for each regressed function)

Check if the function runs on different numbers of threads:

```
add_condition(property="Function", operator="Equal", value="<regressed_function>")
add_grouping(property="Thread_ID")
add_aggregation(name="CpuMs", property="Weight", type="Sum")
```

Run on both traces. Compare:
- **Thread count change** → concurrency/parallelism shift (DOP change, more concurrent queries)
- **Same thread count, higher per-thread CPU** → per-call regression (more data, worse plan)
- **Same thread count, same per-thread CPU** → no meaningful change (noise)

#### 3A.3 — Call stack tree extraction

For the top regressed functions, extract **full call stacks** from both traces.
If multiple regressed functions share the same caller chain (e.g. `StepOnStatements`
calls `PStmtCurSelectNext`), merge them into one logical unit.

Query both traces (mirror pattern, scoped to selected thread):

```
add_condition(property="Thread_ID", operator="Equal", value="{thread_id}")
add_condition(property="Function", operator="Equal", value="<regressed_function>")
add_grouping(property="Stack")
add_aggregation(name="CpuMs", property="Weight", type="Sum")
```

**Present as tree** — convert slash-delimited stack paths into an indented tree.
Collapse common prefixes. Annotate branch points with CPU ms. If the same callee
is reached from multiple callers, show as branches with per-path CPU:

```
└─ ExecuteStmts<1,1>
   ├─── [Path 1: {N} ms ─ {description}]
   │    └─ ... → CacheClockHand::Move → StepOnStatements ── {ms}
   └─── [Path 2: {N} ms ─ {description}]
        └─ ... → CacheClockHand::Move → StepOnStatements ── {ms}
```

**Show trees for BOTH traces** — the problem trace tree will be deep with high
CPU annotations; the reference trace tree for the same functions will typically
be minimal (near-zero CPU), confirming the regression.

**Print both trees to the session immediately.**

#### 3A.4 — Inclusive CPU call tree comparison

Query the **full stack set** for each trace's selected thread (no function filter):

```
add_condition(property="Thread_ID", operator="Equal", value="{thread_id}")
add_grouping(property="Stack")
add_aggregation(name="CpuMs", property="Weight", type="Sum")
```

Then compute **inclusive CPU** per key frame at the agent layer:
- For each key function name in the call chain, sum CPU across all stacks
  whose `elements` string contains that function name
- This gives the total CPU where that function appears **anywhere** in the
  call path (inclusive = self + all callees)

Present as a **side-by-side inclusive tree**:

```
                                          Trace A (problem)     Trace B (normal)
                                          ─────────────────     ────────────────
Thread Total                              {N} ms  100%         {N} ms  100%
│
└─ process_request                        {N} ms  {%}          {N} ms  {%}
   └─ ExecuteStmts                        {N} ms  {%}          {N} ms  {%}
      └─ ExecuteSql                       {N} ms  {%}          {N} ms  {%}
         └─ CreateMemoryObject            {N} ms  {%}          {N} ms  {%}    ← divergence
            └─ CacheClockHand::Move       {N} ms  {%}          {N} ms  {%}
```

The **divergence point** (where Trace A % jumps far above Trace B %) is the
root of the regression. Annotate it.

**Print this tree to the session immediately** — this is the single most
important output of the entire comparison.

#### 3A.5 — Stack tree comparison summary

After both the stack trees (3A.3) and inclusive CPU tree (3A.4) are presented,
output a **comparison summary table** consolidating the findings:

| | Trace A (problem) | Trace B (reference) |
|---|---|---|
| **Hotspot function total CPU** | {N} ms ({%}) | {N} ms ({%}) |
| **Path 1: {description}** | {N} ms | {N} ms |
| **Path 2: {description}** | {N} ms | {N} ms |
| **Path 3 (if exists)** | — | {N} ms |
| **Call chain** | {same/different} | {same/different} |
| **Code path** | {description} | {description} |

Key observations:
- Are the code paths identical or different between traces?
- Is the regression due to **same path running slower** or **different path**?
- Any paths that appear in one trace but not the other?

**Do NOT draw conclusions about root cause here** — that belongs in Phase 4
(Interpretation) and Phase 6 (Source Code). This section only presents
the factual comparison.

After Phase 3A, proceed to **Phase 4 — SQL Server Interpretation**.

---

## Path B — Thread-First Comparison

### Phase 2B — Thread-Level Overview

Query both traces (mirror pattern):
```
Process = {target_process}
Group by: Thread_ID
Aggregate: Sum(Weight) as CpuMs
```

**Agent-layer diff**:

#### 2B.1 — Thread count and distribution

| Metric | Baseline | Problem |
|--------|----------|---------|
| Total active threads | N | M |
| Hot threads (>1% CPU) | N' | M' |
| Total CPU (ms) | X | Y |

#### 2B.2 — Thread clustering (per trace)

For **each trace independently**, cluster threads by their top function:

```
Process = {target_process}
Group by: Thread_ID, Function
Aggregate: Sum(Weight) as CpuMs
```

For each thread, identify its top-1 function. Group threads with same top function
into clusters. Present per-trace cluster summary:

**Baseline clusters**:

| Cluster | Top Function | Threads | Total CPU (ms) | % of process |
|---------|-------------|---------|----------------|--------------|
| A | CMsqlExecContext::ExecuteStmts | 8 | 180,000 | 61.1% |
| B | LogWriter::Flush | 2 | 45,000 | 15.3% |
| noise | (various) | 20 | 5,000 | 1.7% |

**Problem clusters** (same format).

#### 2B.3 — Cross-trace cluster comparison

Compare clusters between baseline and problem:

| Cluster role | Baseline | Problem | Change |
|-------------|----------|---------|--------|
| Query execution workers | 8 threads, 180s | 12 threads, 250s | +4 threads, +70s |
| Log writer | 2 threads, 45s | 2 threads, 48s | stable |
| NEW: Checkpoint | — | 3 threads, 30s | appeared |
| GONE: Background GC | 2 threads, 10s | — | disappeared |

**Key questions**:
- Did any thread cluster **appear** or **disappear**?
- Did any cluster's thread count change significantly?
- Within stable clusters, did per-thread CPU change?

### Phase 3B — Drill Into Changed Clusters

For each cluster that **changed significantly** (appeared, disappeared, or >20% CPU delta):

#### 3B.1 — Function breakdown within cluster

Pick representative threads from the changed cluster. Query each trace:

```
add_condition(property="Thread_ID", operator="Equal", value="{thread_id}")
add_grouping(property="Function")
add_aggregation(name="CpuMs", property="Weight", type="Sum")
```

Compare which functions are hot on these threads — same as Path A's function
diff but scoped to the affected threads only.

#### 3B.2 — Stack analysis for new/changed functions

For functions that are new or significantly changed within the cluster:

```
add_condition(property="Thread_ID", operator="Equal", value="{thread_id}")
add_condition(property="Function", operator="Equal", value="<changed_function>")
add_grouping(property="Stack")
add_aggregation(name="CpuMs", property="Weight", type="Sum")
```

**Same PID caveat**: Thread-first comparison only makes sense when both traces
capture the **same SQL Server instance** (same PID). If PIDs differ, thread IDs
are meaningless across traces — fall back to Path A.

After Phase 3B, proceed to **Phase 4 — SQL Server Interpretation**.

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

**When to use**: The inclusive CPU tree from Phase 3A.4 clearly shows where
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
