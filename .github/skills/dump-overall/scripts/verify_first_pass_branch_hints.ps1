# verify_first_pass_branch_hints.ps1
# Independent Gate B verifier. A failure here never changes Gate A's overall ledger/receipt.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$OutDir
)
$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()
function Need([string]$name) {
    $p = Join-Path $OutDir $name
    if (-not (Test-Path -LiteralPath $p -PathType Leaf) -or (Get-Item -LiteralPath $p).Length -eq 0) {
        $failures.Add("missing or empty: $p")
    }
    return $p
}
$receiptPath = Need 'overall_completion_receipt.json'
$statusPath = Need "${CaseId}_first_pass_probe_status.json"
$jsonPath = Need "${CaseId}_first_pass_branch_hints.json"
$htmlPath = Need "${CaseId}_first_pass_branch_hints.html"
if ($failures.Count -eq 0) {
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $branch = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $html = Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
    if ([string]$receipt.status -ne 'PASS') { $failures.Add('overall receipt is not PASS') }
    $overallPath = Join-Path $OutDir ([string]$receipt.overallReport)
    if (-not (Test-Path -LiteralPath $overallPath -PathType Leaf)) {
        $failures.Add("overall report from receipt is missing: $overallPath")
    } elseif ($receipt.PSObject.Properties.Name -contains 'overallSha256') {
        $actualOverallHash = (Get-FileHash -LiteralPath $overallPath -Algorithm SHA256).Hash
        if ($actualOverallHash -ne [string]$receipt.overallSha256) { $failures.Add('overall report hash changed after Gate A') }
    }
    if (-not [bool]$status.overallGate.immutableForThisPhase) { $failures.Add('probe status does not declare overall-gate isolation') }
    if (@($status.probes | Where-Object kind -eq 'required').Count -ne 12) { $failures.Add('required probe count is not 12') }
    if (@($status.probes | Where-Object kind -eq 'optional').Count -ne 6) { $failures.Add('optional probe count is not 6') }
    if (@($branch.buckets).Count -ne 8) { $failures.Add('branch bucket count is not 8') }
    $allowedProbe = @('signal-present','no-signal','unavailable-with-evidence')
    foreach ($entry in @($status.probes)) {
        if ($allowedProbe -notcontains [string]$entry.status) { $failures.Add("invalid probe coverage status: $($entry.status)") }
    }
    $allowedCoverage = @('data-present','empty-result','unavailable-with-evidence')
    $allowedRouting = @('route-signal','context-only','no-route-signal','unavailable-with-evidence')
    foreach ($entry in @($branch.buckets)) {
        if ($allowedCoverage -notcontains [string]$entry.coverageStatus) { $failures.Add("invalid bucket coverage status: $($entry.coverageStatus)") }
        if ($allowedRouting -notcontains [string]$entry.routingStatus) { $failures.Add("invalid bucket routing status: $($entry.routingStatus)") }
        if (-not [string]$entry.routingReason) { $failures.Add("bucket routing reason missing: $($entry.name)") }
    }
    if ($html -match '(?i)\blikely\b|root cause (?:is|was)|likely cause') { $failures.Add('branch report contains prohibited conclusion wording') }
    if ($html -notmatch 'cannot invalidate or rewrite that PASS') { $failures.Add('branch report is missing the isolation statement') }
    if ($html -notmatch 'Data coverage' -or $html -notmatch 'Routing relevance') { $failures.Add('branch report does not separate data coverage from routing relevance') }
    $hrefs = [regex]::Matches($html,'<a\b[^>]*\bhref\s*=\s*["'']([^"'']+)["'']','IgnoreCase') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^(#|https?:|mailto:|javascript:)' } | Sort-Object -Unique
    foreach ($href in $hrefs) {
        $target = Join-Path $OutDir ([System.Net.WebUtility]::HtmlDecode($href).Replace('/','\'))
        if (-not (Test-Path -LiteralPath $target)) { $failures.Add("broken local link: $href") }
    }
}
if ($failures.Count -gt 0) {
    Write-Host '[verify_first_pass_branch_hints] FAIL (Gate B only; overall PASS is unchanged)' -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "[verify_first_pass_branch_hints] PASS (Gate B): $CaseId" -ForegroundColor Green
exit 0
