# set_route_execution_check.ps1
# Atomically update one Gate C route checklist item and recompute route status.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ledger,
    [Parameter(Mandatory)][string]$Route,
    [Parameter(Mandatory)][string]$Check,
    [ValidateSet('pending','in-progress','completed','unavailable-with-evidence','failed')][string]$Status,
    [string[]]$Evidence = @(),
    [string]$Note = ''
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) { throw "route ledger not found: $Ledger" }
$doc = Get-Content -LiteralPath $Ledger -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not ($doc.routes.PSObject.Properties.Name -contains $Route)) { throw "route not found: $Route" }
$routeObj = $doc.routes.$Route
if (-not ($routeObj.checks.PSObject.Properties.Name -contains $Check)) { throw "route check not found: $Route.$Check" }
$base = Split-Path -Parent $Ledger
$storedEvidence = @()
foreach ($path in @($Evidence)) {
    $resolved = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $base $path }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or (Get-Item -LiteralPath $resolved).Length -eq 0) {
        throw "evidence missing or empty: $resolved"
    }
    $storedEvidence += if ([System.IO.Path]::IsPathRooted($path)) { [System.IO.Path]::GetRelativePath($base,$resolved).Replace('\','/') } else { $path.Replace('\','/') }
}
if ($Status -in @('completed','unavailable-with-evidence') -and $storedEvidence.Count -eq 0) {
    throw "$Status requires non-empty evidence"
}
$item = $routeObj.checks.$Check
$item.status = $Status
$item.evidence = @($storedEvidence)
$item.note = $Note
if ($item.PSObject.Properties.Name -contains 'updatedAt') { $item.updatedAt = (Get-Date).ToString('o') }
else { $item | Add-Member -NotePropertyName updatedAt -NotePropertyValue (Get-Date).ToString('o') }

$knownOptionalCheckNames = if ($Route -eq 'scheduler_non_yield') { @('spinlock_thread_inventory','spinlock_owner_validation') } else { @() }
$requiredChecks = @($routeObj.checks.PSObject.Properties | Where-Object {
    ($knownOptionalCheckNames -notcontains $_.Name) -and (-not ($_.Value.PSObject.Properties.Name -contains 'required') -or [bool]$_.Value.required)
})
$checkStatuses = @($requiredChecks | ForEach-Object { [string]$_.Value.status })
if (@($checkStatuses | Where-Object { $_ -eq 'failed' }).Count -gt 0) {
    $routeObj.status = 'failed'
} elseif (@($checkStatuses | Where-Object { $_ -notin @('completed','unavailable-with-evidence') }).Count -eq 0) {
    $unavailableCount = @($checkStatuses | Where-Object { $_ -eq 'unavailable-with-evidence' }).Count
    if ($unavailableCount -eq $checkStatuses.Count) { $routeObj.status = 'unavailable-with-evidence' }
    elseif ($unavailableCount -gt 0) { $routeObj.status = 'completed-with-limitations' }
    else { $routeObj.status = 'completed' }
} elseif (@($checkStatuses | Where-Object { $_ -ne 'pending' }).Count -gt 0) {
    $routeObj.status = 'in-progress'
} else {
    $routeObj.status = 'pending'
}
if ($routeObj.PSObject.Properties.Name -contains 'updatedAt') { $routeObj.updatedAt = (Get-Date).ToString('o') }
else { $routeObj | Add-Member -NotePropertyName updatedAt -NotePropertyValue (Get-Date).ToString('o') }
$temp = "$Ledger.tmp"
[System.IO.File]::WriteAllText($temp, ($doc | ConvertTo-Json -Depth 24), [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::Move($temp,$Ledger,$true)
Write-Host "[set_route_execution_check] $Route.$Check -> $Status ; route=$($routeObj.status)"
exit 0
