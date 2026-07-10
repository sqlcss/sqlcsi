# build_sqlscriptrepl.ps1 - compile SqlScriptRepl.cs into SqlScriptRepl.exe (inside the
# DumpViewer folder). Self-locating: uses the SqlScriptRepl.cs sitting next to THIS script.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File build_sqlscriptrepl.ps1 `
#     [-DumpViewerDir 'C:\Users\lduan\tools\DumpViewer']
#
# Notes (see repo memory sql_script_repl.md):
#   - in-box Framework csc (C# 5); output goes INTO the DumpViewer folder (needs its
#     version-matched CsDebugScript.* siblings at runtime).
#   - MUST reference the netstandard.dll facade or CS0012 (CsDebugScript.Utils is netstandard2.0).
param(
    [string] $DumpViewerDir = 'C:\Users\lduan\tools\DumpViewer'
)
$ErrorActionPreference = 'Stop'

$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "csc not found: $csc" }

$src = Join-Path $PSScriptRoot 'SqlScriptRepl.cs'
if (-not (Test-Path $src)) { throw "source not found next to this script: $src" }

$dv  = $DumpViewerDir
if (-not (Test-Path (Join-Path $dv 'DumpViewer.exe'))) { throw "DumpViewer.exe not found in: $dv" }
$out = Join-Path $dv 'SqlScriptRepl.exe'

$netstd = 'C:\Program Files\dotnet\sdk\10.0.301\Microsoft\Microsoft.NET.Build.Extensions\net461\lib\netstandard.dll'
if (-not (Test-Path $netstd)) { $netstd = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\netstandard.dll' }

$refs = @(
    (Join-Path $dv 'DumpViewer.exe'),
    (Join-Path $dv 'CsDebugScript.Common.dll'),
    (Join-Path $dv 'CsDebugScript.Utils.dll'),
    $netstd
)
$refArgs = $refs | ForEach-Object { '/r:' + $_ }
$allArgs = @('/nologo', '/platform:x64', '/target:exe', ('/out:' + $out)) + $refArgs + @($src)

Write-Host "csc args:"; $allArgs | ForEach-Object { Write-Host "  $_" }
& $csc @allArgs 2>&1 | ForEach-Object { Write-Host $_ }
Write-Host "=== csc exit $LASTEXITCODE ==="
if (Test-Path $out) { Write-Host ("BUILT: {0} ({1} bytes)" -f $out, (Get-Item $out).Length) }
else { throw "OUTPUT MISSING - build failed" }
