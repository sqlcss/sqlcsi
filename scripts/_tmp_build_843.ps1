# Builder for case 2607030030000843 dump-overall report artifacts
$ErrorActionPreference = 'Stop'
$cid  = '2607030030000843'
$da   = "C:\Users\lduan\sqlcsi-archive\reports\${cid}_dump_code_analysis"
$do   = "C:\Users\lduan\sqlcsi-archive\reports\${cid}_dump_overall"
New-Item -ItemType Directory -Force -Path $do | Out-Null

# ---- 1. parse tsqlstack_all.txt into per-tid blocks --------------------------
$tf = "$da\${cid}_tsqlstack_all.txt"
$lines = Get-Content $tf
$blocks = @{}
$cur = $null; $body = $null
foreach ($ln in $lines) {
    if ($ln -match '^===TASK_(\d+)\s+') {
        if ($cur) { $blocks[$cur] = $body }
        $cur = $Matches[1]; $body = New-Object System.Collections.Generic.List[string]
        continue
    }
    if ($cur) { $body.Add($ln) }
}
if ($cur) { $blocks[$cur] = $body }

function Get-Tsql($b) {
    if (-not $b) { return $null }
    $sb = New-Object System.Text.StringBuilder
    $capture = $false
    foreach ($l in $b) {
        if ($l -match '^Input string:\s*(.*)$') {
            if ($sb.Length -gt 0) { [void]$sb.AppendLine() }
            [void]$sb.Append($Matches[1]); $capture = $true; continue
        }
        if ($capture) {
            if ($l -match '^(CMsqlExecContext:|Executing statement:|-----|\s*CExecuteStatement:|\s*CStatement:|Parameter \d+:|ntdll!|COM Error)') { $capture = $false; continue }
            [void]$sb.Append(' ' + $l.Trim())
        }
    }
    $t = $sb.ToString().Trim()
    if ($t) { return $t } else { return $null }
}
function Get-StmtClass($b) {
    if (-not $b) { return $null }
    foreach ($l in $b) { if ($l -match 'CStatement:\s*\S+\s*\(\s*(C\w+)\s*\)') { return $Matches[1] } }
    foreach ($l in $b) { if ($l -match 'CExecuteStatement:\s*\S+\s*\(\s*(C\w+)\s*\)') { return $Matches[1] } }
    return $null
}
function Has-ComErr($b) { foreach ($l in $b) { if ($l -match 'COM Error .*0x80020101') { return $true } } return $false }

# ---- 2. load per-main task fields -------------------------------------------
$tj = Get-Content "$da\task_fields.json" -Raw | ConvertFrom-Json

$exec = @{}
foreach ($o in $tj) {
    $m = $o.main
    $tid = "$($m.tid)"
    $b = $blocks[$tid]
    $exec[$tid] = [ordered]@{
        tid=$tid; spid=$m.spid; kids=$o.childCount
        worker=$m.workerState; wait=$m.waitType; elapsed=$m.elapsedMs; cpu=$m.cpuMs
        tsql=(Get-Tsql $b); stmt=(Get-StmtClass $b); comerr=(Has-ComErr $b)
    }
}

# export a compact intermediate
$exec.Values | ConvertTo-Json -Depth 5 | Set-Content "$da\${cid}_exec_extract.json" -Encoding UTF8
Write-Host "exec_extract rows: $($exec.Count)"
$exec.Values | ForEach-Object { "t{0} SPID{1} kids{2} {3} wait={4} stmt={5} tsql={6}" -f $_.tid,$_.spid,$_.kids,$_.worker,$_.wait,$_.stmt,($(if($_.tsql){$_.tsql.Substring(0,[Math]::Min(60,$_.tsql.Length))}else{'<none>'})) }
