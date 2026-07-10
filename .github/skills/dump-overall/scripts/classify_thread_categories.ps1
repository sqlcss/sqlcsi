# =============================================================================
# classify_thread_categories.ps1 — SQL-CSI dump-overall 第一步 FALLBACK classifier
#
# WHY: In PRIMARY mode, DumpViewer emits ready-made functional buckets
# (BusyThreads / LatchThreads / BackupThreads / ...) as *Threads.html sidecars.
# In FALLBACK mode we only have `!mex.us` (unique-stack) output and per-thread
# call stacks — DumpViewer's buckets do NOT exist. This script REPRODUCES the
# same 线程功能分类 from raw call stacks alone, so 第一步 表 2 can be built in
# either mode.
#
# INPUT: a JSON file that is EITHER
#   { "rows": [ { thread_id|id, call_stack|stack, worker_state?, worker_last_wait? }, ... ] }
#   or a bare array [ {...}, ... ].
# Works with:
#   - DumpViewer parsed\threaddetails.json  (PRIMARY — for validation)
#   - a FALLBACK list shredded from `!mex.us` (id + concatenated stack text)
#
# OUTPUT: JSON { generatedFrom, totalThreads, categories:[ {key,label,method,ids,note} ] }
#   method = how this bucket was derived:
#     'stack'  = reliably reproduced from call-stack signatures (parity with DumpViewer)
#     'state'  = needs worker_state (RUNNING); degrades to 'top-frame heuristic' w/o state
#     'na'     = NOT stack-derivable — needs SchedulerMonitor ring / XEvent (reported empty)
#
# EXIT: 0 ok; 1 input missing/invalid.
#
# SIGNATURE TABLE was reverse-engineered from DumpViewer's own *Threads sidecars
# on dump 2607030030000843 (SQL 2022). See repo memory dumpviewer_thread_categories.md.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ThreadsJson,
    [string]$Out
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $ThreadsJson)) { Write-Host "[classify] ERROR: input not found: $ThreadsJson" -ForegroundColor Red; exit 1 }
try { $doc = Get-Content $ThreadsJson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Host "[classify] ERROR: parse failed: $_" -ForegroundColor Red; exit 1 }

# normalize to a flat list of { id, stack, state, wait }
$rowsRaw = if ($doc -is [System.Array]) { $doc }
           elseif ($doc.PSObject.Properties.Name -contains 'rows') { $doc.rows }
           else { $doc }
$threads = @()
foreach ($r in $rowsRaw) {
    $id    = if ($null -ne $r.thread_id) { $r.thread_id } elseif ($null -ne $r.id) { $r.id } else { $null }
    $stack = if ($null -ne $r.call_stack) { "$($r.call_stack)" } elseif ($null -ne $r.stack) { "$($r.stack)" } else { '' }
    $state = "$($r.worker_state)".Trim()
    $wait  = "$($r.worker_last_wait)".Trim()
    if ($null -eq $id) { continue }
    $threads += [pscustomobject]@{ id=[int]$id; stack=$stack; state=$state; wait=$wait }
}
if ($threads.Count -eq 0) { Write-Host "[classify] ERROR: no usable threads in input" -ForegroundColor Red; exit 1 }

# -----------------------------------------------------------------------------
# Signature table. Each entry: key,label,method,regex(single-line, case-insensitive).
# regex is matched against the WHOLE call-stack text (all frames joined).
# Order matters only for readability; a thread may match MANY buckets.
# -----------------------------------------------------------------------------
$sig = @(
    @{ key='iocp'; label='IOCP 线程';               method='stack'; rx='SOS_Node::ListenOnIOCompletionPort' }
    @{ key='nio';  label='网络 I/O (Network I/O)';   method='stack'; rx='TDSSNIClient::|WaitOnWriteAsyncToFinish|flush_buffer|CTds\w*::Send|SNIWriteAsync|SNIReadAsync|Tds\w*::Read' }
    @{ key='bak';  label='备份操作 (Backup)';        method='stack'; rx='BackupThread::|BackupOperation::|BackupVirtualDeviceSet|BackupLogMediaWriter|RestoreOperation::|sqlvdi!' }
    @{ key='chk';  label='检查点 (Checkpoint)';      method='stack'; rx='Checkpoint(Helper|Loop|RU2|Worker|RU)|RegisterCheckPtWorker' }
    @{ key='lw';   label='惰性写入 (LazyWriter)';    method='stack'; rx='BPool::LazyWriter|!lazywriter\b' }
    @{ key='lat';  label='闩锁相关 (Latch)';         method='stack'; rx='LatchBase::|Latch::Acquire|::AcquireLatch|LatchWaitList' }
    @{ key='exc';  label='触发异常 (Exception)';     method='stack'; rx='KiUserExceptionDispatch|RtlDispatchException|_CxxThrowException|RaiseException|CDmpDump::|CImageHelper::DoMiniDump|SQLDumperLibraryInvoke|sqllang!stackTrace\b' }
    @{ key='mon';  label='监视器线程 (Monitor)';     method='stack'; rx='SchedulerMonitor::|ResourceMonitor::|DeadlockMonitor::|lockMonitor(Thread)?\b|SystemHealthMonitor|SQLAgentMonitorThread' }
    @{ key='par';  label='并行执行 (Parallel)';      method='stack'; rx='CXPort|CXPacket|CXTransport|CXPipe|CQScanExchange|SubprocEntrypoint' }
    @{ key='fio';  label='文件 I/O (File I/O)';      method='stack'; rx='FCB::(Async)?(Read|Write)|WriteFileGather|ReadFileScatter|AsyncDiskWorker|DiskWorker::|FileHandleAsyncIO' }
)

$cats = @()
foreach ($s in $sig) {
    $ids = @($threads | Where-Object { $_.stack -match "(?i)$($s.rx)" } | ForEach-Object { $_.id } | Sort-Object -Unique)
    $cats += [pscustomobject]@{ key=$s.key; label=$s.label; method=$s.method; ids=$ids; count=$ids.Count; note=$null }
}

# Busy = worker_state RUNNING (state-based). FALLBACK w/o state: top non-OS frame not in
# scheduler-idle set (SwitchContext/SuspendNonPreemptive waiting on dispatcher) → running work.
$busyIds = @()
$hasState = @($threads | Where-Object { $_.state }).Count -gt 0
if ($hasState) {
    $busyIds = @($threads | Where-Object { $_.state -eq 'WORKER_STATE_RUNNING' } | ForEach-Object { $_.id } | Sort-Object -Unique)
    $busyNote = 'worker_state=WORKER_STATE_RUNNING'
} else {
    # heuristic: not idle-parked on the work dispatcher
    $busyIds = @($threads | Where-Object { $_.stack -notmatch '(?i)SOS_WorkDispatcher|PWAIT_SOS_WORK_DISPATCHER|SwitchContext' -and $_.stack } | ForEach-Object { $_.id } | Sort-Object -Unique)
    $busyNote = 'FALLBACK 无 worker_state:栈顶未停在 work dispatcher 的近似判定'
}
$cats += [pscustomobject]@{ key='busy'; label='忙碌线程 (Busy)'; method='state'; ids=$busyIds; count=$busyIds.Count; note=$busyNote }

# NonYield = NOT stack-derivable. Requires SchedulerMonitor non-yield detection / long quantum
# (SOS ring buffer RING_BUFFER_SCHEDULER_MONITOR or system_health non_yield XEvent).
$cats += [pscustomobject]@{ key='nony'; label='未让出调度 (NonYield)'; method='na'; ids=@(); count=0;
    note='栈签名不可复现:需 SchedulerMonitor ring (RING_BUFFER_SCHEDULER_MONITOR) 或 system_health non_yield/ NonYieldingTask 事件。第四步交叉验证。' }

$result = [ordered]@{
    generatedFrom = (Resolve-Path $ThreadsJson).Path
    totalThreads  = $threads.Count
    hasWorkerState= $hasState
    categories    = $cats
}

# console summary
Write-Host "totalThreads=$($threads.Count)  hasWorkerState=$hasState"
foreach ($c in $cats) {
    $idsTxt = if ($c.count -gt 0) { ($c.ids -join ',') } else { '—' }
    "{0,-26} [{1,-5}] n={2,-3} {3}" -f $c.label, $c.method, $c.count, $idsTxt | Write-Host
}

if ($Out) {
    $json = $result | ConvertTo-Json -Depth 6
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Out, $json, $enc)
    Write-Host "[classify] wrote $Out"
}
exit 0
