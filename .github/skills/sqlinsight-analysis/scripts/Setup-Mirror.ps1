#requires -Version 5.1
<#
.SYNOPSIS
    Set up the "mirror" folder containing SqlCsScripts.dll + SqlDebugTypes.dll
    that the SqlInsightBridge hydrates at runtime.

    Copies the newest version pair found across the well-known symbol/tool
    locations into a single flat folder that we can point SQLINSIGHT_MIRROR at.
#>
param(
    [string]$Destination = 'C:\Users\lduan\sqlcsi-archive\mirror'
)
$ErrorActionPreference = 'Stop'

$candidates = @(
    'C:\Tools\WinDbgCs\NetStandard20Refs\2022',
    'C:\Tools\WinDbgCs\NetStandard20Refs'
) + (Get-ChildItem 'C:\symbols\SqlCsScripts.dll' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

$best = $null
foreach ($dir in $candidates) {
    $cs = Join-Path $dir 'SqlCsScripts.dll'
    $dt = Join-Path $dir 'SqlDebugTypes.dll'
    if ((Test-Path $cs) -and (Test-Path $dt)) {
        $t = ((Get-Item $cs).LastWriteTime, (Get-Item $dt).LastWriteTime | Sort-Object -Descending)[0]
        if ($null -eq $best -or $t -gt $best.Time) { $best = [pscustomobject]@{Dir=$dir; Time=$t} }
    }
}
if ($null -eq $best) { throw "No folder with BOTH SqlCsScripts.dll and SqlDebugTypes.dll found." }

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
Copy-Item (Join-Path $best.Dir 'SqlCsScripts.dll')  $Destination -Force
Copy-Item (Join-Path $best.Dir 'SqlDebugTypes.dll') $Destination -Force
Write-Host "Mirror source: $($best.Dir)  (newest write: $($best.Time))" -ForegroundColor Green
Get-ChildItem $Destination | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
