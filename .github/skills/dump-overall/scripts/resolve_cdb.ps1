<#
.SYNOPSIS
Resolves cdb.exe consistently for SQL-CSI dump workflows.

.DESCRIPTION
Dot-source this file, then call Resolve-CdbPath. Discovery order:
  1. Explicit -Cdb path
  2. WinDbg Store/MSIX packages (Slow, standard, Fast, Preview)
  3. Windows SDK debugger installations
  4. PATH

AppX package registration is authoritative for Store WinDbg. Direct recursive
enumeration of C:\Program Files\WindowsApps is intentionally avoided because its
ACLs can make an installed cdb.exe appear missing.
#>

function Resolve-CdbPath {
    [CmdletBinding()]
    param(
        [string]$Cdb,
        [switch]$Required
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Cdb) { $candidates.Add($Cdb) }

    $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^Microsoft\.WinDbg(?:\.(?:Slow|Fast|Preview))?$' } |
        ForEach-Object {
            $rank = switch ($_.Name) {
                'Microsoft.WinDbg.Slow'    { 0 }
                'Microsoft.WinDbg'         { 1 }
                'Microsoft.WinDbg.Fast'    { 2 }
                'Microsoft.WinDbg.Preview' { 3 }
                default                    { 9 }
            }
            [pscustomobject]@{ Package = $_; Rank = $rank }
        } |
        Sort-Object Rank, @{ Expression = { [version]$_.Package.Version }; Descending = $true })

    foreach ($entry in $packages) {
        if ($entry.Package.InstallLocation) {
            $candidates.Add((Join-Path $entry.Package.InstallLocation 'amd64\cdb.exe'))
            $candidates.Add((Join-Path $entry.Package.InstallLocation 'x64\cdb.exe'))
        }
    }

    foreach ($sdkPath in @(
        "${env:ProgramFiles(x86)}\Windows Kits\11\Debuggers\x64\cdb.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe",
        "${env:ProgramFiles}\Windows Kits\11\Debuggers\x64\cdb.exe",
        "${env:ProgramFiles}\Windows Kits\10\Debuggers\x64\cdb.exe"
    )) {
        if ($sdkPath) { $candidates.Add($sdkPath) }
    }

    $pathCommand = Get-Command cdb.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($pathCommand) { $candidates.Add($pathCommand.Source) }

    $resolved = $candidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        Select-Object -First 1

    if (-not $resolved -and $Required) {
        throw 'cdb.exe not found. Install WinDbg Store/MSIX or Windows SDK Debugging Tools, or pass -Cdb.'
    }

    return $resolved
}
