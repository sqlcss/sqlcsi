# gen_task_sweep.ps1 - generate the headless cdb DScript task.js sweep .wds file
# (one thread per line) and OPTIONALLY run it headless in cdb.
#
# Encodes the PROVEN recipe from repo memory cdb_headless_dscript_sweep.md
# (verified 2026-07-02 on dump 2606250030005483, 38-task sweep == baseline):
#   * symbols via -y (NEVER .sympath inside -c)
#   * q is the LAST LINE INSIDE the .wds (never after the file ref in -c)
#   * run with $$><  (BLOCK mode) because the .wds has many lines
#   * .wds written UTF-8 no-BOM (here-strings corrupt markers)
#
# The .wds owns its own .logopen/.logclose and ends with q so headless cdb exits.
# The parse marker per block is  ===TASK_<tid> <ROLE>===  which §1.7.3
# (parse_task_fields.ps1) splits on: ^===TASK_(\d+)\s+(MAIN|CHILD[^=]*)===
#
# NOTE: DScript COM must be registered first (per-user, no admin):
#   powershell -NoProfile -File register_dscript.ps1
#
# Usage (generate only):
#   powershell -NoProfile -ExecutionPolicy Bypass -File gen_task_sweep.ps1 `
#     -Threads '7364:MAIN,120:CHILD-A,144:CHILD-B' `
#     -DscriptPath 'C:\Tools\dscript\sql2019' `
#     -LogFile 'C:\...\<case>_task_all.txt' `
#     -OutWds  'C:\...\<case>_task_all.wds'
# (-Threads is ONE comma-separated string - powershell -File does not array-bind
#  space-separated tokens, so pass them comma-joined in a single quoted arg.)
#
# Usage (generate + run headless in cdb):
#   ... same as above ... -Run -Dump 'C:\...\sqldump0001.mdmp'
param(
    # Comma- (or semicolon-) separated list; each entry is "TID" or "TID:ROLE".
    # ROLE defaults to MAIN; children use CHILD / CHILD-A / ...  e.g. '7364:MAIN,120:CHILD-A'
    [string] $Threads,
    # File containing the same comma-/semicolon-/newline-separated thread specs.
    # Prefer this for large sweeps so task shells cannot reinterpret commas.
    [string] $ThreadsFile,
    [Parameter(Mandatory=$true)][string]   $DscriptPath,   # folder holding task.js
    [Parameter(Mandatory=$true)][string]   $LogFile,       # .logopen target (the task_all.txt)
    [Parameter(Mandatory=$true)][string]   $OutWds,        # path to write the generated .wds
    [string] $Script  = 'task.js',
    [switch] $Run,                                          # also run it headless in cdb
    [switch] $RunPerThread,                                 # run each thread in its own bounded cdb process
    [int] $PerThreadTimeoutSec = 60,                         # used with -RunPerThread
    [int] $ShardSize = 0,                                    # with -Run, run bounded shards of this size
    [int] $ShardTimeoutSec = 300,                             # used with -ShardSize
    [string] $Dump,                                         # required with -Run
    [string] $SymPath = 'srv*C:\Symbols*https://symweb.azurefd.net',
    [string] $Cdb                                           # cdb.exe; auto-detect Store WinDbg if omitted
)

$ErrorActionPreference = 'Stop'

$js = Join-Path $DscriptPath $Script
if (!(Test-Path $js)) { throw "script not found: $js (is -DscriptPath correct?)" }

# --- build the .wds (proven layout) ---
if ($Threads -and $ThreadsFile) { throw "pass either -Threads or -ThreadsFile, not both" }
if ($ThreadsFile) {
    if (-not (Test-Path -LiteralPath $ThreadsFile -PathType Leaf)) { throw "threads file not found: $ThreadsFile" }
    $Threads = Get-Content -LiteralPath $ThreadsFile -Raw -Encoding UTF8
}
$threadList = $Threads -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if (-not $threadList) { throw "thread list is empty - pass -Threads or -ThreadsFile" }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine(".logopen $LogFile")
foreach ($t in $threadList) {
    $parts = $t -split ':', 2
    $tid  = $parts[0].Trim()
    if ($tid -notmatch '^\d+$') { throw "bad thread spec '$t' - expected 'TID' or 'TID:ROLE'" }
    $role = if ($parts.Count -gt 1 -and $parts[1].Trim()) { $parts[1].Trim() } else { 'MAIN' }
    [void]$sb.AppendLine("~$tid s ; .echo ===TASK_$tid $role=== ; !dscript.run $js")
}
[void]$sb.AppendLine(".echo ##### END TASK.JS SWEEP #####")
[void]$sb.AppendLine(".logclose")
[void]$sb.AppendLine("q")

$dir = Split-Path $OutWds -Parent
if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[System.IO.File]::WriteAllText($OutWds, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[gen_task_sweep] wrote $($threadList.Count)-thread sweep -> $OutWds"
Write-Host "[gen_task_sweep] .logopen target -> $LogFile"

if (-not $Run) {
    Write-Host ""
    Write-Host "Generate-only. To run headless in cdb (symbols warm ~1-2 s/task):"
    Write-Host "  & <cdb> -y '$SymPath' -z '<dump>' -c `"`$`$><$OutWds`" *> '$([System.IO.Path]::ChangeExtension($OutWds,'console.txt'))'"
    return
}

# --- optional: run it headless in cdb (the proven invocation) ---
if (!$Dump)          { throw "-Run requires -Dump" }
if (!(Test-Path $Dump)) { throw "dump not found: $Dump" }
. (Join-Path $PSScriptRoot 'resolve_cdb.ps1')
$Cdb = Resolve-CdbPath -Cdb $Cdb -Required

$console = [System.IO.Path]::ChangeExtension($OutWds, 'console.txt')
Write-Host "[gen_task_sweep] cdb  : $Cdb"

if ($RunPerThread) {
    if ($PerThreadTimeoutSec -le 0) { throw "-PerThreadTimeoutSec must be > 0" }
    $runDir = Join-Path (Split-Path -Parent $OutWds) ([System.IO.Path]::GetFileNameWithoutExtension($OutWds) + '_per_thread')
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    if (Test-Path -LiteralPath $LogFile) { Remove-Item -LiteralPath $LogFile -Force }
    $summary = New-Object System.Collections.ArrayList
    foreach ($t in $threadList) {
        $parts = $t -split ':', 2
        $tid  = $parts[0].Trim()
        $role = if ($parts.Count -gt 1 -and $parts[1].Trim()) { $parts[1].Trim() } else { 'MAIN' }
        $safeRole = ($role -replace '[^A-Za-z0-9_.-]', '_')
        $oneLog = Join-Path $runDir ("{0}_{1}.txt" -f $tid, $safeRole)
        $oneWds = Join-Path $runDir ("{0}_{1}.wds" -f $tid, $safeRole)
        $oneConsole = [System.IO.Path]::ChangeExtension($oneWds, 'console.txt')
        $oneErr = [System.IO.Path]::ChangeExtension($oneWds, 'err.txt')
        $one = New-Object System.Text.StringBuilder
        [void]$one.AppendLine(".logopen $oneLog")
        [void]$one.AppendLine("~$tid s ; .echo ===TASK_$tid $role=== ; !dscript.run $js")
        [void]$one.AppendLine(".echo ===END_TASK_$tid===")
        [void]$one.AppendLine(".logclose")
        [void]$one.AppendLine("q")
        [System.IO.File]::WriteAllText($oneWds, $one.ToString(), (New-Object System.Text.UTF8Encoding($false)))

        Write-Host ("[gen_task_sweep] run-per-thread: TID {0} {1}" -f $tid, $role)
        $proc = Start-Process -FilePath $Cdb -ArgumentList @('-y', $SymPath, '-z', $Dump, '-c', "`$`$><$oneWds", '-G', '-lines') -RedirectStandardOutput $oneConsole -RedirectStandardError $oneErr -WindowStyle Hidden -PassThru
        $completed = $false
        $reachedEnd = $false
        $deadline = [DateTime]::UtcNow.AddSeconds($PerThreadTimeoutSec)
        do {
            if ($proc.WaitForExit(1000)) { $completed = $true; break }
            if ((Test-Path -LiteralPath $oneLog) -and (Select-String -LiteralPath $oneLog -Pattern "===END_TASK_$tid===" -Quiet)) {
                $reachedEnd = $true
                break
            }
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $completed -and $reachedEnd) {
            try { $proc.Kill() } catch {}
            $completed = $true
            Write-Host ("[gen_task_sweep] TID {0} reached end marker but cdb stayed open; killed prompt" -f $tid) -ForegroundColor Yellow
        }
        if (-not $completed) {
            try { $proc.Kill() } catch {}
            $bytes = 0
            if (Test-Path -LiteralPath $oneLog) {
                $bytes = (Get-Item -LiteralPath $oneLog).Length
                if ($bytes -gt 0) {
                    Get-Content -LiteralPath $oneLog -Raw -Encoding UTF8 | Add-Content -LiteralPath $LogFile -Encoding UTF8
                } else {
                    Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value "===TASK_$tid $role==="
                }
            } else {
                Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value "===TASK_$tid $role==="
            }
            Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value "DSCRIPT_TIMEOUT script=$Script timeoutSec=$PerThreadTimeoutSec"
            if (-not ((Test-Path -LiteralPath $oneLog) -and (Select-String -LiteralPath $oneLog -Pattern "===END_TASK_$tid===" -Quiet))) {
                Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value "===END_TASK_$tid==="
            }
            [void]$summary.Add([ordered]@{ tid=[int]$tid; role=$role; status='timeout'; bytes=$bytes; log=$oneLog; console=$oneConsole })
            Write-Host ("[gen_task_sweep] TID {0} TIMEOUT after {1}s" -f $tid, $PerThreadTimeoutSec) -ForegroundColor Yellow
            continue
        }
        $status = 'empty'
        $bytes = 0
        if (Test-Path -LiteralPath $oneLog) {
            $bytes = (Get-Item -LiteralPath $oneLog).Length
            if ($bytes -gt 0) {
                Get-Content -LiteralPath $oneLog -Raw -Encoding UTF8 | Add-Content -LiteralPath $LogFile -Encoding UTF8
                $status = 'done'
            }
        }
        [void]$summary.Add([ordered]@{ tid=[int]$tid; role=$role; status=$status; bytes=$bytes; log=$oneLog; console=$oneConsole })
        Write-Host ("[gen_task_sweep] TID {0} {1} ({2} bytes)" -f $tid, $status, $bytes)
    }
    Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value "##### END TASK.JS SWEEP #####"
    $summaryPath = [System.IO.Path]::ChangeExtension($OutWds, 'summary.json')
    [System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    $n = 0
    if (Test-Path $LogFile) { $n = (Select-String $LogFile -Pattern '(?m)^===TASK_').Count }
    Write-Host ""
    Write-Host "[gen_task_sweep] done. task blocks in log: $n  (expected $($threadList.Count))"
    Write-Host "[gen_task_sweep] log     -> $LogFile"
    Write-Host "[gen_task_sweep] summary -> $summaryPath"
    exit 0
}

if ($ShardSize -gt 0) {
    if ($ShardTimeoutSec -le 0) { throw "-ShardTimeoutSec must be > 0" }
    $runDir = Join-Path (Split-Path -Parent $OutWds) ([System.IO.Path]::GetFileNameWithoutExtension($OutWds) + '_shards')
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    if (Test-Path -LiteralPath $LogFile) { Remove-Item -LiteralPath $LogFile -Force }
    $summary = New-Object System.Collections.ArrayList
    $shardIndex = 0
    for ($start = 0; $start -lt $threadList.Count; $start += $ShardSize) {
        $shardIndex++
        $end = [Math]::Min($start + $ShardSize - 1, $threadList.Count - 1)
        $slice = @($threadList[$start..$end])
        $oneLog = Join-Path $runDir ("shard_{0:000}.txt" -f $shardIndex)
        $oneWds = Join-Path $runDir ("shard_{0:000}.wds" -f $shardIndex)
        $oneConsole = [System.IO.Path]::ChangeExtension($oneWds, 'console.txt')
        $oneErr = [System.IO.Path]::ChangeExtension($oneWds, 'err.txt')
        $one = New-Object System.Text.StringBuilder
        [void]$one.AppendLine(".logopen $oneLog")
        foreach ($t in $slice) {
            $parts = $t -split ':', 2
            $tid  = $parts[0].Trim()
            $role = if ($parts.Count -gt 1 -and $parts[1].Trim()) { $parts[1].Trim() } else { 'MAIN' }
            [void]$one.AppendLine("~$tid s ; .echo ===TASK_$tid $role=== ; !dscript.run $js")
        }
        [void]$one.AppendLine(".echo ##### END TASK.JS SHARD $shardIndex #####")
        [void]$one.AppendLine(".logclose")
        [void]$one.AppendLine("q")
        [System.IO.File]::WriteAllText($oneWds, $one.ToString(), (New-Object System.Text.UTF8Encoding($false)))

        Write-Host ("[gen_task_sweep] run-shard {0}: {1} threads" -f $shardIndex, $slice.Count)
        $proc = Start-Process -FilePath $Cdb -ArgumentList @('-y', $SymPath, '-z', $Dump, '-c', "`$`$><$oneWds", '-G', '-lines') -RedirectStandardOutput $oneConsole -RedirectStandardError $oneErr -WindowStyle Hidden -PassThru
        $completed = $false
        $reachedEnd = $false
        $deadline = [DateTime]::UtcNow.AddSeconds($ShardTimeoutSec)
        do {
            if ($proc.WaitForExit(1000)) { $completed = $true; break }
            $blockCount = if (Test-Path -LiteralPath $oneLog) { (Select-String -LiteralPath $oneLog -Pattern '^===TASK_' | Measure-Object).Count } else { 0 }
            $hasEnd = if (Test-Path -LiteralPath $oneLog) { [bool](Select-String -LiteralPath $oneLog -Pattern "END TASK\.JS SHARD $shardIndex" -Quiet) } else { $false }
            if ($blockCount -ge $slice.Count -and $hasEnd) {
                $reachedEnd = $true
                break
            }
        } while ([DateTime]::UtcNow -lt $deadline)
        $blockCount = if (Test-Path -LiteralPath $oneLog) { (Select-String -LiteralPath $oneLog -Pattern '^===TASK_' | Measure-Object).Count } else { 0 }
        $hasEnd = if (Test-Path -LiteralPath $oneLog) { [bool](Select-String -LiteralPath $oneLog -Pattern "END TASK\.JS SHARD $shardIndex" -Quiet) } else { $false }
        if (-not $completed -and ($reachedEnd -or ($blockCount -ge $slice.Count -and $hasEnd))) {
            try { $proc.Kill() } catch {}
            $completed = $true
            Write-Host ("[gen_task_sweep] shard {0} reached end marker but cdb stayed open; killed prompt" -f $shardIndex) -ForegroundColor Yellow
        }
        if (-not $completed) {
            try { $proc.Kill() } catch {}
            if (Test-Path -LiteralPath $oneLog) {
                Get-Content -LiteralPath $oneLog -Raw -Encoding UTF8 | Add-Content -LiteralPath $LogFile -Encoding UTF8
            }
            Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value "##### DSCRIPT_SHARD_TIMEOUT shard=$shardIndex timeoutSec=$ShardTimeoutSec blocks=$blockCount/$($slice.Count) #####"
            foreach ($t in $slice) {
                $parts = $t -split ':', 2
                $tid  = $parts[0].Trim()
                $role = if ($parts.Count -gt 1 -and $parts[1].Trim()) { $parts[1].Trim() } else { 'MAIN' }
                [void]$summary.Add([ordered]@{ tid=[int]$tid; role=$role; shard=$shardIndex; status='shard-timeout'; blocks=$blockCount; log=$oneLog; console=$oneConsole })
            }
            Write-Host ("[gen_task_sweep] shard {0} TIMEOUT after {1}s; blocks={2}/{3}" -f $shardIndex, $ShardTimeoutSec, $blockCount, $slice.Count) -ForegroundColor Yellow
        } else {
            if (Test-Path -LiteralPath $oneLog) {
                Get-Content -LiteralPath $oneLog -Raw -Encoding UTF8 | Add-Content -LiteralPath $LogFile -Encoding UTF8
            }
            foreach ($t in $slice) {
                $parts = $t -split ':', 2
                $tid  = $parts[0].Trim()
                $role = if ($parts.Count -gt 1 -and $parts[1].Trim()) { $parts[1].Trim() } else { 'MAIN' }
                [void]$summary.Add([ordered]@{ tid=[int]$tid; role=$role; shard=$shardIndex; status='done'; log=$oneLog; console=$oneConsole })
            }
            Write-Host ("[gen_task_sweep] shard {0} done; blocks={1}/{2}" -f $shardIndex, $blockCount, $slice.Count)
        }
    }
    Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value "##### END TASK.JS SWEEP #####"
    $summaryPath = [System.IO.Path]::ChangeExtension($OutWds, 'summary.json')
    [System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    $n = 0
    if (Test-Path $LogFile) { $n = (Select-String $LogFile -Pattern '(?m)^===TASK_').Count }
    Write-Host ""
    Write-Host "[gen_task_sweep] done. task blocks in log: $n  (expected $($threadList.Count))"
    Write-Host "[gen_task_sweep] log     -> $LogFile"
    Write-Host "[gen_task_sweep] summary -> $summaryPath"
    exit 0
}

Write-Host "[gen_task_sweep] run  : -y '$SymPath' -z '$Dump' -c `"`$`$><$OutWds`""
# -y = symbols (never .sympath in -c); $$>< = BLOCK mode (the .wds has many lines / $$ comments)
& $Cdb -y $SymPath -z $Dump -c "`$`$><$OutWds" *> $console

$n = 0
if (Test-Path $LogFile) { $n = (Select-String $LogFile -Pattern '(?m)^===TASK_').Count }
Write-Host ""
Write-Host "[gen_task_sweep] done. task blocks in log: $n  (expected $($threadList.Count))"
Write-Host "[gen_task_sweep] log     -> $LogFile"
Write-Host "[gen_task_sweep] console -> $console"
