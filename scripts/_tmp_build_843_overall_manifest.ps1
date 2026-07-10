Add-Type -AssemblyName System.Web
$ov = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall'
$reports = "$ov\dumpviewer_out\Reports"
$ws = Get-Content "$ov\2607030030000843_worker_states.json" -Raw | ConvertFrom-Json
$tag = @{ IDLE='t-idle'; SUSPENDED='t-sus'; RUNNABLE='t-rbl'; RUNNING='t-run'; SYSTEM='t-idle'; OTHER='t-idle' }
$trows = @()
foreach ($r in $ws.rows) {
    $waitHtml = [System.Web.HttpUtility]::HtmlEncode("$($r.TopWaits)")
    $trows += ,@(
        @{ html = "<span class='tag $($tag[$r.State])'>$($r.State)</span>" },
        "$($r.Stacks)",
        "$($r.Threads)",
        "$($r.Pct)%",
        @{ html = "<span class='mono' style='font-size:12px'>$waitHtml</span>" }
    )
}

# ---- Load ThreadDetails for per-thread enrichment (state/wait/task/stack) ----
$td = Get-Content "$ov\parsed\threaddetails.json" -Raw | ConvertFrom-Json
function Get-ThrState($wsv, $wait) {
    $s = "$wsv".Trim()
    if (-not $s) { return 'SYSTEM' }
    switch ($s) {
        'WORKER_STATE_RUNNING'   { return 'RUNNING' }
        'WORKER_STATE_RUNNABLE'  { return 'RUNNABLE' }
        'WORKER_STATE_SUSPENDED' { if ("$wait".Trim() -eq 'PWAIT_SOS_WORK_DISPATCHER') { return 'IDLE' } else { return 'SUSPENDED' } }
        default { return 'OTHER' }
    }
}
$stateTag = @{ RUNNING='t-run'; RUNNABLE='t-rbl'; SUSPENDED='t-sus'; IDLE='t-idle'; SYSTEM='t-idle'; OTHER='t-idle' }
$rowById = @{}
foreach ($r in $td.rows) { $rowById["$($r.thread_id)"] = $r }

$invStyle = @"
<style>
.tcat details{margin:2px 0}
.tcat>details>summary{cursor:pointer;color:var(--accent);font-weight:600;padding:5px 0;font-size:13px}
.tcat .thr{margin:2px 0 2px 16px}
.tcat .thr>summary{cursor:pointer;font-size:12px;color:var(--text)}
.tcat .thr pre{margin:4px 0 8px;white-space:pre-wrap}
.tid{color:var(--teal);font-weight:600}
.tmeta{color:var(--dim);font-size:11px}
.chip{display:inline-block;background:#2b2b40;border:1px solid var(--border);border-radius:10px;padding:1px 8px;margin:2px;font-size:11px}
</style>
"@

# ---- 表 2 · 线程功能分类 + inline stacks ONLY for categorized threads (NO external links) ----
$catDefs = @(
    @{ key='nony'; file='NonYieldThreads.html';   label='未让出调度 (NonYield)';   note='调度器未让出——潜在 hang/spin' }
    @{ key='exc';  file='ExceptionThreads.html';  label='触发异常 (Exception)';    note='线程栈中命中异常处理' }
    @{ key='lat';  file='LatchThreads.html';      label='闩锁相关 (Latch)';        note='正在做 latch 获取/等待' }
    @{ key='busy'; file='BusyThreads.html';       label='忙碌线程 (Busy)';         note='非空闲、正在执行工作' }
    @{ key='par';  file='InParallelThreads.html'; label='并行执行 (Parallel)';     note='并行查询 worker' }
    @{ key='fio';  file='FileIOThreads.html';     label='文件 I/O (File I/O)';     note='正在做文件读写' }
    @{ key='nio';  file='NetworkIOThreads.html';  label='网络 I/O (Network I/O)';  note='正在做网络收发' }
    @{ key='iocp'; file='IOCPThreads.html';       label='IOCP 线程';               note='I/O 完成端口线程' }
    @{ key='bak';  file='BackupThreads.html';     label='备份操作 (Backup)';       note='备份/还原相关' }
    @{ key='chk';  file='CheckpointThreads.html'; label='检查点 (Checkpoint)';     note='CHECKPOINT worker' }
    @{ key='lw';   file='LazyWriterThreads.html'; label='惰性写入 (LazyWriter)';   note='LazyWriter / 内存清理' }
    @{ key='mon';  file='MonitorThreads.html';    label='监视器线程 (Monitor)';    note='调度器/资源监视器' }
)

function Get-ThrCallStack($r) {
    # authoritative ThreadDetails stack when available; else empty
    if ($r) { return "$($r.call_stack)" } else { return '' }
}

$catRows  = @()
$catParts = @($invStyle, "<div class='tcat'>")
$catUnion = @{}   # unique categorized thread ids (for count)
foreach ($c in $catDefs) {
    $htmlPath = Join-Path $reports $c.file
    $ids = @()
    if (Test-Path $htmlPath) {
        $chtml = Get-Content $htmlPath -Raw
        $sc = [regex]::Match($chtml, "src='([^']*_json\.js)'").Groups[1].Value
        $scPath = Join-Path $reports $sc
        if ($sc -and (Test-Path $scPath)) {
            $ctxt = Get-Content $scPath -Raw
            if (-not [string]::IsNullOrWhiteSpace($ctxt)) {
                $ids = @([regex]::Matches($ctxt, '(?m)^\s{2}\[\s*(\d+)\s*,') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object)
            }
        }
    }
    $n = $ids.Count
    # 表 2 chips link to this category's OWN inline anchors (unique per category+thread)
    $anchors = if ($n -gt 0) { (($ids | ForEach-Object { "<a class='chip' href='#thr-$($c.key)-$_'>tid $_</a>" }) -join ' ') } else { "<span class='dim'>—</span>" }
    $catRows += ,@(
        @{ html = "<b>$([System.Web.HttpUtility]::HtmlEncode($c.label))</b>" },
        "$n",
        @{ html = $anchors },
        [System.Web.HttpUtility]::HtmlEncode($c.note)
    )
    # inline: full stacks for this category's threads, grouped under the category
    if ($n -gt 0) {
        $catParts += "<details open><summary>$([System.Web.HttpUtility]::HtmlEncode($c.label)) &mdash; $n 线程</summary>"
        $catParts += "<div class='dim' style='font-size:11px;margin:2px 0 4px'>$([System.Web.HttpUtility]::HtmlEncode($c.note))</div>"
        foreach ($tid in $ids) {
            $catUnion["$tid"] = $true
            $r     = $rowById["$tid"]
            $st    = if ($r) { Get-ThrState $r.worker_state $r.worker_last_wait } else { 'OTHER' }
            $tag   = $stateTag[$st]
            $wait  = if ($r) { "$($r.worker_last_wait)".Trim() } else { '' }
            $tstat = if ($r) { "$($r.task_state)".Trim() } else { '' }
            $meta  = if ($r) { "sched $($r.scheduler_id) · os tid $($r.sys_thread_id)" } else { '' }
            if ($wait)  { $meta += " · wait=$([System.Web.HttpUtility]::HtmlEncode($wait))" }
            if ($tstat) { $meta += " · task=$([System.Web.HttpUtility]::HtmlEncode($tstat))" }
            $stack = [System.Web.HttpUtility]::HtmlEncode((Get-ThrCallStack $r))
            $catParts += "<details class='thr' id='thr-$($c.key)-$tid'><summary><span class='tid'>tid $tid</span> <span class='tag $tag'>$st</span> <span class='tmeta'>$meta</span></summary><pre>$stack</pre></details>"
        }
        $catParts += "</details>"
    } else {
        $catParts += "<details><summary>$([System.Web.HttpUtility]::HtmlEncode($c.label)) &mdash; 0 线程</summary><div class='dim' style='font-size:12px'>无匹配线程(健康)</div></details>"
    }
}
$catParts += "</div>"
$catHtml = ($catParts -join "`n")
$catUnionCount = $catUnion.Keys.Count

# ---- 第二步 · Tasks.Enumerate (PRIMARY / DumpViewer Tasks 侧栏) ----
$tbl2Html  = Get-Content "$ov\parsed\2607030030000843_tbl2_state_summary.html" -Raw -Encoding UTF8
$tbl3Html  = Get-Content "$ov\parsed\2607030030000843_tbl3_scheduler_pivot.html" -Raw -Encoding UTF8
$tstats    = Get-Content "$ov\2607030030000843_tasks_stats.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$tTotalRows  = [int]$tstats.totalRows
$tBound      = [int]$tstats.totalBound
$tNull       = $tTotalRows - $tBound

$step2 = [ordered]@{
    h2     = '第二步 · SQLOS 任务级权威状态(Tasks.Enumerate)'
    blocks = @(
        @{ type='note'; html="本步以 <b>DumpViewer Tasks 侧栏</b>(=<code>MiniDumpData</code> 任务枚举,等价 <code>!execute Tasks.Enumerate</code> 的权威口径,<b>非</b> <code>task.js</code> 过滤子集)枚举 SQLOS 任务级状态。共 <b>$tTotalRows</b> 行,其中 <b>$tBound</b> 行为已绑定 worker 的真实任务,<b>$tNull</b> 行为 <code>nullptr</code> 占位(未绑定/已回收,已从下方状态分母剔除)。<b>纯客观列举:不判断 RUNNABLE 积压是否代表 CPU 压力,不标注 culprit。</b>完整 $tTotalRows 行任务清单见 <a href='2607030030000843_tasks.html'>任务级明细页 &rsaquo;</a>。" }
        ,@{ type='h3'; text='表 2 · SQLOS 任务级状态汇总(分母=已绑定任务)' }
        ,@{ type='raw'; html=$tbl2Html }
        ,@{ type='h3'; text='表 3 · 按调度器分布(SchedulerId 透视,隐藏/系统 id≥1048576 聚合)' }
        ,@{ type='raw'; html=$tbl3Html }
    )
}

# ---- 第三步 · 执行语句线程统计(process_commands_internal · 基于线程的 task.js/tsqlstack.js 回退法,方法保持不变) ----
$se = Get-Content "$ov\2607030030000843_sql_exec_manifest.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$seThreads = @($se.sections[0].threads)
$seCardMain  = ($se.cards | Where-Object { $_.k -eq '执行语句主线程' }).v
$seCardChild = ($se.cards | Where-Object { $_.k -eq '并行子线程' }).v
$seStateTag = @{ run='t-run'; rbl='t-rbl'; susp='t-sus'; idle='t-idle' }
$seRun = 0; $seSusp = 0; $seRows = @()
foreach ($t in $seThreads) {
    $meta = "$($t.meta)"
    $spid = ([regex]::Match($meta, '<b>SPID</b>\s*<code>([^<]*)</code>')).Groups[1].Value
    $wait = ([regex]::Match($meta, '<b>Wait</b>\s*<code>([^<]*)</code>')).Groups[1].Value
    $scls = ([regex]::Match($meta, '<b>语句类</b>\s*<code>([^<]*)</code>')).Groups[1].Value
    $elap = ([regex]::Match($meta, '<b>Elapsed</b>\s*(.*?)\s*&nbsp;·&nbsp;\s*<b>CPU</b>')).Groups[1].Value
    $cpu  = ([regex]::Match($meta, '<b>CPU</b>\s*(.*)$')).Groups[1].Value
    $tagCls = $seStateTag["$($t.statusTag)"]; if (-not $tagCls) { $tagCls = 't-idle' }
    $stText = "$($t.statusText)" -replace '^[^\w]*\s*',''
    if ($t.statusTag -eq 'run')  { $seRun++ }
    if ($t.statusTag -eq 'susp') { $seSusp++ }
    $seRows += ,@(
        @{ html = "<span class='mono'>$([System.Web.HttpUtility]::HtmlEncode("$($t.tid)"))</span>" },
        @{ html = "<span class='mono'>$([System.Web.HttpUtility]::HtmlEncode($spid))</span>" },
        @{ html = "<span class='tag $tagCls'>$([System.Web.HttpUtility]::HtmlEncode($stText))</span>" },
        @{ html = "<span class='mono' style='font-size:12px'>$([System.Web.HttpUtility]::HtmlEncode($wait))</span>" },
        @{ html = "<code>$([System.Web.HttpUtility]::HtmlEncode($scls))</code>" },
        [System.Web.HttpUtility]::HtmlEncode($elap),
        [System.Web.HttpUtility]::HtmlEncode($cpu)
    )
}
$seTotal = $seThreads.Count
$seStateRows = @(
    ,@( @{ html="<span class='tag t-run'>RUNNING</span>" }, "$seRun",  ([math]::Round(100.0*$seRun/$seTotal,1).ToString()+'%') )
    ,@( @{ html="<span class='tag t-sus'>SUSPENDED</span>" }, "$seSusp", ([math]::Round(100.0*$seSusp/$seTotal,1).ToString()+'%') )
    ,@( @{ html="<b>合计</b>" }, "<b>$seTotal</b>", '<b>100%</b>' )
)

$step3 = [ordered]@{
    h2     = '第三步 · 执行语句线程统计(process_commands_internal)'
    blocks = @(
        @{ type='note'; html="本步用<b>基于线程的回退法</b>(<code>task.js</code> 扫描 + <code>tsqlstack.js</code> 解码,<b>方法保持不变</b>)枚举正在执行 T-SQL 的用户线程:主线程 = 调用栈含 <code>process_commands_internal</code>;子线程 = <code>SubprocEntrypoint</code>(并行查询 worker)。共 <b>$seCardMain</b> 个执行语句主线程 + <b>$seCardChild</b> 个并行子线程。过滤 minidump 限制下,部分语句文本(<code>CStmtInsert</code> 等)未随转储捕获(<code>tsqlstack.js</code> 返回 COM <code>0x80020101</code>),此处仅列举可解码内容。<b>纯客观列举,不做根因判定。</b>每线程完整 T-SQL 文本与子线程明细见 <a href='2607030030000843_sql_exec_thread.html'>执行语句线程详情页 &rsaquo;</a>。" }
        ,@{ type='h3'; text='表 4 · 执行语句主线程状态汇总(分母=14 主线程)' }
        ,@{ type='table'; cols=@('状态','线程数','占比'); colClasses=@('','num','num'); rows=$seStateRows }
        ,@{ type='h3'; text='表 5 · 执行语句主线程清单(TID / SPID / 状态 / 等待 / 语句类 / 耗时)' }
        ,@{ type='note'; html="* 标注的 Elapsed/CPU 为 worker 自创建以来的累计值(长驻/池化 worker),非单条语句耗时。完整语句文本见上方<b>详情页</b>链接。" }
        ,@{ type='table'; cols=@('线程 TID','SPID','状态','等待类型','语句类','Elapsed','CPU'); colClasses=@('num','num','','','','',''); rows=$seRows }
    )
}

$m = [ordered]@{
    title    = 'Dump 全局快照 (第一步+第二步+第三步 · PRIMARY/DumpViewer)'
    caseId   = '2607030030000843'
    subtitle = 'SQLDump0001.mdmp · SQL 2022 (16.0.4205.1) · 权威 worker_state 口径 · 纯客观列举,无根因判断'
    cards    = @(
        @{ k='Dump 来源'; v='SQLDump0001.mdmp' },
        @{ k='SQL 版本'; v='16.0.4205.1 (2022)' },
        @{ k='分析模式'; v='PRIMARY — DumpViewer' },
        @{ k='OS 线程数'; v="$($ws.totalThreads)" },
        @{ k='唯一栈'; v="$($ws.totalStacks)" }
    )
    sections = @(
        [ordered]@{
            h2     = '第一步 · 线程清单与状态统计 (权威 worker_state)'
            blocks = @(
                @{ type='h3'; text='表 1 · SQLOS Worker 状态分布(ThreadDetails.worker_state,引擎权威值)' },
                @{ type='note'; html="数据源:<b>DumpViewer ThreadDetails</b>(=<code>MiniDumpData.GetThreadDetails</code>,即 <code>SOS_Worker.m_state</code> 权威态),<b>未跑 <code>!mex.us</code></b>(PRIMARY 模式无 <code>_us.html</code>)。<code>WORKER_STATE_SUSPENDED</code> 按 <code>worker_last_wait</code> 拆分:等待 <code>PWAIT_SOS_WORK_DISPATCHER</code> 记为 <b>IDLE</b>(空闲 worker,无 task),其余记为 <b>SUSPENDED</b>(真实资源等待)。表 1 只做<b>全量状态汇总</b>;完整调用栈<b>不再内联全部 332 线程</b>,仅内联下方<b>特殊功能分类</b>命中的线程(见表 2)。全量线程明细见 DumpViewer 原生页 <a href='dumpviewer_out/Reports/ThreadDetails.html'>ThreadDetails ›</a> · <a href='dumpviewer_out/Reports/UniqueStacks.html'>UniqueStacks ›</a>。" },
                @{ type='table'; cols=@('状态分类','唯一栈','线程数','占比','代表 wait_type'); colClasses=@('','num','num','num',''); rows=$trows }
                ,@{ type='h3'; text='表 2 · 线程功能分类(DumpViewer 内建 *Threads 分组)' }
                ,@{ type='note'; html="DumpViewer 依据每个线程的调用栈签名,把 332 个 OS 线程归入若干<b>功能桶</b>(一个线程可同时命中多个桶,例如并行 worker 同时出现在 Backup 与 Parallel)。纯客观归类,<b>不含根因判断</b>。点<b>线程 ID</b> 可跳转到下方内联的完整调用栈。<code>NonYield=0</code> 表示未发现未让出调度的线程(健康信号)。" }
                ,@{ type='table'; cols=@('功能分类','线程数','线程 ID(点击跳转)','说明'); colClasses=@('','num','',''); rows=$catRows }
                ,@{ type='h3'; text="特殊分类线程完整调用栈(仅内联命中功能分类的线程 · 共 $catUnionCount 个唯一线程)" }
                ,@{ type='note'; html="只把<b>命中上述功能桶</b>的线程完整调用栈内联到此处(其余 $(332 - $catUnionCount) 个常规/空闲线程不展开,保持报告精简),按<b>功能分类</b>分组、逐线程折叠显示 <code>worker_state / scheduler_id / os tid / wait / task_state</code> 头部与<b>完整调用栈</b>(取自 DumpViewer ThreadDetails 权威数据,无外部链接)。表 2 的线程 ID 锚点指向此处。" }
                ,@{ type='raw'; html=$catHtml }
            )
        }
        ,$step2
        ,$step3
    )
    footer = 'Generated by dump-overall (PRIMARY/DumpViewer) — pure enumeration, no root cause. 第一步仅内联命中功能分类的线程;第二步任务级状态取自 DumpViewer Tasks 侧栏(等价 Tasks.Enumerate);第三步执行语句线程取自基于线程的 task.js/tsqlstack.js 回退法(方法保持不变)。第四步待续。'
}

$json = $m | ConvertTo-Json -Depth 8
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText("$ov\2607030030000843_overall_manifest.json", $json, $enc)
Write-Host "manifest bytes=$((Get-Item "$ov\2607030030000843_overall_manifest.json").Length)"
