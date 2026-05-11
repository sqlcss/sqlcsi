# SQL-CSI: SQL Server Case Scene Investigation

AI-powered toolkit for CSS engineers to analyze SQL Server ERRORLOG files, XEvent traces (system_health), crash dumps, and engine source code. Runs inside VS Code as a Copilot Chat agent (`@sql-csi`) with a router → sub-agent → skill architecture and MCP integration.

## Architecture

```
sqlcsi/
├── sql-csi.agent.md                  # Entry agent — router + full-analysis orchestrator
│
├── agents/                            # Sub-agents (description + lightweight workflow)
│   ├── errorlog-analysis.agent.md
│   ├── xevent-analysis.agent.md
│   ├── docs-lookup.agent.md
│   ├── dump-analysis.agent.md
│   └── source-search.agent.md
│
├── skills/                            # Detailed methodologies (forked context per skill)
│   ├── errorlog-analysis/SKILL.md
│   ├── xevent-analysis/SKILL.md
│   ├── docs-lookup/SKILL.md
│   └── dump-analysis/SKILL.md
│   #  (source-search has no separate skill — methodology is inline in its agent file)
│
├── scripts/                           # Standalone scripts (CLI + invoked by skills)
│   ├── parse_errorlog.js
│   ├── extract_xel.ps1
│   ├── parse_xevent.js
│   └── gen_merged_report.js
│
├── .vscode/
│   └── mcp.json                       # MCP server registrations
│
├── .github/
│   └── copilot-instructions.md        # Workspace-wide Copilot guidance
│
└── reports/                           # Generated reports (git-ignored)
```

## Agents and Skills

| Component | Type | Purpose | Backed by |
|-----------|------|---------|-----------|
| `sql-csi` | Entry agent | Route requests; orchestrate full analysis | — |
| `errorlog-analysis` | Agent + Skill | Parse ERRORLOG, extract errors, timeline, patterns | [scripts/parse_errorlog.js](scripts/parse_errorlog.js) |
| `xevent-analysis` | Agent + Skill | Parse system_health XEL, wait analysis, merged report | [scripts/extract_xel.ps1](scripts/extract_xel.ps1), [scripts/parse_xevent.js](scripts/parse_xevent.js), [scripts/gen_merged_report.js](scripts/gen_merged_report.js) |
| `docs-lookup` | Agent + Skill | KB fixes, CU applicability, wait type research | `microsoft-learn` MCP |
| `dump-analysis` | Agent + Skill | WinDbg / Mirrors commands for SQL Server dumps | WinDbg (external) |
| `source-search` | Agent | Engine source code search across SQL 2016/2017/2019/2022/2025 | `msdata` / `csswiki` MCP |

**Why split agent / skill?** Agents are short entry files with `description` frontmatter so the router can match user intent. Skills hold the detailed step-by-step methodology and are loaded only when the matching agent activates, keeping context small.

## Workflows

| # | Trigger (example) | Routes to | What it does |
|---|-------------------|-----------|--------------|
| 1 | `analyze errorlog <path>` | `errorlog-analysis` | Parse ERRORLOG, extract errors, timeline, patterns |
| 2 | `analyze xevent <path>` | `xevent-analysis` | Parse system_health XEL files, wait analysis, merge with ERRORLOG |
| 3 | `research error <N>` | `docs-lookup` | Look up KB fixes, wait type causes via Microsoft Learn |
| 4 | `analyze dump <path>` | `dump-analysis` | Generate WinDbg/Mirrors commands for a SQL crash dump |
| 5 | `search error <N>` | `source-search` | Search SQL Server source code for error definition + raising code |
| 6 | `full analysis` | All (orchestrated) | Run 1 → 2 → 3 → 5 sequentially; produce combined report |

## Key Features

### ERRORLOG Analysis
- Auto-detect UTF-16LE / UTF-8 encoding
- Multi-line message parsing
- Error classification by subsystem (HADR, LOCKING, MEMORY, etc.)
- Pattern detection: cascades, repeating, paired errors, LSN progression
- Priority assignment: HIGH / MEDIUM / LOW
- AG role change timeline tracking

### XEvent Analysis
- Binary XEL extraction via PowerShell `Read-SqlXEvent`
- 4 focused analysis areas:
  - `sp_server_diagnostics` — WARNING/ERROR states only
  - `scheduler_monitor` — CPU > 75% or Memory < 80%
  - `error_reported` — ERRORLOG complement
  - `wait_info` — all waits with category classification
- Cross-correlation with ERRORLOG findings

### Microsoft Docs Lookup
- KB article search and CU applicability check
- Wait type root cause analysis from official CSS I/O guide
- Diagnostic DMV queries

### Dump Analysis
- Subsystem-aware WinDbg/Mirrors script generation (HADR, Memory, Scheduler, Locking, IO, Connectivity)
- SOSRingBuffer LINQ queries filtered by error number / task / scheduler
- Parsing of pasted-back WinDbg output

### Source Code Search
- Error definition lookup in `sqlerrorcodes.h`
- Find code that raises the error
- Function logic analysis
- XEvent diagnostics discovery
- HTML report with Azure DevOps links

## Prerequisites

- **VS Code** with GitHub Copilot Chat extension
- **Node.js** (v18+)
- **PowerShell** with `SqlServer` module (auto-installed on first XEL extraction)
- **MCP servers** configured in [.vscode/mcp.json](.vscode/mcp.json):
  - `microsoft-learn` — for `docs-lookup`
  - `msdata` / `csswiki` — for `source-search`
  - Optional: `mssql`, `bluebird-mcp-*`, `azure-mcp`, `enghub`, `icm-prod`, `SqlOps`

## Quick Start

Open the `sqlcsi` folder in VS Code and use Copilot Chat:

```text
@sql-csi analyze errorlog \\server\share\ERRORLOG

@sql-csi search error 19432 in SQL2022

@sql-csi full analysis, errorlog is \\server\share\ERRORLOG, case ID SR12345
```

## Standalone Scripts

The scripts in [scripts/](scripts/) can also be used directly from the CLI:

```bash
# ERRORLOG
node scripts/parse_errorlog.js ERRORLOG* --days 7 --json --output reports/findings.json

# XEvent
powershell -File scripts/extract_xel.ps1 -Path "system_health*.xel" -Days 7 -Output reports/extract.json
node scripts/parse_xevent.js reports/extract.json --errorlog reports/findings.json --json --output reports/xe_findings.json

# Merged report
node scripts/gen_merged_report.js reports/findings.json reports/xe_findings.json reports/merged.html
```

## License

Internal tool for Microsoft CSS. Not for public distribution.
