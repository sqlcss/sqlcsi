#requires -Version 5.1
<#
.SYNOPSIS
    Build SqlInsightBridge.dll (netstandard2.0) using dotnet SDK.
.PARAMETER DumpViewerDir
    Folder containing DumpViewer.exe + CsDebugScript.*.dll.
    Default: C:\Users\lduan\tools\DumpViewer
.PARAMETER OutDir
    Where to place the built DLL. Default: same folder as this script.
#>
param(
    [string]$DumpViewerDir = 'C:\Users\lduan\tools\DumpViewer',
    [string]$OutDir        = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
$proj = Join-Path $PSScriptRoot 'SqlInsightBridge.csproj'
& dotnet build $proj -c Release -v minimal "/p:DumpViewerDir=$DumpViewerDir" | Out-Host
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed ($LASTEXITCODE)" }
$built = Join-Path $PSScriptRoot 'bin\Release\SqlInsightBridge.dll'
if (-not (Test-Path $built)) { throw "Build produced no output: $built" }
Copy-Item $built (Join-Path $OutDir 'SqlInsightBridge.dll') -Force
"SqlInsightBridge.dll -> $(Join-Path $OutDir 'SqlInsightBridge.dll')"
