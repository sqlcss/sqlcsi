# SQL-CSI: SQL Server Case Scene Investigation

AI-powered toolkit for CSS engineers to analyze SQL Server ERRORLOG files, XEvent traces (system_health), crash dumps, and engine source code. Built as a [Claude Code](https://claude.com/claude-code) agent with MCP integration.

## Architecture

```
sqlcsi/
  ├── sql-csi.agent.md              # Claude Code agent (orchestrator)
  ├── references/
  │   ├── errorlog-xevent-analysis.md   # Workflow 1: ERRORLOG + XEvent parsing
  │   ├── dump-analysis.md              # Workflow 2: Dump analysis (WinDbg/Mirrors)
  │   ├── source-code-search.md         # Workflow 3: Source code search (Azure DevOps)
  │   └── full-csi-orchestrator.md      # Workflow 4: Full CSI coordination
  ├── scripts/
  │   ├── parse_errorlog.js             # ERRORLOG parser (Node.js)
  │   ├── extract_xel.ps1              # XEL binary → JSON extractor (PowerShell)
  │   ├── parse_xevent.js              # XEvent JSON analyzer (Node.js)
  │   └── gen_merged_report.js         # Merged ERRORLOG+XEvent HTML report generator
  └── reports/                          # Generated analysis reports (git-ignored)
```

## Workflows

| # | Workflow | Trigger | What It Does |
|---|---------|---------|-------------|
| 1 | **ERRORLOG + XEvent** | `analyze errorlog <path>` | Parse ERRORLOG + system_health XEL files, extract errors, build timeline, detect patterns (cascades, repeating, paired errors), classify by subsystem, wait analysis |
| 2 | **Dump Analysis** | `analyze dump <path>` | Generate WinDbg Mirrors commands for dump investigation, map errors to subsystem-specific ring buffers |
| 3 | **Source Code Search** | `search error <number>` | Look up error definition in `sqlerrorcodes.h`, find raising code, analyze function logic, extract XEvent diagnostics |
| 4 | **Full CSI** | `full analysis` | Orchestrate Workflows 1→2→3, cross-reference findings, generate comprehensive HTML report |

## Key Features

### ERRORLOG Analysis
- Auto-detect UTF-16LE / UTF-8 encoding
- Multi-line message parsing (continuation lines)
- Error classification by subsystem (HADR, LOCKING, MEMORY, etc.)
- Pattern detection: error cascades, repeating errors, paired errors, LSN progression
- Priority assignment: HIGH / MEDIUM / LOW based on severity and frequency
- Interactive focus period selection (1/3/7 days)
- AG role change timeline tracking

### XEvent Analysis (system_health)
- Binary XEL file extraction via PowerShell `Read-SqlXEvent`
- Focused analysis on 4 key areas:
  - **sp_server_diagnostics**: WARNING/ERROR states only, XML data parsing
  - **scheduler_monitor**: CPU > 75% or Memory < 80% alerts
  - **error_reported**: ERRORLOG complement (captures errors not logged to ERRORLOG)
  - **wait_info**: All wait events with type classification (IO/LOCKING/HADR/CPU/etc.)
- Cross-correlation with ERRORLOG findings

### Microsoft Docs Integration
- Automatic KB article lookup for top errors via Microsoft Learn MCP
- Known fix applicability check (FIX_NOT_APPLIED / FIX_ALREADY_APPLIED / NO_KB_FOUND)
- Wait type analysis against official CSS I/O troubleshooting guide
- Diagnostic DMV queries from official code samples

### Merged HTML Reports
- Dark-themed (Catppuccin Mocha) reports with:
  - Part A: Full ERRORLOG analysis (server profile, AG config, errors, patterns, timeline)
  - Part B: XEvent analysis (waits, diagnostics, scheduler, cross-correlation)
  - Part C: Microsoft Docs research (KB fixes, wait type root causes)
  - Part D: Root cause chain + prioritized recommendations

## Prerequisites

- **Node.js** (v18+) — for ERRORLOG and XEvent analysis scripts
- **PowerShell** with `SqlServer` module — for XEL file extraction (`auto-installed on first run`)
- **Claude Code** — as the agent runtime
- **MCP Servers**:
  - `microsoft-learn` — Microsoft Learn docs search (KB articles, wait type reference)
  - `msdata` — Azure DevOps code search (SQL Server source, Workflow 3)
  - `mssql` — optional, for running diagnostic queries

## Quick Start

### 1. Install as Claude Code Agent

Copy the `sql-csi/` directory to `~/.claude/sql-csi/`:

```bash
cp -r sqlcsi/ ~/.claude/sql-csi/
```

### 2. Analyze an ERRORLOG

```
> @sql-csi analyze errorlog \\server\share\ERRORLOG
```

The agent will:
1. Ask you for a focus period (1/3/7 days)
2. Parse all ERRORLOG files in the directory
3. Auto-detect and parse `system_health*.xel` files
4. Generate a merged HTML report
5. Research top errors via Microsoft Learn
6. Present prioritized findings and recommendations

### 3. Search an Error Code

```
> @sql-csi search error 19432 in SQL2022
```

### 4. Full Investigation

```
> @sql-csi full analysis, errorlog is \\server\share\ERRORLOG, case ID SR12345
```

## Scripts Usage (Standalone)

### parse_errorlog.js

```bash
# Parse with 7-day focus, generate JSON + HTML
node scripts/parse_errorlog.js ERRORLOG ERRORLOG.1 ERRORLOG.2 \
  --days 7 --json --output findings.json --html report.html --open
```

### extract_xel.ps1 + parse_xevent.js

```bash
# Step 1: Extract XEL binary → JSON
powershell -File scripts/extract_xel.ps1 \
  -Path "system_health*.xel" -Days 7 -Output xevent_extract.json

# Step 2: Analyze with ERRORLOG cross-correlation
node scripts/parse_xevent.js xevent_extract.json \
  --errorlog findings.json --json --output xevent_findings.json
```

### gen_merged_report.js

```bash
# Merge ERRORLOG HTML + XEvent findings → combined report
node scripts/gen_merged_report.js \
  errorlog_report.html xevent_findings.json merged_report.html
```

## File Sizes

| File | Lines | Description |
|------|-------|-------------|
| `sql-csi.agent.md` | 160 | Agent orchestrator |
| `errorlog-xevent-analysis.md` | 941 | Workflow 1 reference (largest) |
| `dump-analysis.md` | 337 | Workflow 2 reference |
| `source-code-search.md` | 312 | Workflow 3 reference |
| `full-csi-orchestrator.md` | 343 | Workflow 4 reference |
| `parse_errorlog.js` | 1418 | ERRORLOG parser |
| `parse_xevent.js` | 811 | XEvent analyzer |
| `extract_xel.ps1` | 182 | XEL extractor |
| `gen_merged_report.js` | 170 | Report merger |
| **Total** | **4674** | |

## License

Internal tool for Microsoft CSS. Not for public distribution.
