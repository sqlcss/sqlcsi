# =============================================================================
# parse_us_states.ps1 — SQL-CSI dump-overall 第一步 1.5.3 (SQLOS worker state)
#
# Parses `!mex.us` output (`<case>_us.txt`) into unique-stack groups, applies
# the SQLOS worker-state heuristics (IDLE / RUNNABLE / SUSPENDED / RUNNING /
# SYSTEM-WAIT / SYSTEM-RUNNING — stack-inferred, see SKILL.md §1.5.2), and
# emits the aggregated state summary.
#
# OUTPUT: table on stdout (Format-Table) + optional JSON to -OutJson.
# The JSON is what `gen_overall_report.ps1` consumes for 第一步 表 1.
#
# EXIT CODES: 0 = OK; 1 = source file missing or no groups parsed.
# =============================================================================
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Src,              # <case>_us.txt from run_mex_us.ps1
  [string]$OutJson = $null                         # optional; JSON summary for report
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Src)) {
    Write-Host "[parse_us_states] ERROR: source not found: $Src" -ForegroundColor Red
    exit 1
}

$lines = Get-Content $Src
$groups = @(); $cur = $null
foreach ($ln in $lines) {
    if ($ln -match '^(\d+)\s+threads?\s+\[stats\]') {
        if ($cur) { $groups += $cur }
        $cur = [pscustomobject]@{ Count = [int]$Matches[1]; Frames = New-Object Collections.ArrayList }
    } elseif ($cur -and $ln -match 'sqldk!|sqllang!|sqlmin!|sqltses!|ntdll!|KERNELBASE!') {
        [void]$cur.Frames.Add($ln.Trim())
    }
}
if ($cur) { $groups += $cur }

if ($groups.Count -eq 0) {
    Write-Host "[parse_us_states] ERROR: no `[stats]` groups parsed from $Src" -ForegroundColor Red
    exit 1
}

function Classify($g) {
    $j = ($g.Frames -join ' ')
    $w = $j -match 'ZwWaitForSingleObject|ZwSignalAndWaitForSingleObject|SignalObjectAndWait|WaitForSingleObjectEx|WaitForMultipleObjects'
    if ($j -match 'WorkDispatcher::DequeueTask') { return 'IDLE' }
    $t = $j -match 'SOS_Task::Param::Execute|SOS_Scheduler::RunTask'
    if (-not $t) { if ($w) { return 'SYSTEM-WAIT' } else { return 'SYSTEM-RUNNING' } }
    if ($j -match 'OSYieldNoAbort|OSYield\b') { return 'RUNNABLE' }
    if ($w) { return 'SUSPENDED' }
    return 'RUNNING'
}

$rows = $groups |
    ForEach-Object { [pscustomobject]@{ Count = $_.Count; State = (Classify $_) } } |
    Group-Object State |
    ForEach-Object {
        [pscustomobject]@{
            State   = $_.Name
            Stacks  = $_.Count
            Threads = ($_.Group | Measure-Object Count -Sum).Sum
        }
    } |
    Sort-Object Threads -Descending

$totalThreads = ($rows | Measure-Object Threads -Sum).Sum
$totalStacks  = ($rows | Measure-Object Stacks  -Sum).Sum

# add Pct column
$rows = $rows | ForEach-Object {
    $pct = if ($totalThreads -gt 0) { [math]::Round($_.Threads * 100.0 / $totalThreads, 1) } else { 0.0 }
    [pscustomobject]@{ State = $_.State; Stacks = $_.Stacks; Threads = $_.Threads; Pct = $pct }
}

$rows | Format-Table -AutoSize | Out-Host
Write-Host ("[parse_us_states] total: {0} stack groups, {1} threads" -f $totalStacks, $totalThreads) -ForegroundColor Green

if ($OutJson) {
    $obj = [pscustomobject]@{
        source       = (Resolve-Path $Src).Path
        totalStacks  = $totalStacks
        totalThreads = $totalThreads
        rows         = @($rows)
    }
    $json = $obj | ConvertTo-Json -Depth 5
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutJson, $json, $enc)
    Write-Host "[parse_us_states] JSON written: $OutJson" -ForegroundColor Cyan
}
exit 0
