# finalize_non_yield_log_analysis.ps1
# Hard boundary between ERRORLOG+XEvent log analysis and downstream dump detection.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$ReportDir,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][string]$Ledger,
    [Parameter(Mandatory)][string]$ErrorLogFindings,
    [Parameter(Mandatory)][string]$XEventFindings,
    [Parameter(Mandatory)][string[]]$XEventImportEvidence,
    [string[]]$AdditionalEvidence = @(),
    [string]$Receipt = '',
    [string]$Verifier = ''
)
$ErrorActionPreference='Stop'
if (-not $Receipt) { $Receipt = Join-Path $ReportDir 'non_yield_log_analysis_completion_receipt.json' }
if (-not $Verifier) { $Verifier = Join-Path $PSScriptRoot 'verify_non_yield_report.ps1' }
if (Test-Path -LiteralPath $Receipt) { Remove-Item -LiteralPath $Receipt -Force }
function Resolve-Artifact([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $ReportDir $Path)
}
function Need([string]$Path,[string]$Label) {
    $p = Resolve-Artifact $Path
    if (-not (Test-Path -LiteralPath $p -PathType Leaf) -or (Get-Item -LiteralPath $p).Length -eq 0) { throw "$Label missing/empty: $p" }
    return $p
}
function Rel([string]$Path) { return [IO.Path]::GetRelativePath($ReportDir,(Resolve-Path -LiteralPath $Path).Path).Replace('\','/') }
function Artifact([string]$Path) {
    $p = (Resolve-Path -LiteralPath $Path).Path
    return [ordered]@{path=(Rel $p);bytes=(Get-Item -LiteralPath $p).Length;sha256=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
}
if(-not(Test-Path -LiteralPath $ReportDir -PathType Container)){throw "ReportDir missing: $ReportDir"}
$report=Need $ReportPath 'log-analysis report'
$ledgerPath=Need $Ledger 'workflow ledger'
$errorlog=Need $ErrorLogFindings 'specialized ERRORLOG findings'
$xevent=Need $XEventFindings 'analyze-xevent findings'
$imports=@();foreach($path in $XEventImportEvidence){$imports+=Need $path 'import-xevent evidence'}
$additional=@();foreach($path in $AdditionalEvidence){$additional+=Need $path 'additional log-analysis evidence'}
$global:LASTEXITCODE=0
& $Verifier -CaseId $CaseId -ReportDir $ReportDir -ReportPath $report -Ledger $ledgerPath -RequireXEventEvidence
if(-not$?-or$LASTEXITCODE-ne0){throw "non-yield log-analysis report verifier failed with exit $LASTEXITCODE"}
$ledgerDoc=Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8|ConvertFrom-Json
foreach($stepName in @('errorlog_non_yield_context','xevent_import','xevent_environment_context','synthesized_log_conclusion')){
    if(-not($ledgerDoc.requiredSteps.PSObject.Properties.Name-contains$stepName)){throw "ledger required step missing: $stepName"}
    if([string]$ledgerDoc.requiredSteps.$stepName.status-ne'done'){throw "ledger required step is not done: $stepName=$($ledgerDoc.requiredSteps.$stepName.status)"}
}
$receiptObject=[ordered]@{
    caseId=$CaseId
    stage='Non-yield ERRORLOG + XEvent log analysis'
    completionBoundary='Log Gate'
    status='PASS'
    logAnalysisComplete=$true
    reportPublicationAllowed=$true
    downstreamDumpRequiredForLogCompletion=$false
    receiptIsImmutableAfterPublication=$true
    completedAt=(Get-Date).ToString('o')
    report=(Artifact $report)
    workflowLedger=(Artifact $ledgerPath)
    errorlogFindings=(Artifact $errorlog)
    xeventFindings=(Artifact $xevent)
    xeventImportEvidence=@($imports|ForEach-Object{Artifact $_})
    additionalEvidence=@($additional|ForEach-Object{Artifact $_})
    downstream=[ordered]@{
        stage='Post-Log continuation'
        status='not-started'
        affectsLogGateStatus=$false
        mayStartAfterReceiptPass=$true
        dumpDetectionAllowed=$true
        requiredInputReceipt=[IO.Path]::GetFileName($Receipt)
        detector='.github/skills/non-yielding-analysis/scripts/detect_non_yield_dump.ps1'
        rule='Publish the log report immediately at Log Gate PASS. Do not scan/select/delegate a dump before PASS; store downstream state in separate artifacts. Later dump pending/failure cannot mutate or revoke this receipt.'
    }
}
$temp="$Receipt.tmp"
[IO.File]::WriteAllText($temp,($receiptObject|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
[IO.File]::Move($temp,$Receipt,$true)
Write-Host "[finalize_non_yield_log_analysis] PASS: Log Gate complete; publish report now; dump continuation is independent -> $Receipt" -ForegroundColor Green
exit 0
