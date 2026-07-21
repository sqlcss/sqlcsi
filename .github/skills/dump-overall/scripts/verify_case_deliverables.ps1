# verify_case_deliverables.ps1 - hard gate for dump-overall workflow completion.
#
# This script is intentionally independent of gen_overall_report.ps1: it catches both
# an incomplete report and a report that was never generated.
#
# Stages:
#   PreReport  - verifies required workflow steps/artifacts before writing final report.
#   Completion - verifies final deliverables before the agent may call the task complete.
#
# Optional ledger schema:
# {
#   "requiredSteps": {
#     "P3_dscript_exec": { "required": true, "status": "done", "artifacts": ["case_task_all.txt"] },
#     "step2_tasks": { "required": true, "status": "unavailable-with-evidence", "evidence": ["case_tasks_output.txt"] }
#   },
#   "requiredDeliverables": {
#     "overall_html": { "required": true, "stage": "Completion", "status": "done", "path": "case_overall_report.html" }
#   }
# }
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CaseId,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [ValidateSet('PreReport','Completion')][string]$Stage = 'Completion',
    [string]$Ledger,
    [switch]$RequireOverallAlias,
    [switch]$RequireThreadCategories,
    [switch]$RequireSqlExec,
    [switch]$RequireSchedulerInventory
)

$ErrorActionPreference = 'Stop'

function Resolve-CasePath([string]$Path) {
    if (-not $Path) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $OutDir $Path)
}

function Test-NonEmptyFile([string]$Path) {
    $p = Resolve-CasePath $Path
    return ($p -and (Test-Path -LiteralPath $p -PathType Leaf) -and ((Get-Item -LiteralPath $p).Length -gt 0))
}

function Add-Failure([System.Collections.Generic.List[string]]$Failures, [string]$Message) {
    [void]$Failures.Add($Message)
}

function Test-FileContains([string]$Path, [string]$Pattern) {
    $p = Resolve-CasePath $Path
    if (-not (Test-NonEmptyFile $Path)) { return $false }
    return [bool](Select-String -LiteralPath $p -Pattern $Pattern -SimpleMatch -Quiet)
}

$failures = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
    Add-Failure $failures "OutDir missing: $OutDir"
} else {
    if ($Stage -eq 'Completion') {
        $defaultCompletion = @(
            @{ name = 'overall_html'; path = "${CaseId}_overall_report.html" }
        )
        if ($RequireOverallAlias) {
            $defaultCompletion += @{ name = 'overall_alias'; path = 'overall.html' }
        }
        foreach ($item in $defaultCompletion) {
            if (-not (Test-NonEmptyFile $item.path)) {
                Add-Failure $failures ("{0}: required file missing or empty: {1}" -f $item.name, (Resolve-CasePath $item.path))
            }
        }

        $threadCategorySource = Test-NonEmptyFile 'thread_categories.json'
        $threadCategoryRequired = $RequireThreadCategories -or $threadCategorySource
        if ($threadCategoryRequired) {
            $categoryReport = "${CaseId}_thread_categories.html"
            if (-not (Test-NonEmptyFile $categoryReport)) {
                Add-Failure $failures ("thread_categories_html: required file missing or empty: {0}" -f (Resolve-CasePath $categoryReport))
            } else {
                foreach ($anchor in @('cat-iocp','cat-lat','cat-mon','cat-par')) {
                    if (-not (Test-FileContains $categoryReport "id='$anchor'")) {
                        Add-Failure $failures "thread_categories_html: missing anchor $anchor in $(Resolve-CasePath $categoryReport)"
                    }
                }
                if (-not (Test-FileContains $categoryReport '<details id=')) {
                    Add-Failure $failures "thread_categories_html: no expandable stack detail blocks found in $(Resolve-CasePath $categoryReport)"
                }
            }
            $overall = "${CaseId}_overall_report.html"
            if (-not (Test-FileContains $overall $categoryReport)) {
                Add-Failure $failures "overall_html: missing link to $categoryReport"
            }
        }

        $sqlExecSource = (Test-NonEmptyFile 'task_fields.json') -or (Test-NonEmptyFile "${CaseId}_tsqlstack.json")
        $sqlExecRequired = $RequireSqlExec -or $sqlExecSource
        if ($sqlExecRequired) {
            $taskAll = "${CaseId}_task_all.txt"
            $tsqlLog = "${CaseId}_tsqlstack.txt"
            $tsqlJson = "${CaseId}_tsqlstack.json"
            $manifest = "${CaseId}_sql_exec_manifest.json"
            $sqlReport = "${CaseId}_sql_exec_thread.html"
            foreach ($item in @($taskAll,$tsqlLog,$tsqlJson,$manifest,$sqlReport)) {
                if (-not (Test-NonEmptyFile $item)) {
                    Add-Failure $failures ("sql_exec: required file missing or empty: {0}" -f (Resolve-CasePath $item))
                }
            }
            if ((Test-NonEmptyFile $taskAll) -and -not (Test-FileContains $taskAll '##### END TASK.JS SWEEP #####')) {
                Add-Failure $failures "sql_exec: task_all log missing END TASK.JS SWEEP marker"
            }
            if ((Test-NonEmptyFile $tsqlLog) -and -not (Test-FileContains $tsqlLog '##### END TASK.JS SWEEP #####')) {
                Add-Failure $failures "sql_exec: tsqlstack log missing END TASK.JS SWEEP marker"
            }
            if (Test-NonEmptyFile $tsqlJson) {
                try {
                    $tj = Get-Content -LiteralPath (Resolve-CasePath $tsqlJson) -Raw -Encoding UTF8 | ConvertFrom-Json
                    if (@($tj.threads).Count -eq 0) { Add-Failure $failures "sql_exec: tsqlstack json has zero threads" }
                } catch {
                    Add-Failure $failures "sql_exec: tsqlstack json parse failed: $_"
                }
            }
            if (Test-NonEmptyFile $sqlReport) {
                foreach ($needle in @('执行语句主线程','并行子线程','主线程 / 子线程运行时状态明细','tsqlstack 原始输出')) {
                    if (-not (Test-FileContains $sqlReport $needle)) {
                        Add-Failure $failures "sql_exec_html: missing required content '$needle' in $(Resolve-CasePath $sqlReport)"
                    }
                }
            }
            $overall = "${CaseId}_overall_report.html"
            if (-not (Test-FileContains $overall $sqlReport)) {
                Add-Failure $failures "overall_html: missing link to $sqlReport"
            }
        }

        $usReportSource = "${CaseId}_us.txt"
        $tasksUnavailable = (Test-FileContains "${CaseId}_tasks_output.txt" '0 rows') -or (Test-FileContains "${CaseId}_tasks_output.txt" '0 row') -or (Test-FileContains "${CaseId}_tasks_direct.txt" '0 rows') -or (Test-FileContains "${CaseId}_tasks_direct.txt" '0 row')
        $execFallbackRulesPresent = (Test-NonEmptyFile $usReportSource) -and ((Test-FileContains $usReportSource 'sqllang!process_commands') -or (Test-FileContains $usReportSource 'sqllang!process_request') -or (Test-FileContains $usReportSource 'CSQLSource::Execute') -or (Test-FileContains $usReportSource 'sqlmin!SubprocEntrypoint'))
        if ($tasksUnavailable -and $execFallbackRulesPresent) {
            $threadSpec = "${CaseId}_exec_sweep_threads.txt"
            if (-not (Test-NonEmptyFile $threadSpec)) {
                Add-Failure $failures ("exec_sweep_fallback: Tasks.Enumerate unavailable but fallback thread spec is missing or empty: {0}" -f (Resolve-CasePath $threadSpec))
            }
            foreach ($item in @("${CaseId}_task_all.txt", 'task_fields.json', "${CaseId}_tsqlstack.txt", "${CaseId}_tsqlstack.json", "${CaseId}_sql_exec_manifest.json", "${CaseId}_sql_exec_thread.html")) {
                if (-not (Test-NonEmptyFile $item)) {
                    Add-Failure $failures ("exec_sweep_fallback: required task/tsqlstack artifact missing or empty: {0}" -f (Resolve-CasePath $item))
                }
            }
        }

        $schedulerSource = (Test-NonEmptyFile "${CaseId}_sys.schedulers.txt") -or (Test-NonEmptyFile "${CaseId}_Schedulers.Enumerate.txt")
        $schedulerRequired = $RequireSchedulerInventory -or $schedulerSource
        if ($schedulerRequired) {
            $schedulerFile = if (Test-NonEmptyFile "${CaseId}_Schedulers.Enumerate.txt") { "${CaseId}_Schedulers.Enumerate.txt" } else { "${CaseId}_sys.schedulers.txt" }
            if (-not (Test-NonEmptyFile $schedulerFile)) {
                Add-Failure $failures ("scheduler_inventory: required file missing or empty: {0}" -f (Resolve-CasePath $schedulerFile))
            } elseif ($schedulerFile -like '*sys.schedulers.txt' -and -not (Test-FileContains $schedulerFile 'END SYS.SCHEDULERS')) {
                Add-Failure $failures "scheduler_inventory: sys.schedulers log missing END SYS.SCHEDULERS marker"
            }
        }

        $directLogs = @(Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "${CaseId}_*direct*.txt" -or $_.Name -eq "${CaseId}_phase1_direct.txt" })
        $directRingLog = $false
        foreach ($log in $directLogs) {
            if (Select-String -LiteralPath $log.FullName -Pattern '== MARKER_SOSRingBuffers.' -SimpleMatch -Quiet) {
                $directRingLog = $true
                break
            }
        }
        $ringSubreports = @(Get-ChildItem -LiteralPath $OutDir -File -Filter "${CaseId}_sub_SOSRingBuffers*.html" -ErrorAction SilentlyContinue)
        $ringReportsPresent = $directRingLog -or ($ringSubreports.Count -gt 0)
        if ($ringReportsPresent) {
            $txtDir = Join-Path $OutDir 'txt_detail'
            $splitRingFiles = @()
            if (Test-Path -LiteralPath $txtDir -PathType Container) {
                $splitRingFiles = @(Get-ChildItem -LiteralPath $txtDir -File -Filter "${CaseId}_SOSRingBuffers.*.txt" -ErrorAction SilentlyContinue)
            }
            if ($directRingLog -and $splitRingFiles.Count -eq 0) {
                Add-Failure $failures "ringbuf_reports: direct mirror log has SOSRingBuffers markers but no split txt_detail ring-buffer files"
            }
            $overall = "${CaseId}_overall_report.html"
            foreach ($needle in @('以下 9 条','dump 前 top 20','值得注意的记录','打开完整子报告')) {
                if (-not (Test-FileContains $overall $needle)) {
                    Add-Failure $failures "ringbuf_reports: overall report missing parsed ring-buffer content '$needle'; raw direct_mirror/html link alone is incomplete"
                }
            }
        }
    }
}

$ledgerObject = $null
if ($Ledger) {
    if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) {
        Add-Failure $failures "Ledger missing: $Ledger"
    } else {
        try {
            $ledgerObject = Get-Content -LiteralPath $Ledger -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Add-Failure $failures "Ledger parse failed: $_"
        }
    }
}

$okStatuses = @('done','unavailable-with-evidence','skipped-by-user')

if ($ledgerObject) {
    foreach ($groupName in @('requiredSteps','requiredDeliverables')) {
        if (-not ($ledgerObject.PSObject.Properties.Name -contains $groupName)) { continue }
        $group = $ledgerObject.$groupName
        foreach ($prop in $group.PSObject.Properties) {
            $name = $prop.Name
            $item = $prop.Value
            if (($item.PSObject.Properties.Name -contains 'required') -and -not [bool]$item.required) { continue }

            $defaultStage = if ($groupName -eq 'requiredSteps') { 'PreReport' } else { 'Completion' }
            $itemStage = if ($item.PSObject.Properties.Name -contains 'stage') { [string]$item.stage } else { $defaultStage }
            if ($Stage -eq 'PreReport' -and $itemStage -eq 'Completion') { continue }

            $status = if ($item.PSObject.Properties.Name -contains 'status') { [string]$item.status } else { 'missing' }
            if ($okStatuses -notcontains $status) {
                Add-Failure $failures ("{0}.{1}: required item status is '{2}'" -f $groupName, $name, $status)
                continue
            }

            if ($status -eq 'unavailable-with-evidence') {
                $evidence = @()
                if ($item.PSObject.Properties.Name -contains 'evidence') { $evidence = @($item.evidence) }
                if ($evidence.Count -eq 0) {
                    Add-Failure $failures ("{0}.{1}: unavailable-with-evidence requires evidence[]" -f $groupName, $name)
                } else {
                    foreach ($path in $evidence) {
                        if (-not (Test-NonEmptyFile ([string]$path))) {
                            Add-Failure $failures ("{0}.{1}: evidence missing or empty: {2}" -f $groupName, $name, (Resolve-CasePath ([string]$path)))
                        }
                    }
                }
                continue
            }

            $paths = @()
            if ($item.PSObject.Properties.Name -contains 'path') { $paths += [string]$item.path }
            if ($item.PSObject.Properties.Name -contains 'artifacts') { $paths += @($item.artifacts | ForEach-Object { [string]$_ }) }
            foreach ($path in $paths) {
                if (-not (Test-NonEmptyFile $path)) {
                    Add-Failure $failures ("{0}.{1}: artifact missing or empty: {2}" -f $groupName, $name, (Resolve-CasePath $path))
                }
            }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host "[verify_case_deliverables] FAIL ($Stage)" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host "[verify_case_deliverables] PASS ($Stage): $CaseId" -ForegroundColor Green
exit 0