# run_post_overall_branch_hints.ps1
# Canonical Gate B orchestrator. Requires a hash-bound Gate A receipt, never writes
# the overall report/manifest/ledger, and records failures only in Gate B artifacts.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$OutDir,
    [Parameter(Mandatory)][string]$Dump,
    [string]$Wdbgcs = 'C:\Tools\WinDbgCs',
    [string]$SymPath = 'srv*C:\Symbols*https://symweb.azurefd.net',
    [string]$Cdb,
    [int]$TimeoutSec = 1800,
    [switch]$ReuseProbeStatus
)

$ErrorActionPreference = 'Stop'
$gateAReceipt = Join-Path $OutDir 'overall_completion_receipt.json'
$probeStatus = Join-Path $OutDir "${CaseId}_first_pass_probe_status.json"
$branchHtml = Join-Path $OutDir "${CaseId}_first_pass_branch_hints.html"
$branchJson = Join-Path $OutDir "${CaseId}_first_pass_branch_hints.json"
$gateBReceipt = Join-Path $OutDir 'first_pass_branch_completion_receipt.json'
$gateBTemp = "$gateBReceipt.tmp"
$failureLog = Join-Path $OutDir 'first_pass_branch_failure.txt'
$probeRunner = Join-Path $PSScriptRoot 'run_first_pass_probes.ps1'
$reportGenerator = Join-Path $PSScriptRoot 'gen_first_pass_branch_hints_report.ps1'
$branchVerifier = Join-Path $PSScriptRoot 'verify_first_pass_branch_hints.ps1'

foreach ($path in @($gateAReceipt,$probeRunner,$reportGenerator,$branchVerifier,$Dump)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Gate B prerequisite missing: $path" }
}
$receipt = Get-Content -LiteralPath $gateAReceipt -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$receipt.status -ne 'PASS') { throw 'Gate A receipt is not PASS' }
$overall = Join-Path $OutDir ([string]$receipt.overallReport)
if (-not (Test-Path -LiteralPath $overall -PathType Leaf)) { throw "Gate A overall report missing: $overall" }
$overallHashBefore = (Get-FileHash -LiteralPath $overall -Algorithm SHA256).Hash
if ($receipt.PSObject.Properties.Name -contains 'overallSha256' -and $overallHashBefore -ne [string]$receipt.overallSha256) {
    throw 'Gate A overall report hash does not match its completion receipt'
}

if (Test-Path -LiteralPath $gateBTemp) { Remove-Item -LiteralPath $gateBTemp -Force }
if (Test-Path -LiteralPath $gateBReceipt) { Remove-Item -LiteralPath $gateBReceipt -Force }
if (Test-Path -LiteralPath $failureLog) { Remove-Item -LiteralPath $failureLog -Force }

function Invoke-Checked([string]$label,[scriptblock]$command) {
    $global:LASTEXITCODE = 0
    & $command
    if (-not $? -or $LASTEXITCODE -ne 0) { throw "$label failed with exit $LASTEXITCODE" }
}

try {
    if (-not $ReuseProbeStatus -or -not (Test-Path -LiteralPath $probeStatus -PathType Leaf)) {
        Invoke-Checked 'first-pass probe capture' {
            $args = @{
                Dump = $Dump
                OutDir = $OutDir
                CaseId = $CaseId
                Wdbgcs = $Wdbgcs
                SymPath = $SymPath
                OverallReceipt = $gateAReceipt
                TimeoutSec = $TimeoutSec
            }
            if ($Cdb) { $args.Cdb = $Cdb }
            & $probeRunner @args
        }
    } else {
        Write-Host "[run_post_overall_branch_hints] reusing $probeStatus" -ForegroundColor Yellow
    }

    Invoke-Checked 'branch-hints report generation' {
        & $reportGenerator -CaseId $CaseId -OutDir $OutDir -ProbeStatus $probeStatus -OverallReceipt $gateAReceipt -Out $branchHtml -JsonOut $branchJson
    }
    Invoke-Checked 'Gate B verification' {
        & $branchVerifier -CaseId $CaseId -OutDir $OutDir
    }

    $overallHashAfter = (Get-FileHash -LiteralPath $overall -Algorithm SHA256).Hash
    if ($overallHashAfter -ne $overallHashBefore) { throw 'Gate B modified the Gate A overall report' }
    $statusDoc = Get-Content -LiteralPath $probeStatus -Raw -Encoding UTF8 | ConvertFrom-Json
    $branchDoc = Get-Content -LiteralPath $branchJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $gateB = [ordered]@{
        caseId = $CaseId
        gate = 'Gate B — post-overall first-pass branch hints'
        status = 'PASS'
        completedAt = (Get-Date).ToString('o')
        overallGateStatus = 'PASS'
        overallReport = [System.IO.Path]::GetFileName($overall)
        overallSha256Before = $overallHashBefore
        overallSha256After = $overallHashAfter
        overallUnchanged = $true
        captureStatus = [string]$statusDoc.captureStatus
        probeCount = @($statusDoc.probes).Count
        bucketCount = @($branchDoc.buckets).Count
        branchReport = [System.IO.Path]::GetFileName($branchHtml)
        branchReportSha256 = (Get-FileHash -LiteralPath $branchHtml -Algorithm SHA256).Hash
        branchJson = [System.IO.Path]::GetFileName($branchJson)
        branchJsonSha256 = (Get-FileHash -LiteralPath $branchJson -Algorithm SHA256).Hash
        isolationContract = 'Gate B verification is independent. Any Gate B failure is retained separately and cannot alter Gate A status or artifacts.'
    }
    [System.IO.File]::WriteAllText($gateBTemp, ($gateB | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $gateBTemp -Destination $gateBReceipt -Force
    Write-Host "[run_post_overall_branch_hints] PASS (Gate B): $CaseId" -ForegroundColor Green
    Write-Host "  branch report: $branchHtml"
    Write-Host "  Gate A hash unchanged: $overallHashAfter"
    exit 0
} catch {
    if (Test-Path -LiteralPath $gateBTemp) { Remove-Item -LiteralPath $gateBTemp -Force }
    $overallHashAfter = if (Test-Path -LiteralPath $overall -PathType Leaf) { (Get-FileHash -LiteralPath $overall -Algorithm SHA256).Hash } else { 'missing' }
    $failure = @(
        "Gate B failure: $_",
        "Timestamp: $((Get-Date).ToString('o'))",
        'Gate A receipt retained: true',
        "Gate A overall hash before: $overallHashBefore",
        "Gate A overall hash after:  $overallHashAfter",
        "Gate A overall unchanged: $($overallHashBefore -eq $overallHashAfter)"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($failureLog, $failure, [System.Text.UTF8Encoding]::new($false))
    Write-Host '[run_post_overall_branch_hints] FAIL (Gate B only)' -ForegroundColor Red
    Write-Host "  Gate A remains independently recorded in $gateAReceipt" -ForegroundColor Yellow
    Write-Host "  Failure evidence: $failureLog" -ForegroundColor Yellow
    exit 2
}
