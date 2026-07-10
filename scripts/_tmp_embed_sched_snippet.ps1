# Embed the SchedulerMonitor snippet into the 2606250030005483 main overall_report.
param(
    [string]$Main    = 'C:\Users\lduan\sqlcsi-archive\reports\2606250030005483_dump_overall\2606250030005483_overall_report.html',
    [string]$Snippet = 'C:\Users\lduan\sqlcsi-archive\reports\2606250030005483_dump_overall\2606250030005483_scheduler_monitor_snippet.html',
    [string]$SubReportName = '2606250030005483_scheduler_monitor.html'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Main))    { throw "main report not found: $Main" }
if (-not (Test-Path -LiteralPath $Snippet)) { throw "snippet not found: $Snippet" }

$mainHtml = Get-Content -LiteralPath $Main    -Raw -Encoding UTF8
$snip     = Get-Content -LiteralPath $Snippet -Raw -Encoding UTF8

# Idempotent: strip previous injection (if re-running)
$marker = '<!-- SCHEDULER_MONITOR_SECTION -->'
if ($mainHtml -match [regex]::Escape($marker)) {
    $mainHtml = [regex]::Replace(
        $mainHtml,
        [regex]::Escape($marker) + '[\s\S]*?<!-- /SCHEDULER_MONITOR_SECTION -->',
        ''
    )
}

$section = @"
$marker
<h2>第三步 · SchedulerMonitor 环形缓冲（dump 时刻附近切片）</h2>
<div class="note">SOSRingBuffers.EnumerateSchedulerMonitorRecords · 共 256 条记录 · 本节仅展示 <b>STUCK / NONYIELD / DEADLOCK 事件 + 最近 40 条</b>。完整分页表见 <a href="$SubReportName">$SubReportName</a>。</div>
$snip
<!-- /SCHEDULER_MONITOR_SECTION -->
"@

# Insert just before <div class="foot">
if ($mainHtml -notmatch '<div class="foot">') {
    throw "cannot find '<div class=""foot"">' in main report — insertion aborted"
}
$mainHtml = $mainHtml -replace '<div class="foot">', ($section + '<div class="foot">')

[System.IO.File]::WriteAllText(
    $Main, $mainHtml, (New-Object System.Text.UTF8Encoding($false))
)

Write-Host "[embed] injected SchedulerMonitor section into $Main"
Write-Host ("[embed] main size now: {0} bytes" -f (Get-Item -LiteralPath $Main).Length)
