# =============================================================================
# run_windbgcs_direct.ps1 — SQL-CSI dump-overall / dump-analysis fallback
#
# Headless cdb.exe driver that BYPASSES `!dcs_initsymsvr` and instead directly
# registers a build-matched SqlCsScripts.dll from a pre-seeded folder like
#   C:\Tools\WinDbgCs\NetStandard20Refs\build_<version>\SqlCsScripts.dll
#
# WHEN TO USE:
#   Prefer run_windbgcs_tasks.ps1 first. Use THIS script when that one exits 1
#   because the log shows `SYMSRV: ... SqlCsScripts.SymSvrManifest.dll ...
#   HttpQueryInfo(HTTP_QUERY_CONTENT_LENGTH): 800C2F76 - ERROR_HTTP_HEADER_NOT_FOUND`
#   (i.e. the build's symsvr manifest was never published to symweb).
#
# WHAT IT DOES:
#   1. Resolves cdb.exe (Windows Kits or WinDbg Store, incl. .Slow/.Preview/.Fast)
#   2. Writes a UTF-8 no-BOM .cdb batch that:
#        .load <WinDbgCsExt.dll>
#        !execute <Scripts>            (register assembly — session-scoped)
#        .echo == MARKER_<expr> ==
#        !execute <expr>               (one per element of -Expr, with fences)
#        q
#   3. Runs `cdb -y <sym> -z <dump> -cf <batch> -logo <log> -G -lines`
#   4. Verifies at least one non-error section produced output.
#
# EXIT CODES: 0 = at least one !execute produced output (no "No results" marker
#                immediately after every fence);
#             1 = cdb not found / timeout / every !execute returned "No results".
#
# EXAMPLE (SQL 2019 15.0.4312.2, case 2606250030005483, verified 2026-07-04):
#   .\run_windbgcs_direct.ps1 `
#     -Dump    'C:\Temp\<case>\LOG\SQLDump0001.mdmp' `
#     -OutDir  'C:\Users\lduan\sqlcsi-archive\reports\<case>_dump_code_analysis' `
#     -CaseId  '<case>' `
#     -Scripts 'C:\Tools\WinDbgCs\NetStandard20Refs\build_15.0.4312.2\SqlCsScripts.dll' `
#     -Expr    @('Tasks.Enumerate',
#                'SOSRingBuffers.EnumerateExceptionRingRecords',
#                'SOSRingBuffers.EnumerateSchedulerMonitorRecords',
#                'SOSRingBuffers.EnumerateMemoryBrokerRingRecords')
# =============================================================================
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Dump,
  [Parameter(Mandatory)][string]$OutDir,           # e.g. reports/<case>_dump_code_analysis
  [Parameter(Mandatory)][string]$CaseId,
  [Parameter(Mandatory)][string]$Scripts,          # full path to build-matched SqlCsScripts.dll
  [Parameter(Mandatory)][string[]]$Expr,           # e.g. @('Tasks.Enumerate','SOSRingBuffers.EnumerateExceptionRingRecords')
  [string]$Wdbgcs   = 'C:\Tools\WinDbgCs',         # folder containing WinDbgCsExt.dll
  [string]$SymPath  = 'srv*C:\Symbols*https://symweb.azurefd.net',
  [string]$Cdb      = $null,
  [string]$Tag      = 'phase1_direct',             # output filename tag: <case>_<tag>.cdb/.txt
  [int]$TimeoutSec  = 900
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Dump))    { throw "dump not found: $Dump" }
if (-not (Test-Path $Wdbgcs))  { throw "wdbgcs folder not found: $Wdbgcs" }
$ext = Join-Path $Wdbgcs 'WinDbgCsExt.dll'
if (-not (Test-Path $ext))     { throw "WinDbgCsExt.dll missing under: $Wdbgcs" }
if (-not (Test-Path $Scripts)) { throw "build-matched SqlCsScripts.dll not found: $Scripts" }
if (-not $Expr -or $Expr.Count -eq 0) { throw "no expressions provided (-Expr)" }
if (-not (Test-Path $OutDir))  { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# ---- resolve cdb.exe (same logic as run_windbgcs_tasks.ps1) ------------------
if (-not $Cdb) {
    $cand = @(
        (Get-Command cdb.exe -ErrorAction SilentlyContinue).Source,
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe",
        "${env:ProgramFiles}\Windows Kits\10\Debuggers\x64\cdb.exe"
    )
    $wdbg = (Get-AppxPackage *WinDbg* -ErrorAction SilentlyContinue | Select-Object -First 1).InstallLocation
    if ($wdbg) { $cand += (Join-Path $wdbg 'amd64\cdb.exe') }
    try {
        $glob = Get-ChildItem "${env:ProgramFiles}\WindowsApps\Microsoft.WinDbg*_x64_*\amd64\cdb.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($glob) { $cand += $glob.FullName }
    } catch {}
    # NOTE: force array with @(...) or PS unwraps single-element result into a
    # string and [0] returns the first character (e.g. 'C').
    $Cdb = @($cand | Where-Object { $_ -and (Test-Path $_) })[0]
}
if (-not $Cdb -or -not (Test-Path $Cdb)) {
    Write-Host "[run_windbgcs_direct] ERROR: cdb.exe not found — install Windows Kits Debuggers or WinDbg Store package (any of Microsoft.WinDbg / .Fast / .Slow / .Preview)" -ForegroundColor Red
    exit 1
}
Write-Host "[run_windbgcs_direct] cdb.exe   : $Cdb"      -ForegroundColor Green
Write-Host "[run_windbgcs_direct] WinDbgCs  : $Wdbgcs"   -ForegroundColor Green
Write-Host "[run_windbgcs_direct] Scripts   : $Scripts"  -ForegroundColor Green
Write-Host "[run_windbgcs_direct] dump      : $Dump"     -ForegroundColor Green
Write-Host "[run_windbgcs_direct] Expr ($($Expr.Count)) : $($Expr -join ', ')" -ForegroundColor Green

# ---- paths -------------------------------------------------------------------
$cdbBatch  = Join-Path $OutDir "$($CaseId)_$($Tag).cdb"
$cdbLog    = Join-Path $OutDir "$($CaseId)_$($Tag).txt"

# ---- write cdb batch (UTF-8 no-BOM) -----------------------------------------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("* ============================================================================")
[void]$sb.AppendLine("* SQL-CSI dump direct-load sweep · Case: $CaseId · Tag: $Tag")
[void]$sb.AppendLine("* Generated by run_windbgcs_direct.ps1 — DO NOT edit by hand.")
[void]$sb.AppendLine("* Bypasses !dcs_initsymsvr; direct-loads a build-matched SqlCsScripts.dll.")
[void]$sb.AppendLine("* ============================================================================")
[void]$sb.AppendLine(".symopt+ 0x40")
[void]$sb.AppendLine(".reload /f")
[void]$sb.AppendLine("vertarget")
[void]$sb.AppendLine("lmvm sqlservr")
[void]$sb.AppendLine(".load $ext")
[void]$sb.AppendLine("!execute $Scripts")
foreach ($e in $Expr) {
    # Sanitize marker (only [A-Za-z0-9_.]).
    $safe = ($e -replace '[^A-Za-z0-9_.]','_')
    [void]$sb.AppendLine(".echo == MARKER_$safe ==")
    [void]$sb.AppendLine("!execute $e")
}
[void]$sb.AppendLine(".echo == MARKER_DONE ==")
[void]$sb.AppendLine("q")

$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($cdbBatch, $sb.ToString(), $enc)
Write-Host "[run_windbgcs_direct] batch written: $cdbBatch"

# ---- run cdb -----------------------------------------------------------------
Write-Host "[run_windbgcs_direct] running cdb (timeout ${TimeoutSec}s)..."
$cdbArgs = @('-y', $SymPath, '-z', $Dump, '-cf', $cdbBatch, '-logo', $cdbLog, '-G', '-lines')
$p = Start-Process -FilePath $Cdb -ArgumentList $cdbArgs -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    try { $p.Kill() } catch {}
    Write-Host "[run_windbgcs_direct] ERROR: cdb timed out after $TimeoutSec s" -ForegroundColor Red
    exit 1
}

# ---- verify outputs ----------------------------------------------------------
if (-not (Test-Path $cdbLog)) {
    Write-Host "[run_windbgcs_direct] ERROR: log not written: $cdbLog" -ForegroundColor Red
    exit 1
}
$sz     = (Get-Item $cdbLog).Length
$hasDone = (Select-String -Path $cdbLog -Pattern '== MARKER_DONE ==' -SimpleMatch -Quiet)

# Per-expression pass/fail: pass = fence present AND no "No results" in the
# following ~10 lines (until next fence).
$lines = Get-Content $cdbLog
$results = @()
foreach ($e in $Expr) {
    $safe = ($e -replace '[^A-Za-z0-9_.]','_')
    $idx  = ($lines | Select-String -Pattern "== MARKER_$safe ==" -SimpleMatch | Where-Object { $_.Line -notmatch '\.echo' } | Select-Object -First 1).LineNumber
    $ok   = $false
    if ($idx) {
        $tail = $lines[($idx-1)..([Math]::Min($lines.Count-1, $idx+15))]
        $ok = -not ($tail -match 'No results to process')
    }
    $results += [pscustomobject]@{ Expr = $e; Fence = [bool]$idx; Data = $ok }
}
$okCount = ($results | Where-Object { $_.Data }).Count

Write-Host "[run_windbgcs_direct] log = $sz bytes ; MARKER_DONE = $hasDone ; passing exprs = $okCount / $($Expr.Count)" `
    -ForegroundColor ($(if ($okCount -gt 0) { 'Green' } else { 'Red' }))
$results | Format-Table -AutoSize | Out-String | Write-Host

if ($okCount -gt 0) { exit 0 }
Write-Host "[run_windbgcs_direct] NOTE: All expressions returned 'No results to process'." -ForegroundColor Yellow
Write-Host "  · Check the class name via bare '!execute' (no arg) — it prints the A-Z catalog." -ForegroundColor Yellow
Write-Host "  · Verify the build matches: `lmDvm sqlservr` vs the path in -Scripts." -ForegroundColor Yellow
exit 1
