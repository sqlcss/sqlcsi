[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$Dir,
    [string]$TaskFields,
    [string]$TsqlStackJson,
    [string]$ThreadsJson,
    [string]$Out,
    [string]$BackLink
)

$ErrorActionPreference = 'Stop'
if (-not $TaskFields)    { $TaskFields = Join-Path $Dir 'task_fields.json' }
if (-not $TsqlStackJson) { $TsqlStackJson = Join-Path $Dir "${CaseId}_tsqlstack.json" }
if (-not $ThreadsJson)   { $ThreadsJson = Join-Path $Dir 'threads_from_us.json' }
if (-not $Out)           { $Out = Join-Path $Dir "${CaseId}_sql_exec_manifest.json" }
if (-not $BackLink)      { $BackLink = "${CaseId}_overall_report.html" }

foreach ($p in @($TaskFields,$TsqlStackJson,$ThreadsJson)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "input not found: $p" }
}

function HE([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}
function Text([object]$v) { if ($null -eq $v) { '' } else { [string]$v } }
function FieldOr([object]$o, [string]$name, [string]$fallback = '') {
    if ($null -eq $o) { return $fallback }
    if ($o.PSObject.Properties.Name -contains $name) { return (Text $o.$name) }
    return $fallback
}
function StatusTag([string]$worker, [string]$wait) {
    if ($worker -match 'RUNNABLE') { return 'runn' }
    if ($worker -match 'SUSPENDED') { return 'susp' }
    if (-not $wait) { return 'run' }
    return 'sys'
}
function CardClass([string]$worker, [string]$wait) {
    if ($worker -match 'RUNNABLE') { return 'warn' }
    if ($worker -match 'SUSPENDED') { return 'no' }
    return 'ok'
}

$tasks = @(Get-Content -LiteralPath $TaskFields -Raw -Encoding UTF8 | ConvertFrom-Json)
$tsql = Get-Content -LiteralPath $TsqlStackJson -Raw -Encoding UTF8 | ConvertFrom-Json
$threads = @(Get-Content -LiteralPath $ThreadsJson -Raw -Encoding UTF8 | ConvertFrom-Json)

$stackByTid = @{}
foreach ($t in $threads) { $stackByTid[[int]$t.id] = (Text $t.stack) }
$tsqlByTid = @{}
foreach ($t in @($tsql.threads)) { $tsqlByTid[[int]$t.tid] = $t }
$timeoutTids = @{}
$tsqlSummaryPath = Join-Path $Dir "${CaseId}_tsqlstack.summary.json"
if (Test-Path -LiteralPath $tsqlSummaryPath) {
    foreach ($entry in @(Get-Content -LiteralPath $tsqlSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if ([string]$entry.status -match 'timeout') { $timeoutTids[[int]$entry.tid] = $entry }
    }
}

$mainRows = @($tasks | ForEach-Object { $_.main })
$mainTids = @($mainRows | ForEach-Object { [int]$_.tid })
$childRows = @($tasks | ForEach-Object { @($_.children) } | Where-Object { $_ })
$childTidsFromTask = @($childRows | ForEach-Object { [int]$_.tid })
$childTidsFromStack = @($threads | Where-Object { (Text $_.stack) -match 'SubprocEntrypoint|CXPacket|CXPort|CXPipe|CQScanExchange|CXTransport' -and (Text $_.stack) -notmatch 'process_commands_internal' } | ForEach-Object { [int]$_.id })
$childTids = @($childTidsFromTask + $childTidsFromStack | Sort-Object -Unique)

$mainBySpid = @{}
foreach ($m in $mainRows) {
    $spid = Text $m.spid
    if ($spid -and -not $mainBySpid.ContainsKey($spid)) { $mainBySpid[$spid] = [int]$m.tid }
}
$childByTid = @{}
foreach ($c in $childRows) { $childByTid[[int]$c.tid] = $c }

$mainThreads = @()
foreach ($m in ($mainRows | Sort-Object tid)) {
    $tid = [int]$m.tid
    $t = $tsqlByTid[$tid]
    $isTimeout = $timeoutTids.ContainsKey($tid) -or ($t -and $t.timeout)
    $raw = if ($t) { Text $t.rawBefore } else { 'tsqlstack block missing' }
    if ($t -and $t.comError) {
        $raw += "`r`n`r`n-- tsqlstack partial: COM $($t.comError.code) VA=$($t.comError.virtualAddress) line=$($t.comError.sourceLine)"
    }
    if ($isTimeout) {
        $timeoutSeconds = if ($t -and $t.timeout) { $t.timeout.timeoutSec } else { 300 }
        $raw += "`r`n`r`n-- tsqlstack shard timeout: exceeded ${timeoutSeconds}s; partial output above is preserved from the filtered minidump."
    }
    if ($raw -notmatch '\S') { $raw = 'tsqlstack produced no readable header before timeout/COM abort.' }
    $meta = "<b>SPID</b> $(HE (Text $m.spid)) · <b>Scheduler</b> $(HE (Text $m.sched)) · <b>Worker</b> $(HE (Text $m.workerState)) · <b>Wait</b> $(HE (Text $m.waitType)) · <b>Elapsed</b> $(HE (Text $m.elapsedMs)) ms · <b>Children</b> $(HE (Text ($tasks | Where-Object { $_.main.tid -eq $tid } | Select-Object -First 1 -ExpandProperty childCount)))"
    $mainThreads += [ordered]@{
        tid        = [string]$tid
        cardCls    = CardClass (Text $m.workerState) (Text $m.waitType)
        statusTag  = StatusTag (Text $m.workerState) (Text $m.waitType)
        statusText = if ($t) { if ($isTimeout) { 'TIMEOUT' } elseif ($t.comError) { 'PARTIAL' } else { 'OK' } } else { 'MISSING' }
        meta       = $meta
        tsqlstack  = $raw
        stack      = if ($stackByTid.ContainsKey($tid)) { $stackByTid[$tid] } else { '' }
    }
}

$childTable = [System.Text.StringBuilder]::new()
[void]$childTable.AppendLine('<table><thead><tr><th>线程</th><th>SPID</th><th>父主线程</th><th>Task 状态</th><th>Worker 状态</th><th>Scheduler</th><th>Wait type</th><th>Elapsed</th></tr></thead><tbody>')
foreach ($tid in $childTids) {
    $c = if ($childByTid.ContainsKey($tid)) { $childByTid[$tid] } else { $null }
    $spid = if ($c) { Text $c.spid } else { '' }
    $parent = if ($spid -and $mainBySpid.ContainsKey($spid)) { [string]$mainBySpid[$spid] } else { '' }
    [void]$childTable.AppendLine(('<tr><td class="mono">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td class="num">{7}</td></tr>' -f `
    (HE ([string]$tid)), (HE $spid), (HE $parent), (HE (FieldOr $c 'taskState' 'from stack only')), (HE (FieldOr $c 'workerState')), (HE (FieldOr $c 'sched')), (HE (FieldOr $c 'waitType')), (HE (FieldOr $c 'elapsedMs'))))
}
[void]$childTable.AppendLine('</tbody></table>')
foreach ($tid in $childTids) {
    $stack = if ($stackByTid.ContainsKey($tid)) { $stackByTid[$tid] } else { 'call stack not found in threads_from_us.json' }
    [void]$childTable.AppendLine("<details><summary>子线程 $tid 调用栈</summary><pre>$(HE $stack)</pre></details>")
}

$rt = [System.Text.StringBuilder]::new()
[void]$rt.AppendLine('<table class="rt"><thead><tr><th>线程</th><th>SPID</th><th>角色</th><th>Task 状态</th><th>Worker 状态</th><th>Wait type</th><th>Elapsed</th><th>CPU</th><th>Task function</th><th>Blocking</th></tr></thead><tbody>')
foreach ($o in ($tasks | Sort-Object { $_.main.tid })) {
    $m = $o.main
    $role = "主 · $($o.childCount) 子"
    $blocking = if ($m.blkReason) { "SPID $($m.blkSpid) (~$($m.blkTid)s) · $($m.blkReason)" } else { '' }
    [void]$rt.AppendLine(('<tr><td class="mono">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td class="num">{6}</td><td class="num">{7}</td><td>{8}</td><td>{9}</td></tr>' -f `
        (HE (Text $m.tid)), (HE (Text $m.spid)), (HE $role), (HE (Text $m.taskState)), (HE (Text $m.workerState)), (HE (Text $m.waitType)), (HE (Text $m.elapsedMs)), (HE (Text $m.cpuMs)), (HE (Text $m.taskFunc)), (HE $blocking)))
    foreach ($c in @($o.children)) {
        $blocking = if ($c.blkReason) { "SPID $($c.blkSpid) (~$($c.blkTid)s) · $($c.blkReason)" } else { '' }
        [void]$rt.AppendLine(('<tr><td class="mono">↳ {0}</td><td>{1}</td><td>CHILD</td><td>{2}</td><td>{3}</td><td>{4}</td><td class="num">{5}</td><td class="num">{6}</td><td>{7}</td><td>{8}</td></tr>' -f `
            (HE (Text $c.tid)), (HE (Text $c.spid)), (HE (Text $c.taskState)), (HE (Text $c.workerState)), (HE (Text $c.waitType)), (HE (Text $c.elapsedMs)), (HE (Text $c.cpuMs)), (HE (Text $c.taskFunc)), (HE $blocking)))
    }
}
[void]$rt.AppendLine('</tbody></table>')

$manifest = [ordered]@{
    title    = '执行语句线程详情（主线程 + 并行子线程）'
    caseId   = $CaseId
    subtitle = 'task.js main+child sweep + tsqlstack.js per-main decode + mex stack sidecar'
    backLink = $BackLink
    cards    = @(
        [ordered]@{ k='执行语句主线程'; v=[string]$mainRows.Count; cls='accent' },
        [ordered]@{ k='并行/子线程'; v=[string]$childTids.Count; cls='mauve' },
        [ordered]@{ k='tsqlstack blocks'; v=[string]@($tsql.threads).Count; cls='green' },
        [ordered]@{ k='tsqlstack partial'; v=[string]@($tsql.threads | Where-Object { $_.comError }).Count; cls='yellow' },
        [ordered]@{ k='tsqlstack timeout'; v=[string]$timeoutTids.Count; cls='orange' }
    )
    legend   = '本页只列举 dump 中执行语句线程状态、T-SQL 解码原始输出和调用栈；COM partial / timeout 是 filtered minidump 或脚本读取边界的证据，不代表线程不存在。'
    sections = @(
        [ordered]@{ h2="一、执行语句主线程（$($mainRows.Count) · 含 process_commands_internal）"; threads=$mainThreads },
        [ordered]@{ h2="二、并行子线程（$($childTids.Count)）"; threads=@(); extraHtml=$childTable.ToString() },
        [ordered]@{ h2="三、主线程 / 子线程运行时状态明细（task.js）"; threads=@(); extraHtml=$rt.ToString() }
    )
    footer   = 'Generated by build_sql_exec_manifest.ps1 + gen_sql_exec_html.ps1.'
}

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
[System.IO.File]::WriteAllText($Out, ($manifest | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
Write-Host "[build_sql_exec_manifest] mains=$($mainRows.Count) children=$($childTids.Count) tsql=$(@($tsql.threads).Count) -> $Out"