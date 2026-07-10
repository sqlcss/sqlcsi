param(
  [string]$Script = 'C:\Tools\dscript\sql2022\scripts\scripts\se_am_datasetsession_latches.js',
  [string]$Name   = 'se_am_datasetsession_latches'
)
$ErrorActionPreference = 'Stop'
$case   = '2607030030000843'
$dump   = 'C:\Temp\2607030030000843\SQLDump0001.mdmp'
$outDir = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall\txt_detail'
$log    = Join-Path $outDir "${case}_${Name}.txt"
$console= Join-Path $outDir "${case}_${Name}.console.txt"
$wds    = Join-Path $env:TEMP "_run_${Name}.wds"

# ---- resolve cdb.exe (Store WinDbg via AppxPackage; WindowsApps ACL blocks glob enumeration) ----
$cdb = (Get-Command cdb.exe -ErrorAction SilentlyContinue).Source
if (-not $cdb) {
  foreach ($p in @("${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe","${env:ProgramFiles}\Windows Kits\10\Debuggers\x64\cdb.exe")) {
    if (Test-Path $p) { $cdb = $p; break }
  }
}
if (-not $cdb) {
  $appx = Get-AppxPackage *WinDbg* -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
  if ($appx) { $c = Join-Path $appx.InstallLocation 'amd64\cdb.exe'; if (Test-Path $c) { $cdb = $c } }
}
if (-not $cdb) { throw "cdb.exe not found" }
foreach ($p in @($cdb,$dump,$Script)) { if (-not (Test-Path $p)) { throw "missing: $p" } }
Write-Host "cdb    = $cdb"
Write-Host "script = $Script"
Write-Host "log    = $log"

$wdsBody = @(
  ".logopen `"$log`""
  ".echo ===${Name}_BEGIN==="
  "!dscript.run $Script"
  ".echo ===${Name}_END==="
  ".logclose"
  "q"
) -join "`r`n"
[IO.File]::WriteAllText($wds, $wdsBody, (New-Object Text.UTF8Encoding($false)))

& $cdb -y 'srv*C:\Symbols*https://symweb.azurefd.net' -z $dump -c "`$`$><$wds" *> $console
Write-Host "cdb exit = $LASTEXITCODE"
Write-Host "===== $Name LOG ====="
if (Test-Path $log) { Get-Content $log -Raw } else { Write-Host "(no log)"; Get-Content $console -Tail 40 }
