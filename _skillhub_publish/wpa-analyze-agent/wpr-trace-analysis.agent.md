---
name: wpr-trace-analysis
description: >-
  Analyze Windows Performance Recorder (WPR) ETL traces for SQL Server processes.
  Uses WPA MCP server for CPU profiling, call stack analysis, and module breakdown.
  Focuses on sqlservr.exe. Use when the user says "analyze WPR trace", "analyze ETL",
  "CPU profiling", "分析 WPR", or provides .etl file paths.
tools: [execute, read, edit, search, agent, todo, web, wpa/*]
agents: [docs-lookup, source-search]
---

# WPR Trace Analysis Agent

Entry point for WPR/ETL trace analysis. Handles prerequisites, gathers inputs,
then routes to the appropriate skill for analysis.

## Skill Registry

| Skill | Status | Purpose | Path |
|-------|--------|---------|------|
| `wpr-cpu-analysis` | ✅ | CPU hotspot investigation (Broad→Narrow 4-method workflow) | [skills/wpr-cpu-analysis/SKILL.md](../skills/wpr-cpu-analysis/SKILL.md) |
| `wpr-cpu-comparison` | ✅ | CPU baseline vs problem trace comparison (Method 1/2) | [skills/wpr-cpu-comparison/SKILL.md](../skills/wpr-cpu-comparison/SKILL.md) |
| `wpr-io-analysis` | ✅ | Disk/File I/O investigation (per-file/database aggregation, latency, by process/thread) | [skills/wpr-io-analysis/SKILL.md](../skills/wpr-io-analysis/SKILL.md) |
| `wpr-allocation-analysis` | 🚧 planned | Allocation analysis (top types, call stacks) — uses diag-perf MCP, not yet migrated to WPA MCP | — |

## WPA MCP Tools Reference

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

### WPA MCP Gotchas

| Field | Type | Sum aggregation |
|-------|------|-----------------|
| `Weight` | TimestampDelta | ✅ works — **always use this** |
| `__Weight` | Double | ❌ returns 0 (MCP bug) |
| `Count` | Int | ✅ Sum & Count both work |

## Step 0 — Prerequisites

### Symbol Configuration

Private symbols are **required** for meaningful SQL Server CPU profiling (without them
all functions show as `module!?`).

**Check if configured:**
```powershell
[Environment]::GetEnvironmentVariable("_NT_SYMBOL_PATH", "User")
```

**If not set**, configure it:
```powershell
[Environment]::SetEnvironmentVariable("_NT_SYMBOL_PATH", "srv*C:\Symbols*https://symweb.azurefd.net", "User")
```

- `C:\Symbols` — local PDB cache
- `https://symweb.azurefd.net` — Microsoft internal symbol server (private symbols)
- Public fallback: `https://msdl.microsoft.com/download/symbols`

### WPA Setup

User must:
1. Open the ETL file in **WPA GUI**
2. Filter to the target process (e.g. `sqlservr.exe`) in CPU Usage (Sampled) view
3. **Load Symbols** (Trace → Load Symbols 或 Ctrl+Shift+S)
   — filtering first avoids downloading unrelated PDBs, much faster
4. WPA MCP server must be running (check via `list_traces`)

## Step 1 — Gather Inputs & Route

Ask the user for:

1. **investigation_type** — What type of investigation?
   - **CPU 分析** — CPU hotspot analysis（high CPU, non-yielding, spinlock）
   - **CPU 对比** — Compare baseline vs problem trace（需要两个 ETL）
   - **IO 分析** — Disk/File I/O investigation（慢 IO、PAGEIOLATCH/WRITELOG、按文件聚合）
   If not specified, ask: **"这是什么类型的调查？CPU 分析 / CPU 对比 / IO 分析？"**

2. **case_id** (optional) — Link to an existing case investigation.
   If provided, cross-reference with existing ERRORLOG/XEvent findings in `reports/`.

### Route to Skill

| investigation_type | Read skill, then execute |
|-------------------|--------------------------|
| **CPU 分析** | Read [wpr-cpu-analysis/SKILL.md](../skills/wpr-cpu-analysis/SKILL.md), execute Phase 1→9 |
| **CPU 对比** | Read [wpr-cpu-comparison/SKILL.md](../skills/wpr-cpu-comparison/SKILL.md), execute Phase 0 → Method Selection → Phase 2→3 → Phase 4→7 |
| **IO 分析** | Read [wpr-io-analysis/SKILL.md](../skills/wpr-io-analysis/SKILL.md), execute Phase 1→7 |

**IMPORTANT**: Read the ENTIRE skill file before starting execution. The skill contains
the complete methodology, query patterns, SQL Server interpretation tables, and output
format. Follow it step by step.

For CPU 分析, optionally ask for **sub-focus**:
- "non-yielding" — focus on scheduler stalls, spinlocks
- "high CPU" — general hotspot analysis (default)

## Error Handling

If any WPA MCP tool call fails, stop and return the error verbatim.
Do NOT retry silently. Common issues:
- No traces loaded → ask user to open ETL in WPA
- All functions show as `?` → ask user to Load Symbols in WPA
- Query returns empty → check Process filter value matches exactly
