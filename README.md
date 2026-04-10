# SQL-CSI: SQL Server Case Scene Investigation

AI-powered toolkit for CSS engineers to analyze SQL Server ERRORLOG files, XEvent traces (system_health), crash dumps, and engine source code. Built as a [Claude Code](https://claude.com/claude-code) agent with skills + sub-agent architecture and MCP integration.

## Architecture

```
sqlcsi/
├── sql-csi.agent.md                        # Main agent — lightweight router (56 lines)
│
├── skills/                                  # Interactive workflows (forked context)
│   ├── errorlog-analysis/
│   │   ├── SKILL.md                         # ERRORLOG parsing, patterns, timeline (469 lines)
│   │   └── scripts/parse_errorlog.js        # Parser script (1418 lines)
│   │
│   ├── xevent-analysis/
│   │   ├── SKILL.md                         # XEvent parsing, wait analysis, merge (324 lines)
│   │   └── scripts/
│   │       ├── extract_xel.ps1              # XEL binary → JSON (PowerShell)
│   │       ├── parse_xevent.js              # XEvent JSON analyzer
│   │       └── gen_merged_report.js         # ERRORLOG+XEvent HTML merge
│   │
│   ├── docs-lookup/
│   │   └── SKILL.md                         # Microsoft Docs KB/wait research (176 lines)
│   │
│   └── dump-analysis/
│       └── SKILL.md                         # WinDbg Mirrors commands (347 lines)
│
├── agents/
│   └── source-search.agent.md               # Source code search — independent agent (322 lines)
│
├── scripts/                                 # Standalone scripts (flat, for CLI use)
│   ├── parse_errorlog.js
│   ├── extract_xel.ps1
│   ├── parse_xevent.js
│   └── gen_merged_report.js
│
└── reports/                                 # Generated reports (git-ignored)
```

## Skills vs Agents

| Component | Type | Context | User Interaction | When to Use |
|-----------|------|---------|-----------------|-------------|
| `errorlog-analysis` | Skill | Fork (isolated) | Yes — asks focus period, error selection | ERRORLOG parsing |
| `xevent-analysis` | Skill | Fork (isolated) | Yes — integrates with errorlog flow | XEL file analysis |
| `docs-lookup` | Skill | Fork (isolated) | No | KB/wait type research |
| `dump-analysis` | Skill | Fork (isolated) | Yes — may ask dump-related questions | WinDbg commands |
| `source-search` | Agent | Independent | No — runs via Task tool | Code search in Azure DevOps |

**Why Skills?** Each skill loads only its own context (~300-500 lines) instead of all 2000+ lines. The `context: fork` setting ensures skills run in isolated context without polluting the main conversation.

**Why Agent for source-search?** Source code search is heavy (fetches files from Azure DevOps, parses code), independent (no user interaction needed mid-search), and can run in parallel with other tasks.

## Workflows

| # | Trigger | Skill/Agent | What It Does |
|---|---------|------------|-------------|
| 1 | `analyze errorlog <path>` | `errorlog-analysis` | Parse ERRORLOG, extract errors, timeline, patterns |
| 2 | `analyze xevent <path>` | `xevent-analysis` | Parse system_health XEL files, wait analysis, merge with ERRORLOG |
| 3 | `research error <N>` | `docs-lookup` | Look up KB fixes, wait type causes via Microsoft Learn |
| 4 | `search error <N>` | `source-search` | Search SQL Server source code for error definition + raising code |
| 5 | `full analysis` | All (orchestrated) | Run 1→2→3→4 sequentially, generate comprehensive report |

## Key Features

### ERRORLOG Analysis (Skill)
- Auto-detect UTF-16LE / UTF-8 encoding
- Multi-line message parsing
- Error classification by subsystem (HADR, LOCKING, MEMORY, etc.)
- Pattern detection: cascades, repeating, paired errors, LSN progression
- Priority assignment: HIGH / MEDIUM / LOW
- AG role change timeline tracking

### XEvent Analysis (Skill)
- Binary XEL extraction via PowerShell `Read-SqlXEvent`
- 4 focused analysis areas:
  - `sp_server_diagnostics` — WARNING/ERROR states only
  - `scheduler_monitor` — CPU > 75% or Memory < 80%
  - `error_reported` — ERRORLOG complement
  - `wait_info` — all waits with category classification
- Cross-correlation with ERRORLOG findings

### Microsoft Docs Lookup (Skill)
- KB article search and CU applicability check
- Wait type root cause analysis from official CSS I/O guide
- Diagnostic DMV queries

### Source Code Search (Agent)
- Error definition lookup in `sqlerrorcodes.h`
- Find code that raises the error
- Function logic analysis
- XEvent diagnostics discovery
- HTML report with Azure DevOps links

## Prerequisites

- **Node.js** (v18+)
- **PowerShell** with `SqlServer` module (auto-installed on first XEL extraction)
- **Claude Code** as agent runtime
- **MCP Servers**: `microsoft-learn`, `msdata` (Azure DevOps), optional `mssql`

## Quick Start

```bash
# Install as Claude Code agent
cp -r sqlcsi/ ~/.claude/sql-csi/

# Analyze ERRORLOG
> @sql-csi analyze errorlog \\server\share\ERRORLOG

# Search error code
> @sql-csi search error 19432 in SQL2022

# Full investigation
> @sql-csi full analysis, errorlog is \\server\share\ERRORLOG, case ID SR12345
```

## Standalone Scripts

```bash
# ERRORLOG
node scripts/parse_errorlog.js ERRORLOG* --days 7 --json --output findings.json

# XEvent
powershell -File scripts/extract_xel.ps1 -Path "system_health*.xel" -Days 7 -Output extract.json
node scripts/parse_xevent.js extract.json --errorlog findings.json --json --output xe_findings.json

# Merged report
node scripts/gen_merged_report.js errorlog_report.html xe_findings.json merged.html
```

## License

Internal tool for Microsoft CSS. Not for public distribution.
