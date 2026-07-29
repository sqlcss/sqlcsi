# inject_non_yield_findings.ps1
# Idempotently publish structured Scheduler/non-yield findings into the final HTML report.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Findings,
    [Parameter(Mandatory)][string]$FinalReport
)
$ErrorActionPreference='Stop'
if(-not(Test-Path -LiteralPath $Findings -PathType Leaf)){throw "findings missing: $Findings"}
if(-not(Test-Path -LiteralPath $FinalReport -PathType Leaf)){throw "final report missing: $FinalReport"}
if([IO.Path]::GetExtension($FinalReport)-ne'.html'){throw 'non-yield final-report injection currently requires HTML'}
. (Join-Path $PSScriptRoot 'non_yield_report_common.ps1')
$f=Get-Content -LiteralPath $Findings -Raw -Encoding UTF8|ConvertFrom-Json
$fragment=Render-NonYieldFindingsHtml $f 'Gate C automated Scheduler / non-yield findings'
$html=Get-Content -LiteralPath $FinalReport -Raw -Encoding UTF8
$start='<!-- NON-YIELD-FINAL-START -->';$end='<!-- NON-YIELD-FINAL-END -->'
$wrapped="$start`n$fragment`n$end"
if($html.Contains($start)){
    $s=$html.IndexOf($start,[StringComparison]::Ordinal);$e=$html.IndexOf($end,$s,[StringComparison]::Ordinal)
    if($e-lt0){throw 'non-yield final marker start exists without end'}
    $e+=$end.Length;$html=$html.Substring(0,$s)+$wrapped+$html.Substring($e)
}else{
    $incident=[regex]::Match($html,'<section\s+id=["'']incident["''][^>]*>','IgnoreCase')
    if(-not$incident.Success){throw 'final report has no incident section'}
    $close=$html.IndexOf('</section>',$incident.Index+$incident.Length,[StringComparison]::OrdinalIgnoreCase)
    if($close-lt0){throw 'incident section has no closing tag'}
    $html=$html.Insert($close,$wrapped+"`n")
}
[IO.File]::WriteAllText($FinalReport,$html,[Text.UTF8Encoding]::new($false))
Write-Host "[inject_non_yield_findings] updated $FinalReport"
exit 0
