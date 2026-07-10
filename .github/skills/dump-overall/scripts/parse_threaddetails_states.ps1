# =============================================================================
# parse_threaddetails_states.ps1 — SQL-CSI dump-overall 第一步 (PRIMARY mode)
#
# PRIMARY (DumpViewer) counterpart to parse_us_states.ps1. Instead of inferring
# each thread's SQLOS worker state from the stack top (!mex.us), it reads the
# AUTHORITATIVE `worker_state` (= SOS_Worker.m_state) that DumpViewer's
# ThreadDetails table already carries, and splits WORKER_STATE_SUSPENDED into
# IDLE (parked in the work dispatcher) vs SUSPENDED (real resource wait) using
# the authoritative `worker_last_wait` column.
#
# INPUT : threaddetails.json (from parse_dumpviewer_json.js on the
#         ThreadDe_*_json.js sidecar) — columns include worker_state,
#         worker_last_wait, task, call_stack.
# OUTPUT: table on stdout + optional JSON to -OutJson, in the SAME schema as
#         parse_us_states.ps1 ({source,totalStacks,totalThreads,rows:[{State,
#         Stacks,Threads,Pct}]}) plus authoritative=$true and a per-state
#         topWaits breakdown — so gen_overall_report.ps1 consumes it unchanged.
#
# CLASSIFICATION (authoritative, first match wins):
#   worker_state empty                                   -> SYSTEM   (non-SQLOS OS thread)
#   WORKER_STATE_RUNNING                                 -> RUNNING
#   WORKER_STATE_RUNNABLE                                -> RUNNABLE
#   WORKER_STATE_SUSPENDED + worker_last_wait = PWAIT_SOS_WORK_DISPATCHER -> IDLE
#   WORKER_STATE_SUSPENDED + any other wait               -> SUSPENDED
#   (any other non-empty worker_state)                   -> OTHER
#
# EXIT CODES:
#   0 = OK (authoritative worker_state present).
#   1 = source missing / not valid JSON.
#   2 = FALLBACK NEEDED — ThreadDetails is empty (0 rows) or carries NO
#       authoritative worker_state at all (every row blank; e.g. a build/dump
#       DumpViewer could not populate SOS state for). The orchestrator MUST then
#       fall back to !mex.us -> parse_us_states.ps1 + gen_us_html.ps1 (_us.html)
#       and point the main report at _us.html instead of ThreadDetails.html.
# =============================================================================
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Src,      # threaddetails.json
  [string]$OutJson = $null                 # optional; JSON summary for report
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Src)) {
    Write-Host "[parse_threaddetails_states] ERROR: source not found: $Src" -ForegroundColor Red
    exit 1
}

$doc = Get-Content $Src -Raw -Encoding UTF8 | ConvertFrom-Json
$rowsIn = @($doc.rows)
if ($rowsIn.Count -eq 0) {
    Write-Host "[parse_threaddetails_states] FALLBACK: ThreadDetails has 0 rows -> run !mex.us path (parse_us_states.ps1 + gen_us_html.ps1)" -ForegroundColor Yellow
    exit 2
}

# FALLBACK trigger: rows exist but NO authoritative worker_state at all
# (every row blank) — DumpViewer could not populate SOS state for this build/dump.
$withState = @($rowsIn | Where-Object { "$($_.worker_state)".Trim() })
if ($withState.Count -eq 0) {
    Write-Host "[parse_threaddetails_states] FALLBACK: $($rowsIn.Count) rows but worker_state is blank on ALL of them -> run !mex.us path (parse_us_states.ps1 + gen_us_html.ps1)" -ForegroundColor Yellow
    exit 2
}

$IDLE_WAIT = 'PWAIT_SOS_WORK_DISPATCHER'

function Classify($r) {
    $ws = "$($r.worker_state)".Trim()
    if (-not $ws) { return 'SYSTEM' }
    switch ($ws) {
        'WORKER_STATE_RUNNING'  { return 'RUNNING' }
        'WORKER_STATE_RUNNABLE' { return 'RUNNABLE' }
        'WORKER_STATE_SUSPENDED' {
            if ("$($r.worker_last_wait)".Trim() -eq $IDLE_WAIT) { return 'IDLE' }
            return 'SUSPENDED'
        }
        default { return 'OTHER' }
    }
}

# Preferred display order
$order = @{ IDLE=0; SUSPENDED=1; RUNNABLE=2; RUNNING=3; SYSTEM=4; OTHER=5 }

$tagged = $rowsIn | ForEach-Object {
    [pscustomobject]@{ State = (Classify $_); Stack = "$($_.call_stack)"; Wait = "$($_.worker_last_wait)".Trim() }
}

$rows = $tagged | Group-Object State | ForEach-Object {
    $g = $_.Group
    $waits = $g | Where-Object { $_.Wait } | Group-Object Wait |
        Sort-Object Count -Descending | Select-Object -First 3 |
        ForEach-Object { "{0}×{1}" -f $_.Name, $_.Count }
    [pscustomobject]@{
        State    = $_.Name
        Stacks   = ($g | Select-Object -ExpandProperty Stack -Unique | Measure-Object).Count
        Threads  = $g.Count
        TopWaits = ($waits -join ', ')
    }
} | Sort-Object @{ e = { $order[$_.State] } }, @{ e = 'Threads'; Descending = $true }

$totalThreads = ($rows | Measure-Object Threads -Sum).Sum
$totalStacks  = ($rows | Measure-Object Stacks  -Sum).Sum

$rows = $rows | ForEach-Object {
    $pct = if ($totalThreads -gt 0) { [math]::Round($_.Threads * 100.0 / $totalThreads, 1) } else { 0.0 }
    [pscustomobject]@{ State = $_.State; Stacks = $_.Stacks; Threads = $_.Threads; Pct = $pct; TopWaits = $_.TopWaits }
}

$rows | Format-Table State, Stacks, Threads, Pct, TopWaits -AutoSize | Out-Host
Write-Host ("[parse_threaddetails_states] AUTHORITATIVE (worker_state): {0} threads, {1} distinct stacks" -f $totalThreads, $totalStacks) -ForegroundColor Green

if ($OutJson) {
    $obj = [pscustomobject]@{
        source        = (Resolve-Path $Src).Path
        authoritative = $true
        totalStacks   = $totalStacks
        totalThreads  = $totalThreads
        rows          = @($rows)
    }
    $json = $obj | ConvertTo-Json -Depth 5
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutJson, $json, $enc)
    Write-Host "[parse_threaddetails_states] JSON written: $OutJson" -ForegroundColor Cyan
}
exit 0
