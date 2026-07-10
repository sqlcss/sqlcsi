<#
gen_exception_html.ps1 — Exception / faulting-thread sub-report from cdb capture text.

INPUT  : raw text produced by an "exception capture" cdb batch containing
         .lastevent / .exr -1 / .ecxr / ~<tid>s / kv delimited by
         ===EXR===, ===ECXR===, ===FAULTING_STACK=== markers.
         (Any text is accepted; markers are optional.)

OUTPUT : self-contained HTML file (Catppuccin Mocha).
         Wraps the whole capture verbatim in <pre>, HTML-escaped, and
         auto-detects the faulting TID from the first `~<tid>s` line for
         the section header.

USAGE  : .\gen_exception_html.ps1 `
             -Src <case>_exception.txt `
             -Out <case>_exception.html `
             -CaseId <case_id> `
             [-Tid <tid>] `
             [-Spid <spid>] `
             [-BackLinkHref <case>_overall_report.html]
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Src,
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][string]$CaseId,
    [string]$Tid = '',
    [string]$Spid = '',
    [string]$BackLinkHref = "${CaseId}_overall_report.html"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Src)) { throw "Src file not found: $Src" }

function HE([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}

$body = Get-Content -LiteralPath $Src -Raw -Encoding UTF8

# Auto-detect faulting TID (decimal) from `0:005> ~<n>s` line if not provided
if (-not $Tid) {
    $m = [regex]::Match($body, '(?m)^\s*\d+:\d+>\s*~(\d+)s\b')
    if ($m.Success) { $Tid = $m.Groups[1].Value }
}
$tidLabel = if ($Tid) { "线程 $Tid" } else { '故障线程' }
if ($Spid) { $tidLabel += " (SPID $Spid)" }

$style = @'
:root{--bg:#1e1e2e;--surface:#252538;--border:#3a3a55;--text:#cdd6f4;--dim:#a6adc8;
--accent:#89b4fa;--green:#a6e3a1;--yellow:#f9e2af;--orange:#fab387;--red:#f38ba8;--teal:#94e2d5;--mauve:#cba6f7;}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI','Microsoft YaHei',sans-serif;margin:0;padding:28px;line-height:1.5}
h1{color:var(--accent);font-size:22px;margin:0 0 4px}
h2{color:var(--mauve);font-size:17px;margin:30px 0 10px;border-bottom:1px solid var(--border);padding-bottom:6px}
h3{color:var(--teal);font-size:14px;margin:18px 0 8px}
.sub{color:var(--dim);font-size:12px;margin-bottom:18px}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
pre{background:#181825;border:1px solid var(--border);border-radius:8px;padding:12px;overflow-x:auto;font-family:'Cascadia Code',Consolas,monospace;font-size:12px;color:var(--dim);line-height:1.45;margin:8px 0;white-space:pre}
'@

$html = @"
<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8"><title>异常与故障栈 · $(HE $CaseId)</title><style>$style</style></head><body><h1>子报告 · 异常与故障栈</h1><div class="sub">Case $(HE $CaseId) · .lastevent / .exr / .ecxr / 故障线程 kv</div><p><a href="$(HE $BackLinkHref)">&larr; 返回主报告</a></p><h3>$(HE $tidLabel) — 故障 / 终结栈（ 原样）</h3><pre>$(HE $body)</pre></body></html>
"@

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Out, $html, $utf8NoBom)
Write-Host "OK: wrote $Out (Tid=$Tid)"
