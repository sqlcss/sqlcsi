# =============================================================================
# gen_overall_report.ps1 — SQL-CSI dump-overall MAIN report generator
#
# Emits the FIXED overall_report.html skeleton (Catppuccin Mocha dark theme,
# header cards, H2 sections with H3 / notes / tables). All dump-specific
# content is supplied by a JSON *manifest* — the agent fills the manifest,
# never hand-writes HTML.
#
# WHY MANIFEST-DRIVEN: the CSS + skeleton is fixed and lives here; the
# per-dump numbers, notes, and cell HTML fragments live in the manifest.
# This is the only supported way to produce <case>_overall_report.html.
#
# -----------------------------------------------------------------------------
# MANIFEST SCHEMA (JSON, UTF-8):
# {
#   "title"     : "Dump 全局快照",                    // optional; default shown
#   "caseId"    : "2606250030005483",                 // required
#   "subtitle"  : "SQLDump0001.mdmp · 纯客观列举…",   // optional
#   "cards"     : [ {"k":"Dump 原因","v":"Stalled Dispatcher"}, ... ],
#   "sections"  : [
#     {
#       "h2"    : "第一步 · 线程清单与状态统计",
#       "blocks": [
#         { "type":"h3",    "text":"表 1 · OS 线程清单（!mex.us 堆栈推断，...）" },
#         { "type":"note",  "html":"按<b>唯一堆栈分页折叠</b> ... <a href='...'>...</a>" },
#         { "type":"table",
#           "cols":       ["状态分类","堆栈组数","线程数","占比"],
#           "colClasses": ["",       "num",     "num",  "num"],
#           "rows": [
#             [ {"html":"<span class='tag t-idle'>IDLE</span>"}, "4", "669", "80.5%" ],
#             ...
#           ]
#         },
#         { "type":"raw",   "html":"...arbitrary HTML fragment..." }
#       ]
#     },
#     ...
#   ],
#   "footer"    : "Generated ... — pure enumeration (no root cause)."   // optional
# }
#
# CELL FORMAT:
#   "string"          → HTML-escaped plain text
#   { "html": "..." } → raw HTML (caller responsible for escaping)
#   { "text": "...", "class": "num mono" } → escaped text with td class
#
# EXIT CODES: 0 = success; 1 = manifest missing / invalid; 2 = write failed.
# =============================================================================
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Manifest,
    [Parameter(Mandatory)][string]$Out,
    [string]$Ledger
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Manifest)) {
    Write-Host "[gen_overall_report] ERROR: manifest not found: $Manifest" -ForegroundColor Red
    exit 1
}

try {
    $m = Get-Content $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "[gen_overall_report] ERROR: manifest parse failed: $_" -ForegroundColor Red
    exit 1
}

if (-not $m.caseId) {
    Write-Host "[gen_overall_report] ERROR: manifest.caseId is required" -ForegroundColor Red
    exit 1
}

if ($Ledger) {
    $verifier = Join-Path $PSScriptRoot 'verify_case_deliverables.ps1'
    $outDirForVerify = Split-Path -Parent $Out
    & $verifier -CaseId ([string]$m.caseId) -OutDir $outDirForVerify -Stage PreReport -Ledger $Ledger
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[gen_overall_report] ERROR: pre-report ledger verification failed" -ForegroundColor Red
        exit 1
    }
}

function HE([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}

function Render-Cell($c) {
    if ($null -eq $c) { return @{ html = ''; cls = '' } }
    if ($c -is [string]) { return @{ html = (HE $c); cls = '' } }
    # object cell
    $cls = ''
    if ($c.PSObject.Properties.Name -contains 'class') { $cls = [string]$c.class }
    if ($c.PSObject.Properties.Name -contains 'html')  { return @{ html = [string]$c.html;      cls = $cls } }
    if ($c.PSObject.Properties.Name -contains 'text')  { return @{ html = (HE ([string]$c.text)); cls = $cls } }
    return @{ html = (HE ($c | ConvertTo-Json -Compress)); cls = $cls }
}

function Render-Table($t) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('<table>')
    if ($t.cols) {
        [void]$sb.Append('<thead><tr>')
        for ($i=0; $i -lt $t.cols.Count; $i++) {
            $cls = ''
            if ($t.colClasses -and $i -lt $t.colClasses.Count -and $t.colClasses[$i]) { $cls = " class=""$($t.colClasses[$i])""" }
            [void]$sb.Append("<th$cls>$(HE $t.cols[$i])</th>")
        }
        [void]$sb.Append('</tr></thead>')
    }
    [void]$sb.Append('<tbody>')
    foreach ($row in $t.rows) {
        [void]$sb.Append('<tr>')
        for ($i=0; $i -lt $row.Count; $i++) {
            $rc = Render-Cell $row[$i]
            $cls = $rc.cls
            if (-not $cls -and $t.colClasses -and $i -lt $t.colClasses.Count) { $cls = $t.colClasses[$i] }
            $clsAttr = if ($cls) { " class=""$cls""" } else { '' }
            [void]$sb.Append("<td$clsAttr>$($rc.html)</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function Render-Block($b) {
    switch ($b.type) {
        'h3'    { return "<h3>$(HE $b.text)</h3>" }
        'note'  { return "<div class=""note"">$($b.html)</div>" }
        'raw'   { return [string]$b.html }
        'table' { return (Render-Table $b) }
        default { return "<!-- unknown block type: $($b.type) -->" }
    }
}

# ---- assemble ----------------------------------------------------------------
$title    = if ($m.title)    { $m.title }    else { 'Dump 全局快照' }
$subtitle = if ($m.subtitle) { $m.subtitle } else { '' }
$footer   = if ($m.footer)   { $m.footer }   else { "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') — pure enumeration (no root cause)." }

$sb = New-Object Text.StringBuilder

$css = @'
:root{--bg:#1e1e2e;--surface:#252538;--border:#3a3a55;--text:#cdd6f4;--dim:#a6adc8;--accent:#89b4fa;--green:#a6e3a1;--yellow:#f9e2af;--orange:#fab387;--red:#f38ba8;--teal:#94e2d5;--mauve:#cba6f7;}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI','Microsoft YaHei',sans-serif;margin:0;padding:28px;line-height:1.5}
h1{color:var(--accent);font-size:22px;margin:0 0 4px}
h2{color:var(--mauve);font-size:17px;margin:30px 0 10px;border-bottom:1px solid var(--border);padding-bottom:6px}
h3{color:var(--teal);font-size:14px;margin:18px 0 8px}
.sub{color:var(--dim);font-size:12px;margin-bottom:18px}
.cards{display:flex;flex-wrap:wrap;gap:12px;margin:16px 0 6px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:10px 14px;min-width:150px}
.card .k{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.4px}
.card .v{color:var(--text);font-size:14px;margin-top:3px;font-weight:600}
table{border-collapse:collapse;width:100%;margin:10px 0 6px;font-size:12.5px}
th,td{border:1px solid var(--border);padding:6px 9px;text-align:left;vertical-align:top}
th{background:#2b2b40;color:var(--accent);font-weight:600}
tr:nth-child(even) td{background:#22223200}
tbody tr:nth-child(even){background:#20202f}
td.num{text-align:right;font-variant-numeric:tabular-nums}
code,pre{font-family:'Cascadia Code',Consolas,monospace}
pre{background:#181825;border:1px solid var(--border);border-radius:6px;padding:12px;overflow:auto;font-size:12px;color:var(--dim)}
.tag{display:inline-block;padding:1px 7px;border-radius:10px;font-size:11px;font-weight:600}
.t-run{background:#3a2733;color:var(--red)}
.t-rbl{background:#3a3327;color:var(--orange)}
.t-sus{background:#27333a;color:var(--teal)}
.t-idle{background:#2a2a3a;color:var(--dim)}
.flags{color:var(--yellow);font-size:11px}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.note{background:#181825;border-left:3px solid var(--accent);padding:8px 12px;border-radius:4px;color:var(--dim);font-size:12px;margin:10px 0}
.foot{color:var(--dim);font-size:11px;margin-top:34px;border-top:1px solid var(--border);padding-top:10px}
.dim{color:var(--dim)}.mono{font-family:'Cascadia Code',Consolas,monospace}
'@

[void]$sb.Append('<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8"><title>')
[void]$sb.Append((HE "$title · $($m.caseId)"))
[void]$sb.Append('</title><style>')
[void]$sb.Append($css)
[void]$sb.Append('</style></head><body>')

# header
[void]$sb.Append("<h1>$(HE $title) · Overall Snapshot</h1>")
if ($subtitle) { [void]$sb.Append("<div class=""sub"">Case $(HE $m.caseId) · $(HE $subtitle)</div>") }
else           { [void]$sb.Append("<div class=""sub"">Case $(HE $m.caseId)</div>") }

# meta cards
if ($m.cards) {
    [void]$sb.Append('<div class="cards">')
    foreach ($c in $m.cards) {
        [void]$sb.Append("<div class=""card""><div class=""k"">$(HE $c.k)</div><div class=""v"">$(HE $c.v)</div></div>")
    }
    [void]$sb.Append('</div>')
}

# sections
foreach ($s in $m.sections) {
    if ($s.h2) { [void]$sb.Append("<h2>$(HE $s.h2)</h2>") }
    foreach ($b in $s.blocks) {
        [void]$sb.Append((Render-Block $b))
    }
}

[void]$sb.Append("<div class=""foot"">$(HE $footer)</div></body></html>")

# write no-BOM UTF-8
try {
    $enc = New-Object System.Text.UTF8Encoding($false)
    $outDir = Split-Path -Parent $Out
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    [System.IO.File]::WriteAllText($Out, $sb.ToString(), $enc)
} catch {
    Write-Host "[gen_overall_report] ERROR: write failed: $_" -ForegroundColor Red
    exit 2
}

$sz = (Get-Item $Out).Length
Write-Host ("[gen_overall_report] wrote {0} ({1:N0} bytes) · {2} sections · {3} cards" -f `
    $Out, $sz, @($m.sections).Count, @($m.cards).Count) -ForegroundColor Green
exit 0
