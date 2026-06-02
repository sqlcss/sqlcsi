WPR Trace Analysis Skills — Setup Guide
========================================

These skills (wpr-cpu-analysis, wpr-allocation-analysis, wpr-cpu-comparison)
require the WPA MCP server to query ETL trace data. Follow these steps to set up.

1. Install WPA (Windows Performance Analyzer)
----------------------------------------------
Download WPA version 11.9.89 (Alpha) or later from:

    https://wpaportal.azurewebsites.net/releases?channel=alpha&channel=bromine

Version 11.9.89 (Alpha) — published Mar 10, 2026 — is the first version with
built-in MCP server support.

Key features in this release:
  - Built-in MCP server for querying table data
  - Processor Counters table
  - Symbol settings: load symbols from specific images only
  - Critical path analysis without waiting for all symbols
  - Improved symbol decoding performance

Install using the .msixbundle installer. After installation, wpa.exe and
wpa-mcp.exe will be available under:

    %LOCALAPPDATA%\Microsoft\WindowsApps\Microsoft.WindowsPerformanceAnalyzerInternal_<hash>\

2. Configure WPA MCP Server in VS Code
----------------------------------------
Add the following entry to .vscode/mcp.json under "servers":

    "wpa": {
      "type": "stdio",
      "command": "<path-to>\\wpa-mcp.exe",
      "args": ["1"]
    }

Replace <path-to> with the actual install path, e.g.:

    C:\\Users\\<user>\\AppData\\Local\\Microsoft\\WindowsApps\\Microsoft.WindowsPerformanceAnalyzerInternal_<hash>\\wpa-mcp.exe

The "1" argument is the WPA instance index (1-based).

3. Before Using a Skill
-------------------------
Before invoking any WPR skill, you must:

  a) Open the ETL trace in WPA
     - Launch wpa.exe
     - File → Open → select the .etl file
     - Wait for the trace to finish processing

  b) Load symbols
     - In WPA, filter to the target process (e.g. sqlservr.exe) first
       to avoid downloading PDBs for hundreds of unrelated processes
     - Trace → Load Symbols (or Ctrl+Shift+S)
     - Wait for symbol resolution to complete

  c) Start the WPA MCP server
     - The MCP server (wpa-mcp.exe) connects to ONE running WPA instance
     - If you have multiple WPA windows open, use the args index to
       select which one (e.g. "1" for the first, "2" for the second)
     - The MCP server must be running before the skill can query data

4. Skill-Specific Notes
------------------------
wpr-cpu-analysis:
  - Uses "CPU Usage (Sampled)" table — requires CPU sampling providers
  - Symbols must be loaded for Function/Stack resolution

wpr-allocation-analysis:
  - Uses diag-perf MCP server (separate from WPA MCP)
  - Requires GC AllocationTick events in the trace
  - CPU-only traces will have no allocation data

wpr-cpu-comparison:
  - Compares two ETL traces (baseline vs problem)
  - Uses diag-perf MCP cpu_compare_traces tool

5. Troubleshooting
-------------------
- "No traces loaded": WPA is not open or ETL not loaded — open the trace first
- Functions show as "?": Symbols not loaded — load symbols in WPA
- MCP connection fails: Ensure wpa-mcp.exe is running and the instance
  index matches the WPA window you want to query
- Allocation data empty: Trace was collected without GC providers
