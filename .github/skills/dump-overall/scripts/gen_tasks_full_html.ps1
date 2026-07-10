<#
gen_tasks_full_html.ps1 — Task-level detail HTML from Tasks.Enumerate raw text.

CANONICAL SHAPE (Catppuccin Mocha, zh):
  1. Header + meta cards           (总任务 / SUSPENDED / RUNNABLE / RUNNING / DONE)
  2. 读法说明 (note)
  3. 表 2 · SQLOS 任务级状态        (3 列 + 合计 · matches overall-report format)
  4. 表 3 · 按调度器分布            (SchedulerId 透视，隐藏/系统 聚合，合计)
  5. 值得注意的行                   (RUNNING / RUNNABLE task_function 列)
  6. 全量任务清单                   (纯列举，SchedulerId 升序)
  7. 过滤 minidump 采集局限 note

The `按 task_function 聚合` section is INTENTIONALLY OMITTED — 表 3
(scheduler pivot) + notable-rows table already convey the key patterns
without over-decorating the subreport.

INPUT  : pipe-separated `!execute Tasks.Enumerate` capture (may contain
         WinDbgCs symbol-load noise / ScriptOutput help table / exception
         tail — only lines starting with `0x[0-9a-f]+ |` are parsed).
         Row format:
           task_addr | scheduler_id | worker | thread | state | function

OUTPUT :
  <Out>                      — self-contained HTML file (zh, Catppuccin Mocha)
  <OutDir>\<CaseId>_tasks_stats.json  — sidecar {stateSummary, schedulerPivot,
                                          notableRows} for overall-report
                                          manifest reuse.

USAGE  : .\gen_tasks_full_html.ps1 `
             -Src   <case>_tasks_enumerate.txt `
             -Out   <case>_tasks.html `
             -CaseId <case_id> `
             [-BackLinkHref <case>_overall_report.html] `
             [-Title  '任务级权威状态清单（Tasks.Enumerate）'] `
             [-Subtitle 'SQLDump0001.mdmp · 数据来源：!execute Tasks.Enumerate']
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Src,
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][string]$CaseId,
    [string]$BackLinkHref = "${CaseId}_overall_report.html",
    [string]$Title    = '任务级权威状态清单（Tasks.Enumerate）',
    [string]$Subtitle = ''
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Src)) { throw "Src file not found: $Src" }

function HE([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}
function StateTag([string]$state) {
    $s = if ($null -eq $state) { '' } else { $state.Trim().ToUpper() }
    switch -Regex ($s) {
        '^RUNNING$'   { return '<span class="tag t-run">RUNNING</span>' }
        '^RUNNABLE$'  { return '<span class="tag t-rbl">RUNNABLE</span>' }
        '^SUSPENDED$' { return '<span class="tag t-sus">SUSPENDED</span>' }
        '^SPINLOOP$'  { return '<span class="tag t-rbl">SPINLOOP</span>' }
        '^DONE$'      { return '<span class="tag t-idle">DONE</span>' }
        '^PENDING$'   { return '<span class="tag t-idle">PENDING</span>' }
        '^NULLPTR$'   { return '<span class="tag t-null">nullptr</span>' }
        default       { return "<span class=""tag t-idle"">$(HE $state)</span>" }
    }
}

# ---- parse rows (strict: only lines starting with 0x[hex]+ | ) --------------
$rowRegex = '^0x[0-9a-f]+\s*\|'
$rows = New-Object System.Collections.Generic.List[object]
foreach ($ln in (Get-Content -LiteralPath $Src -Encoding UTF8)) {
    if ($ln -notmatch $rowRegex) { continue }
    $parts = $ln -split '\s*\|\s*', 6
    if ($parts.Count -lt 6) { while ($parts.Count -lt 6) { $parts += '' } }
    $rows.Add([pscustomobject]@{
        Task     = $parts[0].Trim()
        Sched    = $parts[1].Trim()
        Worker   = $parts[2].Trim()
        Thread   = $parts[3].Trim()
        State    = $parts[4].Trim()
        FuncRaw  = $parts[5].Trim()
        Func     = ($parts[5] -replace '\s*\[.*$','').Trim()  # strip [src loc] / [*]
    }) | Out-Null
}
$total = $rows.Count
$nonNull = ($rows | Where-Object { $_.State -ne 'nullptr' }).Count
if ($total -eq 0) { throw "No task rows parsed from $Src" }

# ---- state summary ----------------------------------------------------------
$stateOrder = @('SUSPENDED','RUNNABLE','RUNNING','DONE')
$stateCounts = @{}
foreach ($s in $stateOrder) { $stateCounts[$s] = 0 }
$nullCount = 0
foreach ($r in $rows) {
    if ($r.State -eq 'nullptr') { $nullCount++; continue }
    if (-not $stateCounts.ContainsKey($r.State)) { $stateCounts[$r.State] = 0 }
    $stateCounts[$r.State]++
}
$stateStats = [ordered]@{}
foreach ($s in $stateOrder) {
    $c = [int]$stateCounts[$s]
    $stateStats[$s] = [pscustomobject]@{
        count = $c
        pct   = if ($nonNull -gt 0) { [math]::Round($c * 100.0 / $nonNull, 1) } else { 0.0 }
    }
}
$totalBound = $nonNull

# ---- scheduler pivot --------------------------------------------------------
$HIDDEN_ID = 1048576
$pivotMap = @{}   # sched -> hashtable(state -> count)
$hidden = @{ Total = 0; SUSPENDED = 0; RUNNABLE = 0; RUNNING = 0; DONE = 0 }
foreach ($r in $rows) {
    if ($r.State -eq 'nullptr') { continue }
    $sn = 0
    $isHidden = $false
    if ($r.Sched -eq 'nullptr' -or -not [int]::TryParse($r.Sched, [ref]$sn)) {
        $isHidden = $true
    } elseif ($sn -ge $HIDDEN_ID) {
        $isHidden = $true
    }
    if ($isHidden) {
        $hidden.Total++
        if ($hidden.ContainsKey($r.State)) { $hidden[$r.State]++ }
    } else {
        if (-not $pivotMap.ContainsKey($sn)) {
            $pivotMap[$sn] = @{ Total = 0; SUSPENDED = 0; RUNNABLE = 0; RUNNING = 0; DONE = 0 }
        }
        $pivotMap[$sn].Total++
        if ($pivotMap[$sn].ContainsKey($r.State)) { $pivotMap[$sn][$r.State]++ }
    }
}
$visibleIds = ($pivotMap.Keys | Sort-Object)

# ---- table 2 HTML (state summary + 合计) ------------------------------------
$sb2 = New-Object System.Text.StringBuilder
[void]$sb2.Append("<h3>表 2 · SQLOS 任务级状态（<span class=""mono"">!execute Tasks.Enumerate</span> · 权威 TaskState，共 $totalBound 个 task）</h3>")
[void]$sb2.Append('<table><thead><tr><th>TaskState</th><th class="num">数量</th><th class="num">占比</th></tr></thead><tbody>')
foreach ($s in $stateOrder) {
    $c = $stateStats[$s].count
    $p = $stateStats[$s].pct
    [void]$sb2.Append("<tr><td>$(StateTag $s)</td><td class=""num"">$c</td><td class=""num"">$($p.ToString('0.0'))%</td></tr>")
}
[void]$sb2.Append("<tr><td><b>合计</b></td><td class=""num""><b>$totalBound</b></td><td class=""num""><b>100%</b></td></tr>")
[void]$sb2.Append('</tbody></table>')

# ---- table 3 HTML (scheduler pivot) -----------------------------------------
$sb3 = New-Object System.Text.StringBuilder
[void]$sb3.Append('<h3>表 3 · 按调度器分布（Tasks.Enumerate 按 SchedulerId 透视 · 纯计数）</h3>')
[void]$sb3.Append('<table><thead><tr><th class="num">调度器</th><th class="num">总数</th><th class="num">SUSPENDED</th><th class="num">RUNNABLE</th><th class="num">RUNNING</th><th class="num">DONE</th></tr></thead><tbody>')
foreach ($id in $visibleIds) {
    $v = $pivotMap[$id]
    [void]$sb3.Append("<tr><td class=""num"">$id</td><td class=""num"">$($v.Total)</td><td class=""num"">$($v.SUSPENDED)</td><td class=""num"">$($v.RUNNABLE)</td><td class=""num"">$($v.RUNNING)</td><td class=""num"">$($v.DONE)</td></tr>")
}
[void]$sb3.Append("<tr><td class=""num"">隐藏/系统 (id&ge;1048576)</td><td class=""num"">$($hidden.Total)</td><td class=""num"">$($hidden.SUSPENDED)</td><td class=""num"">$($hidden.RUNNABLE)</td><td class=""num"">$($hidden.RUNNING)</td><td class=""num"">$($hidden.DONE)</td></tr>")
$sumTot = ($visibleIds | ForEach-Object { $pivotMap[$_].Total } | Measure-Object -Sum).Sum + $hidden.Total
$sumSus = ($visibleIds | ForEach-Object { $pivotMap[$_].SUSPENDED } | Measure-Object -Sum).Sum + $hidden.SUSPENDED
$sumRbl = ($visibleIds | ForEach-Object { $pivotMap[$_].RUNNABLE }  | Measure-Object -Sum).Sum + $hidden.RUNNABLE
$sumRun = ($visibleIds | ForEach-Object { $pivotMap[$_].RUNNING }   | Measure-Object -Sum).Sum + $hidden.RUNNING
$sumDon = ($visibleIds | ForEach-Object { $pivotMap[$_].DONE }      | Measure-Object -Sum).Sum + $hidden.DONE
[void]$sb3.Append("<tr><td><b>合计</b></td><td class=""num""><b>$sumTot</b></td><td class=""num""><b>$sumSus</b></td><td class=""num""><b>$sumRbl</b></td><td class=""num""><b>$sumRun</b></td><td class=""num""><b>$sumDon</b></td></tr>")
[void]$sb3.Append('</tbody></table>')

# ---- notable rows (RUNNING + RUNNABLE) --------------------------------------
$notable = $rows | Where-Object { $_.State -eq 'RUNNING' -or $_.State -eq 'RUNNABLE' } |
    Sort-Object @{Expression={ if ($_.Sched -eq 'nullptr') { [int]::MaxValue } else { [int]$_.Sched } }},State
$sbN = New-Object System.Text.StringBuilder
[void]$sbN.Append('<h3>值得注意的 RUNNING / RUNNABLE 行</h3>')
[void]$sbN.Append('<table><thead><tr><th class="num">调度器</th><th>状态</th><th class="mono">OS 线程</th><th class="mono">task_function</th></tr></thead><tbody>')
foreach ($r in $notable) {
    $threadCell = if ($r.Thread -eq 'nullptr') { '<span class="dim">nullptr</span>' } else { "<code>$(HE $r.Thread)</code>" }
    [void]$sbN.Append("<tr><td class=""num"">$(HE $r.Sched)</td><td>$(StateTag $r.State)</td><td>$threadCell</td><td class=""mono"">$(HE $r.Func)</td></tr>")
}
[void]$sbN.Append('</tbody></table>')

# ---- full listing (sorted by scheduler asc; nullptr last) -------------------
$sorted = $rows | Sort-Object `
    @{Expression={ if ($_.Sched -eq 'nullptr') { [int]::MaxValue } else { [int]$_.Sched } }}, `
    @{Expression='Task'}
$sbF = New-Object System.Text.StringBuilder
[void]$sbF.Append("<h3>全量任务清单（$total 行，按 SchedulerId 升序）</h3>")
[void]$sbF.Append('<table class="full"><thead><tr><th>task</th><th class="num">sched</th><th>worker</th><th>thread</th><th>state</th><th class="mono">task_function</th></tr></thead><tbody>')
foreach ($r in $sorted) {
    $schedCell  = if ($r.Sched  -eq 'nullptr') { '<span class="dim">nullptr</span>' } else { "<code>$(HE $r.Sched)</code>" }
    $workerCell = if ($r.Worker -eq 'nullptr') { '<span class="dim">nullptr</span>' } else { "<code>$(HE $r.Worker)</code>" }
    $threadCell = if ($r.Thread -eq 'nullptr') { '<span class="dim">nullptr</span>' } else { "<code>$(HE $r.Thread)</code>" }
    $funcCell   = if ($r.Func   -eq 'nullptr') { '<span class="dim">nullptr</span>' } else { "<span class=""mono"">$(HE $r.Func)</span>" }
    [void]$sbF.Append("<tr><td><code class=""dim"">$(HE $r.Task)</code></td><td class=""num"">$schedCell</td><td>$workerCell</td><td>$threadCell</td><td>$(StateTag $r.State)</td><td>$funcCell</td></tr>")
}
[void]$sbF.Append('</tbody></table>')

# ---- meta cards -------------------------------------------------------------
function VCls([string]$s) {
    switch ($s) {
        'SUSPENDED' { 'v-red' }
        'RUNNABLE'  { 'v-yellow' }
        'RUNNING'   { 'v-green' }
        'DONE'      { 'v-accent' }
        default     { '' }
    }
}
$cards = New-Object System.Text.StringBuilder
[void]$cards.Append('<div class="cards">')
[void]$cards.Append("<div class=""card""><div class=""k"">总行数</div><div class=""v v-accent"">$total</div></div>")
[void]$cards.Append("<div class=""card""><div class=""k"">有效任务</div><div class=""v"">$totalBound</div></div>")
foreach ($s in $stateOrder) {
    $c = $stateStats[$s].count
    [void]$cards.Append("<div class=""card""><div class=""k"">$s</div><div class=""v $(VCls $s)"">$c</div></div>")
}
[void]$cards.Append('</div>')

# ---- style ------------------------------------------------------------------
$style = @'
:root{--bg:#1e1e2e;--surface:#252538;--border:#3a3a55;--text:#cdd6f4;--dim:#a6adc8;--accent:#89b4fa;--green:#a6e3a1;--yellow:#f9e2af;--orange:#fab387;--red:#f38ba8;--teal:#94e2d5;--mauve:#cba6f7;}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI','Microsoft YaHei',sans-serif;margin:0;padding:28px;line-height:1.5}
h1{color:var(--accent);font-size:22px;margin:0 0 4px}
h2{color:var(--mauve);font-size:17px;margin:26px 0 8px;border-bottom:1px solid var(--border);padding-bottom:6px}
h3{color:var(--teal);font-size:14px;margin:18px 0 8px}
.sub{color:var(--dim);font-size:12px;margin-bottom:14px}
.cards{display:flex;flex-wrap:wrap;gap:12px;margin:14px 0 6px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:10px 14px;min-width:140px}
.card .k{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.4px}
.card .v{color:var(--text);font-size:20px;margin-top:3px;font-weight:700}
.v-red{color:var(--red)}.v-yellow{color:var(--yellow)}.v-green{color:var(--green)}.v-accent{color:var(--accent)}
table{border-collapse:collapse;width:100%;margin:8px 0 4px;font-size:12.5px}
th,td{border:1px solid var(--border);padding:6px 9px;text-align:left;vertical-align:top}
th{background:#2b2b40;color:var(--accent);font-weight:600}
tbody tr:nth-child(even){background:#20202f}
td.num{text-align:right;font-variant-numeric:tabular-nums}
table.full th,table.full td{font-size:11.5px;padding:4px 7px}
code,pre{font-family:'Cascadia Code',Consolas,monospace}
.mono{font-family:'Cascadia Code',Consolas,monospace}
.tag{display:inline-block;padding:1px 7px;border-radius:10px;font-size:11px;font-weight:600;white-space:nowrap}
.t-run{background:#3a2733;color:var(--red)}
.t-rbl{background:#3a3327;color:var(--orange)}
.t-sus{background:#27333a;color:var(--teal)}
.t-idle{background:#2a2a3a;color:var(--dim)}
.t-null{background:#2a2a3a;color:var(--dim)}
.dim{color:var(--dim)}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.note{background:#181825;border-left:3px solid var(--accent);padding:8px 12px;border-radius:4px;color:var(--dim);font-size:12px;margin:8px 0 14px}
.note.warn{border-left-color:var(--red)}
.foot{color:var(--dim);font-size:11px;margin-top:26px;border-top:1px solid var(--border);padding-top:10px}
'@

# ---- assemble ---------------------------------------------------------------
$subtitleLine = if ($Subtitle) { HE $Subtitle } else { "数据来源：<span class=""mono"">!execute Tasks.Enumerate</span>（WinDbgCs / SqlScriptRepl 权威镜像脚本）" }

$html = @"
<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8"><title>$(HE $Title) — Case $(HE $CaseId)</title><style>$style</style></head><body>
<h1>$(HE $Title)</h1>
<div class="sub">Case $(HE $CaseId) · $subtitleLine · <a href="$(HE $BackLinkHref)">&lsaquo; 返回全局快照</a></div>
$($cards.ToString())
<div class="note"><b>读法说明：</b>与主报告「第一步」按栈顶推断的 OS 线程状态不同，本表读取 SOS 引擎自维护的 <span class="mono">TaskState</span> 字段，只统计 <b>已绑定到 worker 的 SOS_Task</b>（不含 idle worker-pool 线程）。<span class="mono">nullptr</span> 行为 SEList 遍历中的占位/表分隔行，不计入状态汇总。</div>
$($sb2.ToString())
<div class="note">数据源：<span class="mono">!execute Tasks.Enumerate</span>（WinDbgCs / SqlScriptRepl 权威镜像脚本，非 <span class="mono">task.js</span> 过滤子集）。另 $nullCount 行 <span class="mono">nullptr</span> 占位/表分隔，未计入状态汇总。</div>
$($sb3.ToString())
$($sbN.ToString())
$($sbF.ToString())
<div class="note warn"><b>过滤 minidump 采集局限：</b><span class="mono">Tasks.Enumerate</span> 在遍历 SEList 时对未落盘页面抛 <span class="mono">InvalidMemoryAddressException</span>（原始输出 tail 段 ~30 行），属预期行为，<b>不影响已列出的任务行</b>；<span class="mono">nullptr</span> 行是该异常在表中的占位表现。</div>
<div class="foot">Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') · Src: <span class="mono">$(HE (Split-Path -Leaf $Src))</span> · Renderer: gen_tasks_full_html.ps1</div>
</body></html>
"@

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Out, $html, $utf8NoBom)

# ---- sidecar stats JSON (for overall-report manifest reuse) -----------------
$statsPath = Join-Path $outDir "${CaseId}_tasks_stats.json"
$visibleForJson = foreach ($id in $visibleIds) {
    $v = $pivotMap[$id]
    [pscustomobject]@{
        id = $id; total = $v.Total; SUSPENDED = $v.SUSPENDED
        RUNNABLE = $v.RUNNABLE; RUNNING = $v.RUNNING; DONE = $v.DONE
    }
}
$notableForJson = foreach ($r in $notable) {
    [pscustomobject]@{ sched = $r.Sched; state = $r.State; thread = $r.Thread; func = $r.Func }
}
$stateForJson = [ordered]@{}
foreach ($s in $stateOrder) {
    $stateForJson[$s] = [pscustomobject]@{ count = $stateStats[$s].count; pct = $stateStats[$s].pct }
}
$stats = [pscustomobject]@{
    caseId          = $CaseId
    totalRows       = $total
    totalBound      = $totalBound
    nullptrRows     = $nullCount
    stateSummary    = $stateForJson
    schedulerPivot  = [pscustomobject]@{
        visible = @($visibleForJson)
        hidden  = [pscustomobject]@{
            total = $hidden.Total; SUSPENDED = $hidden.SUSPENDED
            RUNNABLE = $hidden.RUNNABLE; RUNNING = $hidden.RUNNING; DONE = $hidden.DONE
        }
        total   = [pscustomobject]@{
            total = $sumTot; SUSPENDED = $sumSus; RUNNABLE = $sumRbl; RUNNING = $sumRun; DONE = $sumDon
        }
    }
    notable         = @($notableForJson)
}
$stats | ConvertTo-Json -Depth 6 | Out-File -FilePath $statsPath -Encoding utf8

Write-Host "OK: wrote $Out ($total rows, $totalBound bound tasks; nullptr $nullCount)"
Write-Host "OK: wrote $statsPath (stats sidecar)"
