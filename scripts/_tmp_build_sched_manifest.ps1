# Build two manifests for the 2606250030005483 SchedulerMonitor report:
#   1. FULL manifest  -> all 99 raw columns, paginated sub-report
#   2. SNIPPET manifest -> curated cols + snippet-latest-N + STUCK/NONYIELD filter,
#                          for the main-report embed.
param(
    [string]$Json     = 'C:\Users\lduan\sqlcsi-archive\reports\2606250030005483_dump_overall\2606250030005483_scheduler_monitor.json',
    [string]$OutFull  = 'C:\Users\lduan\sqlcsi-archive\reports\2606250030005483_dump_overall\2606250030005483_scheduler_monitor_manifest.json',
    [string]$OutSnip  = 'C:\Users\lduan\sqlcsi-archive\reports\2606250030005483_dump_overall\2606250030005483_scheduler_monitor_snippet_manifest.json'
)

$ErrorActionPreference = 'Stop'

$src = Get-Content -LiteralPath $Json -Raw -Encoding UTF8 | ConvertFrom-Json
$rows = @($src.rows)

# ----- FULL manifest: all cols, all rows -----
$full = [ordered]@{
    title              = 'SchedulerMonitor 环形缓冲 · SOS Scheduler Monitor Ring Buffer'
    caseId             = '2606250030005483'
    subtitle           = 'SOSRingBuffers.EnumerateSchedulerMonitorRecords · SQLDump0001.mdmp · 时序列举 (仅列举、不分析)'
    backLink           = '2606250030005483_overall_report.html'
    wrapper            = $src.wrapper
    cols               = @($src.cols)
    rows               = $rows
    eventCol           = 'm_Event'
    pageSize           = 50
    # No wall-clock timestampCol -> Δmin column suppressed, snippet uses event+latest logic.
}
$full | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $OutFull -Encoding utf8NoBOM

# ----- SNIPPET manifest: curated cols only -----
$pick = @(
  'm_Event','m_SchedulerId','m_NodeId','m_threadId','Position',
  'm_ProcessUtilization','m_SystemIdle','m_MemoryUtilization',
  'm_KernelTime','m_UserTime','m_PageFaults','m_WorkingSetDelta',
  'm_state','m_LastWaitType','m_TicksWhenCreated','m_TicksWhenWaitStarted','m_Id'
)
$rowsSlim = foreach ($r in $rows) {
    $o = [ordered]@{}
    foreach ($c in $pick) {
        # PSCustomObject: fetch prop safely, empty when missing
        $v = $null
        try { $v = $r.$c } catch { $v = $null }
        $o[$c] = if ($null -eq $v) { '' } else { [string]$v }
    }
    [pscustomobject]$o
}

$snip = [ordered]@{
    title              = 'SchedulerMonitor 环形缓冲 (snippet)'
    caseId             = '2606250030005483'
    subtitle           = 'STUCK/NONYIELD 事件 + 最近 40 条 SYSTEM_HEALTH'
    backLink           = '2606250030005483_overall_report.html'
    wrapper            = $src.wrapper
    cols               = $pick
    rows               = @($rowsSlim)
    eventCol           = 'm_Event'
    pageSize           = 100
    snippetEventRegex  = '^SMR_(STUCK|NONYIELD|DEADLOCK)'
    snippetLatestN     = 40
}
$snip | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $OutSnip -Encoding utf8NoBOM

Write-Host "[manifests]"
Write-Host "  full    -> $OutFull  ($($rows.Count) rows · $($src.cols.Count) cols)"
Write-Host "  snippet -> $OutSnip  ($($rowsSlim.Count) rows · $($pick.Count) cols · latest 40 + STUCK/NONYIELD/DEADLOCK)"
