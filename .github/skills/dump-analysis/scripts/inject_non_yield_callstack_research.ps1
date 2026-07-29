# inject_non_yield_callstack_research.ps1
# Idempotently publishes the verified post-final copied-stack research link into final HTML.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CompletionReceipt,
    [Parameter(Mandatory)][string]$FinalReport
)
$ErrorActionPreference = 'Stop'
foreach ($path in @($CompletionReceipt,$FinalReport)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) { throw "required file missing/empty: $path" }
}
$receipt = Get-Content -LiteralPath $CompletionReceipt -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$receipt.status -ne 'PASS') { throw "callstack research receipt is not PASS: $($receipt.status)" }
$analysisDir = Split-Path -Parent $CompletionReceipt
$reportRel = [string]$receipt.reports.englishHtml.path
$reportPath = if ([IO.Path]::IsPathRooted($reportRel)) { $reportRel } else { Join-Path $analysisDir $reportRel.Replace('/','\') }
if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw "English callstack research report missing: $reportPath" }
if ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash -ne [string]$receipt.reports.englishHtml.sha256) { throw 'English callstack research report hash mismatch' }
$reportHtml = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
if ($reportHtml -notmatch '(?i)<section\b[^>]*\bid=["'']narration["'']') { throw 'English callstack research report has no #narration target' }
function HE([string]$Value) { return [Net.WebUtility]::HtmlEncode($Value) }
$href = [IO.Path]::GetRelativePath((Split-Path -Parent $FinalReport),$reportPath).Replace('\','/')
$narrationHref = $href + '#narration'
$start = '<!-- NON-YIELD-CALLSTACK-RESEARCH-START -->'
$end = '<!-- NON-YIELD-CALLSTACK-RESEARCH-END -->'
$fragment = @"
$start
<div class="card span-6 non-yield-callstack-research">
  <h3>Post-final copied-stack callstack research</h3>
  <p>This high-latency source/bug/PR/CU research ran only after the overall snapshot and base final report already existed. Its primary input is the <strong>FIRST-DETECTED COPIED STACK</strong>; the current stack is secondary persistence evidence.</p>
    <p><a href="$(HE $narrationHref)">Open the bottom-to-top copied-stack narration &rarr;</a><br><a href="$(HE $href)">Open the complete copied-stack callstack research report</a></p>
  <p class="muted">Primary function: <span class="mono">$(HE ([string]$receipt.primaryFunction))</span> · Receipt: <span class="mono">$(HE ([IO.Path]::GetFileName($CompletionReceipt)))</span></p>
</div>
$end
"@
$html = Get-Content -LiteralPath $FinalReport -Raw -Encoding UTF8
$markerPattern = [regex]::Escape($start) + '.*?' + [regex]::Escape($end)
if ([regex]::IsMatch($html,$markerPattern,'Singleline')) {
    $html = [regex]::Replace($html,$markerPattern,[Text.RegularExpressions.MatchEvaluator]{param($m)$fragment},'Singleline')
} else {
    $section = [regex]::Match($html,'(?is)<section\b[^>]*\bid=["'']artifacts["''][^>]*>.*?</section>')
    if ($section.Success) {
        $replacement = $section.Value -replace '(?is)</section>\s*$',[Text.RegularExpressions.MatchEvaluator]{param($m)"$fragment`r`n</section>"}
        $html = $html.Substring(0,$section.Index) + $replacement + $html.Substring($section.Index+$section.Length)
    } elseif ($html -match '(?i)</main>') {
        $html = [regex]::Replace($html,'(?i)</main>',[Text.RegularExpressions.MatchEvaluator]{param($m)"$fragment`r`n</main>"},1)
    } else {
        throw 'final report has neither an artifacts section nor </main> insertion point'
    }
}
$temp = "$FinalReport.tmp"
[IO.File]::WriteAllText($temp,$html,[Text.UTF8Encoding]::new($false))
[IO.File]::Move($temp,$FinalReport,$true)
Write-Host "[inject_non_yield_callstack_research] published -> $FinalReport" -ForegroundColor Green
exit 0
