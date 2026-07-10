<#
tasks_json_to_enumerate.ps1 — PRIMARY (DumpViewer) adapter for 第二步.

Converts a DumpViewer `Tasks` sidecar (parsed to `tasks.json`, either a bare
JSON array or a `{rows:[...]}` object) into the pipe-separated line format that
`gen_tasks_full_html.ps1` expects for `!execute Tasks.Enumerate` captures:

    <task_addr> | <scheduler_id> | <worker> | <thread> | <task_state> | <task_function>

This lets the PRIMARY (DumpViewer) path reuse the SAME canonical subreport
generator + stats-sidecar as the FALLBACK (`!execute Tasks.Enumerate`) path —
identical to how `shred_mex_us.ps1` feeds `classify_thread_categories.ps1` in
第一步. No numbers are re-implemented here; only a shape adapter.

Columns expected in the JSON rows (DumpViewer Tasks):
    task, scheduler_id, worker, thread, task_state, task_function
nullptr placeholder rows keep a real 0x `task` addr with every other field
= "nullptr" — emitted verbatim so the generator counts them in 全量清单 but
excludes them from the bound-task denominator.

USAGE :
  pwsh -File tasks_json_to_enumerate.ps1 -TasksJson <parsed\tasks.json> -Out <case>_tasks_enumerate.txt
EXIT  : 0 ok · 1 input missing / no rows.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TasksJson,
    [Parameter(Mandatory)][string]$Out
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $TasksJson)) { Write-Error "TasksJson not found: $TasksJson"; exit 1 }

$doc = Get-Content -LiteralPath $TasksJson -Raw -Encoding UTF8 | ConvertFrom-Json
$rows = if ($doc -is [System.Array]) { $doc }
        elseif ($doc.PSObject.Properties.Name -contains 'rows') { $doc.rows }
        elseif ($doc.PSObject.Properties.Name -contains 'data') { $doc.data }
        else { $doc }

if (-not $rows -or $rows.Count -eq 0) { Write-Error "No task rows in $TasksJson"; exit 1 }

function Val($r, [string[]]$names) {
    foreach ($n in $names) {
        if ($r.PSObject.Properties.Name -contains $n) {
            $v = $r.$n
            if ($null -ne $v) { return ([string]$v).Trim() }
        }
    }
    return ''
}

$lines = New-Object System.Collections.Generic.List[string]
$emitted = 0
foreach ($r in $rows) {
    $task  = Val $r @('task','task_addr','Task')
    if ($task -notmatch '^0x[0-9a-fA-F]+$') { continue }   # only real task rows
    $sched = Val $r @('scheduler_id','SchedulerId','sched')
    $wkr   = Val $r @('worker','Worker')
    $thr   = Val $r @('thread','Thread')
    $state = Val $r @('task_state','TaskState','state')
    $func  = Val $r @('task_function','TaskFunction','function','func')
    # normalize task addr to lowercase so gen_tasks_full_html.ps1 row regex (^0x[0-9a-f]+ \|) matches
    $task  = $task.ToLower()
    if ($sched -eq '') { $sched = 'nullptr' }
    if ($wkr   -eq '') { $wkr   = 'nullptr' }
    if ($thr   -eq '') { $thr   = 'nullptr' }
    if ($state -eq '') { $state = 'nullptr' }
    if ($func  -eq '') { $func  = 'nullptr' }
    $lines.Add(('{0} | {1} | {2} | {3} | {4} | {5}' -f $task, $sched, $wkr, $thr, $state, $func)) | Out-Null
    $emitted++
}

if ($emitted -eq 0) { Write-Error "No 0x task rows emitted from $TasksJson"; exit 1 }

$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Out, ($lines -join "`r`n") + "`r`n", $enc)
Write-Host "wrote $emitted task rows -> $Out"
exit 0
