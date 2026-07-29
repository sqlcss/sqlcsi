# =============================================================================
# build_ringbuf_reports.ps1  (dump-overall skill — committed)
#
# Parse the 9 cdb/WinDbgCs `!execute` ring-buffer / summary txt captures under
# {Dir}\txt_detail\, emit one paginated HTML sub-report per expression, then
# inject a 「附加步骤 · SOS 环形缓冲 / 摘要全量列举（9 条 !execute）」 section into
# the canonical {CaseId}_overall_manifest.json and regenerate
# {CaseId}_overall_report.html via gen_overall_report.ps1.
#
# Each of the 9 sections in the MAIN report shows, per expression:
#   ① dump 前 top {TopN} 最新记录（position 降序）
#   ② 值得注意的记录（规则化异常判定；命中 0 则显式绿色标注）
#   + 顶部类别直方图，+ 长期未更新缓冲的「距 dump N 天」陈旧标注。
# Pure enumeration + rule-based flagging — NO root-cause analysis (that is the
# dump-analysis skill's job). Anomaly rules live in Get-Anomalies() and are
# meant to be adjusted per case. Catppuccin Mocha theme, no-BOM UTF-8.
#
# Inputs: the 9 raw txt captures named {CaseId}_{expr}.txt in {TxtDir}
# (produced by !execute via cdb+!dcs_initsymsvr or SqlScriptRepl — see SKILL 1.8).
# If acquisition used run_windbgcs_direct.ps1, first run split_direct_mirror_log.ps1
# on the combined `{CaseId}_phase1_direct.txt` log; do not feed/link the combined
# raw log as the report result.
# Run with pwsh (PS7) — powershell 5.1 corrupts the Chinese literals.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Dir,                       # {CaseId}_dump_overall folder
    [string]$TxtDir = '',                                     # default {Dir}\txt_detail
    [Parameter(Mandatory)][string]$CaseId,
    [int]$TopN     = 20,
    [int]$PageSize = 100,
    [string]$Manifest  = '',                                  # default {Dir}\{CaseId}_overall_manifest.json
    [string]$Generator = ''                                   # default sibling gen_overall_report.ps1
)
$ErrorActionPreference = 'Stop'
if (-not $TxtDir)    { $TxtDir    = Join-Path $Dir 'txt_detail' }
if (-not $Manifest)  { $Manifest  = Join-Path $Dir ("{0}_overall_manifest.json" -f $CaseId) }
if (-not $Generator) { $Generator = Join-Path $PSScriptRoot 'gen_overall_report.ps1' }
if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

# ---- expression specs (fixed order; catCol = 类别直方图列, '' = 无) -----------
$specs = @(
    @{ file='ProcessSummary.Enumerate';                                 expr='ProcessSummary.Enumerate';                                 label='进程摘要 · Process Summary';            catCol=''                 }
    @{ file='SOSRingBuffers.EnumerateMemoryBrokerRingRecords';          expr='SOSRingBuffers.EnumerateMemoryBrokerRingRecords';          label='Memory Broker 环形缓冲';                catCol='m_type'           }
    @{ file='SOSRingBuffers.EnumerateBlockedProcessReportRingBufferRecords'; expr='SOSRingBuffers.EnumerateBlockedProcessReportRingBufferRecords'; label='阻塞进程报告 环形缓冲';          catCol=''                 }
    @{ file='SOSRingBuffers.EnumerateMemoryBrokerClerkRingRecords';     expr='SOSRingBuffers.EnumerateMemoryBrokerClerkRingRecords';     label='Memory Broker Clerk 环形缓冲';          catCol='m_clerk'          }
    @{ file='SOSRingBuffers.EnumerateSchedulerMonitorRecords';          expr='SOSRingBuffers.EnumerateSchedulerMonitorRecords';          label='Scheduler Monitor 环形缓冲';            catCol='m_event'          }
    @{ file='SOSRingBuffers.EnumerateExceptionRingRecords';             expr='SOSRingBuffers.EnumerateExceptionRingRecords';             label='Exception 环形缓冲';                    catCol='m_error'          }
    @{ file='SOSRingBuffers.EnumerateSchedulerRingRecords';             expr='SOSRingBuffers.EnumerateSchedulerRingRecords';             label='Scheduler 环形缓冲';                    catCol=''                 }
    @{ file='SOSRingBuffers.EnumerateHadrArPubishEventsRecords';        expr='SOSRingBuffers.EnumerateHadrArPubishEventsRecords';        label='HADR AR Publish Events 环形缓冲';       catCol='m_current_ar_role'}
    @{ file='SOSRingBuffers.EnumerateHadrArSignalStateRecords';         expr='SOSRingBuffers.EnumerateHadrArSignalStateRecords';         label='HADR AR Signal State 环形缓冲';         catCol='m_signal_type'    }
)

function HE([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}

# ---- parse one cdb ring-buffer txt -> @{cols=[];rows=[];note=''} --------------
function Parse-Ringbuf([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @{ cols=@(); rows=@(); note='文件不存在' } }
    $lines = [System.IO.File]::ReadAllLines($path)
    # header = first line starting with 'record' and containing ' | '
    $hdrIdx = -1
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^record\s+\|') { $hdrIdx = $i; break }
    }
    if ($hdrIdx -lt 0) {
        # no table -> capture a short reason from the body
        $body = ($lines | Where-Object { $_ -match '\S' -and $_ -notmatch 'SCRIPTS|Loaded:|All:|Help \||Running:|!execute' } | Select-Object -First 3) -join ' / '
        return @{ cols=@(); rows=@(); note=($body ?? '无记录') }
    }
    $cols = @(($lines[$hdrIdx] -split '\s*\|\s*') | ForEach-Object { $_.Trim() })
    $rows = New-Object System.Collections.ArrayList
    for ($k=$hdrIdx+1; $k -lt $lines.Count; $k++) {
        $ln = $lines[$k]
        if ($ln -notmatch '^0x[0-9a-fA-F]{16}\s*\|') { continue }   # only real record rows
        $cells = @(($ln -split '\s*\|\s*') | ForEach-Object { $_.Trim() })
        if ($cells.Count -lt $cols.Count) { $cells += @('') * ($cols.Count - $cells.Count) }
        elseif ($cells.Count -gt $cols.Count) {
            $tail = ($cells[($cols.Count-1)..($cells.Count-1)] -join ' | ')
            $cells = $cells[0..($cols.Count-2)] + $tail
        }
        $obj = [ordered]@{}
        for ($c=0; $c -lt $cols.Count; $c++) { $obj[$cols[$c]] = $cells[$c] }
        [void]$rows.Add($obj)
    }
    return @{ cols=$cols; rows=@($rows); note='' }
}

# ---- render an HTML table for a set of rows ----------------------------------
function Render-Table([array]$cols, [array]$rows, [string]$catCol) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<div class="tblwrap"><table><thead><tr>')
    foreach ($c in $cols) { [void]$sb.AppendLine("<th>$(HE $c)</th>") }
    [void]$sb.AppendLine('</tr></thead><tbody>')
    foreach ($r in $rows) {
        [void]$sb.AppendLine('<tr>')
        foreach ($c in $cols) { [void]$sb.AppendLine("<td>$(HE ([string]$r[$c]))</td>") }
        [void]$sb.AppendLine('</tr>')
    }
    [void]$sb.AppendLine('</tbody></table></div>')
    return $sb.ToString()
}

# ---- category histogram (top values of catCol) -------------------------------
function Build-Histogram([array]$rows, [string]$catCol) {
    if (-not $catCol -or $rows.Count -eq 0) { return @() }
    $h = @{}
    foreach ($r in $rows) { $v = [string]$r[$catCol]; if ($v) { if ($h.ContainsKey($v)) { $h[$v]++ } else { $h[$v]=1 } } }
    return @($h.GetEnumerator() | Sort-Object @{Expression='Value';Descending=$true}, @{Expression='Key';Ascending=$true} | ForEach-Object { @{ k=$_.Key; n=$_.Value } })
}

# ---- numeric parse: "13706324(0xd12454)" / "14(0xe)" -> int64 ----------------
function NumOf($v) {
    if ($null -eq $v) { return $null }
    if ([string]$v -match '^\s*(-?\d+)') { return [int64]$Matches[1] }
    return $null
}

# ---- newest-record age in whole days from an m_time_stamp cell ---------------
# "...Age: 66.01:47:22.16" -> 66 ; "...Age: 00:09:32.07" -> 0
function AgeDays([string]$ts) {
    if ($ts -match 'Age:\s*(\d+)\.\d{2}:') { return [int]$Matches[1] }
    return 0
}

# ---- rule-based anomaly selection per ring buffer ----------------------------
# Returns @{ rows=<flagged records, newest-first>; label=<human rule text> }.
function Get-Anomalies([string]$expr, [array]$cols, [array]$rows) {
    $flag = New-Object System.Collections.ArrayList
    $label = ''
    switch -Wildcard ($expr) {
        '*MemoryBrokerRingRecords' {
            $label = 'm_last_notification 含 SHRINK（内存收缩压力）'
            foreach ($r in $rows) { if (([string]$r['m_last_notification']) -match 'SHRINK') { [void]$flag.Add($r) } }
        }
        '*MemoryBrokerClerkRingRecords' {
            $label = 'm_internal_freed_pages>0 或 m_periodic_freed_pages>0（clerk 被要求释放内存）'
            foreach ($r in $rows) { if ((NumOf $r['m_internal_freed_pages']) -gt 0 -or (NumOf $r['m_periodic_freed_pages']) -gt 0) { [void]$flag.Add($r) } }
        }
        '*SchedulerMonitorRecords' {
            $label = 'm_event ≠ SMR_SYSTEM_HEALTH（STUCK_DISPATCHER / NONYIELD / DEADLOCK），或 m_process_utilization>90（high CPU），或 m_working_set_delta 释放物理内存>100MB（<-104857600 字节）'
            foreach ($r in $rows) {
                $pu  = NumOf $r['m_process_utilization']
                $wsd = NumOf $r['m_working_set_delta']
                if ((([string]$r['m_event']) -ne 'SMR_SYSTEM_HEALTH') -or `
                    ($null -ne $pu -and $pu -gt 90) -or `
                    ($null -ne $wsd -and $wsd -lt -104857600)) { [void]$flag.Add($r) }
            }
        }
        '*ExceptionRingRecords' {
            $label = 'm_severity ≥ 19（高危）或主导洪泛错误码 top-1 的最新样本（≤15）'
            $h = @{}
            foreach ($r in $rows) { $e=[string]$r['m_error']; if ($e) { if ($h.ContainsKey($e)) { $h[$e]++ } else { $h[$e]=1 } } }
            $top = ($h.GetEnumerator() | Sort-Object @{Expression='Value';Descending=$true}, @{Expression='Key';Ascending=$true} | Select-Object -First 1).Key
            $sampled = 0
            foreach ($r in $rows) {
                $sev = NumOf $r['m_severity']
                if ($null -ne $sev -and $sev -ge 19) { [void]$flag.Add($r) }
                elseif (([string]$r['m_error']) -eq $top -and $sampled -lt 15) { [void]$flag.Add($r); $sampled++ }
            }
        }
        '*SchedulerRingRecords' {
            $label = 'm_return_code ≠ 0（非成功返回码）'
            foreach ($r in $rows) { $rc = NumOf $r['m_return_code']; if ($null -ne $rc -and $rc -ne 0) { [void]$flag.Add($r) } }
        }
        '*HadrArPubishEventsRecords' {
            $label = 'm_has_exception=True 或 m_current_ar_role ∉ {PRIMARY_NORMAL, SECONDARY_NORMAL}（RESOLVING/PENDING 角色迁移）'
            foreach ($r in $rows) {
                $role=[string]$r['m_current_ar_role']; $ex=[string]$r['m_has_exception']
                if ($ex -eq 'True' -or $role -notmatch 'PRIMARY_NORMAL|SECONDARY_NORMAL') { [void]$flag.Add($r) }
            }
        }
        '*HadrArSignalStateRecords' {
            $label = '少数派 m_signal_type（≠ 主导信号类型）'
            $h = @{}
            foreach ($r in $rows) { $v=[string]$r['m_signal_type']; if ($v) { if ($h.ContainsKey($v)) { $h[$v]++ } else { $h[$v]=1 } } }
            $dom = ($h.GetEnumerator() | Sort-Object @{Expression='Value';Descending=$true}, @{Expression='Key';Ascending=$true} | Select-Object -First 1).Key
            foreach ($r in $rows) { if (([string]$r['m_signal_type']) -ne $dom) { [void]$flag.Add($r) } }
        }
        default { $label = '' }
    }
    return @{ rows=@($flag); label=$label }
}

# ---- shared CSS --------------------------------------------------------------
$css = @'
:root{--bg:#1e1e2e;--surface:#252538;--border:#3a3a55;--text:#cdd6f4;--dim:#a6adc8;
--accent:#89b4fa;--green:#a6e3a1;--yellow:#f9e2af;--orange:#fab387;--red:#f38ba8;--teal:#94e2d5;--mauve:#cba6f7;}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI','Microsoft YaHei',sans-serif;margin:0;padding:24px;line-height:1.5}
h1{color:var(--accent);font-size:22px;margin:0 0 4px}
h2{color:var(--mauve);font-size:17px;margin:26px 0 8px;border-bottom:1px solid var(--border);padding-bottom:6px}
h3{color:var(--teal);font-size:14px;margin:16px 0 6px}
.sub{color:var(--dim);font-size:12px;margin-bottom:16px}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.cards{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0 16px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:8px 12px;min-width:130px}
.card .k{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.5px}
.card .v{color:var(--text);font-size:15px;font-weight:600;margin-top:2px;font-family:'Cascadia Code',Consolas,monospace}
.tags{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0 14px}
.tag{background:#181825;border:1px solid var(--border);border-radius:12px;padding:2px 10px;font-size:11px;font-family:'Cascadia Code',Consolas,monospace}
.tag .n{color:var(--accent);margin-left:4px}
.tblwrap{overflow-x:auto;border:1px solid var(--border);border-radius:6px;margin:6px 0 14px}
table{border-collapse:collapse;width:100%;font-size:12px;font-family:'Cascadia Code',Consolas,monospace}
th,td{border:1px solid var(--border);padding:4px 8px;text-align:left;vertical-align:top;white-space:nowrap}
th{background:var(--surface);color:var(--accent);font-weight:600;position:sticky;top:0}
.controls{display:flex;align-items:center;gap:10px;margin:10px 0;flex-wrap:wrap}
.controls button{background:var(--surface);border:1px solid var(--border);color:var(--text);padding:4px 12px;border-radius:6px;cursor:pointer;font-family:inherit}
.controls button:hover{border-color:var(--accent);color:var(--accent)}
.controls button:disabled{opacity:.4;cursor:not-allowed}
.controls input{background:#181825;border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-family:'Cascadia Code',Consolas,monospace;width:80px}
.controls .info{color:var(--dim);font-size:12px}
.callout{background:#181825;border:1px solid var(--border);border-left:3px solid var(--mauve);border-radius:6px;padding:10px 14px;margin:10px 0;color:var(--dim);font-size:12px}
.callout b{color:var(--text)}
.empty{color:var(--yellow)}
.secmeta{color:var(--dim);font-size:12px;margin:2px 0 8px}
'@

# ---- pagination JS template (per sub-report) ---------------------------------
function PaginationJs([int]$pageSize) {
@"
<script>
(function(){
  var pageSize=$pageSize;
  var rows=Array.prototype.slice.call(document.querySelectorAll('#rows tbody tr'));
  var page=1;
  var elPage=document.getElementById('page'),elPages=document.getElementById('pages'),
      elRange=document.getElementById('range'),elJump=document.getElementById('jump'),
      elPrev=document.getElementById('prev'),elNext=document.getElementById('next');
  function render(){
    var pages=Math.max(1,Math.ceil(rows.length/pageSize));
    if(page>pages)page=pages; if(page<1)page=1;
    var start=(page-1)*pageSize,end=Math.min(rows.length,start+pageSize);
    for(var i=0;i<rows.length;i++)rows[i].style.display='none';
    for(var k=start;k<end;k++)rows[k].style.display='';
    elPage.textContent=page;elPages.textContent=pages;
    elRange.textContent=(rows.length?(start+1):0)+'-'+end+' / '+rows.length;
    elJump.value=page;elPrev.disabled=(page<=1);elNext.disabled=(page>=pages);
  }
  elPrev.addEventListener('click',function(){page--;render();});
  elNext.addEventListener('click',function(){page++;render();});
  elJump.addEventListener('change',function(){page=parseInt(elJump.value,10)||1;render();});
  render();
})();
</script>
"@
}

# ---- main assembly -----------------------------------------------------------
$parsed = @{}
$subLinks = @{}

foreach ($s in $specs) {
    $txt = Join-Path $TxtDir ("{0}_{1}.txt" -f $CaseId, $s.file)
    $p = Parse-Ringbuf $txt
    $parsed[$s.expr] = $p

    # -- sub-report ------------------------------------------------------------
    $subName = "{0}_sub_{1}.html" -f $CaseId, ($s.file -replace '[^A-Za-z0-9]','_')
    $subPath = Join-Path $Dir $subName
    $subLinks[$s.expr] = $subName

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">')
    [void]$sb.AppendLine("<title>$(HE $s.label) · $CaseId</title><style>$css</style></head><body>")
    [void]$sb.AppendLine("<h1>$(HE $s.label)</h1>")
    [void]$sb.AppendLine("<div class=`"sub`">Case $CaseId · <code>!execute $(HE $s.expr)</code></div>")
    [void]$sb.AppendLine("<p><a href=`"$($CaseId)_overall_report.html`">&larr; 返回主报告（Overall Snapshot）</a></p>")

    if ($p.rows.Count -eq 0) {
        [void]$sb.AppendLine("<div class=`"callout empty`"><b>无记录。</b> $(HE $p.note)</div>")
    } else {
        [void]$sb.AppendLine('<div class="cards">')
        [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">total records</div><div class=`"v`">$($p.rows.Count)</div></div>")
        [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">columns</div><div class=`"v`">$($p.cols.Count)</div></div>")
        $ts0 = ''
        if ($p.cols -contains 'm_time_stamp') { if ($p.rows[0]['m_time_stamp'] -match 'Date:\s*([0-9T:\.\-]+)') { $ts0 = $Matches[1] } }
        if ($ts0) { [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">newest record</div><div class=`"v`">$(HE $ts0)</div></div>") }
        [void]$sb.AppendLine('</div>')

        $hist = Build-Histogram $p.rows $s.catCol
        if ($hist.Count -gt 0) {
            [void]$sb.AppendLine("<h2>类别分布 · $(HE $s.catCol)</h2><div class=`"tags`">")
            foreach ($e in $hist) { [void]$sb.AppendLine("<span class=`"tag`">$(HE $e.k)<span class=`"n`">$($e.n)</span></span>") }
            [void]$sb.AppendLine('</div>')
        }

        $ageD_sub = AgeDays $p.rows[0]['m_time_stamp']
        if ($ageD_sub -gt 0) { [void]$sb.AppendLine("<div class=`"callout`" style=`"border-left-color:var(--yellow);color:var(--yellow)`">⚠ 最新记录距 dump 约 <b>$ageD_sub 天</b> —— 该环形缓冲长期未更新，并非 dump 前近期活动。</div>") }
        $an_sub = Get-Anomalies $s.expr $p.cols $p.rows
        if ($an_sub.label) {
            [void]$sb.AppendLine("<h2>值得注意的记录 · Anomalies</h2>")
            [void]$sb.AppendLine("<div class=`"secmeta`">异常判定规则：<code>$(HE $an_sub.label)</code></div>")
            if ($an_sub.rows.Count -eq 0) {
                [void]$sb.AppendLine("<div class=`"callout`" style=`"border-left-color:var(--green);color:var(--green)`">无符合规则的异常记录。</div>")
            } else {
                $showS = [Math]::Min(50, $an_sub.rows.Count)
                [void]$sb.AppendLine("<div class=`"secmeta`">命中 <b>$($an_sub.rows.Count)</b> 条，显示前 $showS 条：</div>")
                [void]$sb.AppendLine((Render-Table $p.cols @($an_sub.rows[0..($showS-1)]) $s.catCol))
            }
        }
        [void]$sb.AppendLine('<div class="callout">纯列举 — 每行 = 一条环形缓冲记录（position 降序 = 最新在前）。语义/根因判断见 dump-analysis skill。</div>')
        [void]$sb.AppendLine("<h2>全部记录 · All Records（分页 pageSize=$PageSize）</h2>")
        [void]$sb.AppendLine('<div class="controls"><button id="prev">&larr; 上一页</button><button id="next">下一页 &rarr;</button>')
        [void]$sb.AppendLine('<span class="info">Page <b id="page">1</b> / <b id="pages">1</b> · rows <b id="range"></b></span>')
        [void]$sb.AppendLine('<span class="info">Jump:</span><input id="jump" type="number" min="1" value="1" /></div>')
        $tbl = Render-Table $p.cols $p.rows $s.catCol
        $tbl = $tbl -replace '<table>', '<table id="rows">'
        [void]$sb.AppendLine($tbl)
        [void]$sb.AppendLine((PaginationJs $PageSize))
    }
    [void]$sb.AppendLine('</body></html>')
    [System.IO.File]::WriteAllText($subPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("[sub] {0,-52} records={1,-6} -> {2}" -f $s.expr, $p.rows.Count, $subName)
}

# ---- inject 9 ringbuf sections into the canonical overall_report -------------
# Build one 'raw' block per expression (h3 + meta/link + 异常直方图 + dump 前 top N),
# then splice them into <case>_overall_manifest.json as a new 附加步骤 section and
# regenerate <case>_overall_report.html via the committed generator.
$rawBlocks = New-Object System.Collections.ArrayList

$style = @'
<style>
.rbwrap{overflow-x:auto;border:1px solid var(--border);border-radius:6px;margin:6px 0 14px}
.rbwrap table{font-size:11.5px;margin:0}
.rbwrap th,.rbwrap td{white-space:nowrap}
.rbtags{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0 12px}
.rbtag{background:#181825;border:1px solid var(--border);border-radius:12px;padding:2px 10px;font-size:11px;font-family:'Cascadia Code',Consolas,monospace}
.rbtag .n{color:var(--accent);margin-left:4px}
.rbmeta{color:var(--dim);font-size:12px;margin:4px 0 2px}
'@ + "`n</style>`n" + '<div class="note">以下 9 条 <code>!execute</code> 环形缓冲/摘要命令，每条给出 <b>① dump 前 top ' + $TopN + ' 条最新记录</b> + <b>② 值得注意的记录（规则化异常判定，命中 0 则显式标注）</b>；顶部另附类别直方图。完整分页明细见各自子报告。原始 txt 存于 <code>txt_detail\</code> 供后续 agent 分析。</div>'
[void]$rawBlocks.Add([pscustomobject]@{ type='raw'; html=$style })

$idx = 0
foreach ($s in $specs) {
    $idx++
    $p = $parsed[$s.expr]
    $f = [System.Text.StringBuilder]::new()
    [void]$f.Append("<h3>$idx. $(HE $s.label)</h3>")
    [void]$f.Append("<div class=`"note`"><code>!execute $(HE $s.expr)</code> · records=<b>$($p.rows.Count)</b> · <a href=`"$($subLinks[$s.expr])`">打开完整子报告 &rarr;</a></div>")
    if ($p.rows.Count -eq 0) {
        [void]$f.Append("<div class=`"note`" style=`"border-left-color:var(--yellow);color:var(--yellow)`"><b>无记录。</b> $(HE $p.note)</div>")
    } else {
        $hist = Build-Histogram $p.rows $s.catCol
        if ($hist.Count -gt 0) {
            [void]$f.Append("<div class=`"rbtags`">")
            foreach ($e in $hist) { [void]$f.Append("<span class=`"rbtag`">$(HE $e.k)<span class=`"n`">$($e.n)</span></span>") }
            [void]$f.Append('</div>')
        }
        $ageD = AgeDays $p.rows[0]['m_time_stamp']
        if ($ageD -gt 0) { [void]$f.Append("<div class=`"note`" style=`"border-left-color:var(--yellow);color:var(--yellow)`">⚠ 最新记录距 dump 约 <b>$ageD 天</b> —— 该环形缓冲长期未更新，下表并非 dump 前近期活动。</div>") }
        $take = [Math]::Min($TopN, $p.rows.Count)
        $topRows = @($p.rows[0..($take-1)])
        [void]$f.Append("<div class=`"rbmeta`">① dump 前 top $take 最新记录（position 降序）：</div>")
        $tbl = Render-Table $p.cols $topRows $s.catCol
        $tbl = $tbl -replace '<div class="tblwrap">', '<div class="rbwrap">'
        [void]$f.Append($tbl)
        $an = Get-Anomalies $s.expr $p.cols $p.rows
        if ($an.label) {
            [void]$f.Append("<div class=`"rbmeta`">② 值得注意的记录（异常判定规则：$(HE $an.label)）：</div>")
            if ($an.rows.Count -eq 0) {
                [void]$f.Append("<div class=`"note`" style=`"border-left-color:var(--green);color:var(--green)`">无符合规则的异常记录。</div>")
            } else {
                $showN = [Math]::Min($TopN, $an.rows.Count)
                [void]$f.Append("<div class=`"rbmeta`">命中 <b>$($an.rows.Count)</b> 条，显示前 $showN 条：</div>")
                $t2 = Render-Table $p.cols @($an.rows[0..($showN-1)]) $s.catCol
                $t2 = $t2 -replace '<div class="tblwrap">', '<div class="rbwrap">'
                [void]$f.Append($t2)
            }
        }
    }
    [void]$rawBlocks.Add([pscustomobject]@{ type='raw'; html=$f.ToString() })
}

if (-not (Test-Path -LiteralPath $Manifest)) { throw "overall manifest not found: $Manifest" }
$mo = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json

$secList = [System.Collections.ArrayList]@($mo.sections)
for ($i=$secList.Count-1; $i -ge 0; $i--) { if ($secList[$i].h2 -like '*SOS 环形缓冲*') { $secList.RemoveAt($i) } }
$newSec = [pscustomobject]@{ h2='附加步骤 · SOS 环形缓冲 / 摘要全量列举（9 条 !execute）'; blocks=@($rawBlocks) }
$insertAt = $secList.Count
for ($i=0; $i -lt $secList.Count; $i++) { if ($secList[$i].h2 -like 'DoD*') { $insertAt=$i; break } }
$secList.Insert($insertAt, $newSec)
$mo.sections = @($secList)

# If the base manifest carries a DoD table, close the ring-surface row now that
# all nine raw captures and subreports have been generated.
foreach ($section in @($mo.sections | Where-Object { $_.h2 -like 'DoD*' })) {
    foreach ($block in @($section.blocks | Where-Object { $_.type -eq 'table' })) {
        foreach ($row in @($block.rows)) {
            if (@($row).Count -ge 2 -and [string]$row[0] -match 'Nine ring surfaces|9.*环形缓冲') {
                $row[1] = 'done'
            }
        }
    }
}

$cardList = [System.Collections.ArrayList]@($mo.cards)
$hasCard = $false; foreach ($c in $cardList) { if ($c.k -eq '环形缓冲命令') { $hasCard=$true; $c.v='9 条 · 见附加步骤' } }
if (-not $hasCard) { [void]$cardList.Add([pscustomobject]@{ v='9 条 · 见附加步骤'; k='环形缓冲命令' }) }
$mo.cards=@($cardList)

$json = $mo | ConvertTo-Json -Depth 80
[System.IO.File]::WriteAllText($Manifest, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ""
Write-Host "[manifest] injected 附加步骤 (9 ringbuf sections) -> $Manifest"

$outReport = Join-Path $Dir ("{0}_overall_report.html" -f $CaseId)
& pwsh -NoProfile -ExecutionPolicy Bypass -File $Generator -Manifest $Manifest -Out $outReport
Write-Host "[main] regenerated -> $outReport"

# remove the now-redundant standalone ringbuf main report
$legacy = Join-Path $Dir ("{0}_ringbuf_main_report.html" -f $CaseId)
if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Force; Write-Host "[cleanup] removed legacy $legacy" }
