# =============================================================================
# gen_scheduler_monitor_html.ps1 — SQL-CSI dump-overall
#
# Render the SOS Scheduler Monitor ring buffer (or any tabular mirror result)
# as a paginated, self-contained HTML sub-report, and optionally emit a
# smaller HTML fragment containing only the rows within a ±N minute window
# around dump-capture time. The fragment is meant to be embedded as a
# `{ type: "raw", html: "..." }` block in the MAIN overall_report manifest.
#
# INPUT — a JSON manifest (schema below) produced by
#         `parse_scheduler_monitor.ps1` and lightly enriched by the agent.
#
# {
#   "title"          : "SchedulerMonitor 环形缓冲",
#   "caseId"         : "2606250030005483",
#   "subtitle"       : "SOSRingBuffers.EnumerateSchedulerMonitorRecords · 时序列举",
#   "backLink"       : "2606250030005483_overall_report.html",   // optional
#   "wrapper"        : { "RecordType": "RING_BUFFER_SCHEDULER_MONITOR" }, // optional
#   "cols"           : ["Event","NodeId","SchedulerId",...,"TimeStamp"],
#   "rows"           : [ { "Event":"SMR_SYSTEM_HEALTH", ... "TimeStamp":"..." }, ... ],
#   "timestampCol"   : "TimeStamp",   // optional; default auto-detect
#   "dumpTimeStamp"  : "<value>",     // optional; default = MAX row[timestampCol]
#   "windowMinutes"  : 20,            // optional; default 20 (used for ±snippet)
#   "pageSize"       : 100            // optional; default 100
# }
#
# The parser emits string cell values only, so `dumpTimeStamp` / row values
# are compared as **numeric** when they parse cleanly (SOS_TicksFast64 =
# milliseconds since boot) and as **string equality of prefix** otherwise.
#
# OUTPUT
#   -Out         full paginated HTML (Catppuccin Mocha, one page = pageSize rows)
#   -SnippetOut  (optional) HTML *fragment* containing only the ±window rows +
#                a caption, ready to embed as a manifest `raw` block.
#
# Exit codes: 0 ok; 1 manifest missing/invalid; 2 write failed.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Manifest,
    [Parameter(Mandatory)][string]$Out,
    [string]$SnippetOut
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Manifest)) {
    Write-Host "[gen_scheduler_monitor] ERROR: manifest not found: $Manifest" -ForegroundColor Red
    exit 1
}

try {
    $m = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "[gen_scheduler_monitor] ERROR: manifest not valid JSON: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

function HE([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}

# ---- manifest fields (with defaults) ----------------------------------------
$title       = if ($m.title)        { $m.title }        else { 'SchedulerMonitor Ring Buffer' }
$caseId      = if ($m.caseId)       { $m.caseId }       else { '' }
$subtitle    = if ($m.subtitle)     { $m.subtitle }     else { 'SOSRingBuffers.EnumerateSchedulerMonitorRecords' }
$backLink    = if ($m.backLink)     { $m.backLink }     else { '' }
$cols        = @($m.cols)
$rows        = @($m.rows)
$pageSize    = if ($m.pageSize)     { [int]$m.pageSize }     else { 100 }
$windowMin   = if ($m.windowMinutes){ [int]$m.windowMinutes }else { 20 }
$wrapper     = $m.wrapper
# Column name used to classify event rows for coloring / snippet filter.
# Reflection-based captures expose fields as m_Event; older/curated inputs use Event.
$eventCol    = if ($m.eventCol)     { [string]$m.eventCol } else { 'Event' }
if (-not ($cols -contains $eventCol) -and ($cols -contains 'm_Event')) { $eventCol = 'm_Event' }
# Optional snippet-only knobs (used when no timestampCol / window applies).
# snippetEventRegex : rows whose $eventCol matches this regex ALWAYS go into snippet
# snippetLatestN    : also include the first N rows (row order preserved -> newest first for ring buffers)
$snipEventRegex = if ($m.snippetEventRegex) { [string]$m.snippetEventRegex } else { '' }
$snipLatestN    = if ($m.snippetLatestN)    { [int]$m.snippetLatestN }    else { 0 }

if ($cols.Count -eq 0) {
    Write-Host "[gen_scheduler_monitor] ERROR: manifest.cols is empty" -ForegroundColor Red
    exit 1
}

# ---- detect timestamp column ------------------------------------------------
$tsCol = $null
if ($m.timestampCol) {
    $tsCol = [string]$m.timestampCol
} else {
    foreach ($c in $cols) {
        if ($c -match '^(TimeStamp|Timestamp|Time|Id)$') { $tsCol = $c; break }
    }
}

# ---- resolve dump reference timestamp ---------------------------------------
$dumpTsRaw   = $null
$dumpTsNum   = $null
if ($m.dumpTimeStamp) {
    $dumpTsRaw = [string]$m.dumpTimeStamp
} elseif ($tsCol -and $rows.Count -gt 0) {
    # max of the timestamp column as an approximation of "latest = dump time"
    $best = $null; $bestN = [double]::NegativeInfinity
    foreach ($r in $rows) {
        $v = "$($r.$tsCol)"
        $n = 0.0
        if ([double]::TryParse($v, [ref]$n)) {
            if ($n -gt $bestN) { $bestN = $n; $best = $v }
        }
    }
    if ($best) { $dumpTsRaw = $best }
}
if ($dumpTsRaw) {
    $tmp = 0.0
    if ([double]::TryParse($dumpTsRaw, [ref]$tmp)) { $dumpTsNum = $tmp }
}

# Window as milliseconds when comparing SOS_TicksFast64 (ms since boot)
$windowMs = [double]($windowMin * 60 * 1000)

# ---- classify each row: in-window (bool) + delta minutes when applicable ----
$eventCounts = @{}
foreach ($r in $rows) {
    $ev = "$($r.$eventCol)"
    if ($ev) {
        if ($eventCounts.ContainsKey($ev)) { $eventCounts[$ev]++ } else { $eventCounts[$ev] = 1 }
    }
}

function Test-InWindow($row) {
    if (-not $tsCol) { return $false }
    if ($null -eq $dumpTsNum) { return $false }
    $v = "$($row.$tsCol)"
    $n = 0.0
    if (-not [double]::TryParse($v, [ref]$n)) { return $false }
    return ([Math]::Abs($n - $dumpTsNum) -le $windowMs)
}
function Get-DeltaMin($row) {
    if ($null -eq $dumpTsNum -or -not $tsCol) { return '' }
    $v = "$($row.$tsCol)"; $n = 0.0
    if (-not [double]::TryParse($v, [ref]$n)) { return '' }
    $delta = ($n - $dumpTsNum) / 60000.0
    return ('{0:+0.00;-0.00;0.00}' -f $delta)
}

# ---- CSS (Catppuccin Mocha, same palette as other sub-reports) --------------
$style = @'
:root{--bg:#1e1e2e;--surface:#252538;--border:#3a3a55;--text:#cdd6f4;--dim:#a6adc8;
--accent:#89b4fa;--green:#a6e3a1;--yellow:#f9e2af;--orange:#fab387;--red:#f38ba8;--teal:#94e2d5;--mauve:#cba6f7;}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI','Microsoft YaHei',sans-serif;margin:0;padding:24px;line-height:1.5}
h1{color:var(--accent);font-size:22px;margin:0 0 4px}
h2{color:var(--mauve);font-size:17px;margin:26px 0 8px;border-bottom:1px solid var(--border);padding-bottom:6px}
.sub{color:var(--dim);font-size:12px;margin-bottom:16px}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.cards{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0 20px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:8px 12px;min-width:140px}
.card .k{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.5px}
.card .v{color:var(--text);font-size:15px;font-weight:600;margin-top:2px;font-family:'Cascadia Code',Consolas,monospace}
.tags{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0 16px}
.tag{background:#181825;border:1px solid var(--border);border-radius:12px;padding:2px 10px;font-size:11px;font-family:'Cascadia Code',Consolas,monospace}
.tag .n{color:var(--accent);margin-left:4px}
.tag.red{border-color:var(--red);color:var(--red)}
.tag.orange{border-color:var(--orange);color:var(--orange)}
.tag.yellow{border-color:var(--yellow);color:var(--yellow)}
.tag.green{border-color:var(--green);color:var(--green)}
.tag.teal{border-color:var(--teal);color:var(--teal)}
.controls{display:flex;align-items:center;gap:10px;margin:10px 0;flex-wrap:wrap}
.controls button{background:var(--surface);border:1px solid var(--border);color:var(--text);padding:4px 12px;border-radius:6px;cursor:pointer;font-family:inherit}
.controls button:hover{border-color:var(--accent);color:var(--accent)}
.controls button:disabled{opacity:.4;cursor:not-allowed}
.controls input{background:#181825;border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-family:'Cascadia Code',Consolas,monospace;width:80px}
.controls .info{color:var(--dim);font-size:12px}
table{border-collapse:collapse;width:100%;font-size:12px;font-family:'Cascadia Code',Consolas,monospace;margin:6px 0 14px}
th,td{border:1px solid var(--border);padding:4px 8px;text-align:left;vertical-align:top;white-space:nowrap}
th{background:var(--surface);color:var(--accent);font-weight:600;position:sticky;top:0}
tr.window td{background:#2a2540}
tr.window td:first-child{border-left:3px solid var(--yellow)}
td.num{text-align:right}
td.evt-red{color:var(--red)}
td.evt-orange{color:var(--orange)}
td.evt-yellow{color:var(--yellow)}
td.evt-green{color:var(--green)}
td.evt-teal{color:var(--teal)}
.callout{background:#181825;border:1px solid var(--border);border-left:3px solid var(--mauve);border-radius:6px;padding:10px 14px;margin:10px 0;color:var(--dim);font-size:12px}
.callout b{color:var(--text)}
'@

# ---- event-type -> CSS class (SOS_SchedulerMonitorRecord.Event values) ------
function Get-EventClass([string]$ev) {
    switch -Regex ($ev) {
        '^SMR_STUCK_DISPATCHER_'   { 'evt-red' ; break }
        '^SMR_DEADLOCK_'           { 'evt-red' ; break }
        '^SMR_NONYIELD_'           { 'evt-orange' ; break }
        '^SMR_SYSTEM_HEALTH$'      { 'evt-green' ; break }
        default                    { '' }
    }
}
function Get-TagClass([string]$ev) {
    switch -Regex ($ev) {
        '^SMR_STUCK_DISPATCHER_'   { 'red' ; break }
        '^SMR_DEADLOCK_'           { 'red' ; break }
        '^SMR_NONYIELD_'           { 'orange' ; break }
        '^SMR_SYSTEM_HEALTH$'      { 'green' ; break }
        default                    { 'teal' }
    }
}

# ---- render header cards / event-type tags ----------------------------------
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">')
[void]$sb.AppendLine("<title>$(HE $title) · $(HE $caseId)</title><style>$style</style></head><body>")
[void]$sb.AppendLine("<h1>$(HE $title)</h1>")
[void]$sb.AppendLine("<div class=`"sub`">Case $(HE $caseId) · $(HE $subtitle)</div>")
if ($backLink) { [void]$sb.AppendLine("<p><a href=`"$(HE $backLink)`">&larr; 返回主报告</a></p>") }

# meta cards
[void]$sb.AppendLine('<div class="cards">')
[void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">total records</div><div class=`"v`">$($rows.Count)</div></div>")
[void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">columns</div><div class=`"v`">$($cols.Count)</div></div>")
if ($wrapper) {
    foreach ($p in $wrapper.PSObject.Properties) {
        [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">$(HE $p.Name)</div><div class=`"v`">$(HE ([string]$p.Value))</div></div>")
    }
}
if ($tsCol -and $dumpTsRaw) {
    [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">reference ts (${tsCol})</div><div class=`"v`">$(HE $dumpTsRaw)</div></div>")
    [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">window</div><div class=`"v`">&plusmn;${windowMin} min</div></div>")
}
[void]$sb.AppendLine('</div>')

# event-type histogram tags
if ($eventCounts.Count -gt 0) {
    [void]$sb.AppendLine('<h2>事件类型分布 · Event Type Histogram</h2>')
    [void]$sb.AppendLine('<div class="tags">')
    foreach ($ev in ($eventCounts.Keys | Sort-Object)) {
        $cls = Get-TagClass $ev
        [void]$sb.AppendLine("<span class=`"tag $cls`">$(HE $ev)<span class=`"n`">$($eventCounts[$ev])</span></span>")
    }
    [void]$sb.AppendLine('</div>')
}

[void]$sb.AppendLine('<div class="callout">纯列举 — 每行 = 一条 SOS Scheduler Monitor 环形缓冲记录。事件语义、根因判断请见 dump-analysis skill。</div>')

# ---- paginated table --------------------------------------------------------
[void]$sb.AppendLine('<h2>全部记录 · All Records（分页 · pageSize=' + $pageSize + '）</h2>')
[void]$sb.AppendLine('<div class="controls">')
[void]$sb.AppendLine('  <button id="prev">&larr; 上一页</button>')
[void]$sb.AppendLine('  <button id="next">下一页 &rarr;</button>')
[void]$sb.AppendLine('  <span class="info">Page <b id="page">1</b> / <b id="pages">1</b> · rows <b id="range"></b></span>')
[void]$sb.AppendLine('  <span class="info">Jump to page:</span><input id="jump" type="number" min="1" value="1" />')
[void]$sb.AppendLine('  <label class="info"><input type="checkbox" id="onlyWin" /> only ±window rows</label>')
[void]$sb.AppendLine('</div>')

[void]$sb.AppendLine('<table id="rows"><thead><tr>')
if ($tsCol) { [void]$sb.AppendLine('<th>Δ min</th>') }
foreach ($c in $cols) { [void]$sb.AppendLine("<th>$(HE $c)</th>") }
[void]$sb.AppendLine('</tr></thead><tbody>')

$idx = 0
foreach ($r in $rows) {
    $inWin = Test-InWindow $r
    $rowClass = if ($inWin) { ' class="row window"' } else { ' class="row"' }
    [void]$sb.AppendLine("<tr$rowClass data-win=`"$([int]$inWin)`">")
    if ($tsCol) {
        $dm = Get-DeltaMin $r
        [void]$sb.AppendLine("<td class=`"num`">$(HE $dm)</td>")
    }
    foreach ($c in $cols) {
        $val = "$($r.$c)"
        $tdCls = ''
        if ($c -eq $eventCol) {
            $ecls = Get-EventClass $val
            if ($ecls) { $tdCls = " class=`"$ecls`"" }
        }
        [void]$sb.AppendLine("<td$tdCls>$(HE $val)</td>")
    }
    [void]$sb.AppendLine('</tr>')
    $idx++
}
[void]$sb.AppendLine('</tbody></table>')

# ---- pagination JS ----------------------------------------------------------
$js = @"
<script>
(function(){
  var pageSize = $pageSize;
  var rows = Array.prototype.slice.call(document.querySelectorAll('#rows tbody tr'));
  var page = 1;
  var onlyWin = false;
  var elPage = document.getElementById('page');
  var elPages = document.getElementById('pages');
  var elRange = document.getElementById('range');
  var elJump = document.getElementById('jump');
  var elPrev = document.getElementById('prev');
  var elNext = document.getElementById('next');
  var elOnly = document.getElementById('onlyWin');

  function visibleRows(){
    if (!onlyWin) return rows;
    return rows.filter(function(r){ return r.getAttribute('data-win') === '1'; });
  }
  function render(){
    var vis = visibleRows();
    var pages = Math.max(1, Math.ceil(vis.length / pageSize));
    if (page > pages) page = pages;
    if (page < 1) page = 1;
    var start = (page - 1) * pageSize;
    var end = Math.min(vis.length, start + pageSize);
    // hide all
    for (var i=0;i<rows.length;i++){ rows[i].style.display='none'; }
    // if filtered, hide non-window entirely; else show slice of all
    if (onlyWin){
      for (var j=0;j<vis.length;j++){
        vis[j].style.display = (j >= start && j < end) ? '' : 'none';
      }
    } else {
      for (var k=start;k<end;k++){ rows[k].style.display=''; }
    }
    elPage.textContent = page;
    elPages.textContent = pages;
    elRange.textContent = (vis.length ? (start+1) : 0) + '-' + end + ' / ' + vis.length;
    elJump.value = page;
    elPrev.disabled = (page <= 1);
    elNext.disabled = (page >= pages);
  }
  elPrev.addEventListener('click', function(){ page--; render(); });
  elNext.addEventListener('click', function(){ page++; render(); });
  elJump.addEventListener('change', function(){ page = parseInt(elJump.value,10) || 1; render(); });
  elOnly.addEventListener('change', function(){ onlyWin = elOnly.checked; page = 1; render(); });
  render();
})();
</script>
"@
[void]$sb.AppendLine($js)
[void]$sb.AppendLine('</body></html>')

# ---- write full HTML --------------------------------------------------------
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
try {
    [System.IO.File]::WriteAllText(
        $Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false))
    )
} catch {
    Write-Host "[gen_scheduler_monitor] ERROR: write failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

# ---- optional snippet (raw HTML fragment for main-report manifest) ----------
if ($SnippetOut) {
    $snip = [System.Text.StringBuilder]::new()
    [void]$snip.AppendLine('<div class="callout">')
    if ($tsCol -and $dumpTsRaw) {
        [void]$snip.AppendLine("SchedulerMonitor 记录 · dump 时刻前后 &plusmn;${windowMin} 分钟切片 · 参考 <b>${tsCol}=$(HE $dumpTsRaw)</b>")
    } elseif ($snipEventRegex -or $snipLatestN -gt 0) {
        $parts = @()
        if ($snipEventRegex) { $parts += "事件 &tilde; /$(HE $snipEventRegex)/" }
        if ($snipLatestN -gt 0) { $parts += "最近 $snipLatestN 条" }
        [void]$snip.AppendLine("SchedulerMonitor 记录 · 精选切片（" + ($parts -join ' · ') + '）')
    } else {
        [void]$snip.AppendLine('SchedulerMonitor 记录 · ±' + $windowMin + ' 分钟切片（缺少参考时间 → 显示全部行）')
    }
    [void]$snip.AppendLine('</div>')

    $winRows = @()
    $snipMode = ''
    if ($tsCol -and $null -ne $dumpTsNum) {
        $winRows = @($rows | Where-Object { Test-InWindow $_ })
        $snipMode = "window"
    } elseif ($snipEventRegex -or $snipLatestN -gt 0) {
        # No wall-clock timestamp → use event-regex + latest-N selection.
        $picked = New-Object System.Collections.Generic.HashSet[int]
        if ($snipEventRegex) {
            for ($ri = 0; $ri -lt $rows.Count; $ri++) {
                $ev = "$($rows[$ri].$eventCol)"
                if ($ev -match $snipEventRegex) { [void]$picked.Add($ri) }
            }
        }
        if ($snipLatestN -gt 0) {
            $take = [Math]::Min($snipLatestN, $rows.Count)
            for ($ri = 0; $ri -lt $take; $ri++) { [void]$picked.Add($ri) }
        }
        $winRows = @($picked | Sort-Object | ForEach-Object { $rows[$_] })
        $snipMode = "event+latest"
    } else {
        $winRows = @($rows)
        $snipMode = "all"
    }

    if ($winRows.Count -eq 0) {
        [void]$snip.AppendLine('<div class="callout"><b>0 rows</b> in ±' + $windowMin + ' min window. See full sub-report for the complete ring buffer.</div>')
    } else {
        [void]$snip.AppendLine('<table>')
        [void]$snip.AppendLine('<thead><tr>')
        if ($tsCol) { [void]$snip.AppendLine('<th>Δ min</th>') }
        foreach ($c in $cols) { [void]$snip.AppendLine("<th>$(HE $c)</th>") }
        [void]$snip.AppendLine('</tr></thead><tbody>')
        foreach ($r in $winRows) {
            [void]$snip.AppendLine('<tr>')
            if ($tsCol) {
                $dm = Get-DeltaMin $r
                [void]$snip.AppendLine("<td class=`"num`">$(HE $dm)</td>")
            }
            foreach ($c in $cols) {
                $val = "$($r.$c)"
                $tdCls = ''
                if ($c -eq $eventCol) {
                    $ecls = Get-EventClass $val
                    if ($ecls) { $tdCls = " class=`"$ecls`"" }
                }
                [void]$snip.AppendLine("<td$tdCls>$(HE $val)</td>")
            }
            [void]$snip.AppendLine('</tr>')
        }
        [void]$snip.AppendLine('</tbody></table>')
    }

    $snipDir = Split-Path -Parent $SnippetOut
    if ($snipDir -and -not (Test-Path -LiteralPath $snipDir)) {
        New-Item -ItemType Directory -Path $snipDir -Force | Out-Null
    }
    try {
        [System.IO.File]::WriteAllText(
            $SnippetOut, $snip.ToString(), (New-Object System.Text.UTF8Encoding($false))
        )
    } catch {
        Write-Host "[gen_scheduler_monitor] ERROR: snippet write failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 2
    }
    Write-Host ("[gen_scheduler_monitor] snippet: {0}  ({1} rows in window)" -f $SnippetOut, $winRows.Count)
}

Write-Host ("[gen_scheduler_monitor] OK: {0}  ({1} rows, {2} cols)" -f $Out, $rows.Count, $cols.Count)
exit 0
