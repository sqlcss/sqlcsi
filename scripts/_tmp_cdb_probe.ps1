$ErrorActionPreference = 'Continue'
$out = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_latch_timeout\_cdb_probe.txt'
$lines = @()
$c = (Get-Command cdb.exe -ErrorAction SilentlyContinue).Source
$lines += "get-command cdb.exe -> $c"
$wdbg = (Get-AppxPackage *WinDbg* -ErrorAction SilentlyContinue | Select-Object -First 1)
$lines += "AppxPackage WinDbg -> Name=$($wdbg.Name), Loc=$($wdbg.InstallLocation)"
if ($wdbg) {
    $found = Get-ChildItem $wdbg.InstallLocation -Recurse -Filter cdb.exe -ErrorAction SilentlyContinue
    foreach ($f in $found) { $lines += "cdb-found: $($f.FullName)" }
}
# Also try tools dir
foreach ($p in @('C:\Users\lduan\tools','C:\Debuggers','C:\dbg')) {
    if (Test-Path $p) {
        $found = Get-ChildItem $p -Recurse -Filter cdb.exe -ErrorAction SilentlyContinue
        foreach ($f in $found) { $lines += "tools-cdb: $($f.FullName)" }
    }
}
# check both program files paths
foreach ($p in @('C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe',
                 'C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe',
                 'C:\Program Files (x86)\Windows Kits\11\Debuggers\x64\cdb.exe')) {
    $lines += "check: $p exists=$((Test-Path $p))"
}
# Test if WinDbg AppExecutionAlias exists
foreach ($a in @('C:\Users\lduan\AppData\Local\Microsoft\WindowsApps\cdb.exe',
                 'C:\Users\lduan\AppData\Local\Microsoft\WindowsApps\windbg.exe',
                 'C:\Users\lduan\AppData\Local\Microsoft\WindowsApps\WinDbgX.exe')) {
    $lines += "alias: $a exists=$((Test-Path $a))"
}
# Also scan AppxPackages location for WinDbg
$appxRoot = 'C:\Program Files\WindowsApps'
if (Test-Path $appxRoot) {
    Get-ChildItem $appxRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'WinDbg' } | ForEach-Object {
        $lines += "appx-dir: $($_.FullName)"
    }
}
[System.IO.File]::WriteAllLines($out, $lines)
Write-Host "wrote $out"
Get-Content $out
