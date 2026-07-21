# =============================================================================
# split_direct_mirror_log.ps1 — SQL-CSI dump-overall helper
#
# run_windbgcs_direct.ps1 writes one combined cdb log with fences like:
#   == MARKER_SOSRingBuffers.EnumerateExceptionRingRecords ==
#   !execute SOSRingBuffers.EnumerateExceptionRingRecords
#   record | position | ...
#
# build_ringbuf_reports.ps1 does not read that combined log directly; it expects
# one raw capture per expression under txt_detail\ named:
#   {CaseId}_{Expression}.txt
#
# This helper bridges the two contracts. It preserves the raw section text and
# writes one txt_detail file per direct mirror expression so the ring-buffer
# builder can render categorized subreports and inject top-N/anomaly tables into
# the MAIN overall report.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Log,
    [Parameter(Mandatory)][string]$OutDir,
    [Parameter(Mandatory)][string]$CaseId,
    [string[]]$Expressions = @(),
    [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Log)) { throw "direct mirror log not found: $Log" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$wanted = @{}
foreach ($e in $Expressions) {
    if ($e) { $wanted[$e] = $true }
}

$lines = [System.IO.File]::ReadAllLines($Log)
$sections = New-Object System.Collections.ArrayList
$current = $null
$buffer = $null

function Flush-Section {
    param($Section, $Lines, $Sections)
    if ($null -eq $Section) { return }
    [void]$Sections.Add([pscustomobject]@{
        Expr  = $Section
        Lines = @($Lines)
    })
}

foreach ($line in $lines) {
    if ($line -match '== MARKER_([^=]+?) ==') {
        $marker = $Matches[1].Trim()
        if ($line -match '\.echo\s+==\s+MARKER_') {
            continue
        }
        Flush-Section -Section $current -Lines $buffer -Sections $sections
        if ($marker -eq 'DONE') {
            $current = $null
            $buffer = $null
        } else {
            $current = $marker
            $buffer = New-Object System.Collections.ArrayList
            [void]$buffer.Add($line)
        }
        continue
    }
    if ($null -ne $current) { [void]$buffer.Add($line) }
}
Flush-Section -Section $current -Lines $buffer -Sections $sections

$enc = New-Object System.Text.UTF8Encoding($false)
$written = New-Object System.Collections.ArrayList
foreach ($section in $sections) {
    if ($wanted.Count -gt 0 -and -not $wanted.ContainsKey($section.Expr)) { continue }
    $outPath = Join-Path $OutDir ("{0}_{1}.txt" -f $CaseId, $section.Expr)
    if ((Test-Path -LiteralPath $outPath) -and -not $Overwrite) {
        Write-Host "[skip] $($section.Expr) -> $outPath (exists; use -Overwrite)" -ForegroundColor Yellow
        continue
    }
    [System.IO.File]::WriteAllText($outPath, (($section.Lines -join [Environment]::NewLine) + [Environment]::NewLine), $enc)
    $rowCount = ($section.Lines | Where-Object { $_ -match '^0x[0-9a-fA-F]{16}\s*\|' }).Count
    [void]$written.Add([pscustomobject]@{ Expr=$section.Expr; Rows=$rowCount; Path=$outPath })
}

if ($written.Count -eq 0) {
    Write-Host "[split_direct_mirror_log] no sections written from $Log" -ForegroundColor Yellow
} else {
    Write-Host "[split_direct_mirror_log] wrote $($written.Count) section file(s) to $OutDir" -ForegroundColor Green
    $written | Sort-Object Expr | Format-Table Expr,Rows,Path -AutoSize | Out-String | Write-Host
}