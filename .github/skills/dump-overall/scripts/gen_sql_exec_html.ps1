<#
gen_sql_exec_html.ps1 — Manifest-driven renderer for the SQL-Exec-Thread sub-report.
Produces "执行语句线程详情（主线程 + 并行子线程）" HTML from a JSON manifest.

Owns: fixed CSS (Catppuccin Mocha), page skeleton, header/cards/verdict/section
      layout, per-thread `.tcard` rendering, escape helpers.

Manifest schema (JSON):
{
  "title"       : "执行语句线程详情（主线程 + 并行子线程）",
  "caseId"      : "2606250030005483",
  "subtitle"    : "Case ... · SQLDump0001.mdmp · ...",
  "backLink"    : "2606250030005483_overall_report.html",
  "cards"       : [ { "k": "执行语句主线程", "v": "14", "cls": "accent" }, ... ],
  "legend"      : "raw HTML string or omit",           # optional
  "verdict"     : "raw HTML for the callout crit/info", # optional; not escaped
  "sections"    : [
    {
      "h2"      : "一、执行语句主线程（14 · 有 process_request）",
      "threads" : [
        {
          "tid"        : "133",
          "cardCls"    : "ok|warn|no",                  # left-border color
          "statusTag"  : "run|runn|susp|sys",           # tag color
          "statusText" : "✅ 完整",
          "exception"  : "无（正常 XE 执行）",          # optional
          "meta"       : "raw HTML for the .kv row (b/em/code allowed)",  # optional
          "tsqlstack"  : "raw text (will be HTML-escaped and wrapped in <pre>)", # optional
          "stack"      : "raw text (will be HTML-escaped and wrapped in <pre>)", # optional
          "extraHtml"  : "raw HTML appended to the card (details/pre allowed)"   # optional
        }
      ]
    }
  ],
  "footer"      : "raw HTML" # optional
}

USAGE : .\gen_sql_exec_html.ps1 -Manifest <case>_sql_exec_manifest.json -Out <case>_sql_exec_thread.html
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Manifest,
    [Parameter(Mandatory)][string]$Out
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Manifest)) { throw "Manifest not found: $Manifest" }

$mf = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json

function HE([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}

function Render-Cards($cards) {
    if ($null -eq $cards -or @($cards).Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="meta-grid">')
    foreach ($c in $cards) {
        $k = HE $c.k
        $v = HE $c.v
        $cls = if ($c.cls) { " $($c.cls)" } else { '' }
        [void]$sb.Append("<div class=`"card`"><div class=`"k`">$k</div><div class=`"v$cls`">$v</div></div>")
    }
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

function Render-Thread($t) {
    $tid       = HE $t.tid
    $cardCls   = if ($t.cardCls)    { " $($t.cardCls)" } else { '' }
    $statusTag = if ($t.statusTag)  { $t.statusTag }    else { 'sys' }
    $statusTxt = HE $t.statusText
    $excTxt    = HE $t.exception
    $meta      = if ($t.meta)       { $t.meta }         else { '' }   # raw HTML
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<div class=`"tcard$cardCls`">")
    [void]$sb.Append("<div class=`"thead`"><span class=`"tid`">线程 $tid</span> <span class=`"tag $statusTag`">$statusTxt</span>")
    if ($excTxt) { [void]$sb.Append(" <span class=`"exc`">$excTxt</span>") }
    [void]$sb.Append('</div>')
    if ($meta) { [void]$sb.Append("<div class=`"kv`">$meta</div>") }
    if ($t.tsqlstack) {
        [void]$sb.Append("<details><summary>▶ tsqlstack 原始输出</summary><pre>$(HE $t.tsqlstack)</pre></details>")
    }
    if ($t.stack) {
        [void]$sb.Append("<details><summary>▶ 调用栈（~${tid}k）</summary><pre>$(HE $t.stack)</pre></details>")
    }
    if ($t.extraHtml) { [void]$sb.Append([string]$t.extraHtml) }
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

function Render-Section($sec) {
    $sb = New-Object System.Text.StringBuilder
    if ($sec.h2) { [void]$sb.Append("<h2>$(HE $sec.h2)</h2>") }
    if ($sec.threads) {
        foreach ($t in $sec.threads) { [void]$sb.Append((Render-Thread $t)) }
    }
    if ($sec.extraHtml) { [void]$sb.Append([string]$sec.extraHtml) }
    return $sb.ToString()
}

$title    = if ($mf.title) { $mf.title } else { '执行语句线程详情（主线程 + 并行子线程）' }
$caseId   = HE $mf.caseId
$subtitle = if ($mf.subtitle) { HE $mf.subtitle } else { "Case <b>$caseId</b>" }
$back     = if ($mf.backLink) { HE $mf.backLink } else { "${caseId}_overall_report.html" }
$cardsHtml   = Render-Cards $mf.cards
$legendHtml  = if ($mf.legend)  { "<p class=`"legend`">$($mf.legend)</p>" } else { '' }
$verdictHtml = if ($mf.verdict) { [string]$mf.verdict } else { '' }
$sectionsHtml = New-Object System.Text.StringBuilder
foreach ($sec in $mf.sections) { [void]$sectionsHtml.Append((Render-Section $sec)) }
$footerHtml  = if ($mf.footer)  { [string]$mf.footer } else { '' }

$style = @'
:root{--bg:#1e1e2e;--surface:#252538;--border:#3a3a55;--text:#cdd6f4;--dim:#a6adc8;--accent:#89b4fa;--green:#a6e3a1;--yellow:#f9e2af;--orange:#fab387;--red:#f38ba8;--teal:#94e2d5;--mauve:#cba6f7;}
*{box-sizing:border-box;}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI','Microsoft YaHei',sans-serif;margin:0;padding:0 0 60px;line-height:1.6;}
.container{max-width:1080px;margin:0 auto;padding:0 24px;}
header{background:linear-gradient(135deg,#252538,#1e1e2e);border-bottom:1px solid var(--border);padding:32px 0;margin-bottom:28px;}
h1{margin:0 0 8px;font-size:24px;color:var(--accent);}
h2{color:var(--mauve);border-left:4px solid var(--mauve);padding-left:12px;margin:34px 0 12px;font-size:20px;}
h3{color:var(--teal);font-size:16px;margin:20px 0 8px;}
.sub{color:var(--dim);font-size:14px;}
.meta-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-top:18px;}
.card{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:14px 16px;}
.card .k{color:var(--dim);font-size:12px;text-transform:uppercase;letter-spacing:.5px;}
.card .v{font-size:20px;font-weight:700;margin-top:4px;}
.v.red{color:var(--red);}.v.green{color:var(--green);}.v.yellow{color:var(--yellow);}.v.orange{color:var(--orange);}.v.accent{color:var(--accent);}.v.mauve{color:var(--mauve);}
a{color:var(--accent);}
.tag{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;}
.tag.run{background:#2f4a36;color:var(--green);}
.tag.runn{background:#4a3f24;color:var(--yellow);}
.tag.susp{background:#4a2f3a;color:var(--red);}
.tag.sys{background:#33304a;color:var(--mauve);}
.tcard{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:16px 18px;margin:14px 0;}
.tcard.ok{border-left:4px solid var(--green);}
.tcard.warn{border-left:4px solid var(--orange);}
.tcard.no{border-left:4px solid var(--red);}
.thead{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;}
.tid{font-size:18px;font-weight:700;color:var(--accent);}
.exc{color:var(--dim);font-size:13.5px;}
.kv{margin:8px 0;font-size:14px;}
.kv b{color:var(--mauve);}
.res{background:#2a2a40;border-radius:8px;padding:10px 12px;margin:8px 0;font-size:13.5px;}
details{margin:8px 0;}
summary{cursor:pointer;color:var(--teal);font-size:13px;user-select:none;}
pre{background:#181825;border:1px solid var(--border);border-radius:8px;padding:12px;overflow-x:auto;font-family:'Cascadia Code',Consolas,monospace;font-size:12px;color:var(--dim);line-height:1.45;margin:8px 0;white-space:pre;}
code{background:#2a2a40;color:var(--teal);padding:1px 6px;border-radius:4px;font-family:'Cascadia Code',Consolas,monospace;font-size:13px;}
.callout{border-radius:10px;padding:12px 16px;margin:14px 0;border-left:4px solid;}
.callout.crit{background:#332028;border-color:var(--red);}
.callout.info{background:#1f2a33;border-color:var(--accent);}
.footnote{color:var(--dim);font-size:12.5px;margin-top:8px;}
.legend{color:var(--dim);font-size:13px;margin:4px 0 12px;}
table{width:100%;border-collapse:collapse;margin:14px 0;background:var(--surface);border-radius:10px;overflow:hidden;}
th,td{padding:10px 14px;text-align:left;border-bottom:1px solid var(--border);}
th{background:#2a2a40;color:var(--accent);font-size:13px;text-transform:uppercase;letter-spacing:.5px;}
td{font-size:14px;}
tr:last-child td{border-bottom:none;}
.num{text-align:right;font-variant-numeric:tabular-nums;font-weight:600;}
'@

$html = @"
<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>$(HE $title) — Case $caseId</title><style>$style</style></head><body>
<header><div class="container"><h1>$(HE $title)</h1><div class="sub">$subtitle</div></div></header>
<div class="container">
<p class="sub">&larr; 返回 <a href="$back">主分析报告</a></p>
$cardsHtml
$legendHtml
$verdictHtml
$($sectionsHtml.ToString())
$footerHtml
</div></body></html>
"@

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Out, $html, $utf8NoBom)
Write-Host "OK: wrote $Out"
