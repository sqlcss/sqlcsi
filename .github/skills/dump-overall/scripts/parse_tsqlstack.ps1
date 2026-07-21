<#
parse_tsqlstack.ps1 — Split a tsqlstack.js sweep log into per-thread blocks and
extract structured header fields, PRESERVING whatever tsqlstack managed to print
BEFORE a `COM Error Executing Script: 0x80020101` (a.k.a. "Cannot read from
virtual address" — the typical filtered-minidump symptom).

Why this exists
---------------
tsqlstack.js prints its output line-by-line as it walks the CSQLObject →
CCompPlan → CMsqlExecContext → CExecuteStatement → CStatement chain, THEN it
tries to read the T-SQL text (a blob referenced from CStatement) and the
statement parameters (referenced from CMsqlExecContext). On a filtered minidump
those blobs are often paged out, which raises `COM Error 0x80020101` and aborts
the script — but the header (Nest Level / Procedure name / handle addresses /
Executing statement / CExecuteStatement / CStatement) is ALREADY on stdout and
must not be discarded.

Contract
--------
Input log MUST be a `gen_task_sweep.ps1 -Script tsqlstack.js` capture that
delimits each thread with `===TASK_<tid> <ROLE>===` (identical layout to
task.js sweep — same generator).

Output (one JSON file):
  { threads: [
      { tid, role, procedure, nestLevel, statementIndex,
        parentStatementClass, statementClass,
        csqlObject, ccompPlan, cMsqlExecContext,
        cExecuteStatement, cStatement,
        parameters: [ { name, value } ],   // captured before the error
        locals    : [ { name, value } ],   // captured before the error
        comError  : { code, sourceLine, virtualAddress },  // null if OK
        rawBefore : "text captured BEFORE the COM error (safe to embed)",
        rawAll    : "the ENTIRE per-thread block from the sweep log"
      }, ...
    ]
  }

USAGE
-----
  powershell -NoProfile -ExecutionPolicy Bypass `
    -File .github\skills\dump-overall\scripts\parse_tsqlstack.ps1 `
    -Log '<case>_tsqlstack.txt' -Out '<case>_tsqlstack.json'

Then generators (or the agent) can consume the JSON and, on `comError != null`,
render `rawBefore` in the report card INSTEAD of substituting a "语句文本未捕获"
placeholder — the header is still gold, only the T-SQL body is missing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Log,
    [Parameter(Mandatory)][string]$Out
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Log)) { throw "log not found: $Log" }

$lines = Get-Content -LiteralPath $Log -Encoding UTF8

# ---- Split into ===TASK_<tid> <ROLE>=== blocks (same delimiter as task.js sweep)
$blocks = @()
$cur = $null
foreach ($ln in $lines) {
    if ($ln -match '^===TASK_(\d+)\s+([A-Za-z][A-Za-z0-9_\-]*)===\s*$') {
        if ($cur) { $blocks += ,$cur }
        $cur = [ordered]@{ tid=[int]$Matches[1]; role=$Matches[2]; body=New-Object System.Collections.Generic.List[string] }
        continue
    }
    if ($cur) { $cur.body.Add($ln) | Out-Null }
}
if ($cur) { $blocks += ,$cur }

# ---- Parse one block ----------------------------------------------------------
function Parse-Block {
    param($b)

    $body = @($b.body)
    $r = [ordered]@{
        tid                  = $b.tid
        role                 = $b.role
        procedure            = $null
        nestLevel            = $null
        statementIndex       = $null
        parentStatementClass = $null   # ( CXStmtDML ) etc — from CExecuteStatement line
        statementClass       = $null   # ( CStmtInsert ) etc — from CStatement line
        csqlObject           = $null
        ccompPlan            = $null
        cMsqlExecContext     = $null
        cExecuteStatement    = $null
        cStatement           = $null
        parameters           = @()
        locals               = @()
        comError             = $null
        timeout              = $null
        rawBefore            = $null
        rawAll               = ($body -join "`r`n")
    }

    # Walk lines; capture header fields, and stop appending to rawBefore
    # as soon as we hit the FIRST `COM Error Executing Script:` line.
    $preErr = New-Object System.Collections.Generic.List[string]
    $sawErr = $false
    $errCode = $null; $errVA = $null; $errLine = $null

    for ($i=0; $i -lt $body.Count; $i++) {
        $ln = $body[$i]

        if (-not $sawErr) { [void]$preErr.Add($ln) }

        if ($ln -match '^Nest Level\s*:\s*(\d+)')                  { $r.nestLevel      = [int]$Matches[1]; continue }
        if ($ln -match '^Procedure name\s*:\s*(.+?)\s*$')          { $r.procedure      = $Matches[1].Trim(); continue }
        if ($ln -match '^CSQLObject\s*:\s*([0-9A-Fa-f]+)')         { $r.csqlObject     = $Matches[1]; continue }
        if ($ln -match '^CCompPlan\s*:\s*([0-9A-Fa-f]+)')          { $r.ccompPlan      = $Matches[1]; continue }
        if ($ln -match '^CMsqlExecContext\s*:\s*([0-9A-Fa-f]+)')   { $r.cMsqlExecContext = $Matches[1]; continue }
        if ($ln -match '^Executing statement\s*:\s*0n(\d+)')       { $r.statementIndex = [int]$Matches[1]; continue }
        # CExecuteStatement:  <addr> ( <ClassName> )
        if ($ln -match '^\s*CExecuteStatement\s*:\s*([0-9A-Fa-f]+)\s*\(\s*([A-Za-z0-9_]+)\s*\)') {
            $r.cExecuteStatement    = $Matches[1]
            $r.parentStatementClass = $Matches[2]
            continue
        }
        # CStatement:  <addr> ( <ClassName> )
        if ($ln -match '^\s*CStatement\s*:\s*([0-9A-Fa-f]+)\s*\(\s*([A-Za-z0-9_]+)\s*\)') {
            $r.cStatement     = $Matches[1]
            $r.statementClass = $Matches[2]
            continue
        }
        # Parameter <n>: <name> = [<value>]
        if ($ln -match '^Parameter\s+\d+\s*:\s*(@\w+)\s*=\s*\[(.*)\]\s*$') {
            $r.parameters += ,([ordered]@{ name=$Matches[1]; value=$Matches[2] })
            continue
        }
        # Local <n>: <name> = [<value>]
        if ($ln -match '^Local\s+\d+\s*:\s*(@\w+)\s*=\s*\[(.*)\]\s*$') {
            $r.locals += ,([ordered]@{ name=$Matches[1]; value=$Matches[2] })
            continue
        }
        # COM error markers — first hit wins.
        if (-not $sawErr -and $ln -match 'COM Error Executing Script:\s*(0x[0-9A-Fa-f]+)') {
            $sawErr = $true
            $errCode = $Matches[1]
            # Drop the COM-error line itself from rawBefore (it's noise for the reader).
            if ($preErr.Count -gt 0) { $preErr.RemoveAt($preErr.Count-1) | Out-Null }
            continue
        }
        if ($sawErr -and $ln -match 'Cannot read from virtual address\s*\[\s*0x([0-9A-Fa-f]+)\s*\]') {
            $errVA = '0x' + $Matches[1]
            continue
        }
        if ($sawErr -and $ln -match 'Review Script Line\s*:\s*(\d+)') {
            $errLine = [int]$Matches[1]
            continue
        }
        if ($ln -match '^DSCRIPT_(?:SHARD_)?TIMEOUT\s+script=([^\s]+)\s+timeoutSec=(\d+)') {
            $r.timeout = [ordered]@{
                script = $Matches[1]
                timeoutSec = [int]$Matches[2]
            }
            continue
        }
    }

    if ($sawErr) {
        $r.comError = [ordered]@{
            code           = $errCode
            virtualAddress = $errVA
            sourceLine     = $errLine
        }
    }

    # rawBefore = trimmed, blank-lines collapsed, script banners removed.
    $clean = @($preErr) | Where-Object { $_ -notmatch '^\s*-{5,}\s*$' -and $_ -notmatch '^-{3,}\s*Script (Starting|Complete)\s*-{3,}\s*$' }
    # Trim trailing blank lines
    while ($clean.Count -gt 0 -and [string]::IsNullOrWhiteSpace($clean[-1])) {
        if ($clean.Count -eq 1) { $clean = @(); break }
        $clean = $clean[0..($clean.Count-2)]
    }
    $r.rawBefore = ($clean -join "`r`n").TrimEnd()

    return $r
}

$threads = @()
foreach ($b in $blocks) { $threads += ,(Parse-Block -b $b) }

$json = [ordered]@{
    log     = (Resolve-Path -LiteralPath $Log).Path
    threads = $threads
} | ConvertTo-Json -Depth 8

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
[System.IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding($false)))

$okCount   = ($threads | Where-Object { -not $_.comError -and -not $_.timeout }).Count
$partCount = ($threads | Where-Object {      $_.comError }).Count
$timeoutCount = ($threads | Where-Object { $_.timeout }).Count
Write-Host "[parse_tsqlstack] threads=$($threads.Count)  ok=$okCount  partial(COM 0x80020101)=$partCount  timeout=$timeoutCount  -> $Out"
foreach ($t in $threads) {
    $tag = if ($t.timeout) { "TIMEOUT($($t.timeout.timeoutSec)s)" } elseif ($t.comError) { "PARTIAL($($t.comError.code)@VA=$($t.comError.virtualAddress))" } else { 'OK' }
    Write-Host ("  tid={0,-6} role={1,-6} proc={2,-40} nest={3} stmt#={4} class={5} {6}" -f `
        $t.tid, $t.role, $t.procedure, $t.nestLevel, $t.statementIndex, $t.statementClass, $tag)
}
