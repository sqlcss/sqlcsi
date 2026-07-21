# =============================================================================
# finalize_ringbuf_reports.ps1 — SQL-CSI dump-overall ring-buffer finalizer
#
# One committed entry point for the ring-buffer report contract:
#   1. Detect direct mirror combined logs (`*_direct*.txt`, `*_phase1_direct.txt`).
#   2. Split their `== MARKER_<expr> ==` sections into txt_detail\{case}_{expr}.txt.
#   3. Run build_ringbuf_reports.ps1 to generate categorized subreports and inject
#      top-N + anomaly sections into the MAIN overall report.
#   4. Optionally run verify_case_deliverables.ps1 as the hard gate.
#
# Use this instead of manually linking direct_mirror.html/raw txt. Raw logs remain
# evidence only; the user-facing result is the parsed/classified report section.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Dir,
    [Parameter(Mandatory)][string]$CaseId,
    [string]$TxtDir = '',
    [string[]]$DirectLogs = @(),
    [int]$TopN = 20,
    [int]$PageSize = 100,
    [switch]$SkipVerify,
    [switch]$RequireThreadCategories,
    [switch]$RequireSqlExec,
    [switch]$RequireSchedulerInventory
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { throw "Dir not found: $Dir" }
if (-not $TxtDir) { $TxtDir = Join-Path $Dir 'txt_detail' }
if (-not (Test-Path -LiteralPath $TxtDir -PathType Container)) { New-Item -ItemType Directory -Path $TxtDir -Force | Out-Null }

$splitter = Join-Path $PSScriptRoot 'split_direct_mirror_log.ps1'
$builder  = Join-Path $PSScriptRoot 'build_ringbuf_reports.ps1'
$verifier = Join-Path $PSScriptRoot 'verify_case_deliverables.ps1'

foreach ($script in @($splitter,$builder,$verifier)) {
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "required helper missing: $script" }
}

if (-not $DirectLogs -or $DirectLogs.Count -eq 0) {
    $DirectLogs = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "${CaseId}_*direct*.txt" -or $_.Name -eq "${CaseId}_phase1_direct.txt" } |
        ForEach-Object { $_.FullName })
}

$ringDirectLogs = @()
foreach ($log in $DirectLogs) {
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw "direct log not found: $log" }
    if (Select-String -LiteralPath $log -Pattern '== MARKER_SOSRingBuffers.' -SimpleMatch -Quiet) {
        $ringDirectLogs += $log
    } else {
        Write-Host "[finalize_ringbuf_reports] skip non-ring direct log: $log" -ForegroundColor Yellow
    }
}

foreach ($log in $ringDirectLogs) {
    Write-Host "[finalize_ringbuf_reports] split direct mirror log: $log" -ForegroundColor Cyan
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $splitter `
        -Log $log `
        -OutDir $TxtDir `
        -CaseId $CaseId `
        -Overwrite
    if ($LASTEXITCODE -ne 0) { throw "split_direct_mirror_log.ps1 failed for $log" }
}

$ringTxt = @(Get-ChildItem -LiteralPath $TxtDir -File -Filter "${CaseId}_SOSRingBuffers.*.txt" -ErrorAction SilentlyContinue)
if ($ringDirectLogs.Count -gt 0 -and $ringTxt.Count -eq 0) {
    throw "direct mirror ring logs were found, but no split txt_detail ring-buffer files were created"
}

Write-Host "[finalize_ringbuf_reports] build categorized ring-buffer reports from $TxtDir" -ForegroundColor Cyan
& pwsh -NoProfile -ExecutionPolicy Bypass -File $builder `
    -Dir $Dir `
    -TxtDir $TxtDir `
    -CaseId $CaseId `
    -TopN $TopN `
    -PageSize $PageSize
if ($LASTEXITCODE -ne 0) { throw "build_ringbuf_reports.ps1 failed" }

if (-not $SkipVerify) {
    $verifyArgs = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$verifier,
        '-CaseId',$CaseId,
        '-OutDir',$Dir,
        '-Stage','Completion'
    )
    if ($RequireThreadCategories)    { $verifyArgs += '-RequireThreadCategories' }
    if ($RequireSqlExec)             { $verifyArgs += '-RequireSqlExec' }
    if ($RequireSchedulerInventory)  { $verifyArgs += '-RequireSchedulerInventory' }
    Write-Host "[finalize_ringbuf_reports] run completion verifier" -ForegroundColor Cyan
    & pwsh @verifyArgs
    if ($LASTEXITCODE -ne 0) { throw "verify_case_deliverables.ps1 failed" }
}

Write-Host "[finalize_ringbuf_reports] PASS: ring-buffer reports finalized for $CaseId" -ForegroundColor Green