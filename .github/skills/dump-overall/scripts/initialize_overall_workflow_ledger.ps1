# initialize_overall_workflow_ledger.ps1
# Create the fixed Gate A ledger with every item missing. Call at run start.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Out = '',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $OutDir 'workflow_ledger.json' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
if ((Test-Path -LiteralPath $Out) -and -not $Force) { throw "ledger already exists; use -Force to replace: $Out" }

$ringExpr = @(
    'ProcessSummary_Enumerate',
    'SOSRingBuffers_EnumerateMemoryBrokerRingRecords',
    'SOSRingBuffers_EnumerateBlockedProcessReportRingBufferRecords',
    'SOSRingBuffers_EnumerateMemoryBrokerClerkRingRecords',
    'SOSRingBuffers_EnumerateSchedulerMonitorRecords',
    'SOSRingBuffers_EnumerateExceptionRingRecords',
    'SOSRingBuffers_EnumerateSchedulerRingRecords',
    'SOSRingBuffers_EnumerateHadrArPubishEventsRecords',
    'SOSRingBuffers_EnumerateHadrArSignalStateRecords'
)
$ringReports = @($ringExpr | ForEach-Object { "${CaseId}_sub_$_.html" })
$ledger = [ordered]@{
    caseId = $CaseId
    initializedAt = (Get-Date).ToString('o')
    allowedTerminalStatuses = @('done','unavailable-with-evidence','skipped-by-user')
    requiredSteps = [ordered]@{
        dumpviewer_mode_gate = [ordered]@{required=$true;status='missing';artifacts=@('dumpviewer_out/main.html')}
        step1_os_threads = [ordered]@{required=$true;status='missing';artifacts=@("${CaseId}_us.txt",'us_states.json',"${CaseId}_us.html",'thread_categories.json',"${CaseId}_thread_categories.html")}
        step2_tasks = [ordered]@{required=$true;status='missing';artifacts=@("${CaseId}_tasks_output.txt","${CaseId}_tasks_stats.json","${CaseId}_tasks.html","${CaseId}_tbl2_state_summary.html","${CaseId}_tbl3_scheduler_pivot.html")}
        step3_dscript_exec = [ordered]@{required=$true;status='missing';artifacts=@("${CaseId}_exec_sweep_threads.json","${CaseId}_task_all.txt","${CaseId}_task_all.summary.json",'task_fields.json',"${CaseId}_tsqlstack.txt","${CaseId}_tsqlstack.json","${CaseId}_tsqlstack.summary.json","${CaseId}_sql_exec_manifest.json","${CaseId}_sql_exec_thread.html")}
        step4_schedulers = [ordered]@{required=$true;status='missing';artifacts=@("${CaseId}_sys.schedulers.txt")}
        step5_memory_brokers = [ordered]@{required=$true;status='missing';artifacts=@("${CaseId}_memory_brokers.txt")}
        step6_latch_pages = [ordered]@{required=$true;status='missing';artifacts=@("${CaseId}_dump_latch_contended_pages.txt")}
        exception_context = [ordered]@{required=$true;status='missing';artifacts=@("${CaseId}_exception.html")}
        nine_ring_surfaces = [ordered]@{required=$true;status='missing';artifacts=@(
            "txt_detail/${CaseId}_ProcessSummary.Enumerate.txt",
            "txt_detail/${CaseId}_SOSRingBuffers.EnumerateMemoryBrokerRingRecords.txt",
            "txt_detail/${CaseId}_SOSRingBuffers.EnumerateBlockedProcessReportRingBufferRecords.txt",
            "txt_detail/${CaseId}_SOSRingBuffers.EnumerateMemoryBrokerClerkRingRecords.txt",
            "txt_detail/${CaseId}_SOSRingBuffers.EnumerateSchedulerMonitorRecords.txt",
            "txt_detail/${CaseId}_SOSRingBuffers.EnumerateExceptionRingRecords.txt",
            "txt_detail/${CaseId}_SOSRingBuffers.EnumerateSchedulerRingRecords.txt",
            "txt_detail/${CaseId}_SOSRingBuffers.EnumerateHadrArPubishEventsRecords.txt",
            "txt_detail/${CaseId}_SOSRingBuffers.EnumerateHadrArSignalStateRecords.txt"
        )}
        overall_manifest = [ordered]@{required=$true;status='missing';artifacts=@("${CaseId}_overall_manifest.json")}
    }
    requiredDeliverables = [ordered]@{
        overall_html = [ordered]@{required=$true;stage='Completion';status='missing';path="${CaseId}_overall_report.html"}
        thread_details = [ordered]@{required=$true;stage='Completion';status='missing';artifacts=@("${CaseId}_us.html","${CaseId}_thread_categories.html")}
        task_details = [ordered]@{required=$true;stage='Completion';status='missing';path="${CaseId}_tasks.html"}
        sql_exec_details = [ordered]@{required=$true;stage='Completion';status='missing';path="${CaseId}_sql_exec_thread.html"}
        exception_details = [ordered]@{required=$true;stage='Completion';status='missing';path="${CaseId}_exception.html"}
        ring_subreports = [ordered]@{required=$true;stage='Completion';status='missing';artifacts=$ringReports}
    }
}
[System.IO.File]::WriteAllText($Out, ($ledger | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
Write-Host "[initialize_overall_workflow_ledger] initialized missing-state ledger -> $Out"
exit 0
