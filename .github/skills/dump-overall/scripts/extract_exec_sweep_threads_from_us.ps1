[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$UsTxt,
    [Parameter(Mandatory=$true)][string]$OutThreads,
    [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $UsTxt -PathType Leaf)) { throw "!mex.us source not found: $UsTxt" }

$mainRule = '(?i)(sqllang!process_request|CSQLSource::Execute|sqllang!process_commands(?:_internal)?)'
$childRule = '(?i)(sqlmin!SubprocEntrypoint|CXPacket|CXPort|CXPipe|CQScanExchange|CXTransport)'

$lines = Get-Content -LiteralPath $UsTxt -Encoding UTF8
$groups = @()
$current = $null
foreach ($line in $lines) {
    if ($line -match '^(\d+)\s+threads?\s+\[stats\]:\s*(.*)$') {
        if ($current) { $groups += $current }
        $ids = [regex]::Matches($Matches[2], '(\d+)\[!mex\.t') | ForEach-Object { [int]$_.Groups[1].Value }
        $current = [pscustomobject]@{
            Count  = [int]$Matches[1]
            Ids    = @($ids)
            More   = ($Matches[2] -match '\.\.\.')
            Frames = New-Object Collections.ArrayList
        }
    } elseif ($current -and ($line -match '^\s+(00007|\(Inline\))')) {
        [void]$current.Frames.Add($line.TrimEnd())
    }
}
if ($current) { $groups += $current }

$selected = New-Object System.Collections.Generic.List[object]
foreach ($group in $groups) {
    $stack = ($group.Frames -join "`n")
    $isMain = $stack -match $mainRule
    $isChild = (-not $isMain) -and ($stack -match $childRule)
    if (-not $isMain -and -not $isChild) { continue }
    $role = if ($isMain) { 'MAIN' } else { 'CHILD' }
    foreach ($id in $group.Ids) {
        [void]$selected.Add([pscustomobject]@{
            id = [int]$id
            role = $role
            matchedRule = if ($isMain) { 'exec-main' } else { 'parallel-child' }
            stackGroupCount = $group.Count
            frames = @($group.Frames)
        })
    }
}

$selected = @($selected | Sort-Object id -Unique)
if ($selected.Count -eq 0) { throw "No exec main/parallel child threads matched the fallback rules in $UsTxt" }

$threadSpec = ($selected | ForEach-Object { "{0}:{1}" -f $_.id, $_.role }) -join ','
$outDir = Split-Path -Parent $OutThreads
if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutThreads, $threadSpec + "`r`n", $enc)

if ($OutJson) {
    $jsonDir = Split-Path -Parent $OutJson
    if ($jsonDir -and -not (Test-Path -LiteralPath $jsonDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $jsonDir | Out-Null }
    [System.IO.File]::WriteAllText($OutJson, ($selected | ConvertTo-Json -Depth 8), $enc)
}

$mainCount = @($selected | Where-Object { $_.role -eq 'MAIN' }).Count
$childCount = @($selected | Where-Object { $_.role -eq 'CHILD' }).Count
Write-Host ("[extract_exec_sweep_threads_from_us] total={0} mains={1} children={2} -> {3}" -f $selected.Count, $mainCount, $childCount, $OutThreads) -ForegroundColor Green
Write-Host $threadSpec
