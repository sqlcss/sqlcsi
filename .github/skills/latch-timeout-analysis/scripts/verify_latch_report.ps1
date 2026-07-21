# verify_latch_report.ps1 - hard gate for latch timeout final report completion.
#
# This verifier is intentionally separate from dump-overall verification. Dump-overall
# proves the global snapshot exists; this script proves the final latch report includes
# the latch-native dump evidence and synthesized root-cause mapping when a dump exists.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CaseId,
    [Parameter(Mandatory=$true)][string]$ReportDir,
    [Parameter(Mandatory=$true)][string]$ReportPath,
    [string]$Ledger,
    [switch]$RequireDumpEvidence
)

$ErrorActionPreference = 'Stop'

function Add-Failure([System.Collections.Generic.List[string]]$Failures, [string]$Message) {
    [void]$Failures.Add($Message)
}

function Resolve-ReportPath([string]$Path) {
    if (-not $Path) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $ReportDir $Path)
}

function Test-NonEmptyFile([string]$Path) {
    $p = Resolve-ReportPath $Path
    return ($p -and (Test-Path -LiteralPath $p -PathType Leaf) -and ((Get-Item -LiteralPath $p).Length -gt 0))
}

function Test-AnyPattern([string]$Content, [string[]]$Patterns) {
    foreach ($pattern in $Patterns) {
        if ($Content -match $pattern) { return $true }
    }
    return $false
}

function Test-RequiredPatternGroup([string]$Content, [hashtable[]]$Groups, [System.Collections.Generic.List[string]]$Failures, [string]$Prefix) {
    foreach ($group in $Groups) {
        if (-not (Test-AnyPattern $Content $group.patterns)) {
            Add-Failure $Failures "${Prefix}: missing required content: $($group.name)"
        }
    }
}

$failures = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $ReportDir -PathType Container)) {
    Add-Failure $failures "ReportDir missing: $ReportDir"
}

if (-not (Test-NonEmptyFile $ReportPath)) {
    Add-Failure $failures "Final report missing or empty: $(Resolve-ReportPath $ReportPath)"
}

$content = ''
if (Test-NonEmptyFile $ReportPath) {
    $content = Get-Content -LiteralPath (Resolve-ReportPath $ReportPath) -Raw -Encoding UTF8
}

$requiredReportGroups = @(
    @{ name = 'ERRORLOG latch evidence section'; patterns = @('ERRORLOG', 'ERRORLOG\s+证据') },
    @{ name = 'ERRORLOG latch class'; patterns = @('latch\s+class', 'Latch\s+class', 'latch\s+类型', 'ACCESS_METHODS_[A-Z0-9_]+') },
    @{ name = 'ERRORLOG latch id/address'; patterns = @('latch\s+id', 'latch\s+address', 'latch\s+地址', 'id\s+0x[0-9a-fA-F`]+', '0x[0-9a-fA-F`]+') },
    @{ name = 'ERRORLOG waiters'; patterns = @('waiter', 'waiting\s+task', 'waiters', '等待任务', '等待线程') },
    @{ name = 'ERRORLOG owner task'; patterns = @('owner\s+task', 'owning\s+task', 'owner', '持有任务', '持有者') },
    @{ name = 'ERRORLOG SPID'; patterns = @('\bSPID\b', '\bspid\d+\b', '会话\s*ID') },
    @{ name = 'ERRORLOG input SQL'; patterns = @('Input\s+Buffer', 'input\s+sql', 'blocking\s+sql', 'SQL\s+text', '输入缓冲', 'SQL\s+文本') },
    @{ name = 'ERRORLOG timeout timeline'; patterns = @('timeline', 'timeout\s+timeline', 'first\s+timeout', 'last\s+timeout', 'latch\s+start', '时间线', '窗口') },
    @{ name = 'XEvent evidence section'; patterns = @('XEvent', 'XEvent\s+证据') },
    @{ name = 'XEvent CPU context'; patterns = @('\bCPU\b', 'scheduler\s+monitor', 'sql_cpu', 'CPU\s+压力') },
    @{ name = 'XEvent scheduler context'; patterns = @('scheduler', '调度器') },
    @{ name = 'XEvent waits context'; patterns = @('\bwaits?\b', 'LATCH_EX', 'RESOURCE_SEMAPHORE', '等待') },
    @{ name = 'XEvent query processing context'; patterns = @('QUERY_PROCESSING', 'query\s+processing', '查询处理') },
    @{ name = 'XEvent memory context'; patterns = @('memory', 'RESOURCE_SEMAPHORE', '内存') },
    @{ name = 'XEvent IO context'; patterns = @('\bI/O\b', '\bIO\b', 'PAGEIOLATCH', 'storage', '存储') },
    @{ name = 'XEvent HADR context'; patterns = @('HADR', 'AlwaysOn', 'AG\s+events?', '可用性组') },
    @{ name = 'XEvent system-pressure verdict'; patterns = @('system\s+pressure', 'pressure\s+verdict', 'no\s+system-level\s+pressure', '系统级压力', '压力判断') },
    @{ name = 'dump-overall evidence section'; patterns = @('Dump\s+overall', 'dump-overall', 'Dump\s+证据', 'Verifier') },
    @{ name = 'dump-overall all threads'; patterns = @('all\s+threads', 'ThreadDetails', 'UniqueStacks', '线程清单', '所有线程') },
    @{ name = 'dump-overall task state'; patterns = @('task\s+state', 'Tasks\.Enumerate', 'ActiveTasks', 'task\.js', '任务状态') },
    @{ name = 'dump-overall SQL execution context'; patterns = @('process_commands', 'task\.js', 'tsqlstack', 'T-SQL', '执行上下文') },
    @{ name = 'dump-overall ring buffers'; patterns = @('ring\s+buffers?', 'SOSRingBuffers', '环形缓冲') },
    @{ name = 'synthesized conclusion section'; patterns = @('Synthesized\s+conclusion', 'Confirmed\s+Root\s+Cause', 'Evidence\s+Mapping', '结论摘要', '证据映射') },
    @{ name = 'synthesized root cause'; patterns = @('root\s+cause', 'Confirmed\s+Root\s+Cause', '根因') },
    @{ name = 'synthesized most likely mechanism'; patterns = @('most\s+likely\s+mechanism', 'mechanism', '最可能机制', '机制') },
    @{ name = 'synthesized confidence'; patterns = @('confidence', 'High', 'Medium', 'Low', '置信度') },
    @{ name = 'synthesized evidence mapping'; patterns = @('Evidence\s+Mapping', '证据映射') }
)

Test-RequiredPatternGroup $content $requiredReportGroups $failures 'final_report'

if ($RequireDumpEvidence) {
    $dumpSections = @(
        @{ name = 'latch-native dump evidence'; patterns = @('Latch-Native', 'latch-native', 'Latch Native', 'latch native', 'Latch\s+原生', 'native\s+dump') },
        @{ name = 'owner/waiter map'; patterns = @('owner.?waiter', 'Owner.?Waiter', 'owner / waiter', 'owner/waiter', 'Owner / Waiter', 'waiter map', 'Waiter map', 'Owner.*Waiter', 'Owner.*Waiter', 'owner.*waiter') },
        @{ name = 'm_count decode'; patterns = @('m_count', 'm-count') },
        @{ name = 'owner real stack'; patterns = @('owner real stack', 'Owner real stack', 'owner\s+真实\s+stack', 'owner\s+stack', 'Owner\s+stack') },
        @{ name = 'self-blocking or chain classification'; patterns = @('self-blocking', 'self blocking', 'cross-session', 'cross session', 'chain', '自阻塞', '阻塞链') },
        @{ name = 'minidump limitations'; patterns = @('minidump', 'filtered minidump', 'partial', '限制') },
        @{ name = 'evidence mapping'; patterns = @('Evidence\s+Mapping', '证据映射') }
    )

    Test-RequiredPatternGroup $content $dumpSections $failures 'final_report'
}

if ($Ledger) {
    if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) {
        Add-Failure $failures "Ledger missing: $Ledger"
    } else {
        try {
            $ledgerObject = Get-Content -LiteralPath $Ledger -Raw -Encoding UTF8 | ConvertFrom-Json
            $workflowSteps = @(
                'errorlog_latch_context',
                'xevent_environment_context',
                'dump_overall_snapshot',
                'latch_native_dump_deep_dive',
                'synthesized_conclusion'
            )
            $requiredSteps = $ledgerObject.requiredSteps
            if (-not $requiredSteps) {
                Add-Failure $failures 'ledger: requiredSteps missing'
            } else {
                foreach ($stepName in $workflowSteps) {
                    if (-not ($requiredSteps.PSObject.Properties.Name -contains $stepName)) {
                        Add-Failure $failures "ledger: requiredSteps.$stepName missing"
                    } else {
                        $step = $requiredSteps.$stepName
                        if ([string]$step.status -ne 'done') {
                            Add-Failure $failures "ledger: requiredSteps.$stepName status must be done, got '$($step.status)'"
                        }
                    }
                }
            }

            if ($RequireDumpEvidence) {
                $requiredSteps = $ledgerObject.requiredSteps
                if (-not $requiredSteps) {
                    Add-Failure $failures 'ledger: requiredSteps missing'
                } elseif (-not ($requiredSteps.PSObject.Properties.Name -contains 'latch_native_dump_deep_dive')) {
                    Add-Failure $failures 'ledger: requiredSteps.latch_native_dump_deep_dive missing'
                } else {
                    $nativeStep = $requiredSteps.latch_native_dump_deep_dive
                    if ([string]$nativeStep.status -ne 'done') {
                        Add-Failure $failures "ledger: latch_native_dump_deep_dive status must be done, got '$($nativeStep.status)'"
                    }
                    $artifacts = @()
                    if ($nativeStep.PSObject.Properties.Name -contains 'artifacts') { $artifacts += @($nativeStep.artifacts | ForEach-Object { [string]$_ }) }
                    if ($nativeStep.PSObject.Properties.Name -contains 'evidence') { $artifacts += @($nativeStep.evidence | ForEach-Object { [string]$_ }) }
                    if ($artifacts.Count -eq 0) {
                        Add-Failure $failures 'ledger: latch_native_dump_deep_dive requires artifacts[] or evidence[]'
                    } else {
                        foreach ($artifact in $artifacts) {
                            if (-not (Test-NonEmptyFile $artifact)) {
                                Add-Failure $failures "ledger: latch native artifact missing or empty: $(Resolve-ReportPath $artifact)"
                            }
                        }
                    }
                }
            }
        } catch {
            Add-Failure $failures "Ledger parse failed: $_"
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host "[verify_latch_report] FAIL: $CaseId" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host "[verify_latch_report] PASS: $CaseId" -ForegroundColor Green
exit 0