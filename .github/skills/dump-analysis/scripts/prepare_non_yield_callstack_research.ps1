# prepare_non_yield_callstack_research.ps1
# Creates the post-final Scheduler/non-yield callstack-research request.
# This deliberately runs only after Gate A/Gate C PASS and a base final HTML exists.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$AnalysisDir,
    [Parameter(Mandatory)][string]$FinalReport,
    [Parameter(Mandatory)][string]$Dump,
    [Parameter(Mandatory)][string]$SqlVersion,
    [Parameter(Mandatory)][string]$Branch,
    [string]$Changeset = '',
    [string]$OverallDir = '',
    [string]$OutputDir = '',
    [string]$Request = '',
    [string]$ResearchDate = ''
)
$ErrorActionPreference = 'Stop'
if (-not $OverallDir) { $OverallDir = Join-Path $AnalysisDir "${CaseId}_dump_overall" }
if (-not $OutputDir) { $OutputDir = Join-Path $AnalysisDir 'callstack_research_copied_stack' }
if (-not $Request) { $Request = Join-Path $AnalysisDir "${CaseId}_non_yield_callstack_research_request.json" }
if (-not $ResearchDate) { $ResearchDate = (Get-Date).ToString('yyyy-MM-dd') }
if (-not [IO.Path]::IsPathRooted($FinalReport)) { $FinalReport = Join-Path $AnalysisDir $FinalReport }

function Need-File([string]$Path,[string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        throw "$Label missing or empty: $Path"
    }
}
function Read-Json([string]$Path) { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Sha([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Rel([string]$Path) { return [IO.Path]::GetRelativePath($AnalysisDir,$Path).Replace('\','/') }
function Write-AtomicJson([string]$Path,$Object) {
    $temp = "$Path.tmp"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    [IO.File]::WriteAllText($temp,($Object | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp,$Path,$true)
}

foreach ($pair in @(
    @($AnalysisDir,'analysis directory'),
    @($OverallDir,'overall directory'),
    @($Dump,'dump'),
    @($FinalReport,'base final report')
)) {
    if ($pair[1] -match 'directory') {
        if (-not (Test-Path -LiteralPath $pair[0] -PathType Container)) { throw "$($pair[1]) missing: $($pair[0])" }
    } else { Need-File $pair[0] $pair[1] }
}

$gateAPath = Join-Path $OverallDir 'overall_completion_receipt.json'
$gateCPath = Join-Path $AnalysisDir 'route_execution_completion_receipt.json'
$findingsPath = Join-Path $AnalysisDir "${CaseId}_non_yield_findings.json"
foreach ($pair in @(@($gateAPath,'Gate A receipt'),@($gateCPath,'Gate C receipt'),@($findingsPath,'non-yield findings'))) {
    Need-File $pair[0] $pair[1]
}
$gateA = Read-Json $gateAPath
$gateC = Read-Json $gateCPath
$findings = Read-Json $findingsPath
if ([string]$gateA.status -ne 'PASS') { throw 'Gate A is not PASS' }
if ([string]$gateC.status -ne 'PASS') { throw 'Gate C is not PASS' }
if ([string]$findings.route -ne 'Scheduler / non-yield') { throw 'findings are not for Scheduler / non-yield' }

$overallReport = Join-Path $OverallDir ([string]$gateA.overallReport)
$routeLedger = Join-Path $AnalysisDir ([string]$gateC.routeLedger)
$routeReport = Join-Path $AnalysisDir ([string]$gateC.routeExecutionReport)
foreach ($pair in @(@($overallReport,'Gate A overall report'),@($routeLedger,'Gate C route ledger'),@($routeReport,'Gate C route report'))) {
    Need-File $pair[0] $pair[1]
}
if ((Sha $overallReport) -ne [string]$gateA.overallSha256) { throw 'Gate A overall report hash mismatch' }
if ((Sha $routeLedger) -ne [string]$gateC.routeLedgerSha256) { throw 'Gate C route ledger hash mismatch' }
if ((Sha $routeReport) -ne [string]$gateC.routeExecutionReportSha256) { throw 'Gate C route report hash mismatch' }
$routeDoc = Read-Json $routeLedger
if (-not ($routeDoc.routes.PSObject.Properties.Name -contains 'scheduler_non_yield')) { throw 'scheduler_non_yield route was not selected' }
if (@('completed','completed-with-limitations') -notcontains [string]$routeDoc.routes.scheduler_non_yield.status) {
    throw "scheduler_non_yield route is not completed: $($routeDoc.routes.scheduler_non_yield.status)"
}
if (@($findings.copiedStack.functions).Count -eq 0) { throw 'copied stack functions are empty' }

$baseHtml = Get-Content -LiteralPath $FinalReport -Raw -Encoding UTF8
if ($baseHtml -notmatch [regex]::Escape([IO.Path]::GetFileName($overallReport))) { throw 'base final does not link Gate A overall report' }
if ($baseHtml -notmatch [regex]::Escape([IO.Path]::GetFileName($routeReport))) { throw 'base final does not link Gate C route report' }

$primaryFrame = @($findings.copiedStack.corePath | Where-Object { [string]$_ -match '![^!]+::' } | Select-Object -Last 1)
if ($primaryFrame.Count -eq 0) { $primaryFrame = @($findings.copiedStack.functions | Where-Object { [string]$_ -match '![^!]+::' } | Select-Object -First 1) }
if ($primaryFrame.Count -eq 0) { throw 'could not derive a primary copied-stack function' }
$symbol = ([string]$primaryFrame[0] -split '!',2)[-1]
$token = (($symbol -replace '<[^>]*>','' -replace '::','_' -replace '[^A-Za-z0-9_]+','_').Trim('_')).ToLowerInvariant()
if (-not $token) { $token = 'copied_stack' }
$baseName = "non_yielding_${token}_${ResearchDate}"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$priorFinalReceiptPath = Join-Path $AnalysisDir 'dump_analysis_completion_receipt.json'
$priorFinal = $null
if (Test-Path -LiteralPath $priorFinalReceiptPath -PathType Leaf) {
    $prior = Read-Json $priorFinalReceiptPath
    $priorFinal = [ordered]@{
        path = (Rel $priorFinalReceiptPath)
        sha256 = (Sha $priorFinalReceiptPath)
        status = [string]$prior.status
        finalReportSha256 = [string]$prior.finalReportSha256
        matchesCurrentBaseFinal = ([string]$prior.finalReportSha256 -eq (Sha $FinalReport))
    }
}

$requestObject = [ordered]@{
    caseId = $CaseId
    stage = 'Post-final Scheduler/non-yield copied-stack callstack research'
    status = 'ready'
    generatedAt = (Get-Date).ToString('o')
    sequencing = [ordered]@{
        gateAOverallAlreadyCompleted = $true
        gateCRouteAlreadyCompleted = $true
        baseFinalAlreadyGenerated = $true
        finalCompletionRunsAfterResearch = $true
        rationale = 'Callstack research is intentionally deferred because it is high latency.'
    }
    caseContext = [ordered]@{
        sqlVersion = $SqlVersion
        branch = $Branch
        changeset = $Changeset
        dump = $Dump
        researchDate = $ResearchDate
    }
    prerequisites = [ordered]@{
        gateAReceipt = (Rel $gateAPath)
        gateAReceiptSha256 = (Sha $gateAPath)
        overallReport = (Rel $overallReport)
        overallReportSha256 = (Sha $overallReport)
        gateCReceipt = (Rel $gateCPath)
        gateCReceiptSha256 = (Sha $gateCPath)
        routeLedger = (Rel $routeLedger)
        routeLedgerSha256 = (Sha $routeLedger)
        routeReport = (Rel $routeReport)
        routeReportSha256 = (Sha $routeReport)
        baseFinalReport = (Rel $FinalReport)
        baseFinalReportSha256 = (Sha $FinalReport)
        nonYieldFindings = (Rel $findingsPath)
        nonYieldFindingsSha256 = (Sha $findingsPath)
        priorFinalCompletion = $priorFinal
    }
    primaryEvidence = [ordered]@{
        stack = 'FIRST-DETECTED COPIED STACK'
        source = 'sqlmin!g_copiedStackInfo.threadContext'
        functions = @($findings.copiedStack.functions)
        corePath = @($findings.copiedStack.corePath)
        rawEvidence = [string]$findings.evidence.native
        currentStackUse = 'secondary persistence comparison only'
        primaryFunction = [string]$primaryFrame[0]
    }
    output = [ordered]@{
        directory = (Rel $OutputDir)
        baseName = $baseName
        chineseMarkdown = (Rel (Join-Path $OutputDir "$baseName.md"))
        englishMarkdown = (Rel (Join-Path $OutputDir "${baseName}_en.md"))
        englishHtml = (Rel (Join-Path $OutputDir "${baseName}_en.html"))
    }
    executionContract = [ordered]@{
        agent = 'callstack-research'
        reportSet = @('Chinese Markdown','English Markdown','English Catppuccin Mocha HTML')
        mustNotModify = @('Gate A artifacts','Gate B artifacts','Gate C ledger/reports','base final report')
        invokeOnlyAfterThisRequest = $true
    }
}
$completionReceipt = Join-Path $AnalysisDir 'non_yield_callstack_research_completion_receipt.json'
if (Test-Path -LiteralPath $completionReceipt) { Remove-Item -LiteralPath $completionReceipt -Force }
Write-AtomicJson $Request $requestObject
Write-Host "[prepare_non_yield_callstack_research] READY: base final exists; deferred research request -> $Request" -ForegroundColor Green
exit 0
