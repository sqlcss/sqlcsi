# finalize_dump_analysis.ps1
# Final completion gate after Gate C PASS and final root-cause report generation.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$AnalysisDir,
    [Parameter(Mandatory)][string]$FinalReport,
    [string]$OverallDir = '',
    [string]$Receipt = ''
)
$ErrorActionPreference = 'Stop'
if (-not $OverallDir) { $OverallDir = Join-Path $AnalysisDir "${CaseId}_dump_overall" }
if (-not $Receipt) { $Receipt = Join-Path $AnalysisDir 'dump_analysis_completion_receipt.json' }
$receiptTemp = "$Receipt.tmp"
if (Test-Path -LiteralPath $receiptTemp) { Remove-Item -LiteralPath $receiptTemp -Force }
if (Test-Path -LiteralPath $Receipt) { Remove-Item -LiteralPath $Receipt -Force }
if (-not [System.IO.Path]::IsPathRooted($FinalReport)) { $FinalReport = Join-Path $AnalysisDir $FinalReport }
$gateAPath = Join-Path $OverallDir 'overall_completion_receipt.json'
$gateBPath = Join-Path $OverallDir 'first_pass_branch_completion_receipt.json'
$branchJson = Join-Path $OverallDir "${CaseId}_first_pass_branch_hints.json"
$gateCPath = Join-Path $AnalysisDir 'route_execution_completion_receipt.json'
$postResearchReceiptPath = Join-Path $AnalysisDir 'non_yield_callstack_research_completion_receipt.json'
$postResearchInjector = Join-Path $PSScriptRoot 'inject_non_yield_callstack_research.ps1'
$postResearchReceiptObject = $null
$postResearchStatus = 'not-applicable'
$postResearchNarrationHref = $null
$postResearchFailurePath = Join-Path $AnalysisDir 'non_yield_callstack_research_optional_failure.txt'
$postResearchIssues = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
function Need([string]$path,[string]$label) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) { $failures.Add("$label missing or empty: $path") }
}
function Need-OptionalFile([string]$path,[string]$label) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) { throw "$label missing or empty: $path" }
}
foreach ($pair in @(@($gateAPath,'Gate A receipt'),@($gateBPath,'Gate B receipt'),@($branchJson,'Gate B branch JSON'),@($gateCPath,'Gate C receipt'),@($FinalReport,'final report'))) { Need $pair[0] $pair[1] }
if ($failures.Count -eq 0) {
    $a = Get-Content -LiteralPath $gateAPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $b = Get-Content -LiteralPath $gateBPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $c = Get-Content -LiteralPath $gateCPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $branch = Get-Content -LiteralPath $branchJson -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$a.status -ne 'PASS') { $failures.Add('Gate A is not PASS') }
    if ([string]$b.status -ne 'PASS') { $failures.Add('Gate B is not PASS') }
    if ([string]$c.status -ne 'PASS') { $failures.Add('Gate C is not PASS') }
    $overallPath = Join-Path $OverallDir ([string]$a.overallReport)
    Need $overallPath 'Gate A overall report'
    if (Test-Path -LiteralPath $overallPath) {
        $overallHash = (Get-FileHash -LiteralPath $overallPath -Algorithm SHA256).Hash
        if ($overallHash -ne [string]$a.overallSha256) { $failures.Add('Gate A overall hash mismatch') }
        if ($overallHash -ne [string]$b.overallSha256Before -or $overallHash -ne [string]$b.overallSha256After) { $failures.Add('Gate B did not preserve current Gate A hash') }
    }
    $branchHash = (Get-FileHash -LiteralPath $branchJson -Algorithm SHA256).Hash
    if ($branchHash -ne [string]$c.sourceBranchSha256) { $failures.Add('Gate C source branch JSON hash mismatch') }
    $routeLedger = Join-Path $AnalysisDir ([string]$c.routeLedger)
    $routeReport = Join-Path $AnalysisDir ([string]$c.routeExecutionReport)
    Need $routeLedger 'Gate C route ledger'; Need $routeReport 'Gate C route report'
    if (Test-Path -LiteralPath $routeLedger) {
        if ((Get-FileHash -LiteralPath $routeLedger -Algorithm SHA256).Hash -ne [string]$c.routeLedgerSha256) { $failures.Add('Gate C route ledger hash mismatch') }
    }
    if (Test-Path -LiteralPath $routeReport) {
        if ((Get-FileHash -LiteralPath $routeReport -Algorithm SHA256).Hash -ne [string]$c.routeExecutionReportSha256) { $failures.Add('Gate C route report hash mismatch') }
    }
    if (@($c.routeSubreports).Count -ne [int]$c.selectedRouteCount) {
        $failures.Add("Gate C route subreport count $(@($c.routeSubreports).Count) does not match selected route count $($c.selectedRouteCount)")
    }
    foreach ($subreport in @($c.routeSubreports)) {
        $subreportPath = Join-Path $AnalysisDir ([string]$subreport.path)
        Need $subreportPath "Gate C route subreport $($subreport.route)"
        if (Test-Path -LiteralPath $subreportPath -PathType Leaf) {
            if ((Get-FileHash -LiteralPath $subreportPath -Algorithm SHA256).Hash -ne [string]$subreport.sha256) {
                $failures.Add("Gate C route subreport hash mismatch: $($subreport.route)")
            }
        }
    }
    $selectedCount = @($branch.buckets | Where-Object routingStatus -eq 'route-signal').Count
    if ($selectedCount -eq 0) { $selectedCount = 1 }
    if ([int]$c.selectedRouteCount -ne $selectedCount) { $failures.Add("Gate C route count $($c.selectedRouteCount) does not match Gate B selected/fallback count $selectedCount") }
    if (Test-Path -LiteralPath $routeLedger -PathType Leaf) {
        $routeDoc = Get-Content -LiteralPath $routeLedger -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($routeDoc.routes.PSObject.Properties.Name -contains 'scheduler_non_yield') {
            $postResearchStatus = 'not-produced'
            $nonYieldFindings = Join-Path $AnalysisDir "${CaseId}_non_yield_findings.json"
            $injector = Join-Path $PSScriptRoot 'inject_non_yield_findings.ps1'
            $nonYieldVerifier = Join-Path $PSScriptRoot 'verify_non_yield_route.ps1'
            Need $nonYieldFindings 'structured non-yield findings'; Need $injector 'non-yield final-report injector'; Need $nonYieldVerifier 'non-yield route verifier'
            if ($failures.Count -eq 0) {
                $global:LASTEXITCODE = 0
                & $injector -Findings $nonYieldFindings -FinalReport $FinalReport
                if (-not $? -or $LASTEXITCODE -ne 0) { $failures.Add("non-yield final-report injection failed with exit $LASTEXITCODE") }
                if ($failures.Count -eq 0) {
                    $global:LASTEXITCODE = 0
                    & $nonYieldVerifier -CaseId $CaseId -AnalysisDir $AnalysisDir -Ledger $routeLedger -FinalReport $FinalReport
                    if (-not $? -or $LASTEXITCODE -ne 0) { $failures.Add("non-yield route verification failed with exit $LASTEXITCODE") }
                }
            }
            # Optional post-final extension. Any failure is recorded but never
            # added to the mandatory failure list above.
            if ($failures.Count -eq 0) {
                try {
                    Need-OptionalFile $postResearchReceiptPath 'post-final non-yield callstack research receipt'
                    Need-OptionalFile $postResearchInjector 'post-final callstack research injector'
                    $candidateReceipt = Get-Content -LiteralPath $postResearchReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$candidateReceipt.status -ne 'PASS') { throw "post-final non-yield callstack research is not PASS: $($candidateReceipt.status)" }
                    $requestPath = Join-Path $AnalysisDir ([string]$candidateReceipt.request)
                    Need-OptionalFile $requestPath 'post-final non-yield callstack research request'
                    if ((Get-FileHash -LiteralPath $requestPath -Algorithm SHA256).Hash -ne [string]$candidateReceipt.requestSha256) { throw 'post-final non-yield callstack research request hash mismatch' }
                    foreach ($reportProperty in @($candidateReceipt.reports.PSObject.Properties)) {
                        $reportPath = Join-Path $AnalysisDir ([string]$reportProperty.Value.path).Replace('/','\')
                        Need-OptionalFile $reportPath "post-final callstack research report $($reportProperty.Name)"
                        if ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash -ne [string]$reportProperty.Value.sha256) { throw "post-final callstack research report hash mismatch: $($reportProperty.Name)" }
                    }
                    if ([System.IO.Path]::GetFileName([string]$candidateReceipt.prerequisiteBindings.baseFinalReport) -ne [System.IO.Path]::GetFileName($FinalReport)) { throw 'post-final callstack research was prepared against a different base final report' }
                    $global:LASTEXITCODE = 0
                    & $postResearchInjector -CompletionReceipt $postResearchReceiptPath -FinalReport $FinalReport
                    if (-not $? -or $LASTEXITCODE -ne 0) { throw "post-final callstack research injection failed with exit $LASTEXITCODE" }
                    $postResearchReceiptObject = $candidateReceipt
                    $postResearchStatus = 'published'
                    if (Test-Path -LiteralPath $postResearchFailurePath) { Remove-Item -LiteralPath $postResearchFailurePath -Force }
                } catch {
                    $postResearchStatus = 'unavailable-with-evidence'
                    $postResearchIssues.Add($_.Exception.Message)
                    $optionalText = "Optional post-final copied-stack research/link publication unavailable with evidence.`r`nCase: $CaseId`r`nTime: $((Get-Date).ToString('o'))`r`nError: $($_.Exception.Message)`r`n`r`nGate A, Gate B, Gate C, the base final report, and their prior reports remain valid.`r`n"
                    [IO.File]::WriteAllText($postResearchFailurePath,$optionalText,[Text.UTF8Encoding]::new($false))
                    Write-Warning "Optional copied-stack research publication failed without blocking final report generation: $($_.Exception.Message)"
                }
            }
        }
    }
    $html = Get-Content -LiteralPath $FinalReport -Raw -Encoding UTF8
    if ($postResearchReceiptObject) {
        $postResearchHtmlPath = Join-Path $AnalysisDir ([string]$postResearchReceiptObject.reports.englishHtml.path).Replace('/','\')
        $postResearchNarrationHref = [IO.Path]::GetRelativePath((Split-Path -Parent $FinalReport),$postResearchHtmlPath).Replace('\','/') + '#narration'
        if ($html -notmatch [regex]::Escape($postResearchNarrationHref)) {
            $failures.Add("final report does not link copied-stack narration: $postResearchNarrationHref")
        }
    }
    $routeReportName = [System.IO.Path]::GetFileName($routeReport)
    if ($html -notmatch [regex]::Escape($routeReportName)) { $failures.Add("final report does not link Gate C route report: $routeReportName") }
    $overallReportName = [System.IO.Path]::GetFileName($overallPath)
    if ($html -notmatch [regex]::Escape($overallReportName)) { $failures.Add("final report does not link Gate A overall report: $overallReportName") }
    if ($html -match '<section[^>]+id=["'']overall["''][^>]*>.*?<h2>Global dump snapshot — required four-step inventory</h2>' -and $html -notmatch '<div hidden[^>]*>\s*<h2>Legacy embedded global snapshot') {
        $failures.Add('final report visibly duplicates the full Gate A overall inventory instead of using a handoff summary')
    }
    $htmlForMandatoryLinkValidation = $html
    if ($postResearchStatus -ne 'published') {
        $optionalMarkerPattern = '(?s)' + [regex]::Escape('<!-- NON-YIELD-CALLSTACK-RESEARCH-START -->') + '.*?' + [regex]::Escape('<!-- NON-YIELD-CALLSTACK-RESEARCH-END -->')
        $htmlForMandatoryLinkValidation = [regex]::Replace($htmlForMandatoryLinkValidation,$optionalMarkerPattern,'')
    }
    $hrefs = [regex]::Matches($htmlForMandatoryLinkValidation,'<a\b[^>]*\bhref\s*=\s*["'']([^"'']+)["'']','IgnoreCase') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^(#|https?:|mailto:|javascript:)' } | Sort-Object -Unique
    foreach ($href in $hrefs) {
        $decodedHref = [System.Net.WebUtility]::HtmlDecode($href)
        $pathOnly = ($decodedHref -split '[?#]',2)[0]
        if (-not $pathOnly) { continue }
        $target = Join-Path $AnalysisDir $pathOnly.Replace('/','\')
        if (-not (Test-Path -LiteralPath $target)) { $failures.Add("final report broken local link: $href") }
    }
}
if ($failures.Count -gt 0) {
    Write-Host '[finalize_dump_analysis] FAIL' -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    Write-Host '  No final dump-analysis receipt was published.' -ForegroundColor Red
    exit 1
}
$finalReceipt = [ordered]@{
    caseId=$CaseId;gate='Final dump-analysis completion';status='PASS';completedAt=(Get-Date).ToString('o')
    gateAReceipt=[System.IO.Path]::GetRelativePath($AnalysisDir,$gateAPath).Replace('\','/');gateAReceiptSha256=(Get-FileHash -LiteralPath $gateAPath -Algorithm SHA256).Hash
    gateBReceipt=[System.IO.Path]::GetRelativePath($AnalysisDir,$gateBPath).Replace('\','/');gateBReceiptSha256=(Get-FileHash -LiteralPath $gateBPath -Algorithm SHA256).Hash
    gateCReceipt=[System.IO.Path]::GetRelativePath($AnalysisDir,$gateCPath).Replace('\','/');gateCReceiptSha256=(Get-FileHash -LiteralPath $gateCPath -Algorithm SHA256).Hash
    finalReport=[System.IO.Path]::GetFileName($FinalReport);finalReportSha256=(Get-FileHash -LiteralPath $FinalReport -Algorithm SHA256).Hash
    selectedRoutes=[int](Get-Content -LiteralPath $gateCPath -Raw -Encoding UTF8 | ConvertFrom-Json).selectedRouteCount
    postFinalNonYieldResearch=[ordered]@{
        status=$postResearchStatus
        issues=@($postResearchIssues)
        failureEvidence=if(Test-Path -LiteralPath $postResearchFailurePath){[IO.Path]::GetFileName($postResearchFailurePath)}else{$null}
        receipt=if($postResearchReceiptObject){[System.IO.Path]::GetFileName($postResearchReceiptPath)}else{$null}
        receiptSha256=if($postResearchReceiptObject){(Get-FileHash -LiteralPath $postResearchReceiptPath -Algorithm SHA256).Hash}else{$null}
        englishHtml=if($postResearchReceiptObject){[string]$postResearchReceiptObject.reports.englishHtml.path}else{$null}
        narrationHref=$postResearchNarrationHref
    }
}
[System.IO.File]::WriteAllText($receiptTemp,($finalReceipt|ConvertTo-Json -Depth 8),[System.Text.UTF8Encoding]::new($false))
[System.IO.File]::Move($receiptTemp,$Receipt,$true)
Write-Host "[finalize_dump_analysis] PASS: $CaseId -> $Receipt" -ForegroundColor Green
exit 0
