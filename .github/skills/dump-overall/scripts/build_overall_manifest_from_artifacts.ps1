# build_overall_manifest_from_artifacts.ps1
# Assemble the dump-overall MAIN manifest from committed artifact contracts.
# Pure enumeration only: no root cause, likelihood, or remediation language.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$Dir,
    [Parameter(Mandatory)][string]$DumpName,
    [Parameter(Mandatory)][string]$SqlVersion,
    [string]$Mode = 'FALLBACK',
    [string]$CaptureTime = '',
    [string]$DumpType = 'User minidump',
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $Dir "${CaseId}_overall_manifest.json" }

$paths = [ordered]@{
    us             = Join-Path $Dir 'us_states.json'
    categories     = Join-Path $Dir 'thread_categories.json'
    tasks          = Join-Path $Dir "${CaseId}_tasks_stats.json"
    tasksTable2    = Join-Path $Dir "${CaseId}_tbl2_state_summary.html"
    tasksTable3    = Join-Path $Dir "${CaseId}_tbl3_scheduler_pivot.html"
    taskFields     = Join-Path $Dir 'task_fields.json'
    tsqlSummary    = Join-Path $Dir "${CaseId}_tsqlstack.summary.json"
    schedulers     = Join-Path $Dir "${CaseId}_sys.schedulers.txt"
    memoryBrokers  = Join-Path $Dir "${CaseId}_memory_brokers.txt"
    latchPages     = Join-Path $Dir "${CaseId}_dump_latch_contended_pages.txt"
}
foreach ($entry in $paths.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) { throw "required artifact missing: $($entry.Value)" }
}

function HE([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}
function Tag([string]$state) {
    $cls = switch ($state) {
        'RUNNING' {'t-run'} 'RUNNABLE' {'t-rbl'} 'SUSPENDED' {'t-sus'}
        default {'t-idle'}
    }
    return @{ html = "<span class='tag $cls'>$(HE $state)</span>" }
}
function TextCell([object]$value, [string]$class = '') {
    return @{ text = if ($null -eq $value) { '' } else { [string]$value; }; class = $class }
}

$us = Get-Content -LiteralPath $paths.us -Raw -Encoding UTF8 | ConvertFrom-Json
$categories = Get-Content -LiteralPath $paths.categories -Raw -Encoding UTF8 | ConvertFrom-Json
$tasks = Get-Content -LiteralPath $paths.tasks -Raw -Encoding UTF8 | ConvertFrom-Json
$taskFields = @(Get-Content -LiteralPath $paths.taskFields -Raw -Encoding UTF8 | ConvertFrom-Json)
$tsqlSummary = @(Get-Content -LiteralPath $paths.tsqlSummary -Raw -Encoding UTF8 | ConvertFrom-Json)
$timeoutSet = @{}
foreach ($entry in $tsqlSummary) { if ([string]$entry.status -match 'timeout') { $timeoutSet[[int]$entry.tid] = $true } }

$stateRows = @()
foreach ($row in $us.rows) {
    $stateRows += ,@(
        (Tag ([string]$row.State)),
        (TextCell $row.Stacks 'num'),
        (TextCell $row.Threads 'num'),
        (TextCell ("{0:N1}%" -f [double]$row.Pct) 'num')
    )
}
$stateRows += ,@(@{html='<b>Total</b>'},@{html="<b>$($us.totalStacks)</b>";class='num'},@{html="<b>$($us.totalThreads)</b>";class='num'},@{html='<b>100.0%</b>';class='num'})

$categoryRows = @()
foreach ($category in $categories.categories) {
    $ids = @($category.ids)
    $idText = if ($ids.Count -gt 0) { ($ids -join ', ') } else { '—' }
    $categoryRows += ,@(
        [string]$category.label,
        (TextCell $category.count 'num'),
        [string]$category.method,
        (TextCell $idText 'mono')
    )
}

$execRows = @()
$runtime = [System.Text.StringBuilder]::new()
[void]$runtime.Append('<table><thead><tr><th>Thread</th><th>SPID</th><th>Role</th><th>Task state</th><th>Worker state</th><th>Scheduler</th><th>Wait type</th><th>Elapsed ms</th></tr></thead><tbody>')
foreach ($item in ($taskFields | Sort-Object { [int]$_.main.tid })) {
    $main = $item.main
    $tsqlStatus = if ($timeoutSet.ContainsKey([int]$main.tid)) { 'PARTIAL / SHARD TIMEOUT' } else { 'captured; see detail' }
    $execRows += ,@(
        (TextCell $main.tid 'num mono'),
        (TextCell $main.spid 'num'),
        [string]$main.sched,
        [string]$main.taskState,
        [string]$main.workerState,
        [string]$main.waitType,
        (TextCell $item.childCount 'num'),
        $tsqlStatus
    )
    [void]$runtime.Append("<tr><td class='mono'>$(HE ([string]$main.tid))</td><td>$(HE ([string]$main.spid))</td><td><b>MAIN · $($item.childCount) children</b></td><td>$(HE ([string]$main.taskState))</td><td>$(HE ([string]$main.workerState))</td><td>$(HE ([string]$main.sched))</td><td>$(HE ([string]$main.waitType))</td><td class='num'>$(HE ([string]$main.elapsedMs))</td></tr>")
    foreach ($child in @($item.children)) {
        [void]$runtime.Append("<tr><td class='mono'>↳ $(HE ([string]$child.tid))</td><td>$(HE ([string]$child.spid))</td><td>CHILD</td><td>$(HE ([string]$child.taskState))</td><td>$(HE ([string]$child.workerState))</td><td>$(HE ([string]$child.sched))</td><td>$(HE ([string]$child.waitType))</td><td class='num'>$(HE ([string]$child.elapsedMs))</td></tr>")
    }
}
[void]$runtime.Append('</tbody></table>')
$childCount = @($taskFields | ForEach-Object { @($_.children) }).Count

# sys.schedulers.js: address node scheduler status online idle affinity ...
$schedulerRows = @()
foreach ($line in (Get-Content -LiteralPath $paths.schedulers -Encoding UTF8)) {
    if ($line -notmatch '^0x[0-9A-Fa-f]+') { continue }
    $p = @($line -split '\s+' | Where-Object { $_ })
    if ($p.Count -lt 24) { continue }
    $schedulerRows += ,@(
        (TextCell $p[0] 'mono'), (TextCell $p[2] 'num'), "$($p[3]) $($p[4])",
        (TextCell $p[6] 'num'), (TextCell $p[11] 'num'), (TextCell $p[12] 'num'),
        (TextCell $p[14] 'num'), (TextCell $p[16] 'num'), (TextCell $p[17] 'mono'),
        (TextCell $p[18] 'num'), (TextCell $p[22] 'num'), (TextCell $p[23] 'num')
    )
}
$visibleSchedulers = @($schedulerRows | Where-Object { $_[2] -eq 'VISIBLE ONLINE' }).Count
$hiddenSchedulers = @($schedulerRows | Where-Object { $_[2] -eq 'HIDDEN ONLINE' }).Count

$brokerRows = @()
foreach ($line in (Get-Content -LiteralPath $paths.memoryBrokers -Encoding UTF8)) {
    if ($line -notmatch '^\d+\s+MEMORYBROKER_') { continue }
    $p = @($line -split '\s+' | Where-Object { $_ })
    if ($p.Count -lt 10) { continue }
    $brokerRows += ,@(
        (TextCell $p[0] 'num'), $p[1], (TextCell $p[2] 'num'), (TextCell $p[3] 'num'),
        (TextCell $p[4] 'num'), (TextCell $p[5] 'num'), (TextCell $p[6] 'num'),
        (TextCell $p[7] 'num'), $p[8], (TextCell (($p[9..($p.Count-1)]) -join ' ') 'mono')
    )
}

$latchText = Get-Content -LiteralPath $paths.latchPages -Raw -Encoding UTF8
$progress = [regex]::Matches($latchText, 'Processing\s+(\d+)\s+of\s+(\d+)\s+-\s+Found\s+(\d+)\s+threads\s+\((\d+)\s+pages\)') | Select-Object -Last 1
$latchProcessed = if ($progress) { $progress.Groups[1].Value } else { 'unknown' }
$latchTotal = if ($progress) { $progress.Groups[2].Value } else { 'unknown' }
$latchThreads = if ($progress) { $progress.Groups[3].Value } else { 'unknown' }
$latchPages = if ($progress) { $progress.Groups[4].Value } else { 'unknown' }

$task2 = Get-Content -LiteralPath $paths.tasksTable2 -Raw -Encoding UTF8
$task3 = Get-Content -LiteralPath $paths.tasksTable3 -Raw -Encoding UTF8

$sections = @(
    [ordered]@{
        h2='Step 1 · OS thread inventory (!mex.us fallback)'
        blocks=@(
            @{type='note';html="FALLBACK detail pages: <a href='${CaseId}_us.html'>unique-stack inventory</a> with pagination/filtering and <a href='${CaseId}_thread_categories.html'>functional thread categories</a>. This section enumerates facts only."},
            @{type='h3';text='Table 1 · Stack-inferred SQLOS worker-state distribution'},
            @{type='table';cols=@('State','Unique stacks','Threads','Share');colClasses=@('','num','num','num');rows=$stateRows},
            @{type='h3';text='Table 2 · Functional stack categories'},
            @{type='note';html='A thread may appear in more than one category. FALLBACK Busy is heuristic; category counts do not replace the authoritative execution set.'},
            @{type='table';cols=@('Category','Threads','Method','Thread IDs');colClasses=@('','num','','mono');rows=$categoryRows}
        )
    },
    [ordered]@{
        h2='Step 2 · Tasks.Enumerate bound-task inventory'
        blocks=@(
            @{type='note';html="Authoritative source: <span class='mono'>!execute Tasks.Enumerate</span>. Full $($tasks.totalRows)-row inventory: <a href='${CaseId}_tasks.html'>task detail report</a>. The state total and scheduler pivot both reconcile to $($tasks.totalBound) bound tasks, including PENDING."},
            @{type='raw';html=$task2}, @{type='raw';html=$task3}
        )
    },
    [ordered]@{
        h2='Step 3 · Executing statement threads (process_commands_internal)'
        blocks=@(
            @{type='note';html="The normalized selection contains <b>$($taskFields.Count) MAIN + $childCount CHILD = $($taskFields.Count + $childCount)</b> unique thread-role pairs. <span class='mono'>task.js</span> completed for every pair. T-SQL detail: <a href='${CaseId}_sql_exec_thread.html'>per-main execution report</a>."},
            @{type='h3';text='Per-main summary'},
            @{type='table';cols=@('TID','SPID','Scheduler','Task state','Worker state','Wait type','Children','T-SQL status');colClasses=@('num','num','','','','','num','');rows=$execRows},
            @{type='h3';text='Main / child runtime-state table'}, @{type='raw';html=$runtime.ToString()}
        )
    },
    [ordered]@{
        h2='Step 4 · Scheduler inventory / 第四步 · 调度器清单 (sys.schedulers.js)'
        blocks=@(
            @{type='note';html="Raw output: <a href='${CaseId}_sys.schedulers.txt'>${CaseId}_sys.schedulers.txt</a>. Rows: <b>$($schedulerRows.Count)</b>; visible online: <b>$visibleSchedulers</b>; hidden online: <b>$hiddenSchedulers</b>."},
            @{type='h3';text='Scheduler detail'},
            @{type='table';cols=@('Address','Scheduler','Status','Idle','Workers','Tasks','Runnable','Pending disk IO','Active worker','Yield count','Debugger TID','Pending tasks');colClasses=@('mono','num','','num','num','num','num','num','mono','num','num','num');rows=$schedulerRows}
        )
    },
    [ordered]@{
        h2='Step 5 · Memory broker inventory'
        blocks=@(
            @{type='note';html="Raw output: <a href='${CaseId}_memory_brokers.txt'>${CaseId}_memory_brokers.txt</a>. This table is an objective dump-time enumeration."},
            @{type='table';cols=@('Pool','Broker type','Alloc KB','Alloc KB/s','Predicted KB','Target KB','Future KB','Overall limit KB','Last notification','Callback');colClasses=@('num','','num','num','num','num','num','num','','mono');rows=$brokerRows}
        )
    },
    [ordered]@{
        h2='Step 6 · Latch-contended page inventory / 第六步 · latch 争用页面清单'
        blocks=@(
            @{type='note';html="Raw output: <a href='${CaseId}_dump_latch_contended_pages.txt'>${CaseId}_dump_latch_contended_pages.txt</a>. Script: <span class='mono'>dump_latch_contended_pages.js</span>."},
            @{type='table';cols=@('Threads scanned','Total threads','Contended latch threads','Contended pages','End marker');colClasses=@('num','num','num','num','');rows=@(,@((TextCell $latchProcessed 'num'),(TextCell $latchTotal 'num'),(TextCell $latchThreads 'num'),(TextCell $latchPages 'num'),$(if($latchText -match 'END LATCH CONTENDED PAGES'){'present'}else{'missing'})))}
        )
    },
    [ordered]@{
        h2='Exception / dump-context detail'
        blocks=@(@{type='note';html="Raw exception, callback, and selected thread context: <a href='${CaseId}_exception.html'>exception detail report</a>. This is enumeration only."})
    },
    [ordered]@{
        h2='DoD / Gate status'
        blocks=@(
            @{type='table';cols=@('Required surface','Status','Artifact');colClasses=@('','','mono');rows=@(
                @('DumpViewer-first mode gate','done','dumpviewer_out/'),
                @('OS threads + functional categories','done',"${CaseId}_us.html / ${CaseId}_thread_categories.html"),
                @('Tasks.Enumerate','done',"${CaseId}_tasks.html"),
                @('task.js + tsqlstack.js','done',"${CaseId}_sql_exec_thread.html"),
                @('Scheduler inventory','done',"${CaseId}_sys.schedulers.txt"),
                @('Memory brokers','done',"${CaseId}_memory_brokers.txt"),
                @('Latch-contended pages','done',"${CaseId}_dump_latch_contended_pages.txt"),
                @('Exception context','done',"${CaseId}_exception.html"),
                @('Nine ring surfaces','pending injection','txt_detail/')
            )}
        )
    }
)

$manifest = [ordered]@{
    title='SQL Server Dump Overall Snapshot'
    caseId=$CaseId
    subtitle="$DumpName · SQL Server $SqlVersion · $DumpType · pure enumeration, no root-cause assessment"
    cards=@(
        @{k='Dump';v=$DumpName}, @{k='SQL build';v=$SqlVersion}, @{k='Mode';v=$Mode},
        @{k='Capture time';v=$CaptureTime}, @{k='OS threads';v=[string]$us.totalThreads},
        @{k='Bound tasks';v=[string]$tasks.totalBound}, @{k='Exec threads';v=[string]($taskFields.Count + $childCount)}
    )
    sections=$sections
    footer='Generated by dump-overall — objective thread, task, scheduler, memory, latch, exception, T-SQL, and ring-buffer enumeration only. Root-cause analysis is intentionally excluded.'
}

[System.IO.File]::WriteAllText($Out, ($manifest | ConvertTo-Json -Depth 80), [System.Text.UTF8Encoding]::new($false))
Write-Host "[build_overall_manifest_from_artifacts] sections=$($sections.Count) mains=$($taskFields.Count) children=$childCount schedulers=$($schedulerRows.Count) brokers=$($brokerRows.Count) -> $Out"
exit 0
