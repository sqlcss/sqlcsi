<#
.SYNOPSIS
  FALLBACK helper: shred a `!mex.us` log (unique-stacks) into a {id, stack} JSON array
  that classify_thread_categories.ps1 can consume.

  Each mex.us group looks like:
      N thread(s) [stats]: 22[!mex.t 22] 46[!mex.t 46] 51[!mex.t 51]
          <hex> module!frame+0x..   (source @ line)
          (Inline)  module!frame+0x..
          ...
      <blank line ends the group>

  A group may list MANY thread ids (identical stacks). Every id gets one row with the
  same stack text (module!frame lines only, source suffix stripped).

.PARAMETER UsTxt   Path to the {case}_us.txt mex.us log. (required)
.PARAMETER Out     Optional path to write the JSON array. Always prints count to console.

  Exit 0 ok, 1 input missing/no groups parsed.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$UsTxt,
  [string]$Out
)

if (-not (Test-Path -LiteralPath $UsTxt)) {
  Write-Error "[shred] input not found: $UsTxt"; exit 1
}

$lines = Get-Content -LiteralPath $UsTxt -Encoding UTF8
$rows  = New-Object System.Collections.Generic.List[object]

$headerRe = '^\s*\d+\s+thread(s)?\s+\[stats\]:\s*(?<ids>.+)$'
$idRe     = '(\d+)\s*\[!mex\.t'
$frameRe  = '^\s+(?:[0-9a-fA-F`]{6,}|\(Inline\))\s+(?<frame>[^\s].*?)\s*(?:\([^()]*@[^()]*\)\s*)?$'

$curIds   = @()
$curStack = New-Object System.Collections.Generic.List[string]

function Flush-Group {
  param($ids, $stackList)
  if (-not $ids -or $ids.Count -eq 0) { return }
  $stackText = ($stackList -join "`n").Trim()
  foreach ($id in $ids) {
    $rows.Add([pscustomobject]@{ id = [int]$id; stack = $stackText }) | Out-Null
  }
}

foreach ($ln in $lines) {
  $m = [regex]::Match($ln, $headerRe)
  if ($m.Success) {
    # close previous group
    Flush-Group -ids $curIds -stackList $curStack
    $curStack = New-Object System.Collections.Generic.List[string]
    $idMatches = [regex]::Matches($m.Groups['ids'].Value, $idRe)
    $curIds = @($idMatches | ForEach-Object { $_.Groups[1].Value })
    continue
  }
  if ([string]::IsNullOrWhiteSpace($ln)) {
    # blank line ends the current group
    Flush-Group -ids $curIds -stackList $curStack
    $curIds = @(); $curStack = New-Object System.Collections.Generic.List[string]
    continue
  }
  if ($curIds.Count -gt 0) {
    $fm = [regex]::Match($ln, $frameRe)
    if ($fm.Success) { $curStack.Add($fm.Groups['frame'].Value) | Out-Null }
  }
}
# flush trailing group (no blank line at EOF)
Flush-Group -ids $curIds -stackList $curStack

if ($rows.Count -eq 0) {
  Write-Error "[shred] no thread groups parsed from $UsTxt"; exit 1
}

Write-Host "[shred] parsed $($rows.Count) thread rows from $([System.IO.Path]::GetFileName($UsTxt))"

if ($Out) {
  $json = ($rows | ConvertTo-Json -Depth 4)
  $enc  = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Out, $json, $enc)
  Write-Host "[shred] wrote $Out"
}
exit 0
