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
    [Parameter(Mandatory=$true)][string] $Threads,
    [Parameter(Mandatory=$true)][string]   $DscriptPath,   # folder holding task.js
    [Parameter(Mandatory=$true)][string]   $LogFile,       # .logopen target (the task_all.txt)
    [Parameter(Mandatory=$true)][string]   $OutWds,        # path to write the generated .wds
    [string] $Script  = 'task.js',
    [switch] $Run,                                          # also run it headless in cdb
    [string] $Dump,                                         # required with -Run
    [string] $SymPath = 'srv*C:\Symbols*https://symweb.azurefd.net',
    [string] $Cdb                                           # cdb.exe; auto-detect Store WinDbg if omitted
)

$ErrorActionPreference = 'Stop'

$js = Join-Path $DscriptPath $Script
if (!(Test-Path $js)) { throw "script not found: $js (is -DscriptPath correct?)" }

# --- build the .wds (proven layout) ---
$threadList = $Threads -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if (-not $threadList) { throw "-Threads is empty - pass e.g. '7364:MAIN,120:CHILD-A'" }

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
if (-not $Cdb) {
    $Cdb = (Get-Item 'C:\Program Files\WindowsApps\Microsoft.WinDbg.*_x64__8wekyb3d8bbwe\amd64\cdb.exe' -ErrorAction SilentlyContinue |
            Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName)
}
if (-not $Cdb -or !(Test-Path $Cdb)) { throw "cdb.exe not found - pass -Cdb <path> (Store WinDbg amd64\cdb.exe)" }

$console = [System.IO.Path]::ChangeExtension($OutWds, 'console.txt')
Write-Host "[gen_task_sweep] cdb  : $Cdb"
Write-Host "[gen_task_sweep] run  : -y '$SymPath' -z '$Dump' -c `"`$`$><$OutWds`""
# -y = symbols (never .sympath in -c); $$>< = BLOCK mode (the .wds has many lines / $$ comments)
& $Cdb -y $SymPath -z $Dump -c "`$`$><$OutWds" *> $console

$n = 0
if (Test-Path $LogFile) { $n = (Select-String $LogFile -Pattern '(?m)^===TASK_').Count }
Write-Host ""
Write-Host "[gen_task_sweep] done. task blocks in log: $n  (expected $($threadList.Count))"
Write-Host "[gen_task_sweep] log     -> $LogFile"
Write-Host "[gen_task_sweep] console -> $console"
