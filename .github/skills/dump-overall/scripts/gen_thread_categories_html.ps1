<#
.SYNOPSIS
  Generate the dump-overall functional-thread detail sub-report from !mex.us.

.WHY
  The main report's "线程功能分类" table is only a summary. The dump-overall
  contract requires every thread that hits a functional bucket to have its stack
  available from the report. This script owns that artifact so agents do not
  hand-roll or forget it.

.OUTPUT
    <CaseId>_thread_categories.html with:
        - one summary table row per functional bucket
        - one section per bucket, anchored as cat-<key> even when empty
        - one expandable stack group per matching !mex.us unique-stack group

.NOTE
  !mex.us may truncate the thread-id list for a large unique-stack group with
  "...". This script preserves the authoritative group thread count from the
  header, so the report does not under-count or drop the group's stack.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$UsTxt,
    [Parameter(Mandatory=$true)][string]$Out,
    [Parameter(Mandatory=$true)][string]$CaseId,
    [string]$BackLink = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $UsTxt -PathType Leaf)) { throw "!mex.us file not found: $UsTxt" }
if (-not $BackLink) { $BackLink = "${CaseId}_overall_report.html" }

function HE([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}

function Get-TopFrame($group) {
    foreach ($frame in $group.Frames) {
        if ($frame -match '(sqldk|sqllang|sqlmin|sqltses)!([^\s+]+)' -and
            $frame -notmatch 'SwitchContext|SuspendNonPreemptive|WaitableBase::Wait|SignalAndWait|ProcessTasks|RunTask|WorkerEntryPoint|ThreadEntryPoint') {
            return $Matches[1] + '!' + $Matches[2]
        }
    }
    foreach ($frame in $group.Frames) {
        if ($frame -match '(sqldk|sqllang|sqlmin|sqltses)!([^\s+]+)') { return $Matches[1] + '!' + $Matches[2] }
    }
    return '(no sql frame)'
}

$lines = Get-Content -LiteralPath $UsTxt -Encoding UTF8
$groups = @()
$current = $null

foreach ($line in $lines) {
    if ($line -match '^(\d+)\s+threads?\s+\[stats\]:\s*(.*)$') {
        if ($current) { $groups += ,$current }
        $ids = @([regex]::Matches($Matches[2], '(\d+)\[!mex\.t') | ForEach-Object { [int]$_.Groups[1].Value })
        $current = [pscustomobject]@{
            Count  = [int]$Matches[1]
            Ids    = $ids
            More   = ($Matches[2] -match '\.\.\.')
            Frames = New-Object Collections.ArrayList
        }
    }
    elseif ($current -and ($line -match '^\s+(00007|\(Inline\))')) {
        [void]$current.Frames.Add($line.TrimEnd())
    }
}
if ($current) { $groups += ,$current }

if ($groups.Count -eq 0) { throw "No !mex.us stack groups parsed from $UsTxt" }

$categories = @(
    @{ key='iocp'; label='IOCP 线程'; rx='SOS_Node::ListenOnIOCompletionPort' }
    @{ key='nio';  label='网络 I/O (Network I/O)'; rx='TDSSNIClient::|WaitOnWriteAsyncToFinish|flush_buffer|CTds\w*::Send|SNIWriteAsync|SNIReadAsync|Tds\w*::Read' }
    @{ key='bak';  label='备份操作 (Backup)'; rx='BackupThread::|BackupOperation::|BackupVirtualDeviceSet|BackupLogMediaWriter|RestoreOperation::|sqlvdi!' }
    @{ key='chk';  label='检查点 (Checkpoint)'; rx='Checkpoint(Helper|Loop|RU2|Worker|RU)|RegisterCheckPtWorker' }
    @{ key='lw';   label='惰性写入 (LazyWriter)'; rx='BPool::LazyWriter|!lazywriter\b' }
    @{ key='lat';  label='闩锁相关 (Latch)'; rx='LatchBase::|Latch::Acquire|::AcquireLatch|LatchWaitList' }
    @{ key='exc';  label='触发异常 (Exception)'; rx='KiUserExceptionDispatch|RtlDispatchException|_CxxThrowException|RaiseException|CDmpDump::|CImageHelper::DoMiniDump|SQLDumperLibraryInvoke|sqllang!stackTrace\b' }
    @{ key='mon';  label='监视器线程 (Monitor)'; rx='SchedulerMonitor::|ResourceMonitor::|DeadlockMonitor::|lockMonitor(Thread)?\b|SystemHealthMonitor|SQLAgentMonitorThread' }
    @{ key='par';  label='并行执行 (Parallel)'; rx='CXPort|CXPacket|CXTransport|CXPipe|CQScanExchange|SubprocEntrypoint' }
    @{ key='fio';  label='文件 I/O (File I/O)'; rx='FCB::(Async)?(Read|Write)|WriteFileGather|ReadFileScatter|AsyncDiskWorker|DiskWorker::|FileHandleAsyncIO' }
)

$results = foreach ($category in $categories) {
    $matched = @($groups | Where-Object { ($_.Frames -join ' ') -match "(?i)$($category.rx)" })
    $threadCount = ($matched | Measure-Object Count -Sum).Sum
    if ($null -eq $threadCount) { $threadCount = 0 }
    [pscustomobject]@{ Category = $category; Groups = $matched; Threads = [int]$threadCount }
}

$css = @'
:root{--bg:#1e1e2e;--surface:#252538;--border:#3a3a55;--text:#cdd6f4;--dim:#a6adc8;--accent:#89b4fa;--green:#a6e3a1;--yellow:#f9e2af;--orange:#fab387;--red:#f38ba8;--teal:#94e2d5;--mauve:#cba6f7}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI','Microsoft YaHei',sans-serif;margin:0;padding:28px;line-height:1.55}
h1{color:var(--accent);font-size:24px;margin:0 0 6px}h2{color:var(--mauve);font-size:18px;border-bottom:1px solid var(--border);padding-bottom:6px;margin-top:28px}.sub,.note{color:var(--dim)}
table{border-collapse:collapse;width:100%;font-size:13px;margin:12px 0}th,td{border:1px solid var(--border);padding:7px 9px;text-align:left;vertical-align:top}th{background:#2b2b40;color:var(--accent)}
details{background:var(--surface);border:1px solid var(--border);border-radius:8px;margin:10px 0;padding:8px 12px}summary{cursor:pointer;color:var(--teal);font-weight:600}
code,pre{font-family:'Cascadia Code',Consolas,monospace}pre{background:#181825;border:1px solid var(--border);border-radius:6px;padding:10px;overflow:auto;font-size:12px}.ids{color:var(--dim);font-size:12px}.cnt{color:var(--yellow);font-weight:700}a{color:var(--accent)}
'@

$sb = [Text.StringBuilder]::new()
[void]$sb.Append("<!DOCTYPE html><html lang='zh-CN'><head><meta charset='utf-8'><title>$(HE $CaseId) 线程功能分类明细</title><style>$css</style></head><body>")
[void]$sb.Append("<h1>线程功能分类明细 · $(HE $CaseId)</h1>")
[void]$sb.Append("<div class='sub'>来源：<code>!mex.us</code> 唯一栈组。按功能桶列出所有命中 stack group 的完整调用栈；若 mex group 的 thread id 被省略号截断，仍按 group 的 <code>N threads</code> 计数。</div>")
[void]$sb.Append("<p><a href='$(HE $BackLink)'>返回主报告</a> · <a href='$(HE $CaseId)_us.html'>查看全部线程清单</a></p>")
[void]$sb.Append('<table><thead><tr><th>功能桶</th><th>命中 stack groups</th><th>线程数（按 group count）</th><th>明细锚点</th></tr></thead><tbody>')
foreach ($result in $results) {
    $key = $result.Category.key
    [void]$sb.Append("<tr><td>$(HE $result.Category.label)</td><td>$($result.Groups.Count)</td><td>$($result.Threads)</td><td><a href='#cat-$key'>cat-$key</a></td></tr>")
}
[void]$sb.Append('</tbody></table>')

foreach ($result in $results) {
    $key = $result.Category.key
    [void]$sb.Append("<h2 id='cat-$key'>$(HE $result.Category.label) <span class='cnt'>$($result.Threads) threads / $($result.Groups.Count) stack groups</span></h2>")
    if ($result.Groups.Count -eq 0) {
        [void]$sb.Append("<p class='note'>该功能桶无命中线程。</p>")
        continue
    }
    $index = 0
    foreach ($group in @($result.Groups | Sort-Object Count -Descending)) {
        $index++
        $ids = ($group.Ids | ForEach-Object { [string]$_ }) -join ', '
        if ($group.More) { $ids += ' ... (mex.us 省略了其余 thread id)' }
        $stack = ($group.Frames | ForEach-Object { HE $_ }) -join "`n"
        [void]$sb.Append("<details id='thr-$key-$index'><summary>$index. <span class='cnt'>$($group.Count) threads</span> · $(HE (Get-TopFrame $group))</summary><div class='ids'>Thread IDs: $(HE $ids)</div><pre>$stack</pre></details>")
    }
}

[void]$sb.Append('</body></html>')

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
[IO.File]::WriteAllText($Out, $sb.ToString(), [Text.UTF8Encoding]::new($false))

$nonEmptyBuckets = @($results | Where-Object { $_.Groups.Count -gt 0 }).Count
$stackGroups = ($results | Measure-Object { $_.Groups.Count } -Sum).Sum
Write-Host ("[gen_thread_categories_html] wrote {0} ({1} non-empty buckets, {2} matched stack-group entries)" -f $Out, $nonEmptyBuckets, $stackGroups) -ForegroundColor Green
