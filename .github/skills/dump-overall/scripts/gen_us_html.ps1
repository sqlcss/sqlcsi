param(
  [string]$Src = 'C:\Users\lduan\sqlcsi-archive\reports\2606250030005483_dump_code_analysis\2606250030005483_us.txt',
  [string]$Out = 'C:\Users\lduan\sqlcsi-archive\reports\2606250030005483_dump_code_analysis\2606250030005483_us.html',
  [string]$CaseId = '2606250030005483'
)

$lines = Get-Content $Src
$groups=@(); $cur=$null
foreach ($ln in $lines) {
  if ($ln -match '^(\d+)\s+threads?\s+\[stats\]:\s*(.*)$') {
    if ($cur){ $groups+=$cur }
    $ids = [regex]::Matches($Matches[2],'(\d+)\[!mex\.t') | ForEach-Object { $_.Groups[1].Value }
    $cur=[pscustomobject]@{ Count=[int]$Matches[1]; Ids=$ids; Frames=New-Object Collections.ArrayList; More=($Matches[2] -match '\.\.\.') }
  } elseif ($cur -and ($ln -match '^\s+(00007|\(Inline\))')) {
    [void]$cur.Frames.Add($ln.TrimEnd())
  }
}
if ($cur){ $groups+=$cur }

function Classify($g){
  $j = ($g.Frames -join ' ')
  $w = $j -match 'ZwWaitForSingleObject|ZwSignalAndWaitForSingleObject|SignalObjectAndWait|WaitForSingleObjectEx|WaitForMultipleObjects'
  if ($j -match 'WorkDispatcher::DequeueTask'){ return 'IDLE' }
  $t = $j -match 'SOS_Task::Param::Execute|SOS_Scheduler::RunTask'
  if (-not $t){ if($w){return 'SYSTEM-WAIT'}else{return 'SYSTEM-RUNNING'} }
  if ($j -match 'OSYieldNoAbort|OSYield\b'){ return 'RUNNABLE' }
  if ($w){ return 'SUSPENDED' } ; return 'RUNNING'
}
$tagClass = @{ 'IDLE'='idle';'SUSPENDED'='susp';'RUNNABLE'='runn';'RUNNING'='run';'SYSTEM-WAIT'='sys';'SYSTEM-RUNNING'='sys' }

# pick a representative "what" frame (first sql frame that isn't pure scheduler plumbing)
function TopWhat($g){
  foreach($f in $g.Frames){
    if ($f -match '(sqllang|sqlmin|sqltses)!([^\s+]+)' -and $f -notmatch 'SwitchToThreadWorker|SwitchContext|SwitchNonPreemptive|SuspendNonPreemptive|::Suspend\b|WaitableBase::Wait|SignalAndWait|ProcessTasks|RunTask|WorkerEntryPoint|ThreadEntryPoint|ProcessWorker|DequeueTask|WorkerIdleElem'){
      return $Matches[1] + '!' + $Matches[2]
    }
  }
  foreach($f in $g.Frames){ if ($f -match '(sqldk|sqlmin|sqllang)!([^\s+]+)'){ return $Matches[1]+'!'+$Matches[2] } }
  return '(scheduler plumbing)'
}

$groups = $groups | Sort-Object Count -Descending
$total = ($groups | Measure-Object Count -Sum).Sum

function HE([string]$s){ if($null -eq $s){return ''}; $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }

$sb = New-Object Text.StringBuilder
[void]$sb.Append(@"
<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>线程清单 (全部 $total 线程) — Case $CaseId</title>
<style>
:root{--bg:#1e1e2e;--surface:#252538;--border:#3a3a55;--text:#cdd6f4;--dim:#a6adc8;--accent:#89b4fa;--green:#a6e3a1;--yellow:#f9e2af;--orange:#fab387;--red:#f38ba8;--teal:#94e2d5;--mauve:#cba6f7;}
*{box-sizing:border-box;}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI','Microsoft YaHei',sans-serif;margin:0;padding:0 0 60px;line-height:1.55;}
.container{max-width:1100px;margin:0 auto;padding:0 24px;}
header{background:linear-gradient(135deg,#252538,#1e1e2e);border-bottom:1px solid var(--border);padding:26px 0;margin-bottom:20px;}
h1{margin:0 0 6px;font-size:22px;color:var(--accent);}
.sub{color:var(--dim);font-size:13.5px;}
a{color:var(--accent);}
.toolbar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:16px 0;}
.toolbar button{background:var(--surface);color:var(--text);border:1px solid var(--border);border-radius:8px;padding:6px 12px;cursor:pointer;font-size:13px;}
.toolbar button:hover{border-color:var(--accent);}
.toolbar input{background:#16161f;color:var(--text);border:1px solid var(--border);border-radius:8px;padding:7px 12px;font-size:13px;min-width:280px;font-family:'Cascadia Code',Consolas,monospace;}
.toolbar input:focus{outline:none;border-color:var(--accent);}
.searchstat{color:var(--green);font-size:12.5px;font-weight:600;}
.legend{margin-left:auto;color:var(--dim);font-size:12.5px;}
mark{background:var(--yellow);color:#1e1e2e;border-radius:2px;padding:0 1px;}
details.nomatch{display:none;}
details{background:var(--surface);border:1px solid var(--border);border-radius:10px;margin:10px 0;overflow:hidden;}
summary{cursor:pointer;padding:12px 16px;display:flex;align-items:center;gap:12px;list-style:none;}
summary::-webkit-details-marker{display:none;}
summary:hover{background:#2a2a40;}
.cnt{font-size:18px;font-weight:700;color:var(--accent);min-width:54px;text-align:right;font-variant-numeric:tabular-nums;}
.what{font-family:'Cascadia Code',Consolas,monospace;font-size:13px;color:var(--teal);flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.tag{display:inline-block;padding:1px 9px;border-radius:10px;font-size:11.5px;font-weight:700;letter-spacing:.3px;}
.tag.idle{background:#45475a;color:var(--dim);}
.tag.susp{background:#4a2f3a;color:var(--red);}
.tag.runn{background:#4a3f24;color:var(--yellow);}
.tag.run{background:#2f4a36;color:var(--green);}
.tag.sys{background:#33304a;color:var(--mauve);}
.body{padding:4px 16px 16px;border-top:1px solid var(--border);}
.ids{font-family:'Cascadia Code',Consolas,monospace;font-size:12px;color:var(--dim);margin:10px 0;word-break:break-word;}
.ids b{color:var(--text);}
pre{background:#16161f;border:1px solid var(--border);border-radius:8px;padding:12px 14px;overflow-x:auto;font-family:'Cascadia Code',Consolas,monospace;font-size:12.5px;line-height:1.5;margin:0;}
pre .mod{color:var(--mauve);} 
.summary-table{width:100%;border-collapse:collapse;background:var(--surface);border-radius:10px;overflow:hidden;margin:8px 0 4px;}
.summary-table th,.summary-table td{padding:8px 14px;border-bottom:1px solid var(--border);font-size:13px;text-align:left;}
.summary-table th{background:#2a2a40;color:var(--accent);}
.summary-table td.n{text-align:right;font-variant-numeric:tabular-nums;font-weight:600;}
.summary-table tr:last-child td{border-bottom:none;}
</style></head><body>
<header><div class="container">
<h1>线程清单 — 全部 $total 个线程</h1>
<div class="sub">Case <b>$CaseId</b> · SQLDump0001.mdmp · <code>!mex.us</code> 输出 · $($groups.Count) 个唯一调用栈 · <a href="2606250030005483_report.html">&larr; 返回主报告</a></div>
</div></header>
<div class="container">
"@)

# state summary table
$byState = $groups | Group-Object { Classify $_ } | ForEach-Object { [pscustomobject]@{ State=$_.Name; Stacks=$_.Count; Threads=($_.Group|Measure-Object Count -Sum).Sum } } | Sort-Object Threads -Descending
[void]$sb.Append('<table class="summary-table"><thead><tr><th>状态</th><th>唯一栈</th><th>线程数</th><th>占比</th></tr></thead><tbody>')
foreach($r in $byState){
  $pct = [math]::Round(100.0*$r.Threads/$total,1)
  $tc = $tagClass[$r.State]
  [void]$sb.Append("<tr><td><span class='tag $tc'>$($r.State)</span></td><td class='n'>$($r.Stacks)</td><td class='n'>$($r.Threads)</td><td class='n'>$pct%</td></tr>")
}
[void]$sb.Append('</tbody></table>')

[void]$sb.Append(@"
<div class="toolbar">
<input id="q" type="text" placeholder="输入函数名搜索，如 CXPacket / LogoutSession / LockOwner…" autocomplete="off" spellcheck="false">
<button onclick="document.getElementById('q').value='';doSearch()">清除</button>
<button onclick="document.querySelectorAll('details').forEach(d=>{if(d.style.display!=='none')d.open=true})">展开可见</button>
<button onclick="document.querySelectorAll('details').forEach(d=>d.open=false)">全部折叠</button>
<span id="searchstat" class="searchstat"></span>
<span class="legend">按线程数降序 · 点击每组展开</span>
</div>
"@)

$gi=0
foreach($g in $groups){
  $gi++
  $st = Classify $g
  $tc = $tagClass[$st]
  $what = HE (TopWhat $g)
  $idsTxt = ($g.Ids -join ', ')
  if ($g.More){ $idsTxt += ' …（更多见 _us.txt）' }
  $stackHtml = ($g.Frames | ForEach-Object {
      $h = HE $_
      $h = [regex]::Replace($h,'((?:sqldk|sqllang|sqlmin|sqltses|ntdll|KERNELBASE|kernel32)!)','<span class="mod">$1</span>')
      $h
  }) -join "`n"
  [void]$sb.Append(@"
<details$(if($gi -le 3){' open'}) data-count="$($g.Count)">
<summary><span class="cnt">$($g.Count)</span><span class="tag $tc">$st</span><span class="what">$what</span></summary>
<div class="body">
<div class="ids"><b>线程 ID（$($g.Count)）：</b>$idsTxt</div>
<pre>$stackHtml</pre>
</div></details>
"@)
}

[void]$sb.Append(@'
<script>
const q = document.getElementById('q');
const stat = document.getElementById('searchstat');
const groups = Array.from(document.querySelectorAll('details'));
function clearMarks(){ document.querySelectorAll('pre mark').forEach(m=>{ const t=document.createTextNode(m.textContent); m.replaceWith(t); }); }
function hl(el, term){
  const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  const nodes=[]; while(w.nextNode()) nodes.push(w.currentNode);
  nodes.forEach(n=>{
    const lo = n.nodeValue.toLowerCase(); let i = lo.indexOf(term);
    if(i<0) return;
    const frag=document.createDocumentFragment(); let last=0;
    while(i>=0){
      if(i>last) frag.appendChild(document.createTextNode(n.nodeValue.slice(last,i)));
      const mk=document.createElement('mark'); mk.textContent=n.nodeValue.slice(i,i+term.length); frag.appendChild(mk);
      last=i+term.length; i=lo.indexOf(term,last);
    }
    if(last<n.nodeValue.length) frag.appendChild(document.createTextNode(n.nodeValue.slice(last)));
    n.parentNode.replaceChild(frag,n);
  });
}
function doSearch(){
  const term = q.value.trim().toLowerCase();
  clearMarks();
  if(!term){ groups.forEach((d,i)=>{ d.classList.remove('nomatch'); d.open = i<3; }); stat.textContent=''; return; }
  let mStacks=0, mThreads=0;
  groups.forEach(d=>{
    const hit = d.textContent.toLowerCase().includes(term);
    if(hit){ d.classList.remove('nomatch'); d.open=true; mStacks++; mThreads += parseInt(d.dataset.count||'0',10); hl(d.querySelector('pre'), term); hl(d.querySelector('.what'), term); }
    else { d.classList.add('nomatch'); d.open=false; }
  });
  stat.textContent = mStacks ? ('\u5339\u914d ' + mStacks + ' \u4e2a\u6808 / ' + mThreads + ' \u4e2a\u7ebf\u7a0b') : '\u65e0\u5339\u914d';
}
q.addEventListener('input', doSearch);
q.addEventListener('keydown', e=>{ if(e.key==='Escape'){ q.value=''; doSearch(); } });
</script>
'@)
[void]$sb.Append('</div></body></html>')
Set-Content -Path $Out -Value $sb.ToString() -Encoding UTF8
"Wrote $Out  ($($groups.Count) groups, $total threads)"
