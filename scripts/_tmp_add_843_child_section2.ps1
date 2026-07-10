Add-Type -AssemblyName System.Web
$ov  = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall'
$mfp = "$ov\2607030030000843_sql_exec_manifest.json"
$mf  = Get-Content $mfp -Raw -Encoding UTF8 | ConvertFrom-Json

# ---- child call stacks from DumpViewer InParallelThreads sidecar ----
$ip = Get-Content "$ov\inparallel.json" -Raw | ConvertFrom-Json
$stackOf = @{}
foreach ($r in $ip.data) { $stackOf["$($r[0])"] = [string]$r[1] }

# ---- 4 parallel child workers (SubprocEntrypoint) from task_all.txt ----
# parent 329 = SPID 95  BACKUP LOG [VMS_scheduler]   -> children 151, 157
# parent 321 = SPID 102 BACKUP LOG [TestSimulation]  -> children 138, 115
$children = @(
    @{ tid='151'; spid='95';  parent='329'; pstmt='BACKUP LOG [VMS_scheduler]';  tag='run';  tstate='RUNNING';   wstate='WORKER_STATE_RUNNING';   sch='1048602'; ec='3B0C49E8180'; wait='PWAIT_MEMORY_ALLOCATION_EXT (0x8B)'; elapsed='9:21.657' }
    @{ tid='157'; spid='95';  parent='329'; pstmt='BACKUP LOG [VMS_scheduler]';  tag='runn'; tstate='RUNNABLE';  wstate='WORKER_STATE_RUNNABLE';  sch='1048604'; ec='4C7A343E180'; wait='PWAIT_SOS_SCHEDULER_YIELD (0x63)'; elapsed='9:21.273' }
    @{ tid='138'; spid='102'; parent='321'; pstmt='BACKUP LOG [TestSimulation]'; tag='run';  tstate='RUNNING';   wstate='WORKER_STATE_RUNNING';   sch='1048601'; ec='3FB65272180'; wait='PWAIT_MEMORY_ALLOCATION_EXT (0x8B)'; elapsed='9:20.569' }
    @{ tid='115'; spid='102'; parent='321'; pstmt='BACKUP LOG [TestSimulation]'; tag='susp'; tstate='SUSPENDED'; wstate='WORKER_STATE_SUSPENDED'; sch='1048598'; ec='42CDADA6180'; wait='PWAIT_BACKUPIO (0xE3)';               elapsed='9:20.176' }
)

function HE([string]$s){ [System.Web.HttpUtility]::HtmlEncode($s) }

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('<p class="legend">这些线程没有 TDS 请求分发帧（<code>process_commands_internal</code>），是 BACKUP 语句的并行 worker（<code>sqlmin!SubprocEntrypoint</code>），本身不承载顶层 T-SQL 文本；语句归属对应父主线程。<b>纯客观列举，不做根因判定。</b></p>')

# ---- summary table ----
[void]$sb.Append('<table><thead><tr><th>线程</th><th>SPID</th><th>父主线程</th><th>父语句</th><th>Task 状态</th><th>Worker 状态</th><th>Scheduler</th><th>EC</th><th>Wait type</th><th>Elapsed</th></tr></thead><tbody>')
foreach ($c in $children) {
    [void]$sb.Append('<tr>')
    [void]$sb.Append("<td class=""num""><b>$($c.tid)</b></td>")
    [void]$sb.Append("<td class=""num"">$($c.spid)</td>")
    [void]$sb.Append("<td class=""num"">$($c.parent)</td>")
    [void]$sb.Append("<td>$(HE $c.pstmt)</td>")
    [void]$sb.Append("<td><span class=""tag $($c.tag)"">$($c.tstate)</span></td>")
    [void]$sb.Append("<td>$($c.wstate)</td>")
    [void]$sb.Append("<td class=""num"">$($c.sch)</td>")
    [void]$sb.Append("<td><code>$($c.ec)</code></td>")
    [void]$sb.Append("<td><code>$(HE $c.wait)</code></td>")
    [void]$sb.Append("<td class=""num"">$($c.elapsed)</td>")
    [void]$sb.Append('</tr>')
}
[void]$sb.Append('</tbody></table>')

# ---- per-child call stacks (all children) ----
foreach ($c in $children) {
    $st = $stackOf["$($c.tid)"]
    if (-not $st) { $st = '(InParallelThreads 侧车中缺少此线程调用栈)' }
    [void]$sb.Append("<details><summary>▶ 子线程 $($c.tid)（SPID $($c.spid) · 父 $($c.parent)）调用栈</summary><pre>$(HE $st)</pre></details>")
}
$childHtml = $sb.ToString()

$childSection = [ordered]@{
    h2        = '二、并行子线程（4）'
    threads   = @()
    extraHtml = $childHtml
}

# ensure main section keeps 一、 prefix
if ($mf.sections[0].h2 -notmatch '^一、') { $mf.sections[0].h2 = '一、' + $mf.sections[0].h2 }

# replace existing child section (h2 matching 并行子线程) or append
$newSecs = @()
$replaced = $false
foreach ($s in $mf.sections) {
    if ("$($s.h2)" -match '并行子线程') { $newSecs += $childSection; $replaced = $true }
    else { $newSecs += $s }
}
if (-not $replaced) { $newSecs += $childSection }
$mf.sections = $newSecs

$json = $mf | ConvertTo-Json -Depth 12
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($mfp, $json, $enc)
Write-Host "manifest sections=$($mf.sections.Count) replaced=$replaced bytes=$((Get-Item $mfp).Length)"
