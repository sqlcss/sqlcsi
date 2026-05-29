---
name: wpr-cpu-analysis
description: >
  CPU hotspot investigation for SQL Server using WPR/ETL traces and the WPA MCP
  server. Broad→Narrow workflow: module overview → function drill-down →
  SQL Server–specific interpretation → source code lookup.
  USE FOR: "CPU 分析", "high CPU", "non-yielding", "spinlock contention".
  DO NOT USE FOR: CPU comparison (use wpr-cpu-comparison skill), GC analysis,
  allocation analysis.
---

# SQL Server CPU Investigation Skill

Analyze CPU usage in a WPR/ETL trace for SQL Server (`sqlservr.exe`).
Uses WPA MCP tools (query engine) with SQL Server domain knowledge.

**Prerequisites**: User must open the ETL file in WPA and load symbols before
invoking this skill. WPA MCP server must be running.

## Inputs

- `sub_focus` (optional) — "non-yielding" | "high CPU" (default: "high CPU")
- `case_id` (optional) — for cross-reference with ERRORLOG/XEvent

## WPA MCP Tools Used

| Tool | Purpose |
|------|---------|
| `list_traces` | List loaded traces and available tables |
| `get_schema` | Get table schema (fields, filters, aggregations) |
| `start_new_query` | Start a new query on a table |
| `add_condition` | Add filter condition |
| `add_grouping` | Add group-by field |
| `add_aggregation` | Add aggregation (Sum, Count, Average, Min, Max) |
| `perform_query` | Execute the query |
| `cancel_query` | Cancel a running query |

## WPA MCP Query Pattern Reference

Every query follows this pattern:

```
1. start_new_query(traceId, tableName, targetCollection="Rows", logicalOperator="And")
2. add_condition(queryId, condition={"operator": "Equal|Contains|...", "property": "...", "value": "..."})  // optional, repeatable
3. add_grouping(queryId, grouping={"property": "..."})  // repeatable
4. add_aggregation(queryId, aggregation={"name": "UniqueAlias", "property": "...", "type": "Sum|Count|..."})  // repeatable
5. perform_query(queryId, allowQueryingAllData=true)
```

**Key rules**:
- Each aggregation must have a unique `name`
- `condition.operator` must match the field's `supportedFilters` from `get_schema`
- Use `Weight` (TimestampDelta, Sum) for CPU time — **always use this field**
- Do NOT use `__Weight` (Double) — returns 0 (MCP bug)
- Results contain `.toMilliseconds` for easy reading

---

## Phase 1 — Discover Traces & Check Available Tables

```
Call list_traces()
```

From the result:
- Record `traceId` for subsequent queries
- Check `processedTables` for:
  - `"CPU Usage (Sampled)"` — **required** for CPU analysis
  - `"CPU Usage (Precise)"` — optional, for scheduling analysis
- If multiple traces are loaded, ask user which one to analyze

**Determine primary table**:
- If `CPU Usage (Sampled)` exists → use it (has Module, Function, Stack fields)
- If only `CPU Usage (Precise)` exists → use it (has CPU_Usage but no Function field)
- If neither exists → stop, inform user the trace lacks CPU data

## Phase 2 — List Top Processes by CPU

Query `CPU Usage (Sampled)` grouped by `Process`, aggregate `Weight__in_view_` Sum:

```
start_new_query(traceId="{traceId}", tableName="CPU Usage (Sampled)", 
                targetCollection="Rows", logicalOperator="And")
add_grouping(queryId, grouping={"property": "Process"})
add_aggregation(queryId, aggregation={"name": "WeightMs", "property": "Weight__in_view_", "type": "Sum"})
add_aggregation(queryId, aggregation={"name": "Samples", "property": "Count", "type": "Sum"})
perform_query(queryId, allowQueryingAllData=true)
```

**Present top 15 processes** sorted by WeightMs descending.

**IMPORTANT — 必须在 chat session 中直接输出表格**，不要只描述结果，要用 markdown 表格展示：

| Process | PID | Weight (ms) | Samples | % |
|---------|-----|-------------|---------|---|
| sqlservr.exe | 10900 | 96,037 | 96,030 | 48.19% |
| Idle | 0 | 82,718 | 82,650 | 41.50% |
| services.exe | 776 | 3,595 | 3,596 | 1.80% |
| ... | | | | |

**从 `Process` 字段提取 PID**：`Process` 格式为 `"name.exe (PID)"`，拆分为 Process Name 和 PID 两列。
**计算 %**：每个进程的 WeightMs / Total WeightMs × 100。

展示表格后，询问用户：

**"请选择要调查的进程 PID（例如输入 10900）："**

- 如果用户输入了 PID → 用对应的 `Process` 值（如 `"sqlservr.exe (10900)"`）作为后续查询的 filter
- 如果用户说 "sqlservr" 或进程名 → 匹配表格中的对应行，提取完整 `Process` 值
- 记录选中的 `Process` 值为 `{target_process}`，后续所有查询用 `add_condition(operator="Equal", property="Process", value="{target_process}")`

## Phase 3 — Check Symbol Status

**Symbol loading tip**: 告诉用户在 WPA 中先 filter 到目标进程（如 sqlservr.exe），
再 Load Symbols。WPA 只解析当前视图中可见模块的符号，这样避免下载几百个不相关进程的 PDB，
速度快很多。

Query `CPU Usage (Sampled)` where Process = target AND Module = top SQL module,
group by Function, to check if symbols are resolved:

```
start_new_query(...)
add_condition(queryId, condition={"operator": "Equal", "property": "Process", "value": "{target_process}"})
add_condition(queryId, condition={"operator": "Equal", "property": "Module", "value": "sqlmin.dll"})
add_grouping(queryId, grouping={"property": "Function"})
add_aggregation(queryId, aggregation={"name": "WeightMs", "property": "Weight__in_view_", "type": "Sum"})
perform_query(queryId, allowQueryingAllData=true)
```

**Check results**:
- If all Function values are `"?"` → **symbols not loaded**
  → Tell user: "请在 WPA 中先 filter 到 sqlservr.exe，然后 Load Symbols
    (Trace → Load Symbols 或 Ctrl+Shift+S)。完成后告诉我。"
  → **Stop and wait** — do not proceed without symbols
- If Function values contain real names (e.g. `"BPool::Get"`) → **symbols loaded, continue**

## 方法 1 — 按函数聚合（路径 A 主：Function → CPU）

Goal: which function inside the target process is hot?

```
start_new_query  (traceId, "CPU Usage (Sampled)", "Rows", "And")
add_condition    property=Process, operator=StartWith, value="{target_process_name}"
add_grouping     property=Function
add_aggregation  name=CpuUs, type=Sum, property=Weight
perform_query    allowQueryingAllData=true
```

Sort `groupAggregates` by `CpuUs.toMicroseconds` desc. Present top 15 as markdown table:

| Function | CPU (ms) | % |
|----------|----------|---|
| HkCompileAndBindTables | 50,808 | 52.9% |
| CBpWorkfileDelayedCleanupList::WfdclYieldNoAbort | 44,351 | 46.2% |
| ... | | |

**Phase 4 is not complete after this query.** For every hot function, you must also run
**Phase 4b** to independently obtain its per-thread + per-stack breakdown.

## 方法 1b — 每个热函数的 Per-Thread + Stack 分解（路径 A 补充）

Goal: for each hot function from Phase 4, list **which threads** hit it and **what the
leaf-call stack looks like on each thread**. Run this for every hot function — do not
skip it on the assumption that all hot functions share the same threads/stacks.

```
start_new_query  (traceId, "CPU Usage (Sampled)", "Rows", "And")
add_condition    property=Function, operator=Equal, value="<FunctionName>"   # BARE name, NO "module!" prefix
add_grouping     property=Thread_ID
add_grouping     property=Stack
add_aggregation  name=CpuWeight, type=Sum, property=Weight
perform_query    allowQueryingAllData=true
```

Reading the output:
- Top-level groups = threads that ever had this function as the **sampled leaf frame**
- `nestedGroupResults` per thread = distinct stack paths whose leaf is this function
  (usually 1 main path + an `[empty]` row for inline frames)
- Sum per thread = that thread's **self-CPU** in this function (NOT inclusive subtree time)
- Cross-check: this sum ≈ Phase 4's function % × process total
- If all threads share **one identical stack** → strictly homogeneous worker pool;
  any CPU variance is scheduling, not code-path
- Multiple distinct stacks per thread → branching call-sites; report each path's share

**Gotchas:**
- `Function` column stores the **bare** function name (e.g. `HkCompileAndBindTables`).
  Using `"hkengine.dll!HkCompileAndBindTables"` returns 0 rows — **no module prefix!**
- This filter gives **self-CPU** (leaf = function). To get **inclusive subtree time**,
  use `Stack Contains "FunctionName"` instead.
- Stack strings can be long; strip `[Root]` prefix and use `/` as tree indent for readability.

**If this query is slow**: It may be slow on the first run after symbol loading. Retry
once — subsequent runs should be fast due to WPA caching. If still slow, fall back to
extracting per-function per-thread data from Phase 6's `Thread_ID → Function` nested
results (but this loses the Stack information).

## 方法 2 — 按模块 → 函数聚合（路径 A 补充：Module → Function）

Goal: which DLL owns the hot code?

```
start_new_query  (traceId, "CPU Usage (Sampled)", "Rows", "And")
add_condition    property=Process, operator=StartWith, value="{target_process_name}"
add_grouping     property=Module
add_grouping     property=Function
add_aggregation  name=CpuUs, type=Sum, property=Weight
perform_query    allowQueryingAllData=true
```

Each top-level group is a module; `nestedGroupResults` are its functions.
Present as markdown table with SQL Server subsystem mapping:

| Module | Subsystem | CPU (ms) | % | Top Function |
|--------|-----------|----------|---|-------------|
| hkengine.dll | In-Memory OLTP | 51,634 | 53.1% | HkCompileAndBindTables |
| sqlmin.dll | Storage Engine | 42,678 | 43.9% | WfdclYieldNoAbort |
| kernel32.dll | Windows | 2,667 | 2.7% | BaseThreadInitThunk |

### SQL Server Module → Subsystem Mapping

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

## 路径 A / 路径 B 独立性规则

> ⚠️ 方法 1/1b/2 (路径 A — by function) 和 方法 3 (路径 B — by thread) 是
> **独立的**。Their results may not align 1:1.
> A function can span many threads; a thread can host many hot functions.
> Do **NOT** synthesize Path A's per-thread numbers by multiplying Path B's per-thread
> CPU by a global function ratio. Each path must run its own MCP queries.
> Cross-validation between the two belongs in the final conclusion, not inside
> either path's section.

## 方法 3 — 按线程 → CPU 排序 + 聚类（路径 B，独立于方法 1）

Goal: how many worker threads, are they doing the same thing, and is the work balanced?

Run this with its own queries even if Path A already gave the impression that all hot
functions share one thread set. Path B's job is to **discover** the thread layout from
the thread axis, not to reflect Path A's findings.

```
start_new_query  (traceId, "CPU Usage (Sampled)", "Rows", "And")
add_condition    property=Process, operator=StartWith, value="{target_process_name}"
add_grouping     property=Thread_ID
add_grouping     property=Function
add_aggregation  name=CpuUs, type=Sum, property=Weight
perform_query    allowQueryingAllData=true
```

Then **cluster threads by their top function** (NOT by CPU magnitude):

1. For each thread, identify its top-1 `Function` by `CpuUs`
2. Group threads sharing the same top function → one logical worker pool
   ("Cluster A: top=`HkCompileAndBindTables`")
3. Threads with unique tops, each < a few ms → "single-point noise" cluster
4. Inside a cluster, **sub-tier by total CPU magnitude** if you see clear bands
   (e.g. 5 threads ~9.7s vs 7 threads ~7.0s = Sub-A1 / Sub-A2).
   Equal sub-tier totals with unequal thread counts → staggered start or early finish
5. Report each cluster's: thread count, summed CPU, % of total, representative
   top-3 functions per thread

**Why cluster by top function, not by CPU?** Same top function ⇒ same code path ⇒
same logical role. CPU magnitude differences within a cluster are scheduling artifacts.

Present cluster summary as markdown table:

| Cluster | Top Function | Threads | Total CPU (ms) | % | Sub-tiers |
|---------|-------------|---------|----------------|---|-----------|
| A | HkCompileAndBindTables | 12 | 89,400 | 93.1% | A1: 5×9.7s, A2: 7×7.0s |
| B | CreateProcessW | 1 | 1,034 | 1.1% | — |
| noise | (various) | 15 | 342 | 0.4% | — |

### Per-thread stacks with collapsible `<details>` rows

When listing each thread's stack inline with the CPU ranking table:

1. **For a homogeneous cluster** (same top function on N threads): emit shared variant
   blocks ONCE at top, then a tiny `<details>` per thread referencing the shared
   template + showing this thread's per-variant CPU split
2. **For heterogeneous threads** (each with unique stacks): emit one `<details>` per
   thread with all its distinct stacks
3. **For noise threads**: collapse all into ONE `<details>` with thread→leaf table
4. **Query strategy**: instead of one giant `Thread_ID → Stack` query (token blow-up),
   issue **one query per thread of interest** (`condition Thread_ID Equal N`,
   `group Stack`, `Sum Weight`). Skip for homogeneous threads whose stacks you
   already know from 方法 1b.

### 3b — Per-thread Stack 下钻

对 Tier-1（热线程）中选 1 个代表性线程查完整 Stack：

```
start_new_query  (traceId, "CPU Usage (Sampled)", "Rows", "And")
add_condition    property=Process, operator=StartWith, value="{target_process_name}"
add_condition    property=Thread_ID, operator=Equal, value={representative_thread_id}
add_grouping     property=Stack
add_aggregation  name=CpuUs, type=Sum, property=Weight
perform_query    allowQueryingAllData=true
```

**用途**：拿到完整调用栈后才能下结论（是 recovery、查询执行还是编译）。
**对 Tier-2/Tier-3**：也分别对每个有意义的线程做 Stack 查询，列出子路径分组。

**输出格式**：
- Tier-1 代表性线程：列出所有唯一 stack（按 CPU 排序），标注 leaf 函数和占比
- Tier-2 线程：按子路径分组（如 DLL 加载、CodeGen、CreateProcess 等），用 `<details>` 展开
- Tier-3 噪声线程：只列 thread→leaf 表，合并到一个 `<details>` 里

## SQL Server 函数解读

Map hot functions from 方法 1/2 to known SQL Server patterns and root causes:

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
| `hk_*`, `Hk*` | Hekaton operations | Memory-optimized table workload |
| `HkCheckpointCtxt::*`, `HkCkpt*` | Hekaton checkpoint/recovery | Checkpoint I/O or database restore |
| `HkTxRun::*` | Hekaton transaction | Natively compiled procedure execution |
| `HkCompileAndBindTables` | Hekaton table compile | Checkpoint restore loading tables |

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

## 火焰图导出（Optional）

Use when the user says "flame graph", "火焰图", "speedscope", or wants visual stack hotspots.

```
start_new_query  (traceId, "CPU Usage (Sampled)", "Rows", "And")
add_condition    property=Process, operator=StartWith, value="{target_process_name}"
add_grouping     property=Stack
add_aggregation  name=CpuUs, type=Sum, property=Weight
perform_query    allowQueryingAllData=true
```

For each returned group, transform:
- Strip leading `[Root]/` from the `Stack` key
- Replace `/` with `;`
- Append ` <µs>` where µs = `CpuUs.toMicroseconds`
- Simplify long C++ template signatures to readable short names

Write to a `.folded` file, one stack per line:
```
frame1;frame2;...;frameN <weight_us>
```

**Token-budget warning**: Full Stack query on a hot process often returns 140+ unique
stacks with very long strings. Mitigations:
1. Pre-filter by Module (e.g. `add_condition Module StartWith "hkengine.dll"`)
2. Or have user run a script to transform JSON → folded format outside agent context

**Render options**:
- **Speedscope** (easiest): https://www.speedscope.app → drag `.folded` file → Left Heavy view
- **flamegraph.pl** (SVG): `perl flamegraph.pl --title "..." --countname us input.folded > output.svg`

## 源码查找（Optional）

If hot functions are in SQL Server internal code and the user wants deeper understanding:

Route to `source-search` agent with the function name to find:
- The source file and function implementation
- What locks/latches it acquires
- Known issues or bug fixes in that code path

## Output Format

All results must be presented as markdown tables inline in chat.

### Result Narrative Template

When reporting back to the user, structure the conclusion as:

1. **What was the perceived problem?** (e.g. "high CPU", "non-yielding scheduler")
2. **What is actually happening?** (e.g. "Hekaton database recovery via checkpoint restore")
3. **Top cluster**: N threads, X% CPU, signature function
4. **Sub-tiers and what they mean** (staggered start / NUMA grouping / etc.)
5. **Minor secondary paths** worth mentioning
6. **Concrete optimization candidates**, if any

### Executive Summary (≤5 bullets)
- Total CPU pattern: sustained high / spiky / normal
- Top CPU consumer: module + function + %
- Secondary consumers
- SQL Server interpretation: what subsystem is busy and why
- Recommended action

### Recommendations
1. **Primary**: What to fix first + why
2. **Secondary**: Other areas to investigate
3. **Data to collect**: If inconclusive, what additional data would help

### Cross-Reference (if case_id provided)
- ERRORLOG correlations (non-yielding times, dump triggers)
- XEvent correlations (wait types, scheduler pressure)

### 配套文件（必须全部生成）

| 文件 | 用途 |
|------|------|
| `reports/<process>-wpa-analysis.md` | 完整分析报告（方法 1/2/3 + 每线程栈详情 + 综合结论）|
| `reports/<process>-threads.tsv` | 方法 3 完整线程 TSV（Rank, ThreadId, CpuUs, CpuMs, Pct, Note）|
| `reports/<process>-flamegraph.folded` | 火焰图折叠栈数据 (Brendan Gregg 格式，µs) |

---

## WPA MCP Gotchas (verified)

| Field | Type | Sum aggregation |
|-------|------|-----------------|
| `Weight` | TimestampDelta | ✅ works — **always use this** |
| `CPU_Usage__in_view_` | TimestampDelta | ✅ works (Precise table) |
| `__Weight` | Double | ❌ returns 0 (MCP bug) |
| `CPU_Usage` | Precise | ❌ returns 0 (MCP bug) |
| `Count` | Int | ✅ Sum & Count both work |

**→ Always aggregate CPU on `Weight` (Sum). Result `.toMicroseconds` = CPU µs, `.toMilliseconds` = CPU ms.**

Other limitations:
- MCP only supports **flat group + aggregate** — no tree/butterfly view
- `Stack` is slash-delimited: `[Root]/frame1/frame2/.../leaf`
- Full Stack query can blow token budget — pre-filter by Module if needed
- `Function` filter uses **bare name only** — no `module!` prefix

Other limitations:
- MCP only supports **flat group + aggregate** — no tree/butterfly view
- `Stack` is a slash-delimited string `[Root]/frame1/frame2/.../leaf`
- Full Stack query can blow token budget — pre-filter by Module if needed
