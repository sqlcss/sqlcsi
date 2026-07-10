# =============================================================================
# parse_scheduler_monitor.ps1 — SQL-CSI dump-overall
#
# Extract a single mirror-command result block from a SqlScriptRepl / WinDbg
# `!execute` log and turn it into structured JSON that
# `gen_scheduler_monitor_html.ps1` (or any other manifest-driven generator)
# can consume.
#
# The parser is intentionally generic — it works for ANY Class.Method whose
# output uses the SqlScriptRepl pipe-table format:
#
#     mirror> <Expression>
#     Col1 | Col2 | Col3
#     ---------------------------------
#     v1   | v2   | v3
#     ...
#     [REPL] N row(s).
#
# It ALSO tolerates the "wrapper unwrap" preamble that the enhanced
# SqlScriptRepl.exe emits for `SOSRingBufferOutput<T>` (Class.Method returns
# a wrapper with a single .Records enumerable):
#
#     [REPL] Wrapper: SOSRingBufferOutput`1
#       RecordType = RING_BUFFER_SCHEDULER_MONITOR
#
#     Event | NodeId | SchedulerId | ...           <- table follows
#     ...
#
# The scalar wrapper lines are captured as `wrapper` in the JSON.
#
# Parameters:
#   -Src         path to a SqlScriptRepl stdout log OR any text file that
#                contains the raw expression output (WinDbg `!execute` capture
#                works too — provide the block).
#   -Expression  Class.Method (e.g. `SOSRingBuffers.EnumerateSchedulerMonitorRecords`)
#                — used to locate the `mirror> <expression>` echo line. If
#                omitted, the parser takes the FIRST pipe-table block in Src.
#   -OutJson     output path for the JSON manifest.
#
# Output JSON schema (UTF-8, no BOM):
#   {
#     "src"        : "<absolute Src path>",
#     "expression" : "<Class.Method or ''>",
#     "wrapper"    : { "<scalar-name>": "<value>", ... },   // may be empty
#     "cols"       : ["Col1", "Col2", ...],
#     "rows"       : [ { "Col1": "v1", "Col2": "v2", ... }, ... ],
#     "rowCount"   : <int>
#   }
#
# Exit codes: 0 success; 1 Src missing / no header found.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Src,
    [string]$Expression,
    [Parameter(Mandatory)][string]$OutJson
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Src)) {
    Write-Host "[parse_scheduler_monitor] ERROR: Src not found: $Src" -ForegroundColor Red
    exit 1
}

$lines = Get-Content -LiteralPath $Src -Encoding UTF8

# ---- locate the mirror prompt for the requested expression --------------
$startIdx = 0
if ($Expression) {
    # Primary: clean prompt "mirror> <Expression>" (SqlScriptRepl echo).
    $pat = '^mirror>\s+' + [Regex]::Escape($Expression) + '\b'
    $hitIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pat) { $hitIdx = $i; break }
    }
    # Fallback: "[INFO] Found SqlCsScripts.Scripts.<Class>.<Method>, Invoking"
    # (real log where the mirror> prompt got interleaved with DumpViewer INFO output).
    if ($hitIdx -lt 0) {
        $pat2 = 'Found\s+\S*\.?' + [Regex]::Escape($Expression) + ',\s*Invoking'
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pat2) { $hitIdx = $i; break }
        }
    }
    if ($hitIdx -ge 0) { $startIdx = [int]$hitIdx + 1 }
}

# ---- capture optional wrapper preamble  ("[REPL] Wrapper: ..." + "  k = v") ----
$wrapper = [ordered]@{}
$i = $startIdx
while ($i -lt $lines.Count) {
    $ln = $lines[$i]
    if ($ln -match '^\s*\[REPL\]\s+Wrapper:\s+') { $i++; continue }
    if ($ln -match '^\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
        $wrapper[$Matches[1]] = $Matches[2].Trim()
        $i++; continue
    }
    if ($ln.Trim() -eq '') { $i++; continue }
    break
}

# ---- find the header row (first line with " | " that is not a separator) ----
# NOTE: don't break on `mirror>` here — SqlScriptRepl's prompt often shares a
# line with DumpViewer's [INFO] log spillover BEFORE the header. Only [REPL]
# markers reliably terminate a data block.
$headerIdx = -1
for ($j = $i; $j -lt $lines.Count; $j++) {
    $ln = $lines[$j]
    if ($ln -match '^\s*\[REPL\]') { break }
    if ($ln -match '^\s*-{5,}\s*$') { continue }
    if ($ln -match '\S\s\|\s\S') { $headerIdx = $j; break }
}

if ($headerIdx -lt 0) {
    Write-Host "[parse_scheduler_monitor] ERROR: no pipe-delimited header found after '$Expression'" -ForegroundColor Red
    exit 1
}

$cols = @(($lines[$headerIdx] -split '\s*\|\s*') | ForEach-Object { $_.Trim() })

# ---- read data rows until [REPL] N row(s) OR next mirror> ----
$rows = New-Object System.Collections.ArrayList
for ($k = $headerIdx + 1; $k -lt $lines.Count; $k++) {
    $ln = $lines[$k]
    if ($ln -match '^\s*-{5,}\s*$') { continue }
    if ($ln -match '^\s*\[REPL\]') { break }
    if ($ln -match '^\s*mirror>') { break }
    if ($ln.Trim() -eq '') { continue }
    $cells = @(($ln -split '\s*\|\s*') | ForEach-Object { $_.Trim() })
    # Pad or truncate to column count so JSON stays rectangular.
    if ($cells.Count -lt $cols.Count) {
        $pad = @('') * ($cols.Count - $cells.Count)
        $cells = $cells + $pad
    } elseif ($cells.Count -gt $cols.Count) {
        # Overflow — join extras into the last column to preserve information.
        $tail = ($cells[($cols.Count - 1)..($cells.Count - 1)] -join ' | ')
        $cells = $cells[0..($cols.Count - 2)] + $tail
    }
    $obj = [ordered]@{}
    for ($c = 0; $c -lt $cols.Count; $c++) { $obj[$cols[$c]] = $cells[$c] }
    [void]$rows.Add($obj)
}

$result = [ordered]@{
    src        = (Resolve-Path -LiteralPath $Src).Path
    expression = ($Expression ?? '')
    wrapper    = $wrapper
    cols       = $cols
    rows       = @($rows)
    rowCount   = $rows.Count
}

$outDir = Split-Path -Parent $OutJson
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$json = $result | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText(
    $OutJson, $json, (New-Object System.Text.UTF8Encoding($false))
)

Write-Host ("[parse_scheduler_monitor] cols={0}  rows={1}  wrapper={2}  ->  {3}" -f `
    $cols.Count, $rows.Count, $wrapper.Count, $OutJson)
exit 0
