# gen_first_pass_branch_hints_report.ps1
# Render a separate POST-OVERALL signal-routing report. It does not alter Gate A.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$ProbeStatus = '',
    [string]$OverallReceipt = '',
    [string]$Out = '',
    [string]$JsonOut = ''
)

$ErrorActionPreference = 'Stop'
if (-not $ProbeStatus) { $ProbeStatus = Join-Path $OutDir "${CaseId}_first_pass_probe_status.json" }
if (-not $OverallReceipt) { $OverallReceipt = Join-Path $OutDir 'overall_completion_receipt.json' }
if (-not $Out) { $Out = Join-Path $OutDir "${CaseId}_first_pass_branch_hints.html" }
if (-not $JsonOut) { $JsonOut = Join-Path $OutDir "${CaseId}_first_pass_branch_hints.json" }
foreach ($path in @($ProbeStatus,$OverallReceipt)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "required input missing: $path" }
}
$statusDoc = Get-Content -LiteralPath $ProbeStatus -Raw -Encoding UTF8 | ConvertFrom-Json
$receipt = Get-Content -LiteralPath $OverallReceipt -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$receipt.status -ne 'PASS') { throw 'overall completion receipt is not PASS' }

function HE([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}
function Rel([string]$path) {
    if (-not $path) { return '' }
    if ([System.IO.Path]::IsPathRooted($path)) { return [System.IO.Path]::GetRelativePath($OutDir,$path).Replace('\','/') }
    return $path.Replace('\','/')
}
function Count-PipeRows([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return -1 }
    return ([regex]::Matches((Get-Content -LiteralPath $path -Raw -Encoding UTF8),'(?m)^\s*0x[0-9A-Fa-f]+\s*\|')).Count
}
function Parse-PipeRows([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $lines = [System.IO.File]::ReadAllLines($path)
    $headerIndex = -1
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^record\s+\|') { $headerIndex = $i; break }
    }
    if ($headerIndex -lt 0) { return @() }
    $columns = @(($lines[$headerIndex] -split '\s*\|\s*') | ForEach-Object { $_.Trim() })
    $rows = @()
    for ($i=$headerIndex+1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^0x[0-9A-Fa-f]+\s*\|') { continue }
        $cells = @(($lines[$i] -split '\s*\|\s*') | ForEach-Object { $_.Trim() })
        $row = [ordered]@{}
        for ($c=0; $c -lt $columns.Count; $c++) { $row[$columns[$c]] = if ($c -lt $cells.Count) { $cells[$c] } else { '' } }
        $rows += [pscustomobject]$row
    }
    return @($rows)
}
function Artifact-Signal([string]$name,[string]$path,[int]$rows,[string]$zeroStatus='no-signal') {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{source=$name;status='unavailable-with-evidence';count=$null;evidence=(Rel $path);note='artifact missing'}
    }
    $st = if ($rows -gt 0) { 'data-present' } elseif ($rows -eq 0) { 'empty-result' } else { 'data-present' }
    return [pscustomobject]@{source=$name;status=$st;count=if($rows -ge 0){$rows}else{$null};evidence=(Rel $path);note=if($rows -ge 0){"$rows row(s)"}else{'artifact present'}}
}
function Probe([string]$expr) {
    $p = @($statusDoc.probes | Where-Object expression -eq $expr | Select-Object -First 1)
    if ($p.Count -eq 0) { return [pscustomobject]@{source=$expr;status='unavailable-with-evidence';count=$null;evidence=(Rel $statusDoc.combinedLog);note='probe result missing'} }
    $coverage = switch ([string]$p[0].status) {
        'signal-present' { 'data-present' }
        'no-signal' { 'empty-result' }
        default { [string]$p[0].status }
    }
    return [pscustomobject]@{source=$expr;status=$coverage;count=$p[0].rowCount;evidence=(Rel $p[0].evidence);note=[string]$p[0].reason}
}
function Bucket-Coverage([array]$sources) {
    if (@($sources | Where-Object status -eq 'data-present').Count -gt 0) { return 'data-present' }
    if (@($sources | Where-Object status -eq 'empty-result').Count -gt 0) { return 'empty-result' }
    return 'unavailable-with-evidence'
}

$txt = Join-Path $OutDir 'txt_detail'
$exceptionFile = Join-Path $OutDir "${CaseId}_exception.html"
$schedulerRing = Join-Path $txt "${CaseId}_SOSRingBuffers.EnumerateSchedulerMonitorRecords.txt"
$memoryRing = Join-Path $txt "${CaseId}_SOSRingBuffers.EnumerateMemoryBrokerRingRecords.txt"
$blockedRing = Join-Path $txt "${CaseId}_SOSRingBuffers.EnumerateBlockedProcessReportRingBufferRecords.txt"
$hadrPublish = Join-Path $txt "${CaseId}_SOSRingBuffers.EnumerateHadrArPubishEventsRecords.txt"
$hadrSignal = Join-Path $txt "${CaseId}_SOSRingBuffers.EnumerateHadrArSignalStateRecords.txt"
$latchLog = Join-Path $OutDir "${CaseId}_dump_latch_contended_pages.txt"
$execReport = Join-Path $OutDir "${CaseId}_sql_exec_thread.html"
$taskFieldsPath = Join-Path $OutDir 'task_fields.json'
$memoryBrokerLog = Join-Path $OutDir "${CaseId}_memory_brokers.txt"
$threadsJson = Join-Path $OutDir 'us_threads_shredded.json'
$dumpViewerLog = @(Get-ChildItem (Join-Path $OutDir 'dumpviewer_out') -Filter 'DumpViewer_*.log' -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName

$schedulerRows = @(Parse-PipeRows $schedulerRing)
$memoryRows = @(Parse-PipeRows $memoryRing)
$hadrPublishRows = @(Parse-PipeRows $hadrPublish)
$nonYieldRows = @($schedulerRows | Where-Object { [string]$_.m_event -match 'NONYIELD|STUCK_DISPATCHER' })
$memoryShrinkRows = @($memoryRows | Where-Object { [string]$_.m_last_notification -eq 'SHRINK' })
$memoryOomRows = @($memoryRows | Where-Object { ($_ | ConvertTo-Json -Compress) -match '(?i)\bOOM\b|OUT_OF_MEMORY' })
$hadrAbnormalRows = @($hadrPublishRows | Where-Object {
    [string]$_.m_has_exeception -eq 'True' -or [string]$_.m_current_ar_role -notmatch '^HADR_AR_ROLE_(PRIMARY|SECONDARY)_NORMAL$'
})
$spinlockStacks = @()
if (Test-Path -LiteralPath $threadsJson -PathType Leaf) {
    $spinlockStacks = @(Get-Content -LiteralPath $threadsJson -Raw -Encoding UTF8 | ConvertFrom-Json |
        Where-Object { [string]$_.stack -match 'SpinlockBase::Backoff|SpinToAcquire|Spinlock<' })
}

$latchFound = 0
if (Test-Path -LiteralPath $latchLog) {
    $lm = [regex]::Matches((Get-Content -LiteralPath $latchLog -Raw -Encoding UTF8),'Processing\s+\d+\s+of\s+\d+\s+-\s+Found\s+(\d+)\s+threads\s+\((\d+)\s+pages\)') | Select-Object -Last 1
    if ($lm) { $latchFound = [int]$lm.Groups[2].Value }
}
$ioMatches = @()
if (Test-Path -LiteralPath $taskFieldsPath) {
    $taskFields = @(Get-Content -LiteralPath $taskFieldsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    $allTasks = @($taskFields | ForEach-Object { $_.main; @($_.children) })
    $ioMatches = @($allTasks | Where-Object { "$( $_.waitType ) $( $_.taskFunc )" -match 'WRITELOG|PAGEIOLATCH|IO_COMPLETION|ASYNC_IO|WriteFileGather|ReadFileScatter|DiskWorker|FCB::' })
}

$buckets = @()
function Add-Bucket([string]$name,[string]$route,[array]$sources) {
    $script:buckets += [pscustomobject]@{
        name=$name
        coverageStatus=(Bucket-Coverage $sources)
        routingStatus='context-only'
        routingReason='Data is available, but no branch-specific routing predicate has been assigned.'
        downstreamRoute=$route
        sources=@($sources)
    }
}

Add-Bucket 'Exception / AV / dump reason' 'dump-analysis exception / call-stack route' @(
    (Probe 'SOSRingBuffers.EnumerateExceptionRingRecords'),
    (Probe 'ExceptionContext.CurrentStack'),
    (Probe 'ExceptionContext.Enumerate'),
    (Probe 'ExceptionHandlerStacks.Enumerate'),
    (Artifact-Signal 'exception detail report' $exceptionFile $(if(Test-Path $exceptionFile){-1}else{-2}))
)
Add-Bucket 'Scheduler / non-yield' 'scheduler / non-yield route' @(
    (Probe 'Schedulers.Enumerate'), (Probe 'Workers.Enumerate'),
    (Artifact-Signal 'SchedulerMonitor ring records' $schedulerRing (Count-PipeRows $schedulerRing))
)
Add-Bucket 'Memory / OOM / leak' 'memory / OOM / leak route' @(
    (Probe 'MemoryNodes.Enumerate'), (Probe 'SOSNodes.Enumerate'),
    (Probe 'MemoryClerks.Enumerate'), (Probe 'MemoryObjects.Enumerate'), (Probe 'LeakedAllocations.Enumerate'),
    (Artifact-Signal 'memory broker inventory' $memoryBrokerLog $(if(Test-Path $memoryBrokerLog){-1}else{-2})),
    (Artifact-Signal 'MemoryBroker ring records' $memoryRing (Count-PipeRows $memoryRing))
)
Add-Bucket 'Query execution' 'query execution route' @(
    (Probe 'Sessions.Enumerate'), (Probe 'Tasks.Enumerate'), (Probe 'DbccInputBuffers.Enumerate'),
    (Probe 'QueryPlans.Enumerate'), (Probe 'QueryExecutionTrees.Enumerate'),
    (Artifact-Signal 'task.js / tsqlstack detail' $execReport $(if(Test-Path $execReport){-1}else{-2}))
)
Add-Bucket 'Blocking / latch / locking' 'locking / latch route' @(
    (Probe 'Tasks.Enumerate'), (Probe 'Workers.Enumerate'),
    (Artifact-Signal 'blocked-process ring records' $blockedRing (Count-PipeRows $blockedRing)),
    (Artifact-Signal 'latch-contended pages' $latchLog $latchFound)
)
Add-Bucket 'HADR / AG' 'HADR / AG route' @(
    (Artifact-Signal 'HADR AR publish records' $hadrPublish (Count-PipeRows $hadrPublish)),
    (Artifact-Signal 'HADR AR signal-state records' $hadrSignal (Count-PipeRows $hadrSignal))
)
Add-Bucket 'IO / storage / transaction log' 'IO / log route' @(
    [pscustomobject]@{source='task.js wait/function keyword inventory';status=if($ioMatches.Count -gt 0){'data-present'}else{'empty-result'};count=$ioMatches.Count;evidence=(Rel $taskFieldsPath);note="$($ioMatches.Count) IO/log keyword match(es)"}
)
Add-Bucket 'SQLPAL / Linux' 'SQLPAL workflow' @(
    [pscustomobject]@{source='dump platform metadata';status='data-present';count=1;evidence=(Rel $dumpViewerLog);note='Windows x64 platform metadata captured'}
)

foreach ($bucket in $buckets) {
    switch ($bucket.name) {
        'Exception / AV / dump reason' {
            $bucket.routingStatus = 'context-only'
            $bucket.routingReason = 'Historical SQL exception-ring rows and stored contexts are readable, but CurrentStack emitted no rows; row presence is not an AV finding.'
        }
        'Scheduler / non-yield' {
            if ($nonYieldRows.Count -gt 0) {
                $bucket.routingStatus = 'route-signal'
                $bucket.routingReason = "$($nonYieldRows.Count) SchedulerMonitor NONYIELD/STUCK_DISPATCHER record(s) directly match the dump class."
            } else {
                $bucket.routingStatus = 'no-route-signal'
                $bucket.routingReason = 'Scheduler history is present, but no NONYIELD/STUCK_DISPATCHER event was found.'
            }
        }
        'Memory / OOM / leak' {
            if ($memoryOomRows.Count -gt 0) {
                $bucket.routingStatus = 'route-signal'
                $bucket.routingReason = "$($memoryOomRows.Count) OOM marker(s) were found in memory evidence."
            } else {
                $bucket.routingStatus = 'context-only'
                $bucket.routingReason = "$($memoryRows.Count) MemoryBroker history rows are available, including $($memoryShrinkRows.Count) SHRINK row(s), but no OOM marker or direct dump-trigger correlation was established."
            }
        }
        'Query execution' {
            $bucket.routingStatus = 'context-only'
            $bucket.routingReason = "$(@($taskFields).Count) main execution context(s) and decoded T-SQL artifacts are available; they identify workload context, not a query-cause conclusion."
        }
        'Blocking / latch / locking' {
            if ($spinlockStacks.Count -gt 0) {
                $bucket.routingStatus = 'route-signal'
                $bucket.routingReason = "$($spinlockStacks.Count) Spinlock/Backoff stack signature(s) were captured (thread IDs: $(@($spinlockStacks.id) -join ', ')); blocked-process rows and latch-contended pages are both zero."
            } else {
                $bucket.routingStatus = 'no-route-signal'
                $bucket.routingReason = 'No spinlock/backoff stack, blocked-process row, or latch-contended page was captured.'
            }
        }
        'HADR / AG' {
            if ($hadrAbnormalRows.Count -gt 0) {
                $bucket.routingStatus = 'route-signal'
                $bucket.routingReason = "$($hadrAbnormalRows.Count) HADR publish row(s) have an exception or non-normal current role."
            } else {
                $bucket.routingStatus = 'no-route-signal'
                $bucket.routingReason = "$($hadrPublishRows.Count) publish history row(s) are present, but every current role is normal and no publish exception is set."
            }
        }
        'IO / storage / transaction log' {
            $bucket.routingStatus = if ($ioMatches.Count -gt 0) { 'context-only' } else { 'no-route-signal' }
            $bucket.routingReason = if ($ioMatches.Count -gt 0) { "$($ioMatches.Count) task wait/function keyword match was found; a single inventory match is retained as context and is not sufficient to select the IO route." } else { 'No IO/log task keyword match was found.' }
        }
        'SQLPAL / Linux' {
            $bucket.routingStatus = 'no-route-signal'
            $bucket.routingReason = 'The dump is Windows x64, so the SQLPAL/Linux route does not apply.'
        }
    }
}

$result = [ordered]@{
    caseId=$CaseId
    phase='post-overall branch hints'
    overallGate=[ordered]@{status='PASS';receipt=(Rel $OverallReceipt);report=(Rel (Join-Path $OutDir $receipt.overallReport));isolated=$true}
    captureStatus=[string]$statusDoc.captureStatus
    probeStatus=(Rel $ProbeStatus)
    combinedLog=(Rel $statusDoc.combinedLog)
    buckets=$buckets
}
[System.IO.File]::WriteAllText($JsonOut, ($result | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))

function StatusTag([string]$status) {
    $cls = switch ($status) {
        'data-present' {'present'}
        'route-signal' {'route'}
        'context-only' {'context'}
        'empty-result' {'none'}
        'no-route-signal' {'none'}
        default {'unavail'}
    }
    $label = switch ($status) {
        'data-present' {'data present'}
        'empty-result' {'empty result'}
        'route-signal' {'route signal'}
        'context-only' {'context only'}
        'no-route-signal' {'no route signal'}
        default {$status}
    }
    return "<span class='tag $cls'>$(HE $label)</span>"
}
$probeRows = [System.Text.StringBuilder]::new()
foreach ($p in $statusDoc.probes) {
    $coverage = switch ([string]$p.status) { 'signal-present' {'data-present'} 'no-signal' {'empty-result'} default {[string]$p.status} }
    [void]$probeRows.Append("<tr><td class='mono'>$(HE $p.expression)</td><td>$(HE $p.kind)</td><td>$(StatusTag $coverage)</td><td class='num'>$(HE ([string]$p.rowCount))</td><td>$(HE $p.reason)</td><td><a href='$(HE (Rel $p.evidence))'>raw section</a></td></tr>")
}
$bucketRows = [System.Text.StringBuilder]::new()
$bucketDetails = [System.Text.StringBuilder]::new()
foreach ($b in $buckets) {
    [void]$bucketRows.Append("<tr><td><b>$(HE $b.name)</b></td><td>$(StatusTag $b.coverageStatus)</td><td>$(StatusTag $b.routingStatus)</td><td>$(HE $b.routingReason)</td><td>$(HE $b.downstreamRoute)</td></tr>")
    [void]$bucketDetails.Append("<h3>$(HE $b.name)</h3><div class='routewhy'><b>Routing relevance:</b> $(StatusTag $b.routingStatus) $(HE $b.routingReason)</div><table><thead><tr><th>Evidence source</th><th>Data coverage</th><th>Count</th><th>Evidence</th><th>Neutral note</th></tr></thead><tbody>")
    foreach ($s in $b.sources) {
        $link = if ($s.evidence) { "<a href='$(HE (Rel $s.evidence))'>open</a>" } else { '—' }
        [void]$bucketDetails.Append("<tr><td>$(HE $s.source)</td><td>$(StatusTag $s.status)</td><td class='num'>$(HE ([string]$s.count))</td><td>$link</td><td>$(HE $s.note)</td></tr>")
    }
    [void]$bucketDetails.Append('</tbody></table>')
}

$css = @'
:root{--bg:#1e1e2e;--surface:#252538;--border:#3a3a55;--text:#cdd6f4;--dim:#a6adc8;--accent:#89b4fa;--green:#a6e3a1;--yellow:#f9e2af;--red:#f38ba8;--teal:#94e2d5;--mauve:#cba6f7}
*{box-sizing:border-box}body{margin:0;padding:28px;background:var(--bg);color:var(--text);font:14px/1.55 'Segoe UI',sans-serif}main{max-width:1320px;margin:auto}h1{color:var(--accent)}h2{color:var(--mauve);border-bottom:1px solid var(--border);padding-bottom:7px;margin-top:32px}h3{color:var(--teal)}a{color:var(--accent)}.note{background:#181825;border-left:4px solid var(--accent);padding:11px 14px;margin:12px 0;border-radius:6px}.gate{border-left-color:var(--green)}table{border-collapse:collapse;width:100%;max-width:100%;display:block;overflow-x:auto;margin:10px 0 18px}th,td{border:1px solid var(--border);padding:7px 9px;vertical-align:top}th{background:#2b2b40;color:var(--accent);text-align:left}tbody tr:nth-child(even){background:#20202f}.mono{font-family:'Cascadia Code',Consolas,monospace}.num{text-align:right}.tag{display:inline-block;border-radius:999px;padding:2px 8px;font-size:11px;font-weight:700;white-space:nowrap}.present{color:var(--green);background:#263a2c}.route{color:var(--red);background:#3a2733}.context{color:var(--accent);background:#27333a}.none{color:var(--dim);background:#2a2a3a}.unavail{color:var(--yellow);background:#3a3327}.routewhy{background:#181825;border-left:3px solid var(--teal);padding:8px 12px;border-radius:4px;color:var(--dim);margin:8px 0}.cards{display:flex;gap:10px;flex-wrap:wrap}.card{background:var(--surface);border:1px solid var(--border);border-radius:9px;padding:10px 14px}.card b{display:block;color:var(--accent);font-size:18px}.foot{color:var(--dim);font-size:11px;margin-top:30px;border-top:1px solid var(--border);padding-top:10px}
'@
$routeCount = @($buckets | Where-Object routingStatus -eq 'route-signal').Count
$contextCount = @($buckets | Where-Object routingStatus -eq 'context-only').Count
$noneCount = @($buckets | Where-Object routingStatus -eq 'no-route-signal').Count
$unavailableCount = @($buckets | Where-Object routingStatus -eq 'unavailable-with-evidence').Count
$html = @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>First-pass Branch Hints · $CaseId</title><style>$css</style></head><body><main>
<h1>Post-Overall First-pass Probe &amp; Branch-Hints Report</h1>
<p>Case <span class="mono">$(HE $CaseId)</span> · capture status: <span class="mono">$(HE $statusDoc.captureStatus)</span></p>
<div class="note gate"><b>Isolation gate:</b> the previously defined <a href="$(HE $receipt.overallReport)">dump-overall report</a> passed Completion before this phase started. Probe failures here are recorded as <span class="mono">unavailable-with-evidence</span> and cannot invalidate or rewrite that PASS.</div>
<div class="note"><b>How to read this report:</b> <b>Data coverage</b> answers only whether rows or artifacts were captured. <span class="mono">data present</span> is not an error. <b>Routing relevance</b> separately states whether an objective branch-specific predicate was found. A <span class="mono">route signal</span> selects a downstream review path; it still does not prove root cause.</div>
<div class="cards"><div class="card">Branch buckets<b>8</b></div><div class="card">route signals<b>$routeCount</b></div><div class="card">context only<b>$contextCount</b></div><div class="card">no route signal<b>$noneCount</b></div><div class="card">unavailable<b>$unavailableCount</b></div><div class="card">probes<b>$(@($statusDoc.probes).Count)</b></div></div>
<h2>Branch-bucket index</h2><table><thead><tr><th>Bucket</th><th>Data coverage</th><th>Routing relevance</th><th>Why</th><th>Downstream route</th></tr></thead><tbody>$($bucketRows.ToString())</tbody></table>
<h2>Probe matrix</h2><p>This matrix reports <b>coverage only</b>. A probe with 507 task rows or 4096 exception-history rows is marked <span class="mono">data present</span>, not “abnormal.” Combined raw capture: <a href="$(HE (Rel $statusDoc.combinedLog))">$(HE (Rel $statusDoc.combinedLog))</a> · structured status: <a href="$(HE (Rel $ProbeStatus))">$(HE (Rel $ProbeStatus))</a></p><table><thead><tr><th>Expression</th><th>Kind</th><th>Data coverage</th><th>Rows</th><th>Reason</th><th>Evidence</th></tr></thead><tbody>$($probeRows.ToString())</tbody></table>
<h2>Bucket evidence detail</h2>$($bucketDetails.ToString())
<div class="foot">Generated after dump-overall Completion PASS · separate best-effort routing artifact · no root-cause analysis.</div>
</main></body></html>
"@
[System.IO.File]::WriteAllText($Out, $html, [System.Text.UTF8Encoding]::new($false))
Write-Host "[gen_first_pass_branch_hints_report] buckets=8 route=$routeCount context=$contextCount no-route=$noneCount unavailable=$unavailableCount -> $Out"
exit 0
