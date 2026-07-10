# run_sqlscriptrepl.ps1 - headless (auto) driver for SqlScriptRepl.exe.
# VERIFIED WORKING 2026-07-02 on case 2606250030005483 (Tasks.Enumerate -> 115 rows).
#
# SqlScriptRepl reads expressions from STDIN (the 'mirror>' prompt, Console.ReadLine).
# This wraps the pipe-in so the "auto" mirror path is one reusable command. ALWAYS run
# this as a FILE (an inline here-string piped in run_in_terminal gets swallowed).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File run_sqlscriptrepl.ps1 `
#     -Dump 'C:\Temp\...\sqldump0001.mdmp' `
#     -Expr 'Tasks.Enumerate' `
#     -OutDir 'C:\Users\lduan\sqlcsi-archive\reports\<case>_dump_code_analysis' `
#     [-Scripts 'C:\Tools\WinDbgCs\NetStandard20Refs\SqlCsScripts.dll'] `
#     [-DumpViewerDir 'C:\Users\lduan\tools\DumpViewer'] `
#     [-SymPath 'srv*C:\Symbols*https://symweb.azurefd.net']
#
# -Expr may be one expression or several (array / comma-separated); each is fed on its own
# line, then 'quit'. If -Scripts is omitted, SqlScriptRepl auto-detects SqlCsScripts.dll
# next to the dump. First run is slow (DiscoverScripts = minutes).
param(
    [Parameter(Mandatory=$true)][string]   $Dump,
    [Parameter(Mandatory=$true)][string[]] $Expr,
    [Parameter(Mandatory=$true)][string]   $OutDir,
    [string] $Scripts,
    [string] $DumpViewerDir = 'C:\Users\lduan\tools\DumpViewer',
    [string] $SymPath       = 'srv*C:\Symbols*https://symweb.azurefd.net'
)

$ErrorActionPreference = 'Stop'
$exe = Join-Path $DumpViewerDir 'SqlScriptRepl.exe'
if (!(Test-Path $exe))  { throw "SqlScriptRepl.exe not found: $exe (build it - run build_sqlscriptrepl.ps1)" }
if (!(Test-Path $Dump)) { throw "dump not found: $Dump" }
if ($Scripts -and !(Test-Path $Scripts)) { throw "scripts dll not found: $Scripts" }
if (!(Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outRepl = Join-Path $OutDir "repl_out_$stamp"
$logOut  = Join-Path $OutDir "repl_stdout_$stamp.txt"

# STDIN feed: one expression per line, then quit.
$stdin = (($Expr + 'quit') -join "`r`n") + "`r`n"

$argList = @('-f', $Dump, '-o', $outRepl, '-s', $SymPath)
if ($Scripts) { $argList += @('-scripts', $Scripts) }

Push-Location $DumpViewerDir
try {
    $stdin | & $exe @argList *>&1 | Tee-Object -FilePath $logOut
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "[run_sqlscriptrepl] stdout captured -> $logOut"
