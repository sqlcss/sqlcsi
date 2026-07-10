#requires -Version 5.1
<#
.SYNOPSIS
    Run SqlScriptRepl on a SQL Server dump with the SqlInsightBridge loaded.
    Executes a list of REPL commands (default: Bridge.Ping; Latch.Analyze) and
    captures full output for later inspection.
.PARAMETER Dump
    Path to the .mdmp / .dmp file.
.PARAMETER OutDir
    Report output folder (also passed as SQLINSIGHT_OUT).
.PARAMETER Mirror
    Folder containing SqlCsScripts.dll + SqlDebugTypes.dll (passed as SQLINSIGHT_MIRROR).
    Default: C:\Users\lduan\sqlcsi-archive\mirror
.PARAMETER DumpViewerDir
    Folder containing SqlScriptRepl.exe. Default: C:\Users\lduan\tools\DumpViewer
.PARAMETER BridgeDll
    Path to SqlInsightBridge.dll (built via bridge\build.ps1).
.PARAMETER Symbols
    Symbol path. Default: srv*c:\Symbols*https://symweb.azurefd.net
.PARAMETER Commands
    List of REPL commands to send. Default: 'Bridge.Ping','Latch.Analyze'.
.PARAMETER LogFile
    Where to save the full session transcript.
#>
param(
    [Parameter(Mandatory=$true)][string]$Dump,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [string]$Mirror        = 'C:\Users\lduan\sqlcsi-archive\mirror',
    [string]$DumpViewerDir = 'C:\Users\lduan\tools\DumpViewer',
    [string]$BridgeDll     = (Join-Path $PSScriptRoot '..\bridge\SqlInsightBridge.dll'),
    [string]$Symbols       = 'srv*c:\Symbols*https://symweb.azurefd.net',
    [string[]]$Commands    = @('Bridge.Ping','Latch.Analyze'),
    [string]$LogFile
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Dump))         { throw "Dump not found: $Dump" }
if (-not (Test-Path $BridgeDll))    { throw "Bridge DLL not found: $BridgeDll — run bridge\build.ps1 first" }
if (-not (Test-Path $Mirror))       { throw "Mirror folder not found: $Mirror" }
foreach ($n in 'SqlCsScripts.dll','SqlDebugTypes.dll') {
    if (-not (Test-Path (Join-Path $Mirror $n))) { throw "$n missing in mirror folder $Mirror" }
}
$repl = Join-Path $DumpViewerDir 'SqlScriptRepl.exe'
if (-not (Test-Path $repl))         { throw "SqlScriptRepl.exe not found at $repl" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (-not $LogFile) { $LogFile = Join-Path $OutDir 'sqlscriptrepl.out' }

$env:SQLINSIGHT_OUT    = $OutDir
$env:SQLINSIGHT_MIRROR = $Mirror

$input = (($Commands + 'exit') -join "`n") + "`n"
Write-Host "REPL commands to send:" -ForegroundColor Cyan
$Commands | ForEach-Object { "  $_" }

Push-Location $DumpViewerDir
try {
    $input | & $repl -s $Symbols -f $Dump -o $OutDir -scripts $BridgeDll *>&1 > $LogFile
    $code = $LASTEXITCODE
} finally { Pop-Location }

Write-Host "Exit=$code  Log=$LogFile" -ForegroundColor Green

# Quick summary
"----- Key lines -----"
Select-String -Path $LogFile -Pattern 'Discovered|Loaded C:|\[Bridge|\[ERROR\]|Failed|Execute error|Warning|Invoking' |
    ForEach-Object { '{0,5} {1}' -f $_.LineNumber, $_.Line }
