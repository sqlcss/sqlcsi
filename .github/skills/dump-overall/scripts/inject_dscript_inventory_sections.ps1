# inject_dscript_inventory_sections.ps1 - add DScript inventory sections to overall report.
#
# This is intentionally a small post-processor: gen_overall_report.ps1 is manifest-driven,
# while these two DScript outputs may be produced after the main manifest exists.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Dir,
    [Parameter(Mandatory=$true)][string]$CaseId,
    [string]$Overall = '',
    [string]$SchedulerLog = '',
    [string]$LatchPagesLog = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Overall) { $Overall = Join-Path $Dir "${CaseId}_overall_report.html" }
if (-not $SchedulerLog) { $SchedulerLog = Join-Path $Dir "${CaseId}_sys.schedulers.txt" }
if (-not $LatchPagesLog) { $LatchPagesLog = Join-Path $Dir "${CaseId}_dump_latch_contended_pages.txt" }

foreach ($path in @($Overall,$SchedulerLog,$LatchPagesLog)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "required file not found: $path" }
}

function HE([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}

function Rel([string]$Path) { return [System.IO.Path]::GetFileName($Path) }

$schedulerLines = @(Get-Content -LiteralPath $SchedulerLog -Encoding UTF8 | Where-Object { $_ -match '^0x[0-9A-Fa-f]+' })
$visibleRows = @($schedulerLines | Where-Object { $_ -match '\bVISIBLE\s+ONLINE\b' })
$hiddenRows = @($schedulerLines | Where-Object { $_ -match '\bHIDDEN\s+ONLINE\b' })
$schedulerRows = @()
$maxRunnable = 0
$pendingDiskIoSchedulers = 0
foreach ($line in $schedulerLines) {
    $parts = @($line -split '\s+' | Where-Object { $_ })
    if ($parts.Count -gt 16) {
        $schedulerRows += [pscustomobject]@{
            address = $parts[0]
            node_id = $parts[1]
            scheduler_id = $parts[2]
            status = (($parts[3], $parts[4]) -join ' ')
            is_online = $parts[5]
            is_idle = $parts[6]
            worker_count = $parts[11]
            task_count = $parts[12]
            runnable_count = $parts[14]
            pending_disk_io_count = $parts[16]
            active_worker = $parts[17]
            yield_count = $parts[18]
            debugger_thread_id = $parts[22]
            pending_tasks = $parts[23]
            idle_workers = $parts[27]
        }
        $runnable = 0
        if ([int]::TryParse($parts[14], [ref]$runnable) -and $runnable -gt $maxRunnable) { $maxRunnable = $runnable }
        $pending = 0
        if ([int]::TryParse($parts[16], [ref]$pending) -and $pending -gt 0) { $pendingDiskIoSchedulers++ }
    }
}

$schedulerDetailRows = New-Object System.Text.StringBuilder
if ($schedulerRows.Count -gt 0) {
    foreach ($row in $schedulerRows) {
        [void]$schedulerDetailRows.AppendLine(("<tr><td class='mono'>{0}</td><td class='num'>{1}</td><td>{2}</td><td class='num'>{3}</td><td class='num'>{4}</td><td class='num'>{5}</td><td class='num'>{6}</td><td class='num'>{7}</td><td class='num'>{8}</td><td class='mono'>{9}</td><td class='num'>{10}</td></tr>" -f `
            (HE $row.address), (HE $row.scheduler_id), (HE $row.status), (HE $row.is_idle), (HE $row.worker_count), (HE $row.task_count), (HE $row.runnable_count), (HE $row.pending_disk_io_count), (HE $row.yield_count), (HE $row.active_worker), (HE $row.debugger_thread_id)))
    }
} else {
    [void]$schedulerDetailRows.AppendLine('<tr><td colspan="11" class="dim">No scheduler rows were emitted by sys.schedulers.js.</td></tr>')
}

$latchText = Get-Content -LiteralPath $LatchPagesLog -Raw -Encoding UTF8
$progressMatches = [regex]::Matches($latchText, 'Processing\s+(\d+)\s+of\s+(\d+)\s+-\s+Found\s+(\d+)\s+threads\s+\((\d+)\s+pages\)')
$lastProgress = if ($progressMatches.Count -gt 0) { $progressMatches[$progressMatches.Count - 1] } else { $null }
$processed = if ($lastProgress) { $lastProgress.Groups[1].Value } else { 'unknown' }
$total = if ($lastProgress) { $lastProgress.Groups[2].Value } else { 'unknown' }
$latchThreads = if ($lastProgress) { $lastProgress.Groups[3].Value } else { 'unknown' }
$latchPages = if ($lastProgress) { $lastProgress.Groups[4].Value } else { 'unknown' }
$hasEnd = $latchText -match 'END LATCH CONTENDED PAGES'
$latchPageRows = @()
foreach ($match in [regex]::Matches($latchText, '(?m)^\s*(\d+:\d+)\s+(\d+)\s+((?:~\d+\s*,?\s*)+)\s*$')) {
    $latchPageRows += [pscustomobject]@{
        page = $match.Groups[1].Value
        count = $match.Groups[2].Value
        threads = (($match.Groups[3].Value -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ', '
    }
}

$latchDetailRows = New-Object System.Text.StringBuilder
if ($latchPageRows.Count -gt 0) {
    foreach ($row in $latchPageRows) {
        [void]$latchDetailRows.AppendLine("<tr><td class='mono'>$(HE $row.page)</td><td class='num'>$(HE $row.count)</td><td class='mono'>$(HE $row.threads)</td></tr>")
    }
} else {
    [void]$latchDetailRows.AppendLine('<tr><td colspan="3" class="dim">No contended page rows were emitted by the script.</td></tr>')
}

$section = @"
<h2>第四步 · 调度器清单（sys.schedulers.js）</h2>
<div class="note">已执行 <span class='mono'>sys.schedulers.js</span>。该步骤是 dump-overall 的客观清单，不做根因判断；后续 latch/native analysis 使用它判断 owner 是否 RUNNABLE、是否存在 scheduler pressure。Raw output: <a href='$(HE (Rel $SchedulerLog))'>$(HE (Rel $SchedulerLog))</a></div>
<table><thead><tr><th>项目</th><th class="num">值</th></tr></thead><tbody>
<tr><td>Scheduler rows</td><td class="num">$($schedulerLines.Count)</td></tr>
<tr><td>Visible online schedulers</td><td class="num">$($visibleRows.Count)</td></tr>
<tr><td>Hidden online schedulers</td><td class="num">$($hiddenRows.Count)</td></tr>
<tr><td>Max runnable_count</td><td class="num">$(HE ([string]$maxRunnable))</td></tr>
<tr><td>Schedulers with pending_disk_io_count &gt; 0</td><td class="num">$(HE ([string]$pendingDiskIoSchedulers))</td></tr>
</tbody></table>
<h3>Scheduler detail</h3>
<table><thead><tr><th>Address</th><th class="num">Scheduler</th><th>Status</th><th class="num">Idle</th><th class="num">Workers</th><th class="num">Tasks</th><th class="num">Runnable</th><th class="num">Pending disk IO</th><th class="num">Yield count</th><th>Active worker</th><th class="num">Debugger TID</th></tr></thead><tbody>
$($schedulerDetailRows.ToString())</tbody></table>

<h2>第六步 · latch 争用页面清单（dump_latch_contended_pages.js）</h2>
<div class="note">已执行 <span class='mono'>dump_latch_contended_pages.js</span>。这一步不依赖 DumpViewer latch tree；即使 DumpViewer 没有可用 latch tree，也必须保留该 DScript raw evidence。Raw output: <a href='$(HE (Rel $LatchPagesLog))'>$(HE (Rel $LatchPagesLog))</a></div>
<table><thead><tr><th>项目</th><th class="num">值</th></tr></thead><tbody>
<tr><td>Threads scanned</td><td class="num">$(HE ([string]$processed)) / $(HE ([string]$total))</td></tr>
<tr><td>Contended latch threads found</td><td class="num">$(HE ([string]$latchThreads))</td></tr>
<tr><td>Contended pages found</td><td class="num">$(HE ([string]$latchPages))</td></tr>
<tr><td>End marker</td><td class="num">$(if ($hasEnd) { 'present' } else { 'missing' })</td></tr>
</tbody></table>
<h3>Contended page detail</h3>
<table><thead><tr><th>Page</th><th class="num">Count</th><th>Threads</th></tr></thead><tbody>
$($latchDetailRows.ToString())</tbody></table>
"@

$html = Get-Content -LiteralPath $Overall -Raw -Encoding UTF8
$html = [regex]::Replace($html, '<h2>第四步 · 调度器清单（sys\.schedulers\.js）</h2>.*?<h2>第六步 · latch 争用页面清单（dump_latch_contended_pages\.js）</h2>.*?</table>', '', 'Singleline')
$html = $html -replace '<h2>第四步 · SOS 环形缓冲 / DumpViewer latch evidence</h2>', '<h2>DumpViewer latch pages（side evidence only）</h2>'
$html = $html -replace '这些页面支持 latch-native 结论，但不足以形成完整 DumpViewer-primary overall。', '这些页面只能作为 side evidence；如果没有完整 latch tree，不能替代 native DX/DT/DScript latch evidence。'
if ($html -match '<h2>DoD / Gate 状态</h2>') {
    $html = $html -replace '<h2>DoD / Gate 状态</h2>', ($section + '<h2>DoD / Gate 状态</h2>')
} elseif ($html -match '<div class="foot">') {
    $html = $html -replace '<div class="foot">', ($section + '<div class="foot">')
} elseif ($html -match '</body>') {
    $html = $html -replace '</body>', ($section + '</body>')
} else {
    $html += $section
}

[System.IO.File]::WriteAllText($Overall, $html, [System.Text.UTF8Encoding]::new($false))
Write-Host "[inject_dscript_inventory_sections] updated $Overall" -ForegroundColor Green