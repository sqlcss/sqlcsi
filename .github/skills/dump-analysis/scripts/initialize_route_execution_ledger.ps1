# initialize_route_execution_ledger.ps1
# Gate C initializer: consume Gate B branch hints and create required deep-dive checks.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$BranchJson,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Out = '',
    [string[]]$AdditionalRoute = @(),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $OutDir "${CaseId}_route_execution_ledger.json" }
if (-not (Test-Path -LiteralPath $BranchJson -PathType Leaf)) { throw "branch JSON not found: $BranchJson" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
if ((Test-Path -LiteralPath $Out) -and -not $Force) { throw "route ledger exists; use -Force: $Out" }
$branch = Get-Content -LiteralPath $BranchJson -Raw -Encoding UTF8 | ConvertFrom-Json

function Check([string]$description,[string]$action = '') {
    return [ordered]@{required=$true;status='pending';description=$description;action=if($action){$action}else{$description};evidence=@();note=''}
}
function OptionalCheck([string]$description,[string]$action = '') {
    return [ordered]@{required=$false;status='pending';description=$description;action=if($action){$action}else{$description};evidence=@();note='Optional extension: failure or absence does not block the base route.'}
}
function RouteSpec([string]$name) {
    switch ($name) {
        'Exception / AV / dump reason' {
            return [ordered]@{
                exception_context = Check 'Resolve dump reason, stored/current exception context, and callback/faulting thread.'
                current_stack = Check 'Capture the relevant current stack and classify AV/assert/non-exception dump semantics.'
                exception_history = Check 'Correlate exception ring history by time/task without treating history volume as cause.'
            }
        }
        'Scheduler / non-yield' {
            return [ordered]@{
                dscript_non_yield_analysis = Check 'Run DScript non_yield_analysis.js and retain complete or partial output.' '!dscript.run <dscript_path>\non_yield_analysis.js; record offender, pass count, wall/kernel/user time, and any minidump read/symbol limitation.'
                scheduler_monitor_event = Check 'Capture the matching NONYIELD/STUCK_DISPATCHER SchedulerMonitor record and incident identity.' '!execute SOSRingBuffers.EnumerateSchedulerMonitorRecords; filter NONYIELD/STUCK_DISPATCHER and record scheduler, worker, utilization, and timestamp.'
                ptrack_recovery = Check 'Recover SchedulerMonitor::Track from the callback frame.' '~<callback-thread>s; inspect callback stack; switch to SQL_SOSNonYieldSchedulerCallback frame; dv /t /v to recover local pTrack.'
                ptrack_validation = Check 'Validate pTrack -> worker -> scheduler and correlate task, OS TID, scheduler, SPID.' 'dx -r3 pTrack; follow m_pWorker to task/scheduler/system-thread and compare the scheduler pointer/ID with the scheduler inventory.'
                timing_cpu = Check 'Extract pass/diagnosedPass, wall-clock and worker CPU deltas, and preemptive state.' 'Read pTrack m_pass, m_diagnosedPass, m_sysDiff.m_WallClockTime, m_workerDiff Kernel/User times, and worker status; convert timing units.'
                current_stack = Check 'Capture the offending thread current stack.' '~<offending-thread>s; kv; !mex.t <thread>; inspect spin/acquisition frame locals.'
                copied_stack = Check 'Capture first-detected copied stack or retain explicit unavailable evidence.' '.cxr @@(&sqlmin!g_copiedStackInfo.threadContext); kv; .cxr; compare first-detected copied stack with current stack.'
                spinlock_thread_inventory = OptionalCheck 'If current and copied stacks both contain spinlock acquisition, count every current Spinlock stack in the dump.' 'Run !us -l -i Spinlock directly under cdb/MEX; reconcile all group counts and retain every debugger/OS thread pair.'
                spinlock_owner_validation = OptionalCheck 'For every current spinlock waiter, resolve all lock addresses and nominal owner payloads without treating a TID alone as the actual holder.' 'Discover every SpinToAcquire frame; extract this; group waiters by lock; decode each lock qword; resolve nominal owner with ~~[OS_TID]s and !mex.t; capture and classify owner stacks.'
                scheduler_inventory = Check 'Inspect scheduler runnable/work queue, active worker, pending tasks, and yield state.' 'Run sys.schedulers.js or Schedulers.Enumerate plus Tasks.Enumerate; inspect the affected scheduler row and task-state pivot.'
                task_query_correlation = Check 'Correlate worker/task to task.js and decoded T-SQL context.' 'Run task.js and tsqlstack.js on the offending thread; inspect operator locals to correlate SPID, task, SQL text, and database/object context.'
            }
        }
        'Memory / OOM / leak' {
            return [ordered]@{
                oom_markers = Check 'Inspect OOM rings and dump reason for an OOM-specific predicate.'
                node_clerk_inventory = Check 'Capture MemoryNodes and top MemoryClerks, retaining unavailable evidence as needed.'
                object_leak_inventory = Check 'Capture MemoryObjects and LeakedAllocations or explicit unavailable evidence.'
                trigger_correlation = Check 'Correlate memory evidence to dump time instead of using historical rows alone.'
            }
        }
        'Query execution' {
            return [ordered]@{
                task_session_identity = Check 'Correlate task/session/SPID and main/child workers.'
                input_sql = Check 'Capture DbccInputBuffers or DScript tsqlstack input text.'
                plan_tree = Check 'Capture QueryPlans/QueryExecutionTrees or explicit unavailable evidence.'
                operator_context = Check 'Identify the active operator and statement location.'
            }
        }
        'Blocking / latch / locking' {
            return [ordered]@{
                contention_class = Check 'Identify lock/latch/spinlock class and resource address.'
                waiter_stack = Check 'Capture waiter stack and acquisition/backoff path.'
                raw_layout = Check 'Validate private-symbol field layout and raw lock/latch bytes.'
                owner_identity = Check 'Decode owner identity using the correct namespace and map the actual OS thread.'
                owner_stack = Check 'Capture and classify the nominal/actual owner thread stack.'
                task_query_database = Check 'Correlate waiter/owner to task, SPID, query, and database/object context.'
                parent_object = Check 'Validate containing-object address/lifetime; reject incoherent casts.'
                wait_surfaces = Check 'Inspect WaitingTask, blocked-process, latch-page, and spinlock-backoff surfaces, including zero/unavailable results.'
                source_semantics = Check 'Ground acquisition/release and protected-scope semantics in matching source when state is anomalous.'
            }
        }
        'HADR / AG' {
            return [ordered]@{
                ar_state = Check 'Inspect current AR roles/exceptions and HADR manager state.'
                db_state = Check 'Inspect database manager state/API/commit ring transitions.'
                transport_lease = Check 'Inspect transport and lease-worker evidence.'
                time_correlation = Check 'Correlate HADR records to dump time; do not route from stale normal history.'
            }
        }
        'IO / storage / transaction log' {
            return [ordered]@{
                pending_io = Check 'Inspect PendingIOs/all_ios or explicit minidump-unavailable evidence.'
                io_stacks = Check 'Capture IO-related task/thread stacks and waits.'
                file_database = Check 'Map IO to database/file/log manager context.'
                latency_trigger = Check 'Correlate IO latency/state to dump trigger rather than a single background wait.'
            }
        }
        'SQLPAL / Linux' {
            return [ordered]@{
                platform_shape = Check 'Confirm Linux/core/archive and SQLPAL module shape.'
                sqlpal_context = Check 'Run SqlpalDebuggerTool workflow and retain generated context.'
            }
        }
        default {
            return [ordered]@{
                general_context = Check 'Run general dump triage and preserve the relevant current stack and server state.'
            }
        }
    }
}
function KeyOf([string]$name) { return (($name.ToLowerInvariant() -replace '[^a-z0-9]+','_').Trim('_')) }

$selected = @($branch.buckets | Where-Object routingStatus -eq 'route-signal')
foreach ($routeName in @($AdditionalRoute)) {
    if (-not $routeName) { continue }
    if (@($selected | Where-Object name -eq $routeName).Count -eq 0) {
        $selected += [pscustomobject]@{
            name=$routeName
            routingStatus='route-signal'
            routingReason='Explicitly requested by the user in addition to Gate B routing.'
            downstreamRoute='user-selected dump-analysis route'
            selectionOrigin='user-explicit'
        }
    }
}
if ($selected.Count -eq 0) {
    $selected = @([pscustomobject]@{
        name='General triage'; routingStatus='route-signal'; routingReason='No branch-specific route signal was selected; execute general dump triage.'; downstreamRoute='general dump-analysis route'
    })
}
$routes = [ordered]@{}
foreach ($bucket in $selected) {
    $key = KeyOf ([string]$bucket.name)
    $routes[$key] = [ordered]@{
        name = [string]$bucket.name
        selectionReason = [string]$bucket.routingReason
        downstreamRoute = [string]$bucket.downstreamRoute
        selectionOrigin = if ($bucket.PSObject.Properties.Name -contains 'selectionOrigin') { [string]$bucket.selectionOrigin } else { 'Gate B route-signal' }
        required = $true
        status = 'pending'
        executionOrigin = 'post-Gate-B route execution'
        checks = RouteSpec ([string]$bucket.name)
    }
}
$groups = @()
$routeNames = @($selected.name)
if ($routeNames -contains 'Scheduler / non-yield' -and $routeNames -contains 'Blocking / latch / locking') {
    $groups += [ordered]@{
        name='scheduler_spinlock_non_yield'
        routes=@('scheduler_non_yield','blocking_latch_locking')
        strategy='Combined deep dive: recover pTrack/current+copied stack, then decode the contention resource and owner.'
    }
}
$ledger = [ordered]@{
    caseId=$CaseId
    gate='Gate C — dump-analysis route execution'
    initializedAt=(Get-Date).ToString('o')
    sourceBranchJson=[System.IO.Path]::GetFullPath($BranchJson)
    sourceBranchSha256=(Get-FileHash -LiteralPath $BranchJson -Algorithm SHA256).Hash
    selectedRouteCount=$routes.Count
    terminalStatuses=@('completed','completed-with-limitations','unavailable-with-evidence')
    executionGroups=$groups
    routes=$routes
}
[System.IO.File]::WriteAllText($Out, ($ledger | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
Write-Host "[initialize_route_execution_ledger] selected=$($routes.Count) routes=$($routes.Keys -join ', ') -> $Out"
exit 0
