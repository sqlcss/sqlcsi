---
name: wpr-allocation-analysis
description: >
  Allocation analysis for SQL Server using WPR/ETL traces and the diag-perf MCP
  server. Identifies which types consume the most memory, which code paths allocate
  them, and maps findings to SQL Server subsystems.
  USE FOR: "allocation 分析", "memory allocation", "what types are allocated most",
  "GC pressure from allocations".
  DO NOT USE FOR: dump-based memory analysis (use dump tools), CPU analysis, GC
  pause analysis (use GC tools).
---

# SQL Server Allocation Analysis Skill

Analyze memory allocations in a WPR/ETL trace for SQL Server (`sqlservr.exe`).
Identifies top allocated types, allocation call stacks, and maps to SQL Server
subsystems. Based on GC/AllocationTick ETW events.

**Prerequisites**: Trace must already be opened (`perf_open_trace`) and `sqlservr.exe`
PID must be identified before invoking this skill.

**Important**: Allocation analysis requires GC AllocationTick events in the trace.
If the trace was collected with CPU-only providers, there will be no allocation data.
Check `perf_open_trace` output for GC event count — if 0, inform the user that
allocation analysis is not possible with this trace.

## Inputs

- `etl_path` — Path to the opened ETL file
- `pid` — sqlservr.exe process ID
- `case_id` (optional) — for cross-reference with ERRORLOG/XEvent

## MCP Tools Used

| Tool | Purpose |
|------|---------|
| `allocation_get_top_types` | Top allocated types by bytes |
| `allocation_get_stacks_for_type` | Call stacks for a specific type's allocations |
| `allocation_get_grouped_stacks` | Group allocations by module / namespace / type |
| `allocation_get_frame_info` | Allocation bytes through a specific function |

## Phase 1 — Top Allocated Types

```
Call allocation_get_top_types(
    filePath = "{etl_path}",
    processId = {pid},
    maxTypes = 15
)
```

**Identify**:
- Which types dominate allocations? (byte[] / String / specific SQL types)
- Is allocation volume expected for the workload?
- Any surprising types in the top list?

Present:
```
Type                         Allocated Bytes   Count    Assessment
System.Byte[]                1,234,567,890     45,678   Large — check buffer usage
System.String                  456,789,012     23,456   String-heavy operations
System.Object[]                123,456,789     12,345   Array resizing
...
```

## Phase 2 — Allocation by Module

```
Call allocation_get_grouped_stacks(
    filePath = "{etl_path}",
    processId = {pid},
    groupBy = "module",
    maxGroups = 10
)
```

**Map to SQL Server subsystems** (same mapping as wpr-cpu-analysis skill):
- sqlmin.dll → Storage Engine allocations
- sqllang.dll → Query Processing allocations
- hkengine.dll → In-Memory OLTP allocations
- clr.dll / coreclr.dll → SQLCLR allocations

## Phase 3 — Investigate Top Allocators

For the **top 3 allocated types** from Phase 1:

### 3a — Get allocation call stacks

```
Call allocation_get_stacks_for_type(
    filePath = "{etl_path}",
    processId = {pid},
    typeName = "<top_type>",
    maxCallers = 10,
    maxCallees = 5
)
```

**Identify**:
- Which functions allocate this type? (callers)
- Is it a few hot spots or spread across many call sites?
- Can allocation be reduced? (pooling, caching, pre-allocation)

### 3b — Get frame-level detail

For the top allocating function:

```
Call allocation_get_frame_info(
    filePath = "{etl_path}",
    processId = {pid},
    frameName = "<allocating_function>"
)
```

## Phase 4 — SQL Server Interpretation

Map allocation patterns to SQL Server behavior:

| Allocation pattern | Likely cause | Action |
|-------------------|-------------|--------|
| Byte[] dominant, sqlmin callers | Buffer pool / page operations | Check buffer pool size, memory config |
| String dominant, sqllang callers | Query text handling, plan cache | Check ad-hoc query volume |
| Object[] with resizing | Collection growth (ArrayList, Dictionary) | Internal hashtable resizing |
| hkengine allocations | In-Memory OLTP row versions | Check memory-optimized table GC |
| CLR/managed allocations | SQLCLR procedure overhead | Review CLR usage |
| Large byte[] from network | TDS packet buffers | Network traffic volume |

### GC Pressure Assessment

High allocation rates cause GC pressure. Assess impact:
- **Low concern**: Allocations mostly Gen0, collected quickly
- **Medium concern**: Large Object Heap (LOH) allocations (>85KB) — fragments memory
- **High concern**: Very high allocation rate causing frequent Gen2 GCs

If GC pressure is suspected, recommend running GC analysis
(`gc_analyze_process`, `gc_get_performance_issues`) for full GC investigation.

## Output Format

### Executive Summary (≤5 bullets)
- Total allocation volume and rate
- Top allocated type and assessment
- Which SQL Server subsystem allocates the most
- GC pressure level: Low / Medium / High
- Recommended action

### Top Allocated Types (≤10)

```
Type                  Bytes         Count     Module/Subsystem    Assessment
System.Byte[]         1.23 GB       45,678    sqlmin (Storage)    Buffer operations
System.String         456 MB        23,456    sqllang (QPE)       Query text handling
...
```

### Top Allocating Functions (≤5)
For each hot allocator:
- **Function**: `module!FunctionName`
- **Type allocated**: what it allocates
- **Allocation bytes**: volume
- **Callers**: who triggers this allocation
- **Assessment**: SQL Server interpretation

### GC Pressure Assessment
- Allocation rate: X MB/sec
- Gen0 collection frequency (if available from GC tools)
- LOH allocation volume
- Recommendation: OK / investigate further with GC analysis

### Recommendations
1. **If high allocation in user code**: specific functions to optimize
2. **If GC pressure**: run GC analysis for pause/throughput investigation
3. **If LOH fragmentation**: check for large buffer patterns
