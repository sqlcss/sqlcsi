# Overall report manifest builder for 2607030030000843
$ErrorActionPreference = 'Stop'
$cid = '2607030030000843'
$da  = "C:\Users\lduan\sqlcsi-archive\reports\${cid}_dump_code_analysis"
$do  = "C:\Users\lduan\sqlcsi-archive\reports\${cid}_dump_overall"
function HE([string]$s){ if($null -eq $s){return ''}; ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;') }
function Snip([string]$s,[int]$n=70){ if($null -eq $s){return '—'}; $t=($s -replace '\s+',' ').Trim(); if($t.Length -le $n){return $t}; return $t.Substring(0,$n)+' …' }

$us   = Get-Content "$da\..\${cid}_dump_overall\${cid}_us_states.json" -Raw | ConvertFrom-Json
$exec = Get-Content "$da\${cid}_exec_extract.json" -Raw | ConvertFrom-Json
$sm   = Get-Content "$da\${cid}_scheduler_monitor.json" -Raw | ConvertFrom-Json

# ---- 第一步 table ----
$s1rows = @()
foreach($r in $us.rows){
    $cls = switch($r.State){ 'RUNNING'{'ok'} 'SYSTEM-RUNNING'{'ok'} 'SUSPENDED'{'warn'} default{''} }
    $s1rows += ,@( @{html=(HE $r.State);class=$cls}, "$($r.Stacks)", "$([int]$r.Threads)", "$($r.Pct)%" )
}

# ---- 第二步 table ----
$order = $exec | Sort-Object @{e={ if($_.worker -eq 'WORKER_STATE_RUNNING'){0}else{1} }}, spid
$s2rows = @()
foreach($e in $order){
    $isRun = $e.worker -eq 'WORKER_STATE_RUNNING'
    $wcls = if($isRun){'ok'}else{'warn'}
    $ws = ($e.worker -replace 'WORKER_STATE_','')
    $waitTxt = if([string]::IsNullOrWhiteSpace($e.wait)){'—'}else{$e.wait}
    $tsql = if($e.tsql -and $e.tsql -ne '<CORRUPTED>'){ Snip $e.tsql } elseif($e.tsql -eq '<CORRUPTED>'){ '(文本区未捕获)' } else { '(COM 0x80020101 · 文本未捕获)' }
    $s2rows += ,@( "t$($e.tid)", "$($e.spid)", @{html=(HE $ws);class=$wcls}, (HE $waitTxt), "$($e.kids)", (HE $e.stmt), (HE $tsql) )
}

$m = [ordered]@{
    title = 'Dump 全局快照 · 三步走清单'
    caseId = $cid
    subtitle = "Case $cid · SQLDump0001.mdmp（过滤 minidump 56.7 MB）· SQL Server 2022 CU20 16.0.4205.1 · 实例 XTMSSPROD49B · AG XTMSSPROD49_AG"
    cards = @(
        @{k='转储类型';v='过滤 minidump · 56.7 MB'}
        @{k='版本';v='SQL 2022 CU20 · 16.0.4205.1'}
        @{k='总线程 / 总栈';v='332 / 74'}
        @{k='执行语句主线程';v='14'}
        @{k='并行子线程';v='4'}
        @{k='SchedulerMonitor';v='256 条 · 均 SYSTEM_HEALTH'}
    )
    sections = @(
        [ordered]@{
            h2 = '第一步 · OS 线程形态清单（mex us）'
            blocks = @(
                @{ type='note'; html='按调用栈聚合的 OS 线程状态分布。<b>只列举，不解读。</b> 明细见 <a href="'+$cid+'_us.html">线程栈全量报表</a>。' }
                @{ type='table'; cols=@('状态','唯一栈数','线程数','占比'); colClasses=@('','num','num','num'); rows=$s1rows }
                @{ type='note'; html='合计 <b>332</b> 线程 / <b>74</b> 唯一栈。IDLE(41%)+SUSPENDED(38.3%) 占多数，RUNNING 13 线程(3.9%)。' }
            )
        },
        [ordered]@{
            h2 = '第二步 · 执行语句线程（process_commands_internal）'
            blocks = @(
                @{ type='note'; html='共 <b>14</b> 个执行语句主线程 + <b>4</b> 个并行子线程。每行逐一列举 SPID / worker 状态 / 等待类型 / 子线程数 / 语句类 / 语句摘要。完整堆栈与语句文本见 <a href="'+$cid+'_sql_exec_thread.html">执行语句线程详情</a>。' }
                @{ type='table'; cols=@('线程','SPID','Worker','等待类型','子线程','语句类','语句摘要'); colClasses=@('','num','','','num','',''); rows=$s2rows }
                @{ type='note'; html='<b>⚠ 过滤 minidump 限制（如实标注）：</b> <code>Tasks.Enumerate</code> 在此过滤 minidump 上可绑定但返回 0 行（SQLOS 调度器/任务堆未随转储捕获），因此 SKILL 标准流程中的 <b>表2/表3（Tasks.Enumerate 权威计数）不可恢复</b>。本报告采用<b>基于线程的回退法</b>（task.js + tsqlstack.js 逐线程遍历）+ OS 线程形态代理。部分语句文本（CStmtInsert 等）因文本区未落盘返回 COM 0x80020101，已按“文本未捕获”列举。' }
            )
        },
        [ordered]@{
            h2 = '第三步 · SchedulerMonitor 环形缓冲'
            blocks = @(
                @{ type='table'; cols=@('项目','值'); colClasses=@('','');
                   rows=@(
                     ,@('记录数', '256')
                     ,@('事件类型', @{html='全部 <code>SMR_SYSTEM_HEALTH</code>（无 STUCK / NONYIELD / DEADLOCK）';class='ok'})
                     ,@('m_Id 范围', '94704 – 94959（连续递增，最新 94959）')
                     ,@('ProcessUtilization', @{html='6 – 9%';class='ok'})
                     ,@('SystemIdle', @{html='约 87 – 90%';class='ok'})
                     ,@('NodeId / SchedulerId', '65535 / 4294967295（系统级健康信标）')
                   ) }
                @{ type='note'; html='256 条均为例行 <code>SMR_SYSTEM_HEALTH</code> 健康信标，未出现调度器卡滞类事件；ProcessUtilization 稳定在 6–9%，SystemIdle ~88%。<b>只列举，不解读。</b> 全量 256 行见 <a href="'+$cid+'_scheduler_monitor.html">SchedulerMonitor 环形缓冲报表</a>。' }
            )
        },
        [ordered]@{
            h2 = 'DoD 完成度 & P4 说明'
            blocks = @(
                @{ type='table'; cols=@('DoD 项','状态','说明'); colClasses=@('','','');
                   rows=@(
                     ,@('第一步 线程形态清单', @{html='✅';class='ok'}, 'mex us 聚合，332 线程 5 状态')
                     ,@('第二步 执行语句线程逐一列举', @{html='✅';class='ok'}, '14 主 + 4 子，含语句类/等待/子线程数')
                     ,@('表2/表3 Tasks.Enumerate 权威计数', @{html='⚠ 例外';class='warn'}, '过滤 minidump 上不可恢复 — 已用线程回退法替代并如实标注')
                     ,@('第三步 SchedulerMonitor', @{html='✅';class='ok'}, '256 条全部列举 + 汇总')
                     ,@('子报表链接完整', @{html='✅';class='ok'}, 'us / sql_exec_thread / scheduler_monitor 三份')
                     ,@('UTF-8 + Catppuccin Mocha', @{html='✅';class='ok'}, '全部 HTML 无 BOM，深色主题')
                     ,@('只列举不解读', @{html='✅';class='ok'}, '全篇仅客观事实，无根因判定')
                   ) }
                @{ type='note'; html='<b>P4 语言/格式说明：</b> 按用户记忆偏好，生成报告前应确认语言（中文/English）与格式（HTML/Markdown）。本次用户不在线（“work autonomously”），故采用默认 <b>中文 + HTML</b>（与 SKILL 三步走结构一致），在此显式标注该决策，供用户事后复核。' }
            )
        }
    )
}
$m | ConvertTo-Json -Depth 10 | Set-Content "$do\${cid}_overall_manifest.json" -Encoding UTF8
Write-Host "wrote overall_manifest"
