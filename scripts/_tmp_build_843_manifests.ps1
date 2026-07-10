# Manifest builder for case 2607030030000843 dump-overall
$ErrorActionPreference = 'Stop'
$cid = '2607030030000843'
$da  = "C:\Users\lduan\sqlcsi-archive\reports\${cid}_dump_code_analysis"
$do  = "C:\Users\lduan\sqlcsi-archive\reports\${cid}_dump_overall"
$scripts = 'C:\Users\lduan\sqlcsi\.github\skills\dump-overall\scripts'
function HE([string]$s){ if($null -eq $s){return ''}; ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;') }

$exec = Get-Content "$da\${cid}_exec_extract.json" -Raw | ConvertFrom-Json
# order for display: RUNNING first then by spid
$order = $exec | Sort-Object @{e={ if($_.worker -eq 'WORKER_STATE_RUNNING'){0}elseif($_.worker -like '*RUNNABLE*'){1}else{2} }}, spid

$fmtMs = { param($ms) if($null -eq $ms){return '—'}; if($ms -gt 100000000){ return "$([math]::Round($ms/86400000,1)) 天*" }; if($ms -ge 60000){ return "$([math]::Round($ms/60000,1)) 分" }; return "$ms ms" }

# ---------- sql_exec_manifest ----------
$runCount = @($exec | Where-Object { $_.worker -eq 'WORKER_STATE_RUNNING' }).Count
$suspCount = @($exec | Where-Object { $_.worker -like '*SUSPENDED*' }).Count
$threadCards = @()
foreach($e in $order){
    $isRun = $e.worker -eq 'WORKER_STATE_RUNNING'
    $cardCls = if($isRun){'ok'}elseif($e.worker -like '*RUNNABLE*'){'warn'}else{'no'}
    $tag = if($isRun){'run'}elseif($e.worker -like '*RUNNABLE*'){'runn'}else{'susp'}
    $waitTxt = if([string]::IsNullOrWhiteSpace($e.wait)){'（无等待 · 正在运行）'}else{$e.wait}
    $meta = "<b>SPID</b> <code>$($e.spid)</code> &nbsp;·&nbsp; <b>Worker</b> <code>$(HE $e.worker)</code> &nbsp;·&nbsp; <b>Wait</b> <code>$(HE $waitTxt)</code><br><b>语句类</b> <code>$(HE $e.stmt)</code> &nbsp;·&nbsp; <b>子线程</b> <code>$($e.kids)</code> &nbsp;·&nbsp; <b>Elapsed</b> $(& $fmtMs $e.elapsed) &nbsp;·&nbsp; <b>CPU</b> $(& $fmtMs $e.cpu)"
    $tsql = if($e.tsql -and $e.tsql -ne '<CORRUPTED>'){ $e.tsql } elseif($e.tsql -eq '<CORRUPTED>'){ '(语句文本在此过滤 minidump 中不可读 — CCompPlan 区域未捕获)' } else { "(语句文本未捕获 — tsqlstack 返回 COM 0x80020101，$($e.stmt) 的文本在过滤 minidump 中不可用)" }
    $threadCards += [ordered]@{
        tid = "$($e.tid)"; cardCls=$cardCls; statusTag=$tag
        statusText = if($isRun){'▶ RUNNING'}else{"⏸ $(($e.worker -replace 'WORKER_STATE_',''))"}
        meta = $meta
        tsqlstack = $tsql
    }
}
$sqlManifest = [ordered]@{
    title='执行语句线程详情（主线程 + 并行子线程）'
    caseId=$cid
    subtitle="Case $cid · SQLDump0001.mdmp · 过滤 minidump（56.7 MB）· 基于线程（task.js / tsqlstack.js）回退法"
    backLink="${cid}_overall_report.html"
    cards=@(
        @{k='执行语句主线程';v="$($exec.Count)";cls='accent'}
        @{k='并行子线程';v='4'}
        @{k='RUNNING';v="$runCount";cls='ok'}
        @{k='SUSPENDED';v="$suspCount";cls='warn'}
    )
    legend="主线程 = 堆栈含 <code>process_commands_internal</code>；子线程 = <code>SubprocEntrypoint</code>（并行查询工作线程）。* 标注的 Elapsed 为 worker 自创建以来的累计值（长驻/池化 worker），非单条语句耗时。"
    sections=@(
        @{ h2="执行语句主线程（$($exec.Count) 个 · 含 process_commands_internal）"; threads=$threadCards }
    )
    footer="过滤 minidump 限制：部分语句文本（CStmtInsert 等）未随转储捕获，tsqlstack.js 返回 COM 0x80020101。此处仅列举可解码内容，不做根因判定。"
}
$sqlManifest | ConvertTo-Json -Depth 8 | Set-Content "$do\${cid}_sql_exec_manifest.json" -Encoding UTF8
Write-Host "wrote sql_exec_manifest"

# ---------- scheduler_monitor manifest (enrich parsed json) ----------
$sm = Get-Content "$da\${cid}_scheduler_monitor.json" -Raw | ConvertFrom-Json
$keepCols = @('m_Id','m_Event','m_NodeId','m_SchedulerId','m_ProcessUtilization','m_SystemIdle','m_MemoryUtilization','m_PageFaults','m_WorkingSetDelta','m_UserTime','m_KernelTime')
$rows2 = foreach($r in $sm.rows){ $h=[ordered]@{}; foreach($c in $keepCols){ $h[$c]=$r.$c }; $h }
$smManifest = [ordered]@{
    title='SchedulerMonitor 环形缓冲'
    caseId=$cid
    subtitle='SOSRingBuffers.EnumerateSchedulerMonitorRecords · 时序列举（m_Id 递增）'
    backLink="${cid}_overall_report.html"
    wrapper=@{ RecordType='RING_BUFFER_SCHEDULER_MONITOR'; TotalRecords="$($sm.rowCount)" }
    cols=$keepCols
    rows=$rows2
    timestampCol='m_Id'
    windowMinutes=20
    pageSize=100
}
$smManifest | ConvertTo-Json -Depth 6 | Set-Content "$do\${cid}_scheduler_monitor_manifest.json" -Encoding UTF8
Write-Host "wrote scheduler_monitor_manifest"
