[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$LogFile,
    [Parameter(Mandatory)][string]$OutWds,
    [Parameter(Mandatory)][string]$Dump,
    [string]$SymPath = 'srv*C:\Symbols*https://symweb.azurefd.net',
    [string]$Cdb,
    [string]$EndMarker = 'END DSCRIPT ONCE',
    [int]$TimeoutSec = 300
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "script not found: $ScriptPath" }
if (-not (Test-Path -LiteralPath $Dump)) { throw "dump not found: $Dump" }
if (-not $Cdb) {
    $Cdb = (Get-Item 'C:\Program Files\WindowsApps\Microsoft.WinDbg.*_x64__8wekyb3d8bbwe\amd64\cdb.exe' -ErrorAction SilentlyContinue |
            Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName)
    if (-not $Cdb) {
        $pkg = Get-AppxPackage '*WinDbg*' -ErrorAction SilentlyContinue | Sort-Object InstallLocation | Select-Object -Last 1
        if ($pkg -and $pkg.InstallLocation) {
            $candidate = Join-Path $pkg.InstallLocation 'amd64\cdb.exe'
            if (Test-Path -LiteralPath $candidate) { $Cdb = $candidate }
        }
    }
}
if (-not $Cdb -or -not (Test-Path -LiteralPath $Cdb)) { throw "cdb.exe not found - pass -Cdb" }
if ($TimeoutSec -le 0) { throw "-TimeoutSec must be > 0" }

$dir = Split-Path -Parent $OutWds
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
if (Test-Path -LiteralPath $LogFile) { Remove-Item -LiteralPath $LogFile -Force }
$console = [System.IO.Path]::ChangeExtension($OutWds, 'console.txt')
$err = [System.IO.Path]::ChangeExtension($OutWds, 'err.txt')

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine(".logopen $LogFile")
[void]$sb.AppendLine("!dscript.run $ScriptPath")
[void]$sb.AppendLine(".echo ##### $EndMarker #####")
[void]$sb.AppendLine('.logclose')
[void]$sb.AppendLine('q')
[System.IO.File]::WriteAllText($OutWds, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))

Write-Host "[run_dscript_once] cdb : $Cdb"
Write-Host "[run_dscript_once] wds : $OutWds"
Write-Host "[run_dscript_once] log : $LogFile"
$proc = Start-Process -FilePath $Cdb -ArgumentList @('-y', $SymPath, '-z', $Dump, '-c', "`$`$><$OutWds", '-G', '-lines') -RedirectStandardOutput $console -RedirectStandardError $err -WindowStyle Hidden -PassThru
$completed = $false
$reachedEnd = $false
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
do {
    if ($proc.WaitForExit(1000)) { $completed = $true; break }
    if ((Test-Path -LiteralPath $LogFile) -and (Select-String -LiteralPath $LogFile -Pattern ([Regex]::Escape($EndMarker)) -Quiet)) {
        $reachedEnd = $true
        break
    }
} while ([DateTime]::UtcNow -lt $deadline)

if (-not $completed -and $reachedEnd) {
    try { $proc.Kill() } catch {}
    $completed = $true
    Write-Host "[run_dscript_once] reached end marker but cdb stayed open; killed prompt" -ForegroundColor Yellow
}
if (-not $completed) {
    try { $proc.Kill() } catch {}
    Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value "##### DSCRIPT_ONCE_TIMEOUT timeoutSec=$TimeoutSec #####"
    Write-Host "[run_dscript_once] TIMEOUT after ${TimeoutSec}s" -ForegroundColor Yellow
}

$exists = Test-Path -LiteralPath $LogFile
$size = if ($exists) { (Get-Item -LiteralPath $LogFile).Length } else { 0 }
$hasEnd = if ($exists) { [bool](Select-String -LiteralPath $LogFile -Pattern ([Regex]::Escape($EndMarker)) -Quiet) } else { $false }
[pscustomobject]@{ log=$LogFile; exists=$exists; size=$size; endMarker=$hasEnd; completed=$completed; reachedEnd=$reachedEnd } | ConvertTo-Json -Depth 3 | Write-Host
if (-not $exists -or $size -eq 0) { exit 1 }
if (-not $hasEnd) { exit 2 }
exit 0
