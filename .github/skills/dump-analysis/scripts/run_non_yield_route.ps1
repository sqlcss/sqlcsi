# run_non_yield_route.ps1
# Canonical Gate C executor for Scheduler / non-yield.
# Runs non_yield_analysis.js, discovers callback/offender dynamically, performs native
# pTrack/current/copied-stack fallback, correlates Gate A task/query/scheduler evidence,
# emits structured findings, and closes the Scheduler route checklist.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$Dump,
    [Parameter(Mandatory)][string]$AnalysisDir,
    [Parameter(Mandatory)][string]$OverallDir,
    [Parameter(Mandatory)][string]$DscriptPath,
    [Parameter(Mandatory)][string]$MexPath,
    [string]$Ledger = '',
    [string]$Cdb,
    [string]$SymPath = 'srv*C:\Symbols*https://symweb.azurefd.net',
    [string]$SpinlockSweepScript = '',
    [int]$TimeoutSec = 900
)
$ErrorActionPreference = 'Stop'
if (-not $Ledger) { $Ledger = Join-Path $AnalysisDir "${CaseId}_route_execution_ledger.json" }
$overallScripts = Join-Path $PSScriptRoot '..\..\dump-overall\scripts'
$runDscript = Join-Path $overallScripts 'run_dscript_once.ps1'
$resolveCdb = Join-Path $overallScripts 'resolve_cdb.ps1'
$setCheck = Join-Path $PSScriptRoot 'set_route_execution_check.ps1'
if (-not $SpinlockSweepScript) { $SpinlockSweepScript = Join-Path $PSScriptRoot 'run_spinlock_owner_sweep.ps1' }
foreach ($p in @($Dump,$AnalysisDir,$OverallDir,$DscriptPath,$MexPath,$Ledger,$runDscript,$resolveCdb,$setCheck)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "required path missing: $p" }
}
$dscript = Join-Path $DscriptPath 'non_yield_analysis.js'
$mex = Join-Path $MexPath 'mex.dll'
$threadsJson = Join-Path $OverallDir 'us_threads_shredded.json'
if (-not (Test-Path -LiteralPath $dscript -PathType Leaf)) { throw "non_yield_analysis.js missing: $dscript" }
if (-not (Test-Path -LiteralPath $mex -PathType Leaf)) { throw "mex.dll missing: $mex" }
if (-not (Test-Path -LiteralPath $threadsJson -PathType Leaf)) { throw "overall thread JSON missing: $threadsJson" }
. $resolveCdb
$Cdb = Resolve-CdbPath -Cdb $Cdb -Required

function Write-Utf8([string]$path,[string]$text) { [System.IO.File]::WriteAllText($path,$text,[System.Text.UTF8Encoding]::new($false)) }
function First-Match([string]$text,[string]$pattern,[int]$group=1) { $m=[regex]::Match($text,$pattern,'IgnoreCase,Multiline'); if($m.Success){return $m.Groups[$group].Value}; return $null }
function Hex-ToInt([string]$value) { if(-not $value){return $null}; return [Convert]::ToInt64(($value -replace '^0x',''),16) }
function Invoke-Cdb([string]$batch,[string]$log,[int]$timeout) {
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
    $proc=Start-Process -FilePath $Cdb -ArgumentList @('-y',$SymPath,'-z',$Dump,'-cf',$batch,'-logo',$log,'-G','-lines') -PassThru -WindowStyle Hidden
    if(-not $proc.WaitForExit($timeout*1000)){try{$proc.Kill()}catch{}; throw "cdb timed out after ${timeout}s: $batch"}
    if($proc.ExitCode -ne 0){throw "cdb exit $($proc.ExitCode): $batch"}
    if(-not(Test-Path -LiteralPath $log -PathType Leaf) -or (Get-Item -LiteralPath $log).Length -eq 0){throw "cdb log missing/empty: $log"}
}
function Get-Block([string]$text,[string]$start,[string]$end) {
    $s=$text.IndexOf($start,[StringComparison]::Ordinal); if($s -lt 0){return ''}
    $s += $start.Length; $e=$text.IndexOf($end,$s,[StringComparison]::Ordinal); if($e -lt 0){$e=$text.Length}
    return $text.Substring($s,$e-$s).Trim()
}
function Stack-Functions([string]$block) {
    return @([regex]::Matches($block,'(?m)(?:^|\s)([A-Za-z0-9_.<>:$~]+![A-Za-z0-9_<>:$~?,]+)(?:\+0x[0-9a-f]+)?','IgnoreCase') | ForEach-Object {$_.Groups[1].Value} | Select-Object -Unique)
}
function Parse-PipeRows([string]$path) {
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return @()}; $lines=[IO.File]::ReadAllLines($path);$hi=-1
    for($i=0;$i-lt$lines.Count;$i++){if($lines[$i]-match'^record\s+\|'){$hi=$i;break}}
    if($hi-lt0){return @()};$cols=@(($lines[$hi]-split'\s*\|\s*')|ForEach-Object{$_.Trim()});$rows=@()
    for($i=$hi+1;$i-lt$lines.Count;$i++){if($lines[$i]-notmatch'^0x[0-9A-Fa-f]+\s*\|'){continue};$cells=@(($lines[$i]-split'\s*\|\s*')|ForEach-Object{$_.Trim()});$o=[ordered]@{};for($c=0;$c-lt$cols.Count;$c++){$o[$cols[$c]]=if($c-lt$cells.Count){$cells[$c]}else{''}};$rows+=[pscustomobject]$o}
    return @($rows)
}
function Set-Check([string]$name,[string]$status,[string[]]$evidence,[string]$note) {
    & $setCheck -Ledger $Ledger -Route 'scheduler_non_yield' -Check $name -Status $status -Evidence $evidence -Note $note
    if($LASTEXITCODE-ne0){throw "failed to update route check: $name"}
}
function Rel([string]$path){return [IO.Path]::GetRelativePath($AnalysisDir,$path).Replace('\','/')}

# Mark execution as an automated post-Gate-B run.
$ledgerDoc=Get-Content -LiteralPath $Ledger -Raw -Encoding UTF8|ConvertFrom-Json
if(-not($ledgerDoc.routes.PSObject.Properties.Name-contains'scheduler_non_yield')){throw 'scheduler_non_yield route is not selected'}
$ledgerDoc.routes.scheduler_non_yield.executionOrigin='Automated Gate C run_non_yield_route.ps1 execution'
$temp="$Ledger.tmp";Write-Utf8 $temp ($ledgerDoc|ConvertTo-Json -Depth 30);[IO.File]::Move($temp,$Ledger,$true)

# Step 1: required DScript analyzer.
$dscriptLog=Join-Path $AnalysisDir "${CaseId}_non_yield_analysis.txt"
$dscriptWds=Join-Path $AnalysisDir "${CaseId}_non_yield_analysis.wds"
& $runDscript -ScriptPath $dscript -LogFile $dscriptLog -OutWds $dscriptWds -Dump $Dump -SymPath $SymPath -Cdb $Cdb -EndMarker 'END NON YIELD ANALYSIS' -TimeoutSec $TimeoutSec
$dscriptExit=$LASTEXITCODE
$dscriptConsole=[IO.Path]::ChangeExtension($dscriptWds,'console.txt')
if(-not(Test-Path -LiteralPath $dscriptLog -PathType Leaf)){throw 'non-yield DScript output missing'}
$dscriptText=Get-Content -LiteralPath $dscriptLog -Raw -Encoding UTF8
$offender=[int](First-Match $dscriptText 'Offender\s*:\s*~(\d+)')
$passes=[int](First-Match $dscriptText '#\s*passes\s*:\s*(\d+)')
$wallMs=[long](First-Match $dscriptText 'Wall clock time:\s*(\d+)ms')
$kernelMs=[long](First-Match $dscriptText 'Kernel time\s*:\s*(\d+)ms')
$userMs=[long](First-Match $dscriptText 'User time\s*:\s*(\d+)ms')
if($offender-le0){throw 'non_yield_analysis.js did not emit an offender thread'}
$dscriptPartial=$dscriptText-match'COM Error Executing Script|Object expected|Cannot get symbol offset or register|DSCRIPT_ONCE_TIMEOUT'
$dscriptEvidence=@((Rel $dscriptLog));if(Test-Path $dscriptConsole){$dscriptEvidence+=(Rel $dscriptConsole)}
$dscriptNote="offender ~$offender; passes $passes; wall $wallMs ms; kernel $kernelMs ms; user $userMs ms."
if($dscriptPartial){$dscriptNote+=' Extended DScript section was partial; raw error retained and native fallback executed.';Set-Check 'dscript_non_yield_analysis' 'unavailable-with-evidence' $dscriptEvidence $dscriptNote}else{Set-Check 'dscript_non_yield_analysis' 'completed' $dscriptEvidence $dscriptNote}

# Step 2: discover callback thread from the overall stack inventory.
$threadRows=@(Get-Content -LiteralPath $threadsJson -Raw -Encoding UTF8|ConvertFrom-Json)
$callbacks=@($threadRows|Where-Object{[string]$_.stack-match'SQL_SOSNonYieldSchedulerCallback|ExecuteNonYieldSchedulerCallbacks'})
if($callbacks.Count-eq0){throw 'SchedulerMonitor non-yield callback thread was not found in overall stacks'}
$callback=($callbacks|Sort-Object @{Expression={if([string]$_.stack-match'SQL_SOSNonYieldSchedulerCallback'){0}else{1}}},id|Select-Object -First 1)
$callbackTid=[int]$callback.id

# Step 3: discover the DX frame index dynamically.
$discoverBatch=Join-Path $AnalysisDir "${CaseId}_non_yield_frame_discovery.cdb"
$discoverLog=Join-Path $AnalysisDir "${CaseId}_non_yield_frame_discovery.txt"
$discover=@"
.sympath $SymPath
.reload /f
.echo ===== CALLBACK FRAME DISCOVERY =====
~${callbackTid}s
dx -r1 @`$curthread.Stack.Frames
.echo ===== END CALLBACK FRAME DISCOVERY =====
q
"@
Write-Utf8 $discoverBatch $discover;Invoke-Cdb $discoverBatch $discoverLog $TimeoutSec
$discoverText=Get-Content -LiteralPath $discoverLog -Raw -Encoding UTF8
$fm=[regex]::Match($discoverText,'\[(0x[0-9A-Fa-f]+)\]\s*:\s*[^\r\n]*SQL_SOSNonYieldSchedulerCallback')
if(-not$fm.Success){$fm=[regex]::Match($discoverText,'\[(0x[0-9A-Fa-f]+)\]\s*:\s*[^\r\n]*ExecuteNonYieldSchedulerCallbacks')}
if(-not$fm.Success){throw 'callback frame index could not be discovered'}
$callbackFrame=$fm.Groups[1].Value

# Step 4: native pTrack/current/copied-stack fallback.
$nativeBatch=Join-Path $AnalysisDir "${CaseId}_non_yield_native.cdb"
$nativeLog=Join-Path $AnalysisDir "${CaseId}_non_yield_native.txt"
$native=@"
.sympath $SymPath
.reload /f
.load $mex
.echo ===== CALLBACK LOCALS =====
~${callbackTid}s
dx -r1 @`$curthread.Stack.Frames
dx @`$curthread.Stack.Frames[$callbackFrame].SwitchTo()
dv /t /v
dx -r3 pTrack
.echo ===== OFFENDING CURRENT STACK =====
~${offender}s
kv
!mex.t $offender
.echo ===== FIRST-DETECTED COPIED STACK =====
.cxr @@(&sqlmin!g_copiedStackInfo.threadContext)
kv
.cxr
.echo ===== END NON YIELD NATIVE =====
q
"@
Write-Utf8 $nativeBatch $native;Invoke-Cdb $nativeBatch $nativeLog $TimeoutSec
$nativeText=Get-Content -LiteralPath $nativeLog -Raw -Encoding UTF8
$currentBlock=Get-Block $nativeText '===== OFFENDING CURRENT STACK =====' '===== FIRST-DETECTED COPIED STACK ====='
$copiedBlock=Get-Block $nativeText '===== FIRST-DETECTED COPIED STACK =====' '===== END NON YIELD NATIVE ====='
$pTrack=First-Match $nativeText 'SchedulerMonitor::Track \* pTrack\s*=\s*(0x[0-9A-Fa-f`]+)'
if(-not$pTrack){$pTrack=First-Match $nativeText 'pTrack\s*:\s*(0x[0-9A-Fa-f`]+)'}
$worker=First-Match $nativeText 'Worker \* pWorker\s*=\s*(0x[0-9A-Fa-f`]+)'
$task=First-Match $nativeText 'SOS_Task \* pTask\s*=\s*(0x[0-9A-Fa-f`]+)'
$osTid=First-Match $nativeText 'unsigned long threadId\s*=\s*(0x[0-9A-Fa-f]+)'
$schedHex=First-Match $nativeText 'unsigned long schedId\s*=\s*(0x[0-9A-Fa-f]+)'
$schedulerId=Hex-ToInt $schedHex
$nativePassHex=First-Match $nativeText 'm_pass\s*:\s*(0x[0-9A-Fa-f]+)';$nativePass=Hex-ToInt $nativePassHex
$diagHex=First-Match $nativeText 'm_diagnosedPass\s*:\s*(0x[0-9A-Fa-f]+)';$diagnosedPass=Hex-ToInt $diagHex
$sysDiff=Get-Block $nativeText 'm_sysDiff' 'm_memStart'
$workerDiff=Get-Block $nativeText 'm_workerDiff' 'm_pWorker'
$nativeWall100ns=[long](First-Match $sysDiff 'm_WallClockTime\s*:\s*(\d+)')
$nativeKernel100ns=[long](First-Match $workerDiff 'm_KernelTime\s*:\s*(\d+)')
$nativeUser100ns=[long](First-Match $workerDiff 'm_UserTime\s*:\s*(\d+)')
$nativeWallMs=[math]::Round($nativeWall100ns/10000.0,3)
$nativeKernelMs=[math]::Round($nativeKernel100ns/10000.0,3)
$nativeUserMs=[math]::Round($nativeUser100ns/10000.0,3)
$currentFunctions=Stack-Functions $currentBlock;$copiedFunctions=Stack-Functions $copiedBlock
$core=@('sqldk!SpinlockBase::Backoff','sqlmin!Spinlock<160,5,258>::SpinToAcquireOptimistic','sqlmin!LogInfoIter::GetNext')
$currentCore=@($core|Where-Object{$currentFunctions -contains $_});$copiedCore=@($core|Where-Object{$copiedFunctions -contains $_})
$nativeEvidence=@((Rel $nativeLog),(Rel $discoverLog))
if($pTrack-and$worker-and$task-and$schedulerId-ne$null){Set-Check 'ptrack_recovery' 'completed' $nativeEvidence "callback ~$callbackTid frame $callbackFrame recovered pTrack $pTrack";Set-Check 'ptrack_validation' 'completed' $nativeEvidence "pTrack maps to worker $worker, task $task, OS TID $osTid, scheduler $schedulerId"}else{Set-Check 'ptrack_recovery' 'unavailable-with-evidence' $nativeEvidence 'Native callback output did not expose all pTrack locals.';Set-Check 'ptrack_validation' 'unavailable-with-evidence' $nativeEvidence 'Native pTrack identity chain was incomplete.'}
if($nativePass-ne$null-and$nativeWallMs-gt0){Set-Check 'timing_cpu' 'completed' $nativeEvidence "pass=$nativePass diagnosedPass=$diagnosedPass wall=${nativeWallMs}ms workerCPU=$($nativeKernelMs+$nativeUserMs)ms"}else{Set-Check 'timing_cpu' 'unavailable-with-evidence' $nativeEvidence 'Native timing fields were incomplete.'}
if($currentFunctions.Count-gt0){Set-Check 'current_stack' 'completed' $nativeEvidence "current stack captured for ~$offender; core path: $($currentCore -join ' -> ')"}else{Set-Check 'current_stack' 'unavailable-with-evidence' $nativeEvidence 'Current stack could not be parsed.'}
if($copiedFunctions.Count-gt0){Set-Check 'copied_stack' 'completed' $nativeEvidence "first-detected copied stack captured; core path: $($copiedCore -join ' -> ')"}else{Set-Check 'copied_stack' 'unavailable-with-evidence' $nativeEvidence 'Copied stack could not be parsed.'}

# Step 5: incident ring, scheduler inventory, and task/query correlation.
$schedRing=Join-Path $OverallDir "txt_detail\${CaseId}_SOSRingBuffers.EnumerateSchedulerMonitorRecords.txt"
$eventRows=@(Parse-PipeRows $schedRing|Where-Object{[string]$_.m_event-match'NONYIELD|STUCK_DISPATCHER'})
$event=if($schedulerId-ne$null){$eventRows|Where-Object{[string]$_.m_scheduler_id-match"^$schedulerId\("}|Select-Object -First 1}else{$eventRows|Select-Object -First 1}
if($event){Set-Check 'scheduler_monitor_event' 'completed' @((Rel $schedRing)) "$($event.m_event); scheduler $($event.m_scheduler_id); worker $($event.m_worker); SQL $($event.m_process_utilization); idle $($event.m_system_idle); worker utilization $($event.m_worker_utilization)"}else{Set-Check 'scheduler_monitor_event' 'unavailable-with-evidence' @((Rel $schedRing)) 'No matching NONYIELD/STUCK_DISPATCHER row was parsed.'}
$schedulers=Join-Path $OverallDir "${CaseId}_sys.schedulers.txt";$tasksStats=Join-Path $OverallDir "${CaseId}_tasks_stats.json"
$schedulerLine=if(Test-Path $schedulers){Get-Content $schedulers|Where-Object{$_-match"^0x\S+\s+\d+\s+$schedulerId\s+"}|Select-Object -First 1}else{$null}
if($schedulerLine){Set-Check 'scheduler_inventory' 'completed' @((Rel $schedulers),(Rel $tasksStats)) "affected scheduler $schedulerId row and task pivot retained"}else{Set-Check 'scheduler_inventory' 'unavailable-with-evidence' @((Rel $schedulers),(Rel $tasksStats)) 'Affected scheduler row was not parsed.'}
$taskFieldsPath=Join-Path $OverallDir 'task_fields.json';$tsqlJsonPath=Join-Path $OverallDir "${CaseId}_tsqlstack.json"
$taskFields=@(Get-Content -LiteralPath $taskFieldsPath -Raw -Encoding UTF8|ConvertFrom-Json);$taskRow=$taskFields|Where-Object{[int]$_.main.tid-eq$offender}|Select-Object -First 1
$tsqlDoc=Get-Content -LiteralPath $tsqlJsonPath -Raw -Encoding UTF8|ConvertFrom-Json;$tsqlRow=@($tsqlDoc.threads|Where-Object{[int]$_.tid-eq$offender}|Select-Object -First 1)
$spid=if($taskRow){$taskRow.main.spid}else{$null};$sqlText=if($tsqlRow.Count){[string]$tsqlRow[0].rawBefore}else{''}
$queryEvidence=@((Rel $taskFieldsPath),(Rel $tsqlJsonPath))
if($spid-and$sqlText){Set-Check 'task_query_correlation' 'completed' $queryEvidence "offender ~$offender -> SPID $spid; T-SQL decoded"}else{Set-Check 'task_query_correlation' 'unavailable-with-evidence' $queryEvidence 'Task/SPID or T-SQL correlation was incomplete.'}

# Emit structured findings consumed by route and final reports.
$findings=[ordered]@{
    caseId=$CaseId;route='Scheduler / non-yield';generatedAt=(Get-Date).ToString('o');executionOrigin='Automated Gate C run_non_yield_route.ps1 execution'
    dscript=[ordered]@{script=$dscript;status=if($dscriptPartial){'partial'}else{'completed'};offender=$offender;passes=$passes;wallMs=$wallMs;kernelMs=$kernelMs;userMs=$userMs;raw=(Rel $dscriptLog);console=if(Test-Path $dscriptConsole){Rel $dscriptConsole}else{$null}}
    callback=[ordered]@{debuggerThread=$callbackTid;frame=$callbackFrame;pTrack=$pTrack;worker=$worker;task=$task;osTid=$osTid;schedulerId=$schedulerId;pass=$nativePass;diagnosedPass=$diagnosedPass}
    timing=[ordered]@{wallMs=$nativeWallMs;kernelMs=$nativeKernelMs;userMs=$nativeUserMs;workerCpuMs=[math]::Round($nativeKernelMs+$nativeUserMs,3)}
    schedulerMonitor=if($event){[ordered]@{event=[string]$event.m_event;time=[string]$event.m_time_stamp;scheduler=[string]$event.m_scheduler_id;worker=[string]$event.m_worker;processUtilization=[string]$event.m_process_utilization;systemIdle=[string]$event.m_system_idle;workerUtilization=[string]$event.m_worker_utilization}}else{$null}
    currentStack=[ordered]@{functions=$currentFunctions;corePath=$currentCore;raw=$currentBlock}
    copiedStack=[ordered]@{functions=$copiedFunctions;corePath=$copiedCore;raw=$copiedBlock}
    sameCorePath=(@($currentCore).Count-eq$core.Count-and@($copiedCore).Count-eq$core.Count)
    execution=[ordered]@{spid=$spid;task=$task;worker=$worker;debuggerThread=$offender;windowsTid=$osTid;schedulerId=$schedulerId;sql=$sqlText}
    schedulerInventory=[ordered]@{rawLine=$schedulerLine;artifact=(Rel $schedulers);taskStats=(Rel $tasksStats)}
    evidence=[ordered]@{native=(Rel $nativeLog);frameDiscovery=(Rel $discoverLog);dscript=(Rel $dscriptLog);schedulerRing=(Rel $schedRing);taskFields=(Rel $taskFieldsPath);tsql=(Rel $tsqlJsonPath)}
}
$out=Join-Path $AnalysisDir "${CaseId}_non_yield_findings.json";Write-Utf8 $out ($findings|ConvertTo-Json -Depth 20)

# Optional Gate C continuation. It is deliberately fail-open: the canonical
# Scheduler/non-yield findings above remain authoritative and report generation
# continues even if the new cdb/MEX Spinlock extension is missing or fails.
$spinFailure = Join-Path $AnalysisDir "${CaseId}_spinlock_owner_sweep_failure.txt"
try {
    if (-not (Test-Path -LiteralPath $SpinlockSweepScript -PathType Leaf)) { throw "optional Spinlock sweep script missing: $SpinlockSweepScript" }
    $global:LASTEXITCODE = 0
    & $SpinlockSweepScript -CaseId $CaseId -Dump $Dump -AnalysisDir $AnalysisDir -MexPath $MexPath -Findings $out -Ledger $Ledger -Cdb $Cdb -SymPath $SymPath -TimeoutSec ([math]::Max($TimeoutSec,1200))
    $spinExit = $LASTEXITCODE
    if (-not $? -or $spinExit -ne 0) { throw "optional Spinlock owner sweep returned exit code $spinExit" }
} catch {
    $spinError = $_.Exception.Message
    $failureText = @"
Optional Gate C Spinlock owner sweep unavailable with evidence
Case: $CaseId
Time: $((Get-Date).ToString('o'))
Script: $SpinlockSweepScript
Error: $spinError

The pre-existing Scheduler/non-yield analysis, Gate C route reports, and final
root-cause report remain valid. This optional extension is fail-open by design.
"@
    Write-Utf8 $spinFailure $failureText
    try {
        $fallbackFindings = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
        $fallbackHandoff = [pscustomobject][ordered]@{
            status='unavailable-with-evidence';command='!us -l -i Spinlock'
            preconditionMet=(@($currentFunctions | Where-Object { [string]$_ -match '(?i)Spinlock' }).Count -gt 0 -and @($copiedFunctions | Where-Object { [string]$_ -match '(?i)Spinlock' }).Count -gt 0)
            error=$spinError;failureEvidence=(Rel $spinFailure);report=$null;json=$null;locks=@()
        }
        $fallbackFindings | Add-Member -NotePropertyName spinlockOwnerSweep -NotePropertyValue $fallbackHandoff -Force
        $fallbackTemp = "$out.tmp"
        Write-Utf8 $fallbackTemp ($fallbackFindings | ConvertTo-Json -Depth 30)
        [IO.File]::Move($fallbackTemp,$out,$true)
    } catch {
        [IO.File]::AppendAllText($spinFailure,"`r`nFindings handoff update also failed: $($_.Exception.Message)`r`n",[Text.UTF8Encoding]::new($false))
    }
    foreach ($optionalCheck in @('spinlock_thread_inventory','spinlock_owner_validation')) {
        try { Set-Check $optionalCheck 'unavailable-with-evidence' @((Rel $spinFailure)) "Optional Spinlock extension failed; base route preserved. $spinError" }
        catch { [IO.File]::AppendAllText($spinFailure,"Check update failed for ${optionalCheck}: $($_.Exception.Message)`r`n",[Text.UTF8Encoding]::new($false)) }
    }
    Write-Warning "Optional Spinlock owner sweep failed without blocking the base route: $spinError"
}

Write-Host "[run_non_yield_route] completed offender=~$offender callback=~$callbackTid frame=$callbackFrame scheduler=$schedulerId -> $out" -ForegroundColor Green
exit 0
