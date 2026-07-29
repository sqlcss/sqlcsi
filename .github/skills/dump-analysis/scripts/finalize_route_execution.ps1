# finalize_route_execution.ps1
# Gate C verifier + report/receipt generator. Final root-cause reporting must wait for PASS.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$Ledger,
    [string]$Out = '',
    [string]$Receipt = '',
    [string]$FinalReport = ''
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) { throw "route ledger not found: $Ledger" }
$base = Split-Path -Parent $Ledger
if (-not $Out) { $Out = Join-Path $base "${CaseId}_route_execution_report.html" }
if (-not $Receipt) { $Receipt = Join-Path $base 'route_execution_completion_receipt.json' }
$receiptTemp = "$Receipt.tmp"
if (Test-Path -LiteralPath $receiptTemp) { Remove-Item -LiteralPath $receiptTemp -Force }
if (Test-Path -LiteralPath $Receipt) { Remove-Item -LiteralPath $Receipt -Force }
$doc = Get-Content -LiteralPath $Ledger -Raw -Encoding UTF8 | ConvertFrom-Json
$failures = [System.Collections.Generic.List[string]]::new()
$terminal = @('completed','completed-with-limitations','unavailable-with-evidence')
$knownOptionalChecks = @('scheduler_non_yield.spinlock_thread_inventory','scheduler_non_yield.spinlock_owner_validation')
$ledgerMigrated = $false
foreach ($qualified in $knownOptionalChecks) {
    $parts = $qualified.Split('.',2)
    if (($doc.routes.PSObject.Properties.Name -contains $parts[0]) -and ($doc.routes.($parts[0]).checks.PSObject.Properties.Name -contains $parts[1])) {
        $check = $doc.routes.($parts[0]).checks.($parts[1])
        if (-not ($check.PSObject.Properties.Name -contains 'required')) { $check | Add-Member -NotePropertyName required -NotePropertyValue $false; $ledgerMigrated = $true }
        elseif ([bool]$check.required) { $check.required = $false; $ledgerMigrated = $true }
    }
}
# Recompute each route from mandatory checks only. This also repairs legacy
# ledgers whose route status was previously downgraded by an optional extension.
$ledgerChanged = $ledgerMigrated
foreach ($rp in $doc.routes.PSObject.Properties) {
    $requiredStatuses = @($rp.Value.checks.PSObject.Properties | Where-Object {
        $qualified = "$($rp.Name).$($_.Name)"
        ($knownOptionalChecks -notcontains $qualified) -and (-not ($_.Value.PSObject.Properties.Name -contains 'required') -or [bool]$_.Value.required)
    } | ForEach-Object { [string]$_.Value.status })
    $newStatus = $null
    if (@($requiredStatuses | Where-Object { $_ -eq 'failed' }).Count -gt 0) { $newStatus = 'failed' }
    elseif (@($requiredStatuses | Where-Object { $_ -notin @('completed','unavailable-with-evidence') }).Count -eq 0) {
        $unavailable = @($requiredStatuses | Where-Object { $_ -eq 'unavailable-with-evidence' }).Count
        if ($unavailable -eq $requiredStatuses.Count) { $newStatus = 'unavailable-with-evidence' }
        elseif ($unavailable -gt 0) { $newStatus = 'completed-with-limitations' }
        else { $newStatus = 'completed' }
    } elseif (@($requiredStatuses | Where-Object { $_ -ne 'pending' }).Count -gt 0) { $newStatus = 'in-progress' }
    else { $newStatus = 'pending' }
    if ([string]$rp.Value.status -ne $newStatus) { $rp.Value.status = $newStatus; $ledgerChanged = $true }
}
if ($ledgerChanged) {
    $ledgerTemp = "$Ledger.tmp"
    [IO.File]::WriteAllText($ledgerTemp,($doc | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($ledgerTemp,$Ledger,$true)
}
if ([int]$doc.selectedRouteCount -lt 1) { $failures.Add('no selected route or general fallback route') }
foreach ($rp in $doc.routes.PSObject.Properties) {
    $route = $rp.Value
    if ($terminal -notcontains [string]$route.status) { $failures.Add("route not terminal: $($rp.Name)=$($route.status)") }
    foreach ($cp in $route.checks.PSObject.Properties) {
        $check = $cp.Value
        $qualifiedCheck = "$($rp.Name).$($cp.Name)"
        $isRequired = ($knownOptionalChecks -notcontains $qualifiedCheck) -and (-not ($check.PSObject.Properties.Name -contains 'required') -or [bool]$check.required)
        $isTerminal = $terminal -contains [string]$check.status
        if ($isRequired -and -not $isTerminal) { $failures.Add("required check not terminal: $($rp.Name).$($cp.Name)=$($check.status)") }
        if ($isRequired -and @($check.evidence).Count -eq 0) { $failures.Add("required check has no evidence: $($rp.Name).$($cp.Name)") }
        if (-not $isRequired -and -not $isTerminal) { continue }
        if (@($check.evidence).Count -eq 0) { $failures.Add("terminal check has no evidence: $($rp.Name).$($cp.Name)") }
        foreach ($path in @($check.evidence)) {
            $resolved = if ([System.IO.Path]::IsPathRooted([string]$path)) { [string]$path } else { Join-Path $base ([string]$path) }
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or (Get-Item -LiteralPath $resolved).Length -eq 0) {
                $failures.Add("check evidence missing/empty: $resolved")
            }
        }
    }
}
if ($FinalReport) {
    $resolvedFinal = if ([System.IO.Path]::IsPathRooted($FinalReport)) { $FinalReport } else { Join-Path $base $FinalReport }
    if (-not (Test-Path -LiteralPath $resolvedFinal -PathType Leaf) -or (Get-Item -LiteralPath $resolvedFinal).Length -eq 0) {
        $failures.Add("final report missing/empty: $resolvedFinal")
    }
}
if ($failures.Count -gt 0) {
    Write-Host '[finalize_route_execution] FAIL (Gate C)' -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    Write-Host '  No Gate C receipt was published.' -ForegroundColor Red
    exit 1
}
function HE([string]$s) { if ($null -eq $s) { return '' }; return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;') }
function StatusTag([string]$status) {
    $cls = if ($status -eq 'completed') { 'done' } else { 'partial' }
    return "<span class='tag $cls'>$(HE $status)</span>"
}
function ExecutedAction([string]$routeKey,[string]$checkKey,$check) {
    if ($check.PSObject.Properties.Name -contains 'action' -and [string]$check.action) { return [string]$check.action }
    if ($routeKey -eq 'scheduler_non_yield') {
        $actions = @{
            scheduler_monitor_event = '!execute SOSRingBuffers.EnumerateSchedulerMonitorRecords; filter NONYIELD/STUCK_DISPATCHER and record scheduler, worker, utilization, and timestamp.'
            ptrack_recovery = '~61s; inspect callback stack; switch to SQL_SOSNonYieldSchedulerCallback frame 9; dv /t /v to recover local pTrack.'
            ptrack_validation = 'dx -r3 pTrack; follow m_pWorker to task/scheduler/system-thread and compare with scheduler inventory.'
            timing_cpu = 'Read pTrack m_pass, m_diagnosedPass, m_sysDiff.m_WallClockTime, m_workerDiff Kernel/User times, and worker status; convert timing units.'
            current_stack = '~661s; kv; !mex.t 661; inspect SpinToAcquire/LogInfoIter frame locals.'
            copied_stack = '.cxr @@(&sqlmin!g_copiedStackInfo.threadContext); kv; .cxr; compare first-detected and current stacks.'
            scheduler_inventory = 'Run sys.schedulers.js and Tasks.Enumerate; inspect scheduler 42 and its task-state pivot.'
            task_query_correlation = 'Run task.js and tsqlstack.js for thread 661; inspect CDbVLFTable locals to correlate SPID, query, and database ID.'
        }
        if ($actions.ContainsKey($checkKey)) { return $actions[$checkKey] }
    }
    return [string]$check.description
}
$routeCss=@'
:root{--bg:#1e1e2e;--surface:#252538;--border:#3a3a55;--text:#cdd6f4;--dim:#a6adc8;--accent:#89b4fa;--green:#a6e3a1;--yellow:#f9e2af;--teal:#94e2d5;--mauve:#cba6f7}*{box-sizing:border-box}body{margin:0;padding:28px;background:var(--bg);color:var(--text);font:14px/1.55 'Segoe UI',sans-serif}main{max-width:1280px;margin:auto}h1{color:var(--accent)}h2{color:var(--mauve);border-bottom:1px solid var(--border);padding-bottom:7px;margin-top:30px}h3,h4{color:var(--teal)}a{color:var(--accent)}table{border-collapse:collapse;width:100%;max-width:100%;display:block;overflow-x:auto;margin:10px 0 18px}th,td{border:1px solid var(--border);padding:7px 9px;vertical-align:top}th{background:#2b2b40;color:var(--accent);text-align:left}tbody tr:nth-child(even){background:#20202f}.mono{font-family:'Cascadia Code',Consolas,monospace}.tag{display:inline-block;border-radius:999px;padding:2px 8px;font-size:11px;font-weight:700}.done{color:var(--green);background:#263a2c}.partial{color:var(--yellow);background:#3a3327}.note{background:#181825;border-left:3px solid var(--teal);padding:9px 12px;border-radius:5px;color:var(--dim);margin:10px 0}.cards{display:flex;gap:10px;flex-wrap:wrap;margin:14px 0}.card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:10px 14px}.card b{display:block;color:var(--accent)}.grid{display:grid;grid-template-columns:repeat(12,minmax(0,1fr));gap:12px}.span-6{grid-column:span 6}pre{white-space:pre-wrap;word-break:break-word;background:#181825;border:1px solid var(--border);border-radius:6px;padding:10px;overflow:auto;color:var(--dim);font:12px/1.45 'Cascadia Code',Consolas,monospace}@media(max-width:800px){.span-6{grid-column:span 12}}
'@
. (Join-Path $PSScriptRoot 'non_yield_report_common.ps1')
$nonYieldFindingsPath=Join-Path $base "${CaseId}_non_yield_findings.json"
$nonYieldFindings=if(Test-Path -LiteralPath $nonYieldFindingsPath -PathType Leaf){Get-Content -LiteralPath $nonYieldFindingsPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
$routeRows = [System.Text.StringBuilder]::new()
$details = [System.Text.StringBuilder]::new()
$routeSubreports = @()
foreach ($rp in $doc.routes.PSObject.Properties) {
    $key = $rp.Name; $route = $rp.Value
    $subName = "${CaseId}_route_${key}.html"
    $subPath = Join-Path $base $subName
    [void]$routeRows.Append("<tr><td class='mono'>$(HE $key)</td><td><a href='$(HE $subName)'><b>$(HE $route.name)</b></a></td><td>$(StatusTag $route.status)</td><td>$(HE $route.selectionOrigin)</td><td>$(HE $route.executionOrigin)</td><td>$(HE $route.selectionReason)</td><td>$(HE $route.downstreamRoute)</td></tr>")
    [void]$details.Append("<h3><a href='$(HE $subName)'>$(HE $route.name) &rarr;</a></h3><div class='note'>Selected because: $(HE $route.selectionReason)<br><b>Execution origin:</b> $(HE $route.executionOrigin)</div><table><thead><tr><th>Required check</th><th>Status</th><th>What was executed</th><th>Result</th><th>Evidence</th></tr></thead><tbody>")
    $subRows = [System.Text.StringBuilder]::new()
    foreach ($cp in $route.checks.PSObject.Properties) {
        $check = $cp.Value
        $links = @($check.evidence | ForEach-Object { "<a href='$(HE ([string]$_))'>$(HE ([System.IO.Path]::GetFileName([string]$_)))</a>" }) -join '<br>'
        $checkRow = "<tr><td class='mono'>$(HE $cp.Name)</td><td>$(StatusTag $check.status)</td><td>$(HE (ExecutedAction $key $cp.Name $check))</td><td>$(HE $check.note)</td><td>$links</td></tr>"
        [void]$details.Append($checkRow)
        [void]$subRows.Append($checkRow)
    }
    [void]$details.Append('</tbody></table>')
    $structuredSummary=if($key-eq'scheduler_non_yield'-and$nonYieldFindings){Render-NonYieldFindingsHtml $nonYieldFindings 'Structured Scheduler / non-yield findings'}else{''}
    $deferredResearch=if($key-eq'scheduler_non_yield'){"<h2>Deferred post-final continuation</h2><div class='note'><b>Copied-stack callstack research is intentionally not executed inside Gate C.</b><br>The high-latency source, work-item, PR, CU, CSS Wiki, and Microsoft Learn research starts only after the authoritative overall report and a base final root-cause HTML already exist. It produces an independent three-report set, then the final completion gate publishes its verified English HTML link.</div>"}else{''}
    $subHtml = "<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>$(HE $route.name) Deep Dive · $(HE $CaseId)</title><style>$routeCss</style></head><body><main><p><a href='$([System.IO.Path]::GetFileName($Out))'>&larr; Gate C route index</a></p><h1>$(HE $route.name) · Deep-Dive Execution Report</h1><div class='cards'><div class='card'>Route status<b>$(HE $route.status)</b></div><div class='card'>Required checks<b>$(@($route.checks.PSObject.Properties).Count)</b></div><div class='card'>Selection origin<b>$(HE $route.selectionOrigin)</b></div></div><div class='note'><b>Selected because:</b> $(HE $route.selectionReason)<br><b>Execution origin:</b> $(HE $route.executionOrigin)<br><b>Downstream path:</b> $(HE $route.downstreamRoute)</div>$structuredSummary<h2>Execution results and evidence</h2><table><thead><tr><th>Required check</th><th>Status</th><th>What was executed</th><th>Result</th><th>Evidence</th></tr></thead><tbody>$($subRows.ToString())</tbody></table>$deferredResearch</main></body></html>"
    [System.IO.File]::WriteAllText($subPath,$subHtml,[System.Text.UTF8Encoding]::new($false))
    $routeSubreports += [ordered]@{route=$key;name=[string]$route.name;path=$subName;sha256=(Get-FileHash -LiteralPath $subPath -Algorithm SHA256).Hash;checks=@($route.checks.PSObject.Properties).Count}
}
$groupHtml = ''
if (@($doc.executionGroups).Count -gt 0) {
    $rows = @($doc.executionGroups | ForEach-Object { "<tr><td class='mono'>$(HE $_.name)</td><td>$(HE (@($_.routes) -join ', '))</td><td>$(HE $_.strategy)</td></tr>" }) -join ''
    $groupHtml = "<h2>Combined execution groups</h2><table><thead><tr><th>Group</th><th>Routes</th><th>Strategy</th></tr></thead><tbody>$rows</tbody></table>"
}
$css=@'
:root{--bg:#1e1e2e;--surface:#252538;--border:#3a3a55;--text:#cdd6f4;--dim:#a6adc8;--accent:#89b4fa;--green:#a6e3a1;--yellow:#f9e2af;--teal:#94e2d5;--mauve:#cba6f7}*{box-sizing:border-box}body{margin:0;padding:28px;background:var(--bg);color:var(--text);font:14px/1.55 'Segoe UI',sans-serif}main{max-width:1280px;margin:auto}h1{color:var(--accent)}h2{color:var(--mauve);border-bottom:1px solid var(--border);padding-bottom:7px;margin-top:30px}h3{color:var(--teal)}a{color:var(--accent)}table{border-collapse:collapse;width:100%;max-width:100%;display:block;overflow-x:auto;margin:10px 0 18px}th,td{border:1px solid var(--border);padding:7px 9px;vertical-align:top}th{background:#2b2b40;color:var(--accent);text-align:left}tbody tr:nth-child(even){background:#20202f}.mono{font-family:'Cascadia Code',Consolas,monospace}.tag{display:inline-block;border-radius:999px;padding:2px 8px;font-size:11px;font-weight:700}.done{color:var(--green);background:#263a2c}.partial{color:var(--yellow);background:#3a3327}.note{background:#181825;border-left:3px solid var(--teal);padding:9px 12px;border-radius:5px;color:var(--dim)}
'@
$html="<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Dump-analysis Route Execution · $(HE $CaseId)</title><style>$css</style></head><body><main><h1>Gate C · Dump-analysis Route Execution</h1><p>Case <span class='mono'>$(HE $CaseId)</span> · selected routes: $($doc.selectedRouteCount)</p><div class='note'>This report proves that every Gate B <span class='mono'>route-signal</span> was executed or explicitly unavailable with evidence. A checklist row is an evidence requirement, not necessarily a separate debugger process. Final root-cause compilation is blocked until this gate passes.</div><h2>Selected route status</h2><table><thead><tr><th>Key</th><th>Route</th><th>Status</th><th>Selection origin</th><th>Execution origin</th><th>Selection reason</th><th>Deep-dive path</th></tr></thead><tbody>$($routeRows.ToString())</tbody></table>$groupHtml<h2>Execution checklist and evidence</h2>$($details.ToString())</main></body></html>"
[System.IO.File]::WriteAllText($Out,$html,[System.Text.UTF8Encoding]::new($false))
$receiptObject=[ordered]@{
    caseId=$CaseId;gate='Gate C — dump-analysis route execution';status='PASS';completedAt=(Get-Date).ToString('o')
    selectedRouteCount=[int]$doc.selectedRouteCount;routeLedger=[System.IO.Path]::GetFileName($Ledger);routeLedgerSha256=(Get-FileHash -LiteralPath $Ledger -Algorithm SHA256).Hash
    routeExecutionReport=[System.IO.Path]::GetFileName($Out);routeExecutionReportSha256=(Get-FileHash -LiteralPath $Out -Algorithm SHA256).Hash
    routeSubreports=@($routeSubreports)
    sourceBranchJson=[string]$doc.sourceBranchJson;sourceBranchSha256=[string]$doc.sourceBranchSha256
    finalReport=if($FinalReport){[System.IO.Path]::GetFileName($FinalReport)}else{$null}
}
[System.IO.File]::WriteAllText($receiptTemp,($receiptObject|ConvertTo-Json -Depth 8),[System.Text.UTF8Encoding]::new($false))
[System.IO.File]::Move($receiptTemp,$Receipt,$true)
Write-Host "[finalize_route_execution] PASS (Gate C): routes=$($doc.selectedRouteCount) -> $Out" -ForegroundColor Green
exit 0
