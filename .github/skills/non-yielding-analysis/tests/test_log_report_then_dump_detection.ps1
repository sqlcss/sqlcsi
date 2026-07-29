[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$finalizer=Join-Path $root 'scripts\finalize_non_yield_log_analysis.ps1'
$detector=Join-Path $root 'scripts\detect_non_yield_dump.ps1'
$temp=Join-Path $env:TEMP 'sqlcsi_non_yield_sequence_test'
if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
$reportDir=Join-Path $temp 'report';$caseDir=Join-Path $temp 'case'
New-Item -ItemType Directory -Path $reportDir,$caseDir -Force|Out-Null
$errorlog=Join-Path $reportDir 'fixture_non_yield_errorlog.json'
$xevent=Join-Path $reportDir 'fixture_xevent_findings.json'
$import=Join-Path $reportDir 'fixture_xevent_import.txt'
$report=Join-Path $reportDir 'fixture_non_yield_log_analysis_zh.md'
$ledger=Join-Path $reportDir 'workflow_ledger.json'
$receipt=Join-Path $reportDir 'non_yield_log_analysis_completion_receipt.json'
$detection=Join-Path $reportDir 'fixture_non_yield_dump_detection.json'
[ordered]@{analysisType='sql-csi-non-yield-errorlog';caseId='fixture';dumpReferences=@();incidents=@([ordered]@{incidentId='NY-001';incidentType='scheduler';estimatedStartLocal='2026-06-17T15:35:48.659';windowStartLocal='2026-06-17T13:35:48.659';windowEndLocal='2026-06-17T17:36:48.000';schedulerId=42;osTid='0x3a8c';worker='0x123';workerCpuDeltaRatioPct=4.1})}|ConvertTo-Json -Depth 10|Set-Content $errorlog
'{}'|Set-Content $xevent
'import-xevent complete'|Set-Content $import
@'
# Non-yielding scheduler 日志分析
## ERRORLOG 错误日志证据
时间线与采样：estimated start。调度器 Scheduler 42，OS TID 0x3a8c，Worker 0x123。Worker CPU ratio 4%，wait-dominated。Process Utilization 39%，System Idle 56%。
## XEvent 证据
import-xevent 完成。scheduler_monitor_non_yielding_ring_buffer_recorded 位于 xe.scheduler。sp_server_diagnostics QUERY_PROCESSING、RESOURCE、IO_SUBSYSTEM。wait_info Top waits 包含 PAGEIOLATCH 与 RESOURCE_SEMAPHORE。系统压力判断：无 host-wide CPU starvation。
## UTC 与时区对齐
依据共享事件确认 offset UTC+8。
## 综合结论 Root Cause
ERRORLOG does not prove 阻塞函数，根因仍 unresolved。置信度 Medium。证据映射与限制已保留。
'@|Set-Content $report
[ordered]@{caseId='fixture';requiredSteps=[ordered]@{
 errorlog_non_yield_context=[ordered]@{status='done';evidence=@('fixture_non_yield_errorlog.json')}
 xevent_import=[ordered]@{status='done';evidence=@('fixture_xevent_import.txt')}
 xevent_environment_context=[ordered]@{status='done';evidence=@('fixture_xevent_findings.json')}
 synthesized_log_conclusion=[ordered]@{status='done';evidence=@('fixture_non_yield_log_analysis_zh.md')}
}}|ConvertTo-Json -Depth 8|Set-Content $ledger
# Dump companions: only SQLDump0020 is the correct timestamp; SQLDump0004 is older.
$dump20=@'
Current time is 15:36:48 06/17/26.
* BEGIN STACK DUMP:
*   06/17/26 15:36:48 spid 13108
* Non-yielding Scheduler
'@
$dump4=@'
Current time is 15:36:48 01/10/26.
* BEGIN STACK DUMP:
*   01/10/26 15:36:48 spid 11968
* Non-yielding Scheduler
'@
[IO.File]::WriteAllText((Join-Path $caseDir 'SQLDump0020.txt'),$dump20,[Text.Encoding]::Unicode)
[IO.File]::WriteAllBytes((Join-Path $caseDir 'SQLDump0020.mdmp'),[byte[]](1,2,3,4))
[IO.File]::WriteAllText((Join-Path $caseDir 'SQLDump0004.txt'),$dump4,[Text.Encoding]::Unicode)
[IO.File]::WriteAllBytes((Join-Path $caseDir 'SQLDump0004.mdmp'),[byte[]](5,6,7,8))
# Detector must reject before the receipt exists.
$pwsh=(Get-Process -Id $PID).Path
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $detector -CaseId fixture -CaseDir $caseDir -ReportDir $reportDir -LogCompletionReceipt $receipt -ErrorLogFindings $errorlog -OutJson $detection *> (Join-Path $temp 'expected_pre_receipt_failure.txt')
if($LASTEXITCODE-eq0){throw 'dump detector ran before log-analysis receipt PASS'}
& $finalizer -CaseId fixture -ReportDir $reportDir -ReportPath $report -Ledger $ledger -ErrorLogFindings $errorlog -XEventFindings $xevent -XEventImportEvidence $import -Receipt $receipt
if($LASTEXITCODE-ne0){throw 'log-analysis finalizer failed'}
$logGate=Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json
if($logGate.status-ne'PASS'-or-not[bool]$logGate.logAnalysisComplete){throw 'Log Gate did not become independently complete'}
if(-not[bool]$logGate.reportPublicationAllowed){throw 'Log Gate report was not immediately publishable'}
if([bool]$logGate.downstreamDumpRequiredForLogCompletion){throw 'Log Gate incorrectly depends on downstream dump analysis'}
if(-not[bool]$logGate.receiptIsImmutableAfterPublication){throw 'Log Gate receipt is not immutable after publication'}
if([bool]$logGate.downstream.affectsLogGateStatus){throw 'Post-log continuation can incorrectly alter Log Gate status'}
if(-not[bool]$logGate.downstream.mayStartAfterReceiptPass){throw 'Post-log continuation is not explicitly sequenced after Log Gate PASS'}
if(-not(Test-Path -LiteralPath $report -PathType Leaf)){throw 'publishable log report is missing at Log Gate boundary'}
if(Test-Path -LiteralPath $detection){throw 'dump detection ran before the Log Gate publication boundary assertion'}
$receiptHashAtPublication=(Get-FileHash -LiteralPath $receipt -Algorithm SHA256).Hash
$reportHashAtPublication=(Get-FileHash -LiteralPath $report -Algorithm SHA256).Hash
# A downstream detector failure after Log Gate PASS must not mutate the report/receipt.
$missingCaseDir=Join-Path $temp 'intentionally_missing_case_dir'
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $detector -CaseId fixture -CaseDir $missingCaseDir -ReportDir $reportDir -LogCompletionReceipt $receipt -ErrorLogFindings $errorlog -OutJson $detection *> (Join-Path $temp 'expected_post_log_detector_failure.txt')
if($LASTEXITCODE-eq0){throw 'post-log detector failure injection unexpectedly succeeded'}
if((Get-FileHash -LiteralPath $receipt -Algorithm SHA256).Hash-ne$receiptHashAtPublication){throw 'downstream detector failure mutated the Log Gate receipt'}
if((Get-FileHash -LiteralPath $report -Algorithm SHA256).Hash-ne$reportHashAtPublication){throw 'downstream detector failure mutated the log report'}
& $detector -CaseId fixture -CaseDir $caseDir -ReportDir $reportDir -LogCompletionReceipt $receipt -ErrorLogFindings $errorlog -OutJson $detection
if($LASTEXITCODE-ne0){throw 'dump detector failed after PASS receipt'}
if((Get-FileHash -LiteralPath $receipt -Algorithm SHA256).Hash-ne$receiptHashAtPublication){throw 'successful dump detection mutated the Log Gate receipt'}
if((Get-FileHash -LiteralPath $report -Algorithm SHA256).Hash-ne$reportHashAtPublication){throw 'successful dump detection mutated the log report'}
$d=Get-Content -LiteralPath $detection -Raw|ConvertFrom-Json
if($d.prerequisite.completionBoundary-ne'Log Gate'-or-not[bool]$d.prerequisite.logAnalysisComplete){throw 'detector did not preserve Log Gate completion semantics'}
if(-not[bool]$d.prerequisite.receiptIsImmutableAfterPublication){throw 'detector did not preserve Log Gate immutability semantics'}
if($d.summary.matchedDumpCount-ne1){throw "expected one dump match; got $($d.summary.matchedDumpCount)"}
$m=@($d.matches|Where-Object { $_.status -eq 'matched' })
$selectedDumpPath = [string](@($m[0].selected.mdmpPaths)[0])
if($m.Count-ne1-or[IO.Path]::GetFileName($selectedDumpPath)-ne'SQLDump0020.mdmp'){throw 'detector did not uniquely select SQLDump0020.mdmp'}
if([IO.Path]::GetFileName([string]$m[0].dumpAnalysisHandoff.dump_path)-ne'SQLDump0020.mdmp'){throw 'handoff dump_path was truncated by single-element array collapse'}
if(-not$m[0].dumpAnalysisHandoff.log_completion_receipt_sha256){throw 'handoff does not bind log receipt hash'}
if([bool]$m[0].dumpAnalysisHandoff.preexistingGateArtifactsRequired){throw 'Path 1 handoff incorrectly requires pre-existing Gate artifacts'}
if([string]$m[0].dumpAnalysisHandoff.dumpPipelineMode-ne'fresh'){throw 'Path 1 handoff is not marked as a fresh dump pipeline'}
if(@($m[0].dumpAnalysisHandoff.requiredGateSequence)-join','-ne'Gate A - dump-overall,Gate B - branch hints,Gate C - route execution'){throw 'Path 1 Gate sequence is incorrect'}
if(Get-ChildItem -LiteralPath $reportDir -Recurse -File|Where-Object{$_.Name-match'overall_completion_receipt|first_pass_branch|route_execution_completion_receipt'}){throw 'sequencing fixture unexpectedly contains pre-existing Gate A/B/C artifacts'}
Write-Host '[test_log_report_then_dump_detection] PASS: pre-receipt blocked; post-receipt SQLDump0020 matched' -ForegroundColor Green
exit 0
