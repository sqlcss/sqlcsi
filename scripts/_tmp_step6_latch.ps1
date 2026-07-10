$ErrorActionPreference = 'Stop'
$case   = '2607030030000843'
$dump   = 'C:\Temp\2607030030000843\SQLDump0001.mdmp'
$script = 'C:\Tools\dscript\sql2022\scripts\scripts\dump_latch_contended_pages.js'
$outDir = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall\txt_detail'
$log    = Join-Path $outDir "${case}_dump_latch_contended_pages.txt"
$console= Join-Path $outDir "${case}_latch.console.txt"
$wds    = Join-Path $env:TEMP "_step6_latch.wds"

# ---- resolve cdb.exe ----
$cdb = $null
$cands = @(
  (Get-Command cdb.exe -ErrorAction SilentlyContinue).Source,
  "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe",
  "${env:ProgramFiles}\Windows Kits\10\Debuggers\x64\cdb.exe"
)
foreach ($c in $cands) { if ($c -and (Test-Path $c)) { $cdb = $c; break } }
if (-not $cdb) {
  $appx = Get-AppxPackage *WinDbg* -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
  if ($appx) {
    $p = Join-Path $appx.InstallLocation 'amd64\cdb.exe'
    if (Test-Path $p) { $cdb = $p }
  }
}
if (-not $cdb) {
  foreach ($g in @(
      'C:\Program Files\WindowsApps\Microsoft.WinDbg.Slow_*_x64__8wekyb3d8bbwe\amd64\cdb.exe',
      'C:\Program Files\WindowsApps\Microsoft.WinDbg.Fast_*_x64__8wekyb3d8bbwe\amd64\cdb.exe',
      'C:\Program Files\WindowsApps\Microsoft.WinDbg.Preview_*_x64__8wekyb3d8bbwe\amd64\cdb.exe',
      'C:\Program Files\WindowsApps\Microsoft.WinDbg_*_x64__8wekyb3d8bbwe\amd64\cdb.exe',
      'C:\Program Files\WindowsApps\Microsoft.WinDbg*\amd64\cdb.exe')) {
    $hit = Get-Item $g -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($hit) { $cdb = $hit.FullName; break }
  }
}
if (-not $cdb) { throw "cdb.exe not found" }
Write-Host "cdb    = $cdb"
Write-Host "dump   = $dump  (exists=$(Test-Path $dump))"
Write-Host "script = $script (exists=$(Test-Path $script))"
Write-Host "log    = $log"

# ---- build .wds (own logopen/logclose; q on last line; no `$$` comments so single `$><` on the .wds itself; we use $$>< block anyway) ----
$wdsBody = @(
  ".logopen `"$log`""
  ".echo ===STEP6_LATCH_BEGIN==="
  "!dscript.run $script"
  ".echo ===STEP6_LATCH_END==="
  ".logclose"
  "q"
) -join "`r`n"
[IO.File]::WriteAllText($wds, $wdsBody, (New-Object Text.UTF8Encoding($false)))
Write-Host "--- wds ---"; Get-Content $wds | ForEach-Object { "  $_" }

# ---- run cdb headless ----
& $cdb -y 'srv*C:\Symbols*https://symweb.azurefd.net' -z $dump -c "`$`$><$wds" *> $console
Write-Host "cdb exit = $LASTEXITCODE"
Write-Host "===== LATCH LOG ====="
if (Test-Path $log) { Get-Content $log -Raw } else { Write-Host "(no log produced)"; Write-Host "--- console tail ---"; Get-Content $console -Tail 40 }
