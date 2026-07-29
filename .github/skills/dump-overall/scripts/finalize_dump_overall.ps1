# finalize_dump_overall.ps1
# Canonical Gate A finalizer: build MAIN + nine ring subreports, verify Completion,
# then atomically publish a hash-bound completion receipt. No post-overall probes run here.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Manifest = '',
    [string]$Ledger = '',
    [string]$TxtDir = '',
    [int]$TopN = 20,
    [int]$PageSize = 100,
    [switch]$RequireThreadCategories,
    [switch]$RequireSqlExec,
    [switch]$RequireSchedulerInventory,
    [switch]$RequireLatchContendedPages
)

$ErrorActionPreference = 'Stop'
if (-not $Manifest) { $Manifest = Join-Path $OutDir "${CaseId}_overall_manifest.json" }
if (-not $Ledger) { $Ledger = Join-Path $OutDir 'workflow_ledger.json' }
if (-not $TxtDir) { $TxtDir = Join-Path $OutDir 'txt_detail' }
$overall = Join-Path $OutDir "${CaseId}_overall_report.html"
$receiptPath = Join-Path $OutDir 'overall_completion_receipt.json'
$receiptTemp = "$receiptPath.tmp"
$generator = Join-Path $PSScriptRoot 'gen_overall_report.ps1'
$ringBuilder = Join-Path $PSScriptRoot 'build_ringbuf_reports.ps1'
$verifier = Join-Path $PSScriptRoot 'verify_case_deliverables.ps1'
$ledgerSetter = Join-Path $PSScriptRoot 'set_overall_workflow_status.ps1'

foreach ($path in @($Manifest,$Ledger,$TxtDir,$generator,$ringBuilder,$verifier,$ledgerSetter)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Gate A input missing: $path" }
}

# Never leave a stale receipt beside a report being regenerated.
if (Test-Path -LiteralPath $receiptTemp) { Remove-Item -LiteralPath $receiptTemp -Force }
if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath -Force }

function Invoke-Checked([string]$label,[scriptblock]$command) {
    $global:LASTEXITCODE = 0
    & $command
    if (-not $? -or $LASTEXITCODE -ne 0) { throw "$label failed with exit $LASTEXITCODE" }
}

function Test-LedgerItemArtifacts([string]$groupName,[string]$itemName) {
    $doc = Get-Content -LiteralPath $Ledger -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($doc.$groupName.PSObject.Properties.Name -contains $itemName)) { return $false }
    $item = $doc.$groupName.$itemName
    $paths = @()
    if ($item.PSObject.Properties.Name -contains 'path') { $paths += [string]$item.path }
    if ($item.PSObject.Properties.Name -contains 'artifacts') { $paths += @($item.artifacts | ForEach-Object { [string]$_ }) }
    if ($paths.Count -eq 0) { return $false }
    foreach ($path in $paths) {
        $resolved = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $OutDir $path }
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or (Get-Item -LiteralPath $resolved).Length -eq 0) { return $false }
    }
    return $true
}

function Close-LedgerItemIfReady([string]$groupName,[string]$itemName) {
    if (Test-LedgerItemArtifacts $groupName $itemName) {
        Invoke-Checked "ledger transition $groupName.$itemName" {
            & $ledgerSetter -Ledger $Ledger -Group $groupName -Name $itemName -Status done
        }
    }
}

try {
    # These final-stage inputs are mechanically verifiable and should not require
    # a hand-edited status transition.
    Close-LedgerItemIfReady 'requiredSteps' 'overall_manifest'
    Close-LedgerItemIfReady 'requiredSteps' 'nine_ring_surfaces'

    Invoke-Checked 'base overall generation' {
        & $generator -Manifest $Manifest -Out $overall -Ledger $Ledger
    }
    Invoke-Checked 'ring-buffer main/subreport generation' {
        & $ringBuilder -Dir $OutDir -TxtDir $TxtDir -CaseId $CaseId -TopN $TopN -PageSize $PageSize -Manifest $Manifest -Generator $generator
    }
    Invoke-Checked 'ledger-gated final overall generation' {
        & $generator -Manifest $Manifest -Out $overall -Ledger $Ledger
    }

    foreach ($deliverable in @('overall_html','thread_details','task_details','sql_exec_details','exception_details','ring_subreports')) {
        Close-LedgerItemIfReady 'requiredDeliverables' $deliverable
    }

    $verifyArgs = @{
        CaseId = $CaseId
        OutDir = $OutDir
        Ledger = $Ledger
        Stage = 'Completion'
        RequireThreadCategories = [bool]$RequireThreadCategories
        RequireSqlExec = [bool]$RequireSqlExec
        RequireSchedulerInventory = [bool]$RequireSchedulerInventory
        RequireLatchContendedPages = [bool]$RequireLatchContendedPages
    }
    Invoke-Checked 'Gate A completion verification' {
        & $verifier @verifyArgs
    }

    $overallItem = Get-Item -LiteralPath $overall
    $flags = @()
    if ($RequireThreadCategories) { $flags += 'RequireThreadCategories' }
    if ($RequireSqlExec) { $flags += 'RequireSqlExec' }
    if ($RequireSchedulerInventory) { $flags += 'RequireSchedulerInventory' }
    if ($RequireLatchContendedPages) { $flags += 'RequireLatchContendedPages' }
    $receipt = [ordered]@{
        caseId = $CaseId
        gate = 'Gate A — dump-overall Completion'
        stage = 'Completion'
        status = 'PASS'
        completedAt = (Get-Date).ToString('o')
        verifier = 'verify_case_deliverables.ps1'
        requiredFlags = $flags
        overallReport = [System.IO.Path]::GetFileName($overall)
        overallBytes = $overallItem.Length
        overallLastWriteTime = $overallItem.LastWriteTime.ToString('o')
        overallSha256 = (Get-FileHash -LiteralPath $overall -Algorithm SHA256).Hash
        workflowLedger = [System.IO.Path]::GetFileName($Ledger)
        workflowLedgerSha256 = (Get-FileHash -LiteralPath $Ledger -Algorithm SHA256).Hash
        manifest = [System.IO.Path]::GetFileName($Manifest)
        manifestSha256 = (Get-FileHash -LiteralPath $Manifest -Algorithm SHA256).Hash
        isolationContract = 'Post-overall probe and branch-report outcomes cannot invalidate, regenerate, or rewrite this completed Gate A artifact set.'
    }
    [System.IO.File]::WriteAllText($receiptTemp, ($receipt | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $receiptTemp -Destination $receiptPath -Force
    Write-Host "[finalize_dump_overall] PASS (Gate A): $CaseId" -ForegroundColor Green
    Write-Host "  overall: $overall"
    Write-Host "  receipt: $receiptPath"
    exit 0
} catch {
    if (Test-Path -LiteralPath $receiptTemp) { Remove-Item -LiteralPath $receiptTemp -Force }
    Write-Host "[finalize_dump_overall] FAIL (Gate A): $_" -ForegroundColor Red
    Write-Host '  No completion receipt was published.' -ForegroundColor Red
    exit 1
}
