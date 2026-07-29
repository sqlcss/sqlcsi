# finalize_non_yield_callstack_research.ps1
# Verifies the three post-final callstack-research reports and binds them to the
# immutable Gate A/Gate C/base-final/non-yield evidence snapshot.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Request,
    [string]$Receipt = ''
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Request -PathType Leaf)) { throw "research request not found: $Request" }
$analysisDir = Split-Path -Parent $Request
if (-not $Receipt) { $Receipt = Join-Path $analysisDir 'non_yield_callstack_research_completion_receipt.json' }
$requestDoc = Get-Content -LiteralPath $Request -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$requestDoc.status -ne 'ready') { throw "research request is not ready: $($requestDoc.status)" }
if ([string]$requestDoc.primaryEvidence.stack -ne 'FIRST-DETECTED COPIED STACK') { throw 'request primary stack is not FIRST-DETECTED COPIED STACK' }

function Resolve-AnalysisPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $analysisDir $Path.Replace('/','\')
}
function Need-File([string]$Path,[string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        throw "$Label missing or empty: $Path"
    }
}
function Sha([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Assert-Hash([string]$Path,[string]$Expected,[string]$Label) {
    Need-File $Path $Label
    $actual = Sha $Path
    if ($actual -ne $Expected) { throw "$Label hash changed: expected $Expected actual $actual" }
}
function HE([string]$Value) { if ($null -eq $Value) { return '' }; return [Net.WebUtility]::HtmlEncode($Value) }
function Write-AtomicJson([string]$Path,$Object) {
    $temp = "$Path.tmp"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    [IO.File]::WriteAllText($temp,($Object | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp,$Path,$true)
}

$bound = @(
    @('gateAReceipt','gateAReceiptSha256','Gate A receipt'),
    @('overallReport','overallReportSha256','Gate A overall report'),
    @('gateCReceipt','gateCReceiptSha256','Gate C receipt'),
    @('routeLedger','routeLedgerSha256','Gate C route ledger'),
    @('routeReport','routeReportSha256','Gate C route report'),
    @('baseFinalReport','baseFinalReportSha256','base final report'),
    @('nonYieldFindings','nonYieldFindingsSha256','non-yield findings')
)
foreach ($item in $bound) {
    $path = Resolve-AnalysisPath ([string]$requestDoc.prerequisites.($item[0]))
    Assert-Hash $path ([string]$requestDoc.prerequisites.($item[1])) $item[2]
}

$zhPath = Resolve-AnalysisPath ([string]$requestDoc.output.chineseMarkdown)
$enPath = Resolve-AnalysisPath ([string]$requestDoc.output.englishMarkdown)
$htmlPath = Resolve-AnalysisPath ([string]$requestDoc.output.englishHtml)
foreach ($pair in @(@($zhPath,'Chinese Markdown'),@($enPath,'English Markdown'),@($htmlPath,'English HTML'))) { Need-File $pair[0] $pair[1] }
$zh = Get-Content -LiteralPath $zhPath -Raw -Encoding UTF8
$en = Get-Content -LiteralPath $enPath -Raw -Encoding UTF8
$html = Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
$caseId = [string]$requestDoc.caseId
$primaryFunction = ([string]$requestDoc.primaryEvidence.primaryFunction -split '!',2)[-1]
foreach ($pair in @(@($zh,'Chinese Markdown'),@($en,'English Markdown'),@($html,'English HTML'))) {
    foreach ($marker in @($caseId,'FIRST-DETECTED COPIED STACK',$primaryFunction)) {
        if ([string]$pair[0] -notmatch [regex]::Escape($marker)) { throw "$($pair[1]) missing required marker: $marker" }
    }
}
if ($zh -notmatch '[\u4e00-\u9fff]') { throw 'Chinese Markdown contains no Chinese text' }
foreach ($pair in @(@($en,'English Markdown'),@($html,'English HTML'))) {
    if ([string]$pair[0] -notmatch '\bProven\b' -or [string]$pair[0] -notmatch '\bUnresolved\b') {
        throw "$($pair[1]) does not preserve Proven/Unresolved evidence boundaries"
    }
}
if ($html -notmatch '(?i)<!DOCTYPE html>' -or $html -notmatch '(?i)<html\b' -or $html -notmatch '(?i)<body\b') {
    throw 'English HTML structure is incomplete'
}

$hrefs = [regex]::Matches($html,'<a\b[^>]*\bhref\s*=\s*["'']([^"'']+)["'']','IgnoreCase') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^(#|https?:|mailto:|javascript:)' } | Sort-Object -Unique
$htmlDir = Split-Path -Parent $htmlPath
foreach ($href in $hrefs) {
    $target = Join-Path $htmlDir ([Net.WebUtility]::HtmlDecode($href).Replace('/','\'))
    if (-not (Test-Path -LiteralPath $target)) { throw "English HTML broken local link: $href" }
}

$reports = [ordered]@{
    chineseMarkdown = [ordered]@{path=[string]$requestDoc.output.chineseMarkdown;bytes=(Get-Item -LiteralPath $zhPath).Length;sha256=(Sha $zhPath)}
    englishMarkdown = [ordered]@{path=[string]$requestDoc.output.englishMarkdown;bytes=(Get-Item -LiteralPath $enPath).Length;sha256=(Sha $enPath)}
    englishHtml = [ordered]@{path=[string]$requestDoc.output.englishHtml;bytes=(Get-Item -LiteralPath $htmlPath).Length;sha256=(Sha $htmlPath)}
}
$receiptObject = [ordered]@{
    caseId = $caseId
    stage = 'Post-final Scheduler/non-yield copied-stack callstack research'
    status = 'PASS'
    completedAt = (Get-Date).ToString('o')
    request = [IO.Path]::GetFileName($Request)
    requestSha256 = (Sha $Request)
    primaryStack = 'FIRST-DETECTED COPIED STACK'
    primaryFunction = [string]$requestDoc.primaryEvidence.primaryFunction
    reports = $reports
    prerequisiteBindings = [ordered]@{
        gateAReceiptSha256 = [string]$requestDoc.prerequisites.gateAReceiptSha256
        overallReportSha256 = [string]$requestDoc.prerequisites.overallReportSha256
        gateCReceiptSha256 = [string]$requestDoc.prerequisites.gateCReceiptSha256
        routeLedgerSha256 = [string]$requestDoc.prerequisites.routeLedgerSha256
        routeReportSha256 = [string]$requestDoc.prerequisites.routeReportSha256
        baseFinalReport = [string]$requestDoc.prerequisites.baseFinalReport
        baseFinalReportSha256 = [string]$requestDoc.prerequisites.baseFinalReportSha256
        nonYieldFindingsSha256 = [string]$requestDoc.prerequisites.nonYieldFindingsSha256
    }
    publication = [ordered]@{
        finalReportLink = [string]$requestDoc.output.englishHtml
        injectedBy = 'finalize_dump_analysis.ps1 via inject_non_yield_callstack_research.ps1'
        finalCompletionRunsAfterThisReceipt = $true
    }
}
Write-AtomicJson $Receipt $receiptObject
Write-Host "[finalize_non_yield_callstack_research] PASS: reports=3 -> $Receipt" -ForegroundColor Green
exit 0
