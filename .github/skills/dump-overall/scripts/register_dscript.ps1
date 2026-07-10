<#
.SYNOPSIS
  Per-user (HKCU, no admin / no UAC) registration of the WinDbg DScript COM server,
  so that `!dscript.run <script.js>` works in a non-elevated cdb/windbg session.

.WHY
  DScript hosts 4 COM objects (Object Model Root / Tabular Output / Scripting Host /
  Arguments Collection). cdb refuses to run `!dscript.run` unless those CLSIDs are
  registered. The classic fix registers them in HKLM via an elevated cdb run, but:
    * it needs admin/UAC, and
    * it hard-codes the DScript.dll path of ONE WinDbg package version.
  WinDbg (Store "Slow"/"Fast" channels) auto-updates, which changes the package path
  (e.g. Microsoft.WinDbg.Slow_1.2606.5001.1 -> ..._1.2607.xxxx), breaking the old
  registration -> `DSCRIPT extension is not registered as a COM server`.

  This script instead registers the SAME CLSIDs under HKCU\Software\Classes\CLSID,
  which COM resolves BEFORE HKLM and which needs NO elevation. It auto-detects the
  newest DScript.dll on disk and re-extracts the CLSIDs from the dll itself, so it is
  robust across WinDbg updates. The HKCU keys persist across reboots; just re-run this
  after a WinDbg update if dscript starts failing again.

.USAGE
  pwsh -NoProfile -File register_dscript.ps1
#>

# 1. Locate the newest DScript.dll (prefer amd64) across installed WinDbg packages.
#    NOTE: C:\Program Files\WindowsApps has restrictive ACLs, so a blind -Recurse from
#    its root returns nothing. We instead (A) derive it from a running debugger process,
#    then (B) enumerate Microsoft.WinDbg* package dirs and probe known relative paths.
$candidates = New-Object System.Collections.Generic.List[string]

# Strategy A: a debugger is currently running -> use its package root.
foreach ($pn in 'windbg', 'cdb', 'DbgX.Shell', 'EngHost') {
  Get-Process $pn -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Path) {
      $pkgRoot = Split-Path (Split-Path $_.Path -Parent) -Parent   # ...\<pkg>\amd64\x.exe -> <pkg>
      foreach ($arch in 'amd64', 'x86', 'arm64') {
        $p = Join-Path $pkgRoot (Join-Path $arch 'pri\DScript.dll')
        if (Test-Path $p) { $candidates.Add($p) }
      }
    }
  }
}

# Strategy B: enumerate installed WinDbg packages and probe known relative locations.
$winApps = 'C:\Program Files\WindowsApps'
if (Test-Path $winApps) {
  Get-ChildItem $winApps -Directory -Filter 'Microsoft.WinDbg*' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | ForEach-Object {
      foreach ($arch in 'amd64', 'x86', 'arm64') {
        $p = Join-Path $_.FullName (Join-Path $arch 'pri\DScript.dll')
        if (Test-Path $p) { $candidates.Add($p) }
      }
    }
}

# Strategy C: classic Debugging Tools for Windows (SDK/WDK) install.
$wk = 'C:\Program Files (x86)\Windows Kits'
if (Test-Path $wk) {
  Get-ChildItem $wk -Filter 'DScript.dll' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { $candidates.Add($_.FullName) }
}

$candidates = $candidates | Select-Object -Unique
if (-not $candidates) { throw "DScript.dll not found (looked at running debugger, WindowsApps Microsoft.WinDbg* packages, and Windows Kits)." }

# Prefer the amd64 build, then the most recently written file.
$dll = $candidates |
  ForEach-Object { Get-Item $_ } |
  Sort-Object @{ Expression = { $_.FullName -match '\\amd64\\' }; Descending = $true },
              @{ Expression = { $_.LastWriteTime }; Descending = $true } |
  Select-Object -First 1 -ExpandProperty FullName
Write-Host "DScript.dll => $dll"

# 2. Re-extract the 4 COM CLSIDs from the dll (Unicode strings), so we never hard-code them.
$bytes = [System.IO.File]::ReadAllBytes($dll)
$rx = '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
$txtU = [System.Text.Encoding]::Unicode.GetString($bytes)
$guids = [regex]::Matches($txtU, $rx) | ForEach-Object { $_.Value.ToLower() } | Sort-Object -Unique
if ($guids.Count -lt 1) { throw "No CLSIDs found inside $dll" }
Write-Host "Found $($guids.Count) CLSID(s): $($guids -join ', ')"

# 3. Register each CLSID under HKCU\Software\Classes\CLSID (per-user, no admin).
foreach ($g in $guids) {
  $key = "Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\{$g}\InprocServer32"
  New-Item -Path $key -Force | Out-Null
  New-ItemProperty -Path $key -Name '(default)'      -Value $dll  -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $key -Name 'ThreadingModel' -Value 'Both' -PropertyType String -Force | Out-Null
  Write-Host "registered {$g}"
}

# 4. Verify.
Write-Host '--- verify ---'
foreach ($g in $guids) {
  $key = "Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\{$g}\InprocServer32"
  $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
  Write-Host ("{0}  ->  {1}  (TM={2})" -f $g, $p.'(default)', $p.ThreadingModel)
}
Write-Host ''
Write-Host 'DONE. dscript is now usable in a NON-elevated cdb/windbg session:'
Write-Host '  !dscript.run C:\Tools\dscript\sql2019\<script>.js'
