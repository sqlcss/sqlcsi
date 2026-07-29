# verify_non_yield_report.ps1
# Completion gate for synthesized ERRORLOG + XEvent non-yield reports.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$ReportDir,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$Ledger = '',
    [switch]$RequireXEventEvidence
)
$ErrorActionPreference='Stop'
$failures=[Collections.Generic.List[string]]::new()
function Resolve-Artifact([string]$Path) {
    if (-not $Path) { return $null }
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $ReportDir $Path
}
function Need-File([string]$Path,[string]$Label) {
    $p = Resolve-Artifact $Path
    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf) -or (Get-Item -LiteralPath $p).Length -eq 0) {
        $failures.Add("${Label} missing/empty: $p")
    }
}
function Has-Any([string]$Content,[string[]]$Patterns) {
    foreach ($pattern in $Patterns) { if ($Content -match $pattern) { return $true } }
    return $false
}
function Need-Group([string]$Content,[string]$Name,[string[]]$Patterns) {
    if (-not (Has-Any $Content $Patterns)) { $failures.Add("final_report missing: $Name") }
}

if(-not(Test-Path -LiteralPath $ReportDir -PathType Container)){$failures.Add("ReportDir missing: $ReportDir")}
Need-File $ReportPath 'final report'
$content='';$resolvedReport=Resolve-Artifact $ReportPath
if(Test-Path -LiteralPath $resolvedReport -PathType Leaf){$content=Get-Content -LiteralPath $resolvedReport -Raw -Encoding UTF8}

$baseGroups=@(
    @('ERRORLOG evidence section',@('ERRORLOG','错误日志')),
    @('incident type',@('non-yielding scheduler','non-yielding IOCP','resource monitor','stalled dispatcher','非让步调度器','不让步调度器')),
    @('incident timeline',@('timeline','estimated start','first sample','last sample','Interval','时间线','开始时间','采样')),
    @('offender identity',@('Scheduler\s*\d+','scheduler ID','OS TID','Windows TID','Worker\s*0x','调度器','工作线程')),
    @('CPU shape',@('worker CPU','CPU ratio','wait-dominated','cpu-active','Process Utilization','System Idle','CPU 形态','等待主导')),
    @('time-zone alignment',@('UTC','time zone','timezone','offset','时区','时差')),
    @('root-cause boundary',@('does not prove','unresolved','limitation','cannot identify','未证明','无法确认','限制')),
    @('synthesized conclusion',@('Synthesized Conclusion','Root Cause','Conclusion','综合结论','根因','结论')),
    @('confidence',@('confidence','High','Medium','Low','置信度')),
    @('evidence mapping',@('Evidence Mapping','证据映射'))
)
foreach($g in $baseGroups){Need-Group $content $g[0] $g[1]}

if($RequireXEventEvidence){
    $xeGroups=@(
        @('XEvent section',@('XEvent','XEL')),
        @('import-xevent provenance',@('import-xevent','XEvent import','XEL import','XEvent 导入','导入证据')),
        @('scheduler_monitor evidence',@('scheduler_monitor','xe\.scheduler','non_yielding_ring_buffer')),
        @('sp_server_diagnostics evidence',@('sp_server_diagnostics','QUERY_PROCESSING','RESOURCE','IO_SUBSYSTEM')),
        @('wait context',@('wait_info','Top waits','PAGEIOLATCH','WRITELOG','LATCH_','RESOURCE_SEMAPHORE','THREADPOOL','等待')),
        @('system-pressure verdict',@('system pressure','CPU starvation','host-wide','系统压力','CPU 饥饿','全局压力'))
    )
    foreach($g in $xeGroups){Need-Group $content $g[0] $g[1]}
}
if($Ledger){
    Need-File $Ledger 'workflow ledger'
    $ledgerPath=Resolve-Artifact $Ledger
    if(Test-Path -LiteralPath $ledgerPath -PathType Leaf){
        try{
            $doc=Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8|ConvertFrom-Json
            $required=@('errorlog_non_yield_context','synthesized_log_conclusion')
            if($RequireXEventEvidence){$required+=@('xevent_import','xevent_environment_context')}
            foreach($name in $required){
                if(-not($doc.requiredSteps.PSObject.Properties.Name-contains$name)){$failures.Add("ledger requiredSteps.$name missing");continue}
                $step=$doc.requiredSteps.$name
                if([string]$step.status-ne'done'){$failures.Add("ledger requiredSteps.$name must be done; got '$($step.status)'")}
                $artifacts=@();if($step.PSObject.Properties.Name-contains'artifacts'){$artifacts+=@($step.artifacts)};if($step.PSObject.Properties.Name-contains'evidence'){$artifacts+=@($step.evidence)}
                if($artifacts.Count-eq0){$failures.Add("ledger requiredSteps.$name has no evidence/artifacts")}
                foreach($artifact in $artifacts){Need-File ([string]$artifact) "ledger artifact $name"}
            }
        }catch{$failures.Add("Ledger parse/validation failed: $($_.Exception.Message)")}
    }
}
if($failures.Count){Write-Host "[verify_non_yield_report] FAIL: $CaseId" -ForegroundColor Red;foreach($f in $failures){Write-Host " - $f" -ForegroundColor Red};exit 1}
Write-Host "[verify_non_yield_report] PASS: $CaseId" -ForegroundColor Green
exit 0
