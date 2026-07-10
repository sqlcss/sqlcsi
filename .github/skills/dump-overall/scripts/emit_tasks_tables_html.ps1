<#
emit_tasks_tables_html.ps1 — Emit 表 2 (state summary) + 表 3 (scheduler pivot)
                             HTML fragments from a <case>_tasks_stats.json
                             sidecar produced by gen_tasks_full_html.ps1.

USE-CASE: the SQL-CSI dump-overall main report (`<case>_overall_report.html`)
is manifest-driven — see gen_overall_report.ps1. To keep the overall report's
task-state tables in perfect sync with the tasks subreport, the manifest
builder should:
  1. Run gen_tasks_full_html.ps1 first (produces stats JSON sidecar).
  2. Run this script to render the two HTML fragments.
  3. Embed each fragment as a `raw` block in the manifest sections array.

INPUT  : <case>_tasks_stats.json (schema documented in gen_tasks_full_html.ps1)

OUTPUT : one or two HTML fragment files (fully self-contained tables, using
         the same CSS class names as gen_overall_report.ps1: `.mono`, `.num`,
         `.tag`, `.t-run|t-rbl|t-sus|t-idle`, `.note`).

USAGE  : .\emit_tasks_tables_html.ps1 `
             -Stats  <case>_tasks_stats.json `
             -Out2   <case>_tbl2_state_summary.html `
             -Out3   <case>_tbl3_scheduler_pivot.html `
             [-TasksLinkHref  <case>_tasks.html]   # for the note under 表 2

NOTE format under 表 2 (single, not duplicated):
  数据源：!execute Tasks.Enumerate（WinDbgCs / SqlScriptRepl 权威镜像脚本，非
  task.js 过滤子集）。完整 N 行任务清单见 <a href="...">任务级明细页 ›</a>。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Stats,
    [Parameter(Mandatory)][string]$Out2,
    [Parameter(Mandatory)][string]$Out3,
    [string]$TasksLinkHref = '',
    # Data provenance — defaults match the FALLBACK (!execute Tasks.Enumerate) path so
    # existing callers stay byte-identical. PRIMARY (DumpViewer Tasks 侧栏) callers pass
    # DumpViewer-flavored strings.
    [string]$SourceHeaderHtml = '<span class="mono">!execute Tasks.Enumerate</span>',
    [string]$SourceNoteHtml   = '数据源：<span class="mono">!execute Tasks.Enumerate</span>（WinDbgCs / SqlScriptRepl 权威镜像脚本，非 <span class="mono">task.js</span> 过滤子集）。'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Stats)) { throw "Stats sidecar not found: $Stats" }
$s = Get-Content $Stats -Raw -Encoding UTF8 | ConvertFrom-Json

function HE([string]$x) {
    if ($null -eq $x) { return '' }
    return ($x -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}
function StateTag([string]$state) {
    switch ($state) {
        'RUNNING'   { '<span class="tag t-run">RUNNING</span>' }
        'RUNNABLE'  { '<span class="tag t-rbl">RUNNABLE</span>' }
        'SUSPENDED' { '<span class="tag t-sus">SUSPENDED</span>' }
        'DONE'      { '<span class="tag t-idle">DONE</span>' }
        default     { "<span class=""tag t-idle"">$(HE $state)</span>" }
    }
}

$stateOrder = @('SUSPENDED','RUNNABLE','RUNNING','DONE')
$totalBound = [int]$s.totalBound

# ---- 表 2 -------------------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("<h3>表 2 · SQLOS 任务级状态（$SourceHeaderHtml · 权威 TaskState，共 $totalBound 个 task）</h3>")
[void]$sb.Append('<table><thead><tr><th>TaskState</th><th class="num">数量</th><th class="num">占比</th></tr></thead><tbody>')
foreach ($st in $stateOrder) {
    $c = [int]$s.stateSummary.$st.count
    $p = [double]$s.stateSummary.$st.pct
    [void]$sb.Append("<tr><td>$(StateTag $st)</td><td class=""num"">$c</td><td class=""num"">$($p.ToString('0.0'))%</td></tr>")
}
[void]$sb.Append("<tr><td><b>合计</b></td><td class=""num""><b>$totalBound</b></td><td class=""num""><b>100%</b></td></tr>")
[void]$sb.Append('</tbody></table>')

$note = $SourceNoteHtml
if ($TasksLinkHref) {
    $note += "完整 $([int]$s.totalRows) 行任务清单见 <a href=""$(HE $TasksLinkHref)"">任务级明细页 &rsaquo;</a>。"
}
[void]$sb.Append("<div class=""note"">$note</div>")

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$outDir2 = Split-Path -Parent $Out2
if ($outDir2 -and -not (Test-Path $outDir2)) { New-Item -ItemType Directory -Force -Path $outDir2 | Out-Null }
[System.IO.File]::WriteAllText($Out2, $sb.ToString(), $utf8NoBom)
Write-Host "OK: wrote $Out2"

# ---- 表 3 -------------------------------------------------------------------
$sb3 = New-Object System.Text.StringBuilder
[void]$sb3.Append('<h3>表 3 · 按调度器分布（Tasks.Enumerate 按 SchedulerId 透视 · 纯计数）</h3>')
[void]$sb3.Append('<table><thead><tr><th class="num">调度器</th><th class="num">总数</th><th class="num">SUSPENDED</th><th class="num">RUNNABLE</th><th class="num">RUNNING</th><th class="num">DONE</th></tr></thead><tbody>')
foreach ($v in $s.schedulerPivot.visible) {
    [void]$sb3.Append("<tr><td class=""num"">$($v.id)</td><td class=""num"">$($v.total)</td><td class=""num"">$($v.SUSPENDED)</td><td class=""num"">$($v.RUNNABLE)</td><td class=""num"">$($v.RUNNING)</td><td class=""num"">$($v.DONE)</td></tr>")
}
$h = $s.schedulerPivot.hidden
[void]$sb3.Append("<tr><td class=""num"">隐藏/系统 (id&ge;1048576)</td><td class=""num"">$($h.total)</td><td class=""num"">$($h.SUSPENDED)</td><td class=""num"">$($h.RUNNABLE)</td><td class=""num"">$($h.RUNNING)</td><td class=""num"">$($h.DONE)</td></tr>")
$t = $s.schedulerPivot.total
[void]$sb3.Append("<tr><td><b>合计</b></td><td class=""num""><b>$($t.total)</b></td><td class=""num""><b>$($t.SUSPENDED)</b></td><td class=""num""><b>$($t.RUNNABLE)</b></td><td class=""num""><b>$($t.RUNNING)</b></td><td class=""num""><b>$($t.DONE)</b></td></tr>")
[void]$sb3.Append('</tbody></table>')

$outDir3 = Split-Path -Parent $Out3
if ($outDir3 -and -not (Test-Path $outDir3)) { New-Item -ItemType Directory -Force -Path $outDir3 | Out-Null }
[System.IO.File]::WriteAllText($Out3, $sb3.ToString(), $utf8NoBom)
Write-Host "OK: wrote $Out3"
