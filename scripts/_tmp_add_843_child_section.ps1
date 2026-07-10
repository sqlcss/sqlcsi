Add-Type -AssemblyName System.Web
$ov  = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall'
$mfp = "$ov\2607030030000843_sql_exec_manifest.json"
$mf  = Get-Content $mfp -Raw -Encoding UTF8 | ConvertFrom-Json

# ---- 4 parallel child workers (SubprocEntrypoint) from task_all.txt ----
# parent 329 = SPID 95  BACKUP LOG [VMS_scheduler]   -> children 151, 157
# parent 321 = SPID 102 BACKUP LOG [TestSimulation]  -> children 138, 115
$children = @(
    @{ parent='329'; pspid='95';  pstmt='BACKUP LOG [VMS_scheduler]';  tid='151'; spid='95';  card='ok';   tag='run';  st='▶ RUNNING';    ws='WORKER_STATE_RUNNING';    sch='1048602'; ec='3B0C49E8180'; wait='PWAIT_MEMORY_ALLOCATION_EXT (0x8B) · last wait'; elapsed='9.4 分 (9:21.657)' }
    @{ parent='329'; pspid='95';  pstmt='BACKUP LOG [VMS_scheduler]';  tid='157'; spid='95';  card='warn'; tag='runn'; st='◔ RUNNABLE';   ws='WORKER_STATE_RUNNABLE';   sch='1048604'; ec='4C7A343E180'; wait='PWAIT_SOS_SCHEDULER_YIELD (0x63) · last PWAIT_BACKUPIO (0xE3)'; elapsed='9.4 分 (9:21.273)' }
    @{ parent='321'; pspid='102'; pstmt='BACKUP LOG [TestSimulation]'; tid='138'; spid='102'; card='ok';   tag='run';  st='▶ RUNNING';    ws='WORKER_STATE_RUNNING';    sch='1048601'; ec='3FB65272180'; wait='PWAIT_MEMORY_ALLOCATION_EXT (0x8B) · last wait'; elapsed='9.3 分 (9:20.569)' }
    @{ parent='321'; pspid='102'; pstmt='BACKUP LOG [TestSimulation]'; tid='115'; spid='102'; card='no';   tag='susp'; st='⏸ SUSPENDED';  ws='WORKER_STATE_SUSPENDED';  sch='1048598'; ec='42CDADA6180'; wait='PWAIT_BACKUPIO (0xE3) · 等待 9:16.784'; elapsed='9.3 分 (9:20.176)' }
)

function HE([string]$s){ [System.Web.HttpUtility]::HtmlEncode($s) }

$groups = $children | Group-Object parent
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('<p class="sub">这些线程没有 TDS 请求分发帧（<code>process_commands_internal</code>），是 BACKUP 语句的并行 worker（<code>sqlmin!SubprocEntrypoint</code>），本身不承载顶层 T-SQL 语句文本；语句归属于对应的父主线程备份语句。<b>纯客观列举，不做根因判定。</b></p>')
foreach ($g in $groups) {
    $first = $g.Group[0]
    $kids  = ($g.Group | ForEach-Object { $_.tid }) -join ', '
    [void]$sb.Append("<h3>父主线程 $($first.parent)（SPID $($first.pspid)）· $(HE $first.pstmt) <span class=""exc"">（$($g.Count) 子线程：$kids）</span></h3>")
    foreach ($c in $g.Group) {
        [void]$sb.Append("<div class=""tcard $($c.card)"">")
        [void]$sb.Append("<div class=""thead""><span class=""tid"">线程 $($c.tid)</span> <span class=""tag $($c.tag)"">$($c.st)</span> <span class=""exc"">SubprocEntrypoint · 并行 worker</span></div>")
        [void]$sb.Append("<div class=""kv""><b>SPID</b> <code>$($c.spid)</code> &nbsp;·&nbsp; <b>Worker</b> <code>$($c.ws)</code> &nbsp;·&nbsp; <b>Scheduler</b> <code>$($c.sch)</code> &nbsp;·&nbsp; <b>EC</b> <code>$($c.ec)</code><br><b>Task 函数</b> <code>sqlmin!SubprocEntrypoint</code> &nbsp;·&nbsp; <b>Wait</b> <code>$(HE $c.wait)</code> &nbsp;·&nbsp; <b>Elapsed</b> $($c.elapsed)</div>")
        [void]$sb.Append("</div>")
    }
}
$childHtml = $sb.ToString()

$childSection = [ordered]@{
    h2        = '二、并行子线程（4 · SubprocEntrypoint · 备份并行 worker）'
    threads   = @()
    extraHtml = $childHtml
}

# rename main section to 一、... for numbering consistency (text/method unchanged otherwise)
if ($mf.sections[0].h2 -notmatch '^一、') {
    $mf.sections[0].h2 = '一、' + $mf.sections[0].h2
}

# append child section if not already present
$hasChild = $false
foreach ($s in $mf.sections) { if ("$($s.h2)" -match '并行子线程') { $hasChild = $true } }
if (-not $hasChild) {
    $mf.sections = @($mf.sections) + $childSection
}

$json = $mf | ConvertTo-Json -Depth 12
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($mfp, $json, $enc)
Write-Host "manifest sections=$($mf.sections.Count) bytes=$((Get-Item $mfp).Length)"
