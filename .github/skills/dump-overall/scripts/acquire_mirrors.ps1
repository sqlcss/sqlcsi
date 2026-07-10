# =============================================================================
# acquire_mirrors.ps1 — SQL-CSI dump-overall Step 1 fallback
#
# When `!dcs_initsymsvr sqlservr` 404s (e.g. SQL 2019 CU20), auto-copy the
# build-matched Mirror pair (SqlDebugTypes.dll + SqlCsScripts.dll) from the
# released-build share into `{wdbgcs}\NetStandard20Refs`, then verify the pair
# is present.
#
# EXIT CODES: 0 = both DLLs present (whether just copied or already there);
#             1 = copy failed / pair missing on exit.
# =============================================================================
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Wdbgcs,                  # e.g. C:\Tools\WinDbgCs
  [Parameter(Mandatory)][string]$Build,                   # e.g. 15.0.4312.2  — RESOLVE from `lmDvm sqlservr`, don't guess
  [ValidateSet('SQLServer2019','SQLServer2022','SQLServer2016','SQLServer2017')]
  [string]$Product = 'SQLServer2019',
  [string]$Share   = $null,                               # override; default derived from -Product+Build
  [switch]$Force                                          # re-copy even if pair present
)

$ErrorActionPreference = 'Stop'

$dst = Join-Path $Wdbgcs 'NetStandard20Refs'
if (-not (Test-Path $Wdbgcs))           { throw "wdbgcs not found: $Wdbgcs" }
if (-not (Test-Path $dst))              { New-Item -ItemType Directory -Force -Path $dst | Out-Null }

$pair = 'SqlDebugTypes.dll','SqlCsScripts.dll'

$needCopy = $Force -or ($pair | Where-Object { -not (Test-Path (Join-Path $dst $_)) })
if (-not $needCopy) {
    Write-Host "[acquire_mirrors] pair already present in $dst — nothing to do (use -Force to re-copy)" -ForegroundColor Green
    Write-Host ("[acquire_mirrors] SqlCsScripts.dll={0}  SqlDebugTypes.dll={1}" -f `
        (Test-Path "$dst\SqlCsScripts.dll"), (Test-Path "$dst\SqlDebugTypes.dll"))
    exit 0
}

if (-not $Share) {
    $Share = "\\sqlbuilds\released\$Product\RTM\Hotfixes\$Build\bin\retail\x64"
}
Write-Host "[acquire_mirrors] source share : $Share"
Write-Host "[acquire_mirrors] target folder: $dst"

if (-not (Test-Path $Share)) {
    Write-Host "[acquire_mirrors] ERROR: share not reachable — VPN/permissions? Path: $Share" -ForegroundColor Red
    exit 1
}

foreach ($f in $pair) {
    $src = Join-Path $Share $f
    $tgt = Join-Path $dst   $f
    if ((Test-Path $tgt) -and -not $Force) {
        Write-Host "[acquire_mirrors] SKIP  $f (already present)"
        continue
    }
    if (-not (Test-Path $src)) {
        Write-Host "[acquire_mirrors] ERROR: missing on share: $src" -ForegroundColor Red
        exit 1
    }
    Copy-Item $src $tgt -Force
    Write-Host ("[acquire_mirrors] COPY  {0}  ({1} bytes)" -f $f, (Get-Item $tgt).Length) -ForegroundColor Cyan
}

$okA = Test-Path "$dst\SqlCsScripts.dll"
$okB = Test-Path "$dst\SqlDebugTypes.dll"
Write-Host ("[acquire_mirrors] verify: SqlCsScripts.dll={0}  SqlDebugTypes.dll={1}" -f $okA, $okB) -ForegroundColor (($okA -and $okB) ? 'Green' : 'Red')
if ($okA -and $okB) { exit 0 } else { exit 1 }
