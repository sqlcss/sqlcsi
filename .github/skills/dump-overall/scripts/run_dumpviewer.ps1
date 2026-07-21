# =============================================================================
# run_dumpviewer.ps1 — SQL-CSI dump-overall 第零步 (PRIMARY data source)
#
# Runs DumpViewer.exe against the dump to produce the full static-HTML report
# bundle under <OutDir>\dumpviewer_out\ (main.html + Reports\*.html + *_json.js
# data sidecars + logs). DumpViewer self-hosts CsDebugScript/dbgeng, so its
# `!dcs_initsymsvr`-style engine works on SQL 2019 (later CUs) / 2022 / 2025.
#
# This is the PRIMARY overall data source: 第一步 (threads) ← ThreadDetails /
# UniqueStacks, 第二步 (tasks) ← Tasks / ActiveTasks, 第四步 (ring buffers) ←
# SchedRingRecords / MonitorRingRecords / OOMRingRecords / MemBrokerRingRecords.
# The DScript-only 第三步 (per-thread T-SQL decode via tsqlstack.js) is NOT
# produced by DumpViewer and must still be run as a supplement.
#
# Output (under -OutDir):
#   dumpviewer_out\main.html
#   dumpviewer_out\Reports\*.html + *_json.js
#   dumpviewer_out\DumpViewer_*.log
#
# EXIT CODES:
#   0 = SUCCESS  — DumpViewer produced a usable Reports\ set (PRIMARY mode).
#   2 = FALLBACK — DumpViewer failed OR Reports\ is empty/missing the key HTML
#                  (early SQL 2019 CU / older build DumpViewer can't adapt).
#                  Caller must fall back to the full DScript/mirror pipeline.
#   1 = HARD ERROR — DumpViewer.exe or the dump not found (fix inputs first).
# =============================================================================
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Dump,
  [Parameter(Mandatory)][string]$OutDir,                       # e.g. reports/<case>_dump_overall
  [string]$DumpViewer = 'C:\Users\lduan\tools\DumpViewer',     # folder holding DumpViewer.exe (ASK user; this is default)
  [string]$SymPath    = 'srv*C:\Symbols*https://symweb.azurefd.net',
  [int]$TimeoutSec    = 900
)

$ErrorActionPreference = 'Stop'

# ---- validate inputs ---------------------------------------------------------
if (-not (Test-Path $Dump)) {
    Write-Host "[run_dumpviewer] ERROR: dump not found: $Dump" -ForegroundColor Red
    exit 1
}
$exe = Join-Path $DumpViewer 'DumpViewer.exe'
if (-not (Test-Path $exe)) {
    Write-Host "[run_dumpviewer] ERROR: DumpViewer.exe not found under: $DumpViewer — ASK USER for the folder" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$dvOut     = Join-Path $OutDir 'dumpviewer_out'
$reportDir = Join-Path $dvOut 'Reports'

Write-Host "[run_dumpviewer] DumpViewer.exe : $exe"
Write-Host "[run_dumpviewer] dump          : $Dump"
Write-Host "[run_dumpviewer] output        : $dvOut"

# ---- run DumpViewer ----------------------------------------------------------
# command line (from validated runs): DumpViewer.exe -s <sym> -f <dump> -o <out>
$args = @('-s', $SymPath, '-f', $Dump, '-o', $dvOut)
Write-Host "[run_dumpviewer] running (timeout ${TimeoutSec}s)..."
$p = Start-Process -FilePath $exe -ArgumentList $args -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    try { $p.Kill() } catch {}
    Write-Host "[run_dumpviewer] DumpViewer timed out after $TimeoutSec s — FALLBACK to DScript/mirror pipeline" -ForegroundColor Yellow
    exit 2
}
$code = $p.ExitCode

# ---- verify the key report pages exist (mode gate) ---------------------------
# These four back 第一步 / 第二步; their absence means DumpViewer could not adapt
# to this build (early 2019 CU / older) → caller must use the full DScript path.
$key = @('ThreadDetails.html', 'UniqueStacks.html', 'Tasks.html', 'Threads.html')
$present = @($key | Where-Object { Test-Path -LiteralPath (Join-Path $reportDir $_) })
$missing = @($key | Where-Object { -not (Test-Path -LiteralPath (Join-Path $reportDir $_)) })

$reportCount = 0
if (Test-Path -LiteralPath $reportDir) {
    $reportCount = @(Get-ChildItem -LiteralPath $reportDir -Filter *.html -ErrorAction SilentlyContinue).Count
}

Write-Host ("[run_dumpviewer] exit={0}  Reports\*.html={1}  key present={2}/{3}" -f `
    $code, $reportCount, $present.Count, $key.Count)

if ($present.Count -eq $key.Count) {
    Write-Host "[run_dumpviewer] SUCCESS - PRIMARY mode: build the report from dumpviewer_out\Reports data" -ForegroundColor Green
    exit 0
}
else {
    Write-Host ("[run_dumpviewer] FALLBACK - missing key pages: {0}" -f ($missing -join ', ')) -ForegroundColor Yellow
    Write-Host "[run_dumpviewer] DumpViewer could not adapt to this build - use the full DScript/mirror pipeline" -ForegroundColor Yellow
    exit 2
}
