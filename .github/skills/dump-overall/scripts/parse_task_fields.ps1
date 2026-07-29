param(
    [string]$CaseId  = '2606250030005483',
    [string]$Dir     = '',                       # defaults to reports\<CaseId>_dump_code_analysis
    [string]$TaskAll = ''                         # defaults to <Dir>\<CaseId>_task_all.txt
)
$ErrorActionPreference = 'Stop'
if (-not $Dir)     { $Dir = "C:\Users\lduan\sqlcsi-archive\reports\${CaseId}_dump_code_analysis" }
$dir = $Dir
$f = if ($TaskAll) { $TaskAll } else { Join-Path $dir "${CaseId}_task_all.txt" }
$lines = Get-Content $f

# Split into blocks by ===TASK_<tid> <TYPE>===
$blocks = @()
$cur = $null
foreach ($ln in $lines) {
    if ($ln -match '^===TASK_(\d+)\s+(MAIN|CHILD[^=]*)===') {
        if ($cur) { $blocks += ,$cur }
        $cur = [ordered]@{ tid=[int]$Matches[1]; kind=$Matches[2].Trim(); body=New-Object System.Collections.Generic.List[string] }
        continue
    }
    if ($cur) { $cur.body.Add($ln) }
}
if ($cur) { $blocks += ,$cur }

function Get-First([System.Collections.Generic.List[string]]$body, [string]$pattern) {
    foreach ($l in $body) { if ($l -match $pattern) { return $Matches } }
    return $null
}

$rows = @()
foreach ($b in $blocks) {
    $body = $b.body
    $r = [ordered]@{
        tid = $b.tid
        kind = if ($b.kind -like 'CHILD*') { 'CHILD' } else { 'MAIN' }
        spid = $null; sched = $null
        taskState = $null; workerState = $null
        elapsedMs = $null; cpuMs = $null
        taskFunc = $null; waitType = $null
        blkSpid = $null; blkTid = $null; blkReason = $null
    }
    # own SOS_Task line (anchored at col 0, no ----> prefix)
    $m = Get-First $body '^SOS_Task\s*:\s*\S+\s*\(SPID:(\d+),.*~(\d+)s,\s*(Sch\d*):(0x[0-9A-Fa-f]+)'
    if ($m) { $r.spid = [int]$m[1]; $r.sched = $m[3] }
    $m = Get-First $body '^Task state, paramflags:\s*(\S+)'; if ($m) { $r.taskState = $m[1] }
    $m = Get-First $body '^Worker state\s*:\s*(\S+)'; if ($m) { $r.workerState = $m[1] }
    $m = Get-First $body '^Elapsed time\s*:\s*(\d+)\s*ms'; if ($m) { $r.elapsedMs = [long]$m[1] }
    $m = Get-First $body '^CPU time\s*:\s*(\d+)\s*ms'; if ($m) { $r.cpuMs = [long]$m[1] }
    $m = Get-First $body '^Task function\s*:\s*(.+?)\s*$'; if ($m) { $r.taskFunc = $m[1].Trim() }
    $m = Get-First $body '^Wait type description\s*:\s*(.+?)\s*$'; if ($m) { $r.waitType = $m[1].Trim() }
    # blocker
    $m = Get-First $body 'BLOCKER_0[^:]*:\s*(.+?)\s*$'; if ($m) { $r.blkReason = $m[1].Trim() }
    $m = Get-First $body '---->\s*SOS_Task\s*:\s*\S+\s*\(SPID:(\d+),.*~(\d+)s'
    if ($m) { $r.blkSpid = [int]$m[1]; $r.blkTid = [int]$m[2] }
    $rows += ,([pscustomobject]$r)
}

# A sweep may append per-thread retries after the original shard output. Keep one
# best-populated row per (TID, role), otherwise retried children inflate parent
# child counts and the overall execution inventory.
$rows = @($rows | Group-Object tid,kind | ForEach-Object {
    $_.Group | Sort-Object -Descending -Property @{
        Expression = {
            $score = 0
            foreach ($name in @('spid','sched','taskState','workerState','elapsedMs','cpuMs','taskFunc','waitType','blkReason')) {
                if ($null -ne $_[$name] -and [string]$_[$name] -ne '') { $score++ }
            }
            $score
        }
    } | Select-Object -First 1
})

# group by SPID: MAIN is parent, CHILD share parent's SPID
$mains = $rows | Where-Object { $_.kind -eq 'MAIN' }
$children = $rows | Where-Object { $_.kind -eq 'CHILD' }
$out = @()
foreach ($mn in $mains) {
    $kids = @($children | Where-Object { $_.spid -eq $mn.spid } | Sort-Object tid)
    $out += ,([ordered]@{ main=$mn; childCount=$kids.Count; children=$kids })
}

$json = $out | ConvertTo-Json -Depth 6
$outPath = Join-Path $dir 'task_fields.json'
[System.IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "MAINS: $($mains.Count)  CHILDREN: $($children.Count)  outfile: $outPath"
foreach ($o in $out) {
    $mn = $o.main
    Write-Host ("main {0} SPID {1} kids {2} | wait={3} | worker={4} | elapsed={5}ms cpu={6}ms | func={7} | blk=SPID{8}(~{9}s):{10}" -f $mn.tid,$mn.spid,$o.childCount,$mn.waitType,$mn.workerState,$mn.elapsedMs,$mn.cpuMs,$mn.taskFunc,$mn.blkSpid,$mn.blkTid,$mn.blkReason)
}
