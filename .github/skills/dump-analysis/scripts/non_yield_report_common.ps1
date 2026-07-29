# Shared structured renderer for Scheduler / non-yield Gate C findings.
function ConvertTo-NYHtml([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}
function Get-NYDisplayNumber([object]$value) {
    $s=[string]$value
    if($s -match '^\s*(-?\d+)'){return $Matches[1]}
    return $s
}
function Get-NYSqlText([string]$raw) {
    if(-not$raw){return ''}
    $m=[regex]::Match($raw,'Input string:\s*(.*?)(?:\r?\nCCompPlan:)','Singleline,IgnoreCase')
    if($m.Success){return $m.Groups[1].Value.Trim()}
    return $raw.Trim()
}
function Render-NonYieldFindingsHtml($f,[string]$Heading='Automated Gate C Scheduler / non-yield findings') {
    $event=$f.schedulerMonitor
    $current=@($f.currentStack.functions)
    $copied=@($f.copiedStack.functions)
    $currentText=($current -join "`n")
    $copiedText=($copied -join "`n")
    $sql=Get-NYSqlText ([string]$f.execution.sql)
    $dscriptStatus=if([string]$f.dscript.status -eq 'completed'){'completed'}else{'partial · unavailable-with-evidence'}
    $same=if([bool]$f.sameCorePath){'Yes — both snapshots contain Backoff → SpinToAcquireOptimistic → LogInfoIter::GetNext'}else{'No / unavailable'}
    $evidence=$f.evidence
    $spinHtml=''
    if($f.PSObject.Properties.Name -contains 'spinlockOwnerSweep') {
        $s=$f.spinlockOwnerSweep
        if([string]$s.status -in @('completed','not-applicable')) {
            $lockRows=@($s.locks | ForEach-Object {
                $waiters=@($_.waiterDebuggerIds) -join ', '
                $owner=if($null-ne$_.resolvedOwnerDebuggerId){[string]$_.resolvedOwnerDebuggerId}else{'unresolved'}
                "<tr><td class='mono'>$(ConvertTo-NYHtml ([string]$_.address))</td><td class='mono'>$(ConvertTo-NYHtml ([string]$_.qword))</td><td>$(ConvertTo-NYHtml $waiters)</td><td class='mono'>$(ConvertTo-NYHtml ([string]$_.nominalOwnerTid)) / $(ConvertTo-NYHtml $owner)</td><td>$(ConvertTo-NYHtml ([string]$_.ownerStackCompatibility))</td><td>$(ConvertTo-NYHtml ([string]$_.actualHolderStatus))</td><td>$(ConvertTo-NYHtml ([string]$_.parentAddressChainCoherent))</td></tr>"
            }) -join ''
            $spinHtml=@"
<!-- SPINLOCK-OWNER-SWEEP-SUMMARY -->
<h3>Gate C · Spinlock Thread and Nominal Owner Sweep</h3>
<div class="note"><b>Headless debugger command:</b> <span class="mono">$(ConvertTo-NYHtml ([string]$s.command))</span>. This cdb/MEX phase has no WinDbg MCP or DumpViewer ThreadDetails dependency. A lock payload TID is reported as nominal until independent stack/object evidence validates the actual holder.</div>
<div class="cards spinlock-sweep-metrics">
<div class="card"><b>Total dump threads</b>$(ConvertTo-NYHtml ([string]$s.totalThreads))</div>
<div class="card"><b>Spinlock stacks</b>$(ConvertTo-NYHtml ([string]$s.spinlockThreadCount))</div>
<div class="card"><b>Acquire/backoff candidates</b>$(ConvertTo-NYHtml ([string]$s.waiterCandidateThreadCount))</div>
<div class="card"><b>Unique lock addresses</b>$(ConvertTo-NYHtml ([string]$s.uniqueLockCount))</div>
</div>
<div class="note"><b>Detailed analysis:</b> <a href="$(ConvertTo-NYHtml ([string]$s.report))">Open the complete Gate C Spinlock owner sweep report &rarr;</a> · <a href="$(ConvertTo-NYHtml ([string]$s.json))">Structured JSON evidence</a></div>
<table><thead><tr><th>Lock</th><th>Raw qword</th><th>Waiter debugger IDs</th><th>Nominal TID / resolved debugger ID</th><th>Owner-stack compatibility</th><th>Actual-holder status</th><th>Parent chain coherent</th></tr></thead><tbody>$lockRows</tbody></table>
<!-- /SPINLOCK-OWNER-SWEEP-SUMMARY -->
"@
    } else {
        $failureLink=if([string]$s.failureEvidence){"<a href='$(ConvertTo-NYHtml ([string]$s.failureEvidence))'>Open failure evidence</a>"}else{'Failure evidence path was unavailable.'}
        $spinHtml=@"
<!-- SPINLOCK-OWNER-SWEEP-SUMMARY -->
<h3>Gate C · Spinlock Thread and Nominal Owner Sweep</h3>
<div class="note"><b>Optional extension unavailable with evidence.</b> The pre-existing Scheduler/non-yield analysis and final root-cause report are unaffected. $(ConvertTo-NYHtml ([string]$s.error))<br>$failureLink</div>
<!-- /SPINLOCK-OWNER-SWEEP-SUMMARY -->
"@
    }
    }
    return @"
<!-- NON-YIELD-STRUCTURED-SUMMARY -->
<h3>$(ConvertTo-NYHtml $Heading)</h3>
<div class="note"><b>Machine-generated route handoff:</b> generated from <span class="mono">$(ConvertTo-NYHtml ([string]$f.caseId))_non_yield_findings.json</span> by the canonical Gate C executor. The tables below distinguish callback thread, offending thread, current stack, copied stack, and DScript/native evidence.</div>
<h4>Incident identity and SchedulerMonitor event</h4>
<table><thead><tr><th>Field</th><th>Value</th><th>Interpretation</th></tr></thead><tbody>
<tr><td>SchedulerMonitor event</td><td class="mono">$(ConvertTo-NYHtml ([string]$event.event))</td><td>Direct non-yield route predicate.</td></tr>
<tr><td>Event time</td><td class="mono">$(ConvertTo-NYHtml ([string]$event.time))</td><td>Retained ring-buffer incident time.</td></tr>
<tr><td>Callback debugger thread</td><td class="mono">~$(ConvertTo-NYHtml ([string]$f.callback.debuggerThread)) · frame $(ConvertTo-NYHtml ([string]$f.callback.frame))</td><td>SchedulerMonitor callback thread used to recover <span class="mono">pTrack</span>; not the offender.</td></tr>
<tr><td>Offending debugger / Windows thread</td><td class="mono">~$(ConvertTo-NYHtml ([string]$f.execution.debuggerThread)) / $(ConvertTo-NYHtml ([string]$f.execution.windowsTid))</td><td>The worker that failed to yield.</td></tr>
<tr><td>Scheduler / SPID</td><td class="mono">$(ConvertTo-NYHtml ([string]$f.execution.schedulerId)) / $(ConvertTo-NYHtml ([string]$f.execution.spid))</td><td>SQLOS scheduler and SQL session identity.</td></tr>
<tr><td>Worker / task / pTrack</td><td class="mono">$(ConvertTo-NYHtml ([string]$f.execution.worker)) / $(ConvertTo-NYHtml ([string]$f.execution.task)) / $(ConvertTo-NYHtml ([string]$f.callback.pTrack))</td><td>Native identity chain recovered from callback locals.</td></tr>
<tr><td>SQL / system idle / worker utilization</td><td>$(ConvertTo-NYHtml (Get-NYDisplayNumber $event.processUtilization))% / $(ConvertTo-NYHtml (Get-NYDisplayNumber $event.systemIdle))% / $(ConvertTo-NYHtml (Get-NYDisplayNumber $event.workerUtilization))%</td><td>Does not support host-wide CPU saturation.</td></tr>
</tbody></table>
<h4>DScript and native timing cross-check</h4>
<table><thead><tr><th>Surface</th><th>Offender / passes</th><th>Wall</th><th>Kernel</th><th>User</th><th>Status</th></tr></thead><tbody>
<tr><td class="mono">non_yield_analysis.js</td><td class="mono">~$(ConvertTo-NYHtml ([string]$f.dscript.offender)) / $(ConvertTo-NYHtml ([string]$f.dscript.passes))</td><td>$(ConvertTo-NYHtml ([string]$f.dscript.wallMs)) ms</td><td>$(ConvertTo-NYHtml ([string]$f.dscript.kernelMs)) ms</td><td>$(ConvertTo-NYHtml ([string]$f.dscript.userMs)) ms</td><td>$(ConvertTo-NYHtml $dscriptStatus)</td></tr>
<tr><td>Native <span class="mono">SchedulerMonitor::Track</span></td><td class="mono">~$(ConvertTo-NYHtml ([string]$f.execution.debuggerThread)) / $(ConvertTo-NYHtml ([string]$f.callback.pass)) (diagnosed $(ConvertTo-NYHtml ([string]$f.callback.diagnosedPass)))</td><td>$(ConvertTo-NYHtml ([string]$f.timing.wallMs)) ms</td><td>$(ConvertTo-NYHtml ([string]$f.timing.kernelMs)) ms</td><td>$(ConvertTo-NYHtml ([string]$f.timing.userMs)) ms</td><td>native fallback completed</td></tr>
</tbody></table>
<h4>Current stack versus first-detected copied stack</h4>
<div class="note"><b>Copied stack:</b> SQLOS snapshots the offending context into <span class="mono">g_copiedStackInfo.threadContext</span> when SchedulerMonitor first detects the stall. The current stack is captured later at dump time. Same core path: <b>$(ConvertTo-NYHtml $same)</b>.</div>
<div class="grid"><div class="card span-6"><h4>Current stack at dump time</h4><pre>$(ConvertTo-NYHtml $currentText)</pre></div><div class="card span-6"><h4>First-detected copied stack</h4><pre>$(ConvertTo-NYHtml $copiedText)</pre></div></div>
<h4>Task and statement correlation</h4>
<table><tbody><tr><th>SPID</th><td class="mono">$(ConvertTo-NYHtml ([string]$f.execution.spid))</td></tr><tr><th>Scheduler</th><td class="mono">$(ConvertTo-NYHtml ([string]$f.execution.schedulerId))</td></tr><tr><th>Decoded SQL</th><td><pre>$(ConvertTo-NYHtml $sql)</pre></td></tr></tbody></table>
$spinHtml
<div class="note"><b>Raw evidence:</b> <a href="$(ConvertTo-NYHtml ([string]$f.dscript.raw))">non_yield_analysis.js</a> · <a href="$(ConvertTo-NYHtml ([string]$evidence.native))">native pTrack/current/copied-stack</a> · <a href="$(ConvertTo-NYHtml ([string]$evidence.frameDiscovery))">callback frame discovery</a> · <a href="$(ConvertTo-NYHtml ([string]$evidence.schedulerRing))">SchedulerMonitor ring</a> · <a href="$(ConvertTo-NYHtml ([string]$evidence.taskFields))">task.js fields</a> · <a href="$(ConvertTo-NYHtml ([string]$evidence.tsql))">tsqlstack fields</a>.</div>
<!-- /NON-YIELD-STRUCTURED-SUMMARY -->
"@
}
