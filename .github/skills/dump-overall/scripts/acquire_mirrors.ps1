# =============================================================================
# acquire_mirrors.ps1 — SQL-CSI dump-overall Step 1 fallback
#
# When `!dcs_initsymsvr sqlservr` 404s (e.g. SQL 2019 CU20), auto-copy the
# build-matched Mirror pair (SqlDebugTypes.dll + SqlCsScripts.dll) from the
# released-build share, or from the case folder when the case package contains
# the pair, into `{wdbgcs}\NetStandard20Refs\build_<version>`, then verify it.
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
    [string]$CaseDir = $null,                                # optional folder containing SqlCsScripts.dll / SqlDebugTypes.dll
  [switch]$Force                                          # re-copy even if pair present
)

$ErrorActionPreference = 'Stop'

$dst = Join-Path $Wdbgcs ("NetStandard20Refs\build_{0}" -f $Build)
if (-not (Test-Path $Wdbgcs))           { throw "wdbgcs not found: $Wdbgcs" }
if (-not (Test-Path $dst))              { New-Item -ItemType Directory -Force -Path $dst | Out-Null }

$pair = 'SqlDebugTypes.dll','SqlCsScripts.dll'
$optional = 'SqlDebugTypesPartial.cs'

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
if ($CaseDir) { Write-Host "[acquire_mirrors] case folder  : $CaseDir" }
Write-Host "[acquire_mirrors] target folder: $dst"

$sourceDir = $null
if (Test-Path $Share) {
    $sourceDir = $Share
} elseif ($CaseDir -and (Test-Path $CaseDir) -and ($pair | Where-Object { Test-Path (Join-Path $CaseDir $_) }).Count -eq $pair.Count) {
    $sourceDir = $CaseDir
    Write-Host "[acquire_mirrors] share not reachable; using build-matched mirror pair from case folder" -ForegroundColor Yellow
} else {
    Write-Host "[acquire_mirrors] ERROR: no mirror source found. Share unreachable/missing and case folder does not contain the pair." -ForegroundColor Red
    Write-Host "  share: $Share" -ForegroundColor Red
    if ($CaseDir) { Write-Host "  case : $CaseDir" -ForegroundColor Red }
    exit 1
}

foreach ($f in $pair) {
    $src = Join-Path $sourceDir $f
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

$partialSrc = Join-Path $sourceDir $optional
if (Test-Path $partialSrc) {
    Copy-Item $partialSrc (Join-Path $dst $optional) -Force
    Write-Host ("[acquire_mirrors] COPY  {0}  ({1} bytes)" -f $optional, (Get-Item (Join-Path $dst $optional)).Length) -ForegroundColor Cyan
}

$okA = Test-Path "$dst\SqlCsScripts.dll"
$okB = Test-Path "$dst\SqlDebugTypes.dll"
Write-Host ("[acquire_mirrors] verify: SqlCsScripts.dll={0}  SqlDebugTypes.dll={1}" -f $okA, $okB) -ForegroundColor (($okA -and $okB) ? 'Green' : 'Red')
if ($okA -and $okB) { exit 0 } else { exit 1 }
