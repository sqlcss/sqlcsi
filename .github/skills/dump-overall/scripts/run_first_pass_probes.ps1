# run_first_pass_probes.ps1
# POST-OVERALL phase only. It never edits or revalidates the completed overall report.
# Individual probe failures are converted to unavailable-with-evidence and do not fail Gate A.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Dump,
    [Parameter(Mandatory)][string]$OutDir,
    [Parameter(Mandatory)][string]$CaseId,
    [string]$Wdbgcs = 'C:\Tools\WinDbgCs',
    [string]$SymPath = 'srv*C:\Symbols*https://symweb.azurefd.net',
    [string]$Cdb,
    [string]$OverallReceipt = '',
    [int]$TimeoutSec = 1800
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'resolve_cdb.ps1')
if (-not $OverallReceipt) { $OverallReceipt = Join-Path $OutDir 'overall_completion_receipt.json' }
if (-not (Test-Path -LiteralPath $Dump -PathType Leaf)) { throw "dump not found: $Dump" }
if (-not (Test-Path -LiteralPath $OverallReceipt -PathType Leaf)) { throw "overall completion receipt missing: $OverallReceipt" }
$receipt = Get-Content -LiteralPath $OverallReceipt -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$receipt.status -ne 'PASS') { throw "overall completion receipt is not PASS: $OverallReceipt" }
$overallPath = Join-Path $OutDir ([string]$receipt.overallReport)
if (-not (Test-Path -LiteralPath $overallPath -PathType Leaf) -or (Get-Item -LiteralPath $overallPath).Length -eq 0) {
    throw "completed overall report missing or empty: $overallPath"
}
if ($receipt.PSObject.Properties.Name -contains 'overallSha256') {
    $actualOverallHash = (Get-FileHash -LiteralPath $overallPath -Algorithm SHA256).Hash
    if ($actualOverallHash -ne [string]$receipt.overallSha256) {
        throw "overall report hash differs from Gate A receipt: $overallPath"
    }
}
$ext = Join-Path $Wdbgcs 'WinDbgCsExt.dll'
if (-not (Test-Path -LiteralPath $ext -PathType Leaf)) { throw "WinDbgCsExt.dll missing: $ext" }
$Cdb = Resolve-CdbPath -Cdb $Cdb -Required
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$required = @(
    'Times.Enumerate',
    'TraceFlags.Enumerate',
    'Sessions.Enumerate',
    'Tasks.Enumerate',
    'Workers.Enumerate',
    'Schedulers.Enumerate',
    'MemoryNodes.Enumerate',
    'SOSNodes.Enumerate',
    'SOSRingBuffers.EnumerateExceptionRingRecords',
    'ExceptionContext.CurrentStack',
    'ExceptionContext.Enumerate',
    'ExceptionHandlerStacks.Enumerate'
)
$optional = @(
    'MemoryClerks.Enumerate',
    'MemoryObjects.Enumerate',
    'LeakedAllocations.Enumerate',
    'DbccInputBuffers.Enumerate',
    'QueryPlans.Enumerate',
    'QueryExecutionTrees.Enumerate'
)
$all = @($required + $optional)

$batch = Join-Path $OutDir "${CaseId}_first_pass_probes.cdb"
$log = Join-Path $OutDir "${CaseId}_first_pass_probes.txt"
$statusPath = Join-Path $OutDir "${CaseId}_first_pass_probe_status.json"
$sectionsDir = Join-Path $OutDir 'first_pass_probe_sections'
if (-not (Test-Path -LiteralPath $sectionsDir)) { New-Item -ItemType Directory -Force -Path $sectionsDir | Out-Null }

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('* SQL-CSI post-overall first-pass and optional probes')
[void]$sb.AppendLine(".sympath $SymPath")
[void]$sb.AppendLine('.reload /f')
[void]$sb.AppendLine(".load $ext")
[void]$sb.AppendLine('!dcs_initsymsvr')
[void]$sb.AppendLine('.reload /f sqlos.dll')
[void]$sb.AppendLine('.reload /f sqldk.dll')
[void]$sb.AppendLine('.reload /f sqlmin.dll')
[void]$sb.AppendLine('.reload /f sqllang.dll')
foreach ($expr in $all) {
    [void]$sb.AppendLine(".echo == MARKER_$expr ==")
    [void]$sb.AppendLine("!execute $expr")
}
[void]$sb.AppendLine('.echo == MARKER_DONE ==')
[void]$sb.AppendLine('q')
[System.IO.File]::WriteAllText($batch, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }

$captureStatus = 'completed'
$p = Start-Process -FilePath $Cdb -ArgumentList @('-y',$SymPath,'-z',$Dump,'-cf',$batch,'-logo',$log,'-G','-lines') -WindowStyle Hidden -PassThru
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    try { $p.Kill() } catch {}
    $captureStatus = 'timeout-with-evidence'
} elseif ($p.ExitCode -ne 0) {
    $captureStatus = "cdb-exit-$($p.ExitCode)-with-evidence"
}
if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw "probe log not created: $log" }

$lines = [System.IO.File]::ReadAllLines($log)
$sectionMap = @{}
$current = $null
$currentLines = $null
function Save-Section([string]$name, $buffer) {
    if ($name -and $null -ne $buffer) { $sectionMap[$name] = @($buffer) }
}
foreach ($line in $lines) {
    if ($line -match '== MARKER_([^=]+?) ==') {
        if ($line -match '\.echo\s+==\s+MARKER_') { continue }
        Save-Section $current $currentLines
        $name = $Matches[1].Trim()
        if ($name -eq 'DONE') { $current = $null; $currentLines = $null }
        else { $current = $name; $currentLines = [System.Collections.Generic.List[string]]::new(); $currentLines.Add($line) }
        continue
    }
    if ($current) { $currentLines.Add($line) }
}
Save-Section $current $currentLines

$probeResults = @()
foreach ($expr in $all) {
    $kind = if ($required -contains $expr) { 'required' } else { 'optional' }
    $safe = $expr -replace '[^A-Za-z0-9_.-]','_'
    $sectionPath = Join-Path $sectionsDir "${CaseId}_${safe}.txt"
    $section = if ($sectionMap.ContainsKey($expr)) { @($sectionMap[$expr]) } else { @() }
    [System.IO.File]::WriteAllText($sectionPath, (($section -join [Environment]::NewLine) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    $text = $section -join "`n"
    $rowCount = ([regex]::Matches($text, '(?m)^\s*0x[0-9A-Fa-f]+\s*\|')).Count
    $rowCountMatch = [regex]::Match($text, 'Row Count\s*\((\d+)\)')
    if ($rowCountMatch.Success) { $rowCount = [int]$rowCountMatch.Groups[1].Value }
    $hasHeader = $text -match '(?m)^\s*[A-Za-z_][^\r\n]*\|[^\r\n]*$'
    $noResults = $text -match 'INFO:\s+No results to process'
    $errorEvidence = $text -match '(?im)^\s*(ERROR:|Exception type:|.*InvalidMemoryAddressException|.*Failed to|.*Could not find)'
    $substantive = @($section | Where-Object {
        $_ -match '\S' -and
        $_ -notmatch '^\s*(?:\d+:\d+>\s*)?(?:\.echo|!execute)' -and
        $_ -notmatch '^\s*(?:Scripts|Running:|SCRIPTS / HELP|Loaded:|All:|Help \||[-+]+)\s*$' -and
        $_ -notmatch '^\s*== MARKER_' -and
        $_ -notmatch '^\s*INFO:\s+No results to process'
    })
    $status = 'no-signal'
    $reason = 'probe completed and emitted no data rows'
    if ($section.Count -eq 0) { $status = 'unavailable-with-evidence'; $reason = 'probe marker missing from combined log' }
    elseif ($rowCount -gt 0) { $status = 'signal-present'; $reason = "$rowCount data row(s) emitted" }
    elseif ($noResults -or $errorEvidence) { $status = 'unavailable-with-evidence'; $reason = 'probe unavailable or unreadable; raw error retained' }
    elseif ($hasHeader) { $status = 'no-signal'; $reason = 'table emitted with zero data rows' }
    elseif ($substantive.Count -gt 0) { $status = 'signal-present'; $reason = "$($substantive.Count) substantive line(s) emitted" }
    $probeResults += [pscustomobject]@{
        expression = $expr
        kind = $kind
        status = $status
        rowCount = $rowCount
        reason = $reason
        evidence = [System.IO.Path]::GetRelativePath($OutDir,$sectionPath).Replace('\','/')
    }
}

$result = [ordered]@{
    caseId = $CaseId
    phase = 'post-overall first-pass and optional probes'
    overallGate = [ordered]@{
        status = 'PASS'
        receipt = [System.IO.Path]::GetRelativePath($OutDir,$OverallReceipt).Replace('\','/')
        report = [System.IO.Path]::GetRelativePath($OutDir,$overallPath).Replace('\','/')
        immutableForThisPhase = $true
    }
    captureStatus = $captureStatus
    combinedLog = [System.IO.Path]::GetRelativePath($OutDir,$log).Replace('\','/')
    probes = $probeResults
}
[System.IO.File]::WriteAllText($statusPath, ($result | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
$counts = $probeResults | Group-Object status | ForEach-Object { "{0}={1}" -f $_.Name,$_.Count }
Write-Host "[run_first_pass_probes] overallGate=PASS capture=$captureStatus probes=$($probeResults.Count) $($counts -join ' ') -> $statusPath"
exit 0
