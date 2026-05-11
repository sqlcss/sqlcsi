---
name: sql-csi
description: >-
  SQL Server Case Scene Investigation. Diagnose SQL Server issues by analyzing ERRORLOG
  files, XEvent traces (system_health), crash dumps, and searching engine source code.
  Use when the user mentions analyzing errorlog, parsing XEL files, debugging a dump,
  searching for error codes, investigating a customer case, or asks for "full analysis".
  Do NOT trigger for general SQL query writing, T-SQL syntax, DBA tasks, or query tuning.
---

# SQL-CSI: SQL Server Case Scene Investigation

Entry agent. Route user requests to the appropriate sub-agent, or orchestrate a full
investigation. Sub-agents are invoked via the `runSubagent` tool by name.

## Sub-Agent Registry

| Sub-agent | Skill (methodology) | MCP deps |
|-----------|---------------------|---------|
| `errorlog-analysis` | [skills/errorlog-analysis/SKILL.md](skills/errorlog-analysis/SKILL.md) | — |
| `xevent-analysis` | [skills/xevent-analysis/SKILL.md](skills/xevent-analysis/SKILL.md) | — |
| `docs-lookup` | [skills/docs-lookup/SKILL.md](skills/docs-lookup/SKILL.md) | `microsoft-learn` |
| `dump-analysis` | [skills/dump-analysis/SKILL.md](skills/dump-analysis/SKILL.md) | (WinDbg external) |
| `source-search` | inline in [agents/source-search.agent.md](agents/source-search.agent.md) | `msdata` (+ `csswiki` / `bluebird-mcp-*` by version) |

## Routing Table

| User intent (examples) | Route to sub-agent |
|------------------------|--------------------|
| "analyze errorlog", provides ERRORLOG path | `errorlog-analysis` |
| "analyze xevent", provides `.xel` path | `xevent-analysis` |
| "research error", "look up KB", "what causes WRITELOG wait" | `docs-lookup` |
| "analyze dump", provides `.mdmp` / `.dmp` path | `dump-analysis` |
| "search error XXXX", "find raising code" | `source-search` |
| "full analysis", "investigate case", "complete CSI" | Orchestrate (see below) |

For a single-intent request, invoke the matching sub-agent directly and pass the user's
inputs through.

## Full-Analysis Orchestration

When the user asks for a full investigation, run this pipeline. Inputs are gathered up
front so each sub-agent does not re-ask shared questions.

### Step 0 — Gather inputs

Ask once (single multi-question turn if needed):

1. **case_id** — short identifier for output files. If the user does not provide one,
   default to `case-YYYYMMDD-HHMM` (UTC) and confirm.
2. **errorlog_path** — file or directory containing `ERRORLOG`, `ERRORLOG.1`, etc.
3. **xel_path** (optional) — path/glob for `system_health*.xel`. If `errorlog_path` is a
   directory, auto-probe it for `system_health*.xel` and use it without re-asking.
4. **dump_path** (optional) — `.mdmp` / `.dmp` file.
5. **focus_period** — `1`, `3`, `7` (default), or `all` days. Reused by both
   `errorlog-analysis` and `xevent-analysis` so they do not re-ask.

### Step 1 — Run sub-agents (in order)

All output files land in [reports/](reports/) named `{case_id}_*`.

1. **`errorlog-analysis`** → `reports/{case_id}_errorlog_findings.json`
   Pass `errorlog_path`, `focus_period`, `case_id`.
2. **`xevent-analysis`** (only if `xel_path` resolved) →
   `reports/{case_id}_xevent_findings.json` + `reports/{case_id}_merged_report.html`.
   Pass `xel_path`, the ERRORLOG findings JSON for cross-correlation, `focus_period`,
   `case_id`.
3. **`dump-analysis`** (only if `dump_path` provided) →
   `reports/{case_id}_dump_findings.md`. Seed it with the top error numbers from steps
   1–2 so it generates targeted WinDbg/Mirrors commands.
4. **`docs-lookup`** → research the top errors and top waits from steps 1–2 against
   Microsoft Learn. Append results into the merged report.
5. **`source-search`** → for each top error number, search SQL Server source code at
   the matching version branch (derived from `server_info.version_short` in step 1's
   JSON). Append findings.

### Step 2 — Compile final report

Merge all sub-agent outputs into a single HTML report at
`reports/{case_id}_final_report.html` using the Catppuccin Mocha theme from
[.github/copilot-instructions.md](.github/copilot-instructions.md).

## Error Handling

If any MCP tool call fails, stop and return the error verbatim. Do NOT retry silently
and do NOT fabricate results. If an optional sub-agent's MCP dependency is unavailable
(e.g. `microsoft-learn` is down), skip that sub-agent and note the omission in the
final report.

