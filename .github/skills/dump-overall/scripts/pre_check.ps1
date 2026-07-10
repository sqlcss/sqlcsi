<#
pre_check.ps1 — Step 0 tooling verification for dump-overall skill (DumpViewer-first).

Verifies the user-provided tool paths exist. Requirement model matches the DumpViewer-first
architecture:
  -DumpPath      Path to the dump file (.mdmp / .dmp)            REQUIRED (hard fail)
  -DscriptPath   Folder holding task.js / tsqlstack.js           REQUIRED (第三步 always + FALLBACK)
  -DumpViewer    Folder holding DumpViewer.exe                   PRIMARY  (warn if missing → FALLBACK)
  -MexPath       Folder holding mex.dll                          FALLBACK (warn; !mex.us 第一步)
  -Wdbgcs        Folder holding WinDbgCsExt.dll + NetStandard20Refs\{SqlCsScripts,SqlDebugTypes}.dll
                                                                 FALLBACK (warn; Tasks.Enumerate + 4 missing rings)

Prints one line per surface:
    <surface> : OK   (<path>)
    <surface> : MISSING (<expected file>)   — ASK USER / mode note

Exits 0 iff every REQUIRED surface (dump / DScript) is OK.
Exit 1 if any REQUIRED surface is MISSING.
DumpViewer is PRIMARY: MISSING is a warning (run can proceed in FALLBACK mode).
mex.dll / WinDbgCsExt / Mirrors are FALLBACK: MISSING is a warning (only needed if DumpViewer fails).

USAGE (all params come from the P1 answers — the agent MUST ask the user first):
    .\pre_check.ps1 `
        -DumpPath    'C:\...\SQLDump0001.mdmp' `
        -DumpViewer  'C:\Users\lduan\tools\DumpViewer' `
        -DscriptPath 'C:\Tools\dscript\sql2019' `
        [-MexPath    'C:\Tools\mex'] `
        [-Wdbgcs     'C:\Tools\WinDbgCs']
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DumpPath,
    [Parameter(Mandatory)][string]$DscriptPath,
    [string]$DumpViewer = '',
    [string]$MexPath    = '',
    [string]$Wdbgcs     = ''
)

$ErrorActionPreference = 'Stop'
$fail = $false

function Report([string]$label, [bool]$ok, [string]$detail, [string]$tier = 'REQUIRED') {
    if ($ok) {
        Write-Host ("{0,-14}: OK        ({1})" -f $label, $detail)
    } else {
        switch ($tier) {
            'PRIMARY'  { Write-Host ("{0,-14}: MISSING   ({1}) — PRIMARY missing → run in FALLBACK mode (or ASK USER)" -f $label, $detail) }
            'FALLBACK' { Write-Host ("{0,-14}: MISSING   ({1}) — FALLBACK only (needed if DumpViewer fails)" -f $label, $detail) }
            default    { Write-Host ("{0,-14}: MISSING   ({1}) — ASK USER" -f $label, $detail); $script:fail = $true }
        }
    }
}

# --- Required ---------------------------------------------------------------
Report 'dump'        (Test-Path -LiteralPath $DumpPath -PathType Leaf) $DumpPath 'REQUIRED'

$taskJs = Join-Path $DscriptPath 'task.js'
Report 'DScript .js' (Test-Path -LiteralPath $taskJs -PathType Leaf) $taskJs 'REQUIRED'

# --- PRIMARY (DumpViewer-first) ---------------------------------------------
if ($DumpViewer) {
    $dvExe = Join-Path $DumpViewer 'DumpViewer.exe'
    Report 'DumpViewer'  (Test-Path -LiteralPath $dvExe -PathType Leaf) $dvExe 'PRIMARY'
} else {
    Report 'DumpViewer'  $false '(no -DumpViewer given)' 'PRIMARY'
}

# --- FALLBACK (only if DumpViewer fails / unsupported build) -----------------
if ($MexPath) {
    $mexDll = Join-Path $MexPath 'mex.dll'
    Report 'mex.dll'     (Test-Path -LiteralPath $mexDll -PathType Leaf) $mexDll 'FALLBACK'
}
if ($Wdbgcs) {
    $wdbgcsExt = Join-Path $Wdbgcs 'WinDbgCsExt.dll'
    Report 'WinDbgCsExt' (Test-Path -LiteralPath $wdbgcsExt -PathType Leaf) $wdbgcsExt 'FALLBACK'

    $mirrorsDir = Join-Path $Wdbgcs 'NetStandard20Refs'
    $mirrorsOk  = (Test-Path -LiteralPath (Join-Path $mirrorsDir 'SqlCsScripts.dll') -PathType Leaf) -and
                  (Test-Path -LiteralPath (Join-Path $mirrorsDir 'SqlDebugTypes.dll') -PathType Leaf)
    Report 'Mirrors pair' $mirrorsOk "$mirrorsDir\{SqlCsScripts,SqlDebugTypes}.dll" 'FALLBACK'
}

if ($fail) { exit 1 } else { exit 0 }
