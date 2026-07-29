[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$verifier=Join-Path $root 'scripts\verify_non_yield_report.ps1'
$temp=Join-Path $env:TEMP 'sqlcsi_non_yield_verifier_test'
if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
New-Item -ItemType Directory -Path $temp -Force|Out-Null
'{}'|Set-Content (Join-Path $temp 'errorlog.json')
'{}'|Set-Content (Join-Path $temp 'xevent.json')
Write-Output 'import complete'|Set-Content (Join-Path $temp 'xevent_import.txt')
@'
# Non-yielding scheduler Root Cause
## ERRORLOG evidence
Estimated start and first sample timeline. Scheduler 42, OS TID 0x3a8c, Worker 0x123.
Worker CPU ratio 4%, wait-dominated. Process Utilization 39%, System Idle 56%.
## XEvent evidence
import-xevent complete.
scheduler_monitor_non_yielding_ring_buffer_recorded in xe.scheduler.
sp_server_diagnostics QUERY_PROCESSING and RESOURCE plus IO_SUBSYSTEM.
Top waits from wait_info: PAGEIOLATCH and RESOURCE_SEMAPHORE.
System pressure verdict: no host-wide CPU starvation.
## UTC and time zone alignment
Offset UTC+8 from a shared event.
## Synthesized Conclusion
Root Cause remains unresolved; ERRORLOG does not prove the blocked function.
Confidence Medium. Evidence Mapping and limitations retained.
'@|Set-Content (Join-Path $temp 'report.md')
[ordered]@{requiredSteps=[ordered]@{
    errorlog_non_yield_context=[ordered]@{status='done';evidence=@('errorlog.json')}
    xevent_import=[ordered]@{status='done';evidence=@('xevent_import.txt')}
    xevent_environment_context=[ordered]@{status='done';evidence=@('xevent.json')}
    synthesized_log_conclusion=[ordered]@{status='done';evidence=@('report.md')}
}}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $temp 'workflow_ledger.json')
& $verifier -CaseId fixture -ReportDir $temp -ReportPath 'report.md' -Ledger (Join-Path $temp 'workflow_ledger.json') -RequireXEventEvidence
if($LASTEXITCODE-ne0){throw "complete report was rejected: $LASTEXITCODE"}
'# Non-yielding scheduler'|Set-Content (Join-Path $temp 'bad.md')
& $verifier -CaseId fixture -ReportDir $temp -ReportPath 'bad.md'
if($LASTEXITCODE-eq0){throw 'incomplete report unexpectedly passed'}
Write-Host '[test_verify_non_yield_report] PASS: complete accepted; incomplete rejected' -ForegroundColor Green
exit 0
