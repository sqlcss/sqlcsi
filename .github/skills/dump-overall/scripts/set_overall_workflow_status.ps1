# set_overall_workflow_status.ps1
# Atomically transition one Gate A ledger item after its artifacts are produced.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ledger,
    [ValidateSet('requiredSteps','requiredDeliverables')][string]$Group = 'requiredSteps',
    [Parameter(Mandatory)][string]$Name,
    [ValidateSet('missing','done','unavailable-with-evidence','skipped-by-user','failed')][string]$Status,
    [string[]]$Artifacts,
    [string[]]$Evidence,
    [string]$Path
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) { throw "ledger not found: $Ledger" }
$doc = Get-Content -LiteralPath $Ledger -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not ($doc.PSObject.Properties.Name -contains $Group)) { throw "ledger group missing: $Group" }
$groupObject = $doc.$Group
if (-not ($groupObject.PSObject.Properties.Name -contains $Name)) { throw "ledger item missing: $Group.$Name" }
$item = $groupObject.$Name
$item.status = $Status
if ($PSBoundParameters.ContainsKey('Artifacts')) {
    if ($item.PSObject.Properties.Name -contains 'artifacts') { $item.artifacts = @($Artifacts) }
    else { $item | Add-Member -NotePropertyName artifacts -NotePropertyValue @($Artifacts) }
}
if ($PSBoundParameters.ContainsKey('Evidence')) {
    if ($item.PSObject.Properties.Name -contains 'evidence') { $item.evidence = @($Evidence) }
    else { $item | Add-Member -NotePropertyName evidence -NotePropertyValue @($Evidence) }
}
if ($PSBoundParameters.ContainsKey('Path')) {
    if ($item.PSObject.Properties.Name -contains 'path') { $item.path = $Path }
    else { $item | Add-Member -NotePropertyName path -NotePropertyValue $Path }
}
if ($item.PSObject.Properties.Name -contains 'updatedAt') { $item.updatedAt = (Get-Date).ToString('o') }
else { $item | Add-Member -NotePropertyName updatedAt -NotePropertyValue (Get-Date).ToString('o') }
if ($Status -eq 'unavailable-with-evidence' -and @($item.evidence).Count -eq 0) {
    throw 'unavailable-with-evidence requires at least one evidence path'
}
$temp = "$Ledger.tmp"
[System.IO.File]::WriteAllText($temp, ($doc | ConvertTo-Json -Depth 16), [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::Move($temp, $Ledger, $true)
Write-Host "[set_overall_workflow_status] $Group.$Name -> $Status"
exit 0
