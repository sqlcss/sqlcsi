# verify_non_yield_route.ps1
# Route-specific Gate C verifier for Scheduler / non-yield and its final-report handoff.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$AnalysisDir,
    [Parameter(Mandatory)][string]$Ledger,
    [Parameter(Mandatory)][string]$FinalReport
)
$ErrorActionPreference='Stop'
$failures=[Collections.Generic.List[string]]::new()
function Need([string]$path,[string]$label){if(-not(Test-Path -LiteralPath $path -PathType Leaf)-or(Get-Item -LiteralPath $path).Length-eq0){$failures.Add("$label missing/empty: $path")}}
$findings=Join-Path $AnalysisDir "${CaseId}_non_yield_findings.json"
$routeReport=Join-Path $AnalysisDir "${CaseId}_route_scheduler_non_yield.html"
$dscript=Join-Path $AnalysisDir "${CaseId}_non_yield_analysis.txt"
$native=Join-Path $AnalysisDir "${CaseId}_non_yield_native.txt"
$discovery=Join-Path $AnalysisDir "${CaseId}_non_yield_frame_discovery.txt"
$spinSweepJson=Join-Path $AnalysisDir "${CaseId}_spinlock_owner_sweep.json"
$spinSweepHtml=Join-Path $AnalysisDir "${CaseId}_spinlock_owner_sweep.html"
foreach($p in @(@($Ledger,'route ledger'),@($findings,'non-yield findings'),@($routeReport,'Scheduler route report'),@($dscript,'non_yield_analysis output'),@($native,'native non-yield output'),@($discovery,'callback frame discovery'),@($FinalReport,'final report'))){Need $p[0] $p[1]}
if($failures.Count-eq0){
    $l=Get-Content -LiteralPath $Ledger -Raw -Encoding UTF8|ConvertFrom-Json
    $f=Get-Content -LiteralPath $findings -Raw -Encoding UTF8|ConvertFrom-Json
    $routeHtml=Get-Content -LiteralPath $routeReport -Raw -Encoding UTF8
    $finalHtml=Get-Content -LiteralPath $FinalReport -Raw -Encoding UTF8
    if(-not($l.routes.PSObject.Properties.Name-contains'scheduler_non_yield')){$failures.Add('scheduler_non_yield route missing')}
    else{
        $route=$l.routes.scheduler_non_yield;$required=@('dscript_non_yield_analysis','scheduler_monitor_event','ptrack_recovery','ptrack_validation','timing_cpu','current_stack','copied_stack','scheduler_inventory','task_query_correlation')
        foreach($name in $required){if(-not($route.checks.PSObject.Properties.Name-contains$name)){$failures.Add("required non-yield check missing: $name")}elseif([string]$route.checks.$name.status-notin@('completed','unavailable-with-evidence')){$failures.Add("non-yield check not terminal: $name=$($route.checks.$name.status)")}}
        if([string]$route.status-notin@('completed','completed-with-limitations')){$failures.Add("Scheduler route status is not completed: $($route.status)")}
    }
    if([int]$f.dscript.offender-le0-or[int]$f.dscript.passes-le0-or[double]$f.dscript.wallMs-le0){$failures.Add('DScript core metrics incomplete')}
    if(-not$f.callback.pTrack-or-not$f.callback.worker-or-not$f.callback.task-or-not$f.callback.schedulerId){$failures.Add('native pTrack identity chain incomplete')}
    if(@($f.currentStack.functions).Count-eq0){$failures.Add('current stack missing')}
    if(@($f.copiedStack.functions).Count-eq0){$failures.Add('copied stack missing')}
    if(-not$f.schedulerMonitor.event-or[string]$f.schedulerMonitor.event-notmatch'NONYIELD|STUCK_DISPATCHER'){$failures.Add('matching SchedulerMonitor event missing')}
    if(-not$f.execution.spid-or-not$f.execution.sql){$failures.Add('task/query correlation incomplete')}
    $dscriptText=Get-Content -LiteralPath $dscript -Raw -Encoding UTF8
    foreach($needle in @('Offender','# passes','Wall clock time','Kernel time','User time')){if($dscriptText-notmatch[regex]::Escape($needle)){$failures.Add("DScript output missing: $needle")}}
    foreach($needle in @('NON-YIELD-STRUCTURED-SUMMARY','non_yield_analysis.js','Current stack versus first-detected copied stack','SchedulerMonitor event','Task and statement correlation')){if($routeHtml-notmatch[regex]::Escape($needle)){$failures.Add("Scheduler route report missing: $needle")}}
    foreach($needle in @('NON-YIELD-FINAL-START','NON-YIELD-STRUCTURED-SUMMARY','NON-YIELD-FINAL-END')){if($finalHtml-notmatch[regex]::Escape($needle)){$failures.Add("final report missing generated non-yield marker: $needle")}}
    if($f.PSObject.Properties.Name-contains'spinlockOwnerSweep'){
        $spinStatus=[string]$f.spinlockOwnerSweep.status
        if($spinStatus-in@('completed','not-applicable')){
            Need $spinSweepJson 'spinlock owner sweep JSON';Need $spinSweepHtml 'spinlock owner sweep HTML'
            foreach($needle in @('SPINLOCK-OWNER-SWEEP-SUMMARY','Gate C · Spinlock Thread and Nominal Owner Sweep','Total dump threads','Spinlock stacks','Acquire/backoff candidates','Unique lock addresses','Open the complete Gate C Spinlock owner sweep report')){if($routeHtml-notmatch[regex]::Escape($needle)){$failures.Add("successful Spinlock section missing from Scheduler route report: $needle")};if($finalHtml-notmatch[regex]::Escape($needle)){$failures.Add("successful Spinlock section missing from final report: $needle")}}
        }elseif($spinStatus-eq'unavailable-with-evidence'){
            $failureEvidence=Join-Path $AnalysisDir ([string]$f.spinlockOwnerSweep.failureEvidence).Replace('/','\')
            Need $failureEvidence 'optional Spinlock failure evidence'
            foreach($needle in @('SPINLOCK-OWNER-SWEEP-SUMMARY','Optional extension unavailable with evidence','pre-existing Scheduler/non-yield analysis and final root-cause report are unaffected')){if($routeHtml-notmatch[regex]::Escape($needle)){$failures.Add("Spinlock limitation missing from Scheduler route report: $needle")};if($finalHtml-notmatch[regex]::Escape($needle)){$failures.Add("Spinlock limitation missing from final report: $needle")}}
        }
    }
    foreach($value in @([string]$f.dscript.offender,[string]$f.dscript.passes,[string]$f.callback.pTrack,[string]$f.execution.spid,[string]$f.execution.schedulerId)){if($finalHtml-notmatch[regex]::Escape($value)){$failures.Add("final report missing non-yield value: $value")}}
}
if($failures.Count-gt0){Write-Host '[verify_non_yield_route] FAIL' -ForegroundColor Red;foreach($x in $failures){Write-Host " - $x" -ForegroundColor Red};exit 1}
Write-Host "[verify_non_yield_route] PASS: $CaseId" -ForegroundColor Green
exit 0
