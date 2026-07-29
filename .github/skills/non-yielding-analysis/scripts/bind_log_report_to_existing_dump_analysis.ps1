# bind_log_report_to_existing_dump_analysis.ps1
# Audited fallback when dump-analysis agent invocation is unavailable but the
# matched dump already has a complete, hash-verified dump-analysis artifact set.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DetectionJson,
    [Parameter(Mandatory)][string]$DumpAnalysisDir,
    [string]$FinalReport='',
    [string]$BindingReceipt='',
    [string]$DumpFinalizer=''
)
$ErrorActionPreference='Stop'
if(-not$FinalReport){$caseId=[string](Get-Content $DetectionJson -Raw|ConvertFrom-Json).caseId;$FinalReport=Join-Path $DumpAnalysisDir "${caseId}_sqldump0020_final_report.html"}
if(-not$BindingReceipt){$BindingReceipt=Join-Path (Split-Path -Parent $DetectionJson) 'non_yield_log_to_dump_binding_receipt.json'}
if(-not$DumpFinalizer){$DumpFinalizer=Join-Path $PSScriptRoot '..\..\dump-analysis\scripts\finalize_dump_analysis.ps1'}
function Need([string]$Path,[string]$Label){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)-or(Get-Item -LiteralPath $Path).Length-eq0){throw "$Label missing/empty: $Path"}}
function Sha([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function HE([string]$Text){return [Net.WebUtility]::HtmlEncode($Text)}
function Validate-Artifact([string]$Base,$Artifact,[string]$Label){$p=if([IO.Path]::IsPathRooted([string]$Artifact.path)){[string]$Artifact.path}else{Join-Path $Base ([string]$Artifact.path).Replace('/','\')};Need $p $Label;if((Sha $p)-ne[string]$Artifact.sha256){throw "$Label hash mismatch"};return (Resolve-Path $p).Path}
Need $DetectionJson 'dump detection JSON';Need $FinalReport 'dump final report';Need $DumpFinalizer 'dump finalizer'
$detection=Get-Content -LiteralPath $DetectionJson -Raw -Encoding UTF8|ConvertFrom-Json
$matched=@($detection.matches|Where-Object{$_.status-eq'matched'})
if($matched.Count-ne1){throw "expected exactly one matched dump; found $($matched.Count)"}
$handoff=$matched[0].dumpAnalysisHandoff;$caseId=[string]$detection.caseId
if([string]$handoff.invocationPath-ne'path1-non-yielding-to-dump-analysis'){throw "unsupported handoff invocationPath: $($handoff.invocationPath)"}
if([string]$handoff.dumpPipelineMode-ne'fresh'){throw "Path 1 handoff must request a fresh dump pipeline"}
if([bool]$handoff.preexistingGateArtifactsRequired){throw 'Path 1 handoff must not require pre-existing Gate artifacts'}
Need ([string]$handoff.dump_path) 'matched dump';Need ([string]$handoff.log_completion_receipt) 'upstream log receipt';Need ([string]$handoff.log_report) 'upstream log report'
if((Sha ([string]$handoff.log_completion_receipt))-ne[string]$handoff.log_completion_receipt_sha256){throw 'handoff log receipt hash mismatch'}
$logReceipt=Get-Content -LiteralPath ([string]$handoff.log_completion_receipt) -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$logReceipt.status-ne'PASS'){throw "upstream log receipt is not PASS: $($logReceipt.status)"}
$logBase=Split-Path -Parent ([string]$handoff.log_completion_receipt)
$lockedLogReport=Validate-Artifact $logBase $logReceipt.report 'locked upstream log report'
if((Resolve-Path ([string]$handoff.log_report)).Path-ne$lockedLogReport){throw 'handoff log report differs from receipt artifact'}
$dumpPath=[string]$handoff.dump_path;$dumpName=[IO.Path]::GetFileName($dumpPath)
$identityEvidence=Join-Path $DumpAnalysisDir "${caseId}_mirror_deepdive_extract.txt"
Need $identityEvidence 'dump identity evidence'
$identityText=Get-Content -LiteralPath $identityEvidence -TotalCount 20 -Encoding UTF8|Out-String
if($identityText-notmatch[regex]::Escape($dumpPath)){throw "existing dump analysis identity does not match handoff dump: $dumpPath"}
$dumpReceiptPath=Join-Path $DumpAnalysisDir 'dump_analysis_completion_receipt.json';Need $dumpReceiptPath 'existing dump completion receipt'
$oldDumpReceipt=Get-Content -LiteralPath $dumpReceiptPath -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$oldDumpReceipt.status-ne'PASS'){throw 'existing dump analysis is not PASS'}
foreach($binding in @(@('gateAReceipt','gateAReceiptSha256'),@('gateBReceipt','gateBReceiptSha256'),@('gateCReceipt','gateCReceiptSha256'))){$p=Join-Path $DumpAnalysisDir ([string]$oldDumpReceipt.($binding[0])).Replace('/','\');Need $p $binding[0];if((Sha $p)-ne[string]$oldDumpReceipt.($binding[1])){throw "$($binding[0]) hash mismatch"}}
if((Sha $FinalReport)-ne[string]$oldDumpReceipt.finalReportSha256){throw 'existing dump final report hash mismatch before upstream binding'}
$html=Get-Content -LiteralPath $FinalReport -Raw -Encoding UTF8
$href=[IO.Path]::GetRelativePath((Split-Path -Parent $FinalReport),$lockedLogReport).Replace('\','/')
$start='<!-- UPSTREAM-NON-YIELD-LOG-START -->';$end='<!-- UPSTREAM-NON-YIELD-LOG-END -->'
$fragment=@"
$start
<div class="card span-6 upstream-non-yield-log">
  <h3>上游 ERRORLOG + XEvent 日志分析</h3>
  <p>此日志报告已在 dump detection 之前独立生成并由 SHA-256 receipt 锁定。Dump 分析复用该上下文，但不修改其结论。</p>
  <p><a href="$(HE $href)">打开中文 non-yield log-analysis 报告 &rarr;</a></p>
  <p class="muted">匹配 dump：<span class="mono">$(HE $dumpName)</span> · Log receipt：<span class="mono">$(HE ([IO.Path]::GetFileName([string]$handoff.log_completion_receipt)))</span></p>
</div>
$end
"@
$pattern=[regex]::Escape($start)+'.*?'+[regex]::Escape($end)
if([regex]::IsMatch($html,$pattern,'Singleline')){$html=[regex]::Replace($html,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($m)$fragment},'Singleline')}
else{$section=[regex]::Match($html,'(?is)<section\b[^>]*\bid=["'']artifacts["''][^>]*>.*?</section>');if($section.Success){$replacement=$section.Value-replace'(?is)</section>\s*$',[Text.RegularExpressions.MatchEvaluator]{param($m)"$fragment`r`n</section>"};$html=$html.Substring(0,$section.Index)+$replacement+$html.Substring($section.Index+$section.Length)}elseif($html-match'(?i)</main>'){$html=[regex]::Replace($html,'(?i)</main>',[Text.RegularExpressions.MatchEvaluator]{param($m)"$fragment`r`n</main>"},1)}else{throw 'dump final report has no insertion point'}}
$temp="$FinalReport.tmp";[IO.File]::WriteAllText($temp,$html,[Text.UTF8Encoding]::new($false));[IO.File]::Move($temp,$FinalReport,$true)
$overallDir=Join-Path $DumpAnalysisDir "${caseId}_dump_overall"
$global:LASTEXITCODE=0
& $DumpFinalizer -CaseId $caseId -AnalysisDir $DumpAnalysisDir -OverallDir $overallDir -FinalReport $FinalReport
if(-not$?-or$LASTEXITCODE-ne0){throw "dump finalizer failed after upstream binding: $LASTEXITCODE"}
$newDumpReceipt=Get-Content -LiteralPath $dumpReceiptPath -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$newDumpReceipt.status-ne'PASS'-or(Sha $FinalReport)-ne[string]$newDumpReceipt.finalReportSha256){throw 'refreshed dump completion receipt/report hash validation failed'}
$finalHtml=Get-Content -LiteralPath $FinalReport -Raw -Encoding UTF8
if($finalHtml-notmatch[regex]::Escape($href)){throw 'dump final report does not retain upstream log link'}
$bindingObject=[ordered]@{caseId=$caseId;stage='Receipt-gated non-yield log to existing dump-analysis binding';status='PASS';completedAt=(Get-Date).ToString('o');dump=[ordered]@{path=$dumpPath;sha256=(Sha $dumpPath);identityEvidence=$identityEvidence;identityEvidenceSha256=(Sha $identityEvidence)};upstream=[ordered]@{logReport=$lockedLogReport;logReportSha256=(Sha $lockedLogReport);logReceipt=[string]$handoff.log_completion_receipt;logReceiptSha256=(Sha ([string]$handoff.log_completion_receipt));detectionJson=(Resolve-Path $DetectionJson).Path;detectionJsonSha256=(Sha $DetectionJson)};downstream=[ordered]@{reusedExistingAnalysis=$true;dumpAnalysisDir=(Resolve-Path $DumpAnalysisDir).Path;finalReport=(Resolve-Path $FinalReport).Path;finalReportSha256=(Sha $FinalReport);completionReceipt=$dumpReceiptPath;completionReceiptSha256=(Sha $dumpReceiptPath);upstreamHref=$href};limitations=@('dump-analysis custom subagent name was unavailable in the current runtime; an existing complete analysis of the identical dump was hash-verified and rebound through its canonical finalizer.')}
$tmp="$BindingReceipt.tmp";[IO.File]::WriteAllText($tmp,($bindingObject|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false));[IO.File]::Move($tmp,$BindingReceipt,$true)
Write-Host "[bind_log_report_to_existing_dump_analysis] PASS: $dumpName -> $BindingReceipt" -ForegroundColor Green
exit 0
