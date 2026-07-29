[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$parser=Join-Path $root 'scripts\parse_non_yield_errorlog.ps1'
$fixture=Join-Path $PSScriptRoot 'fixtures\non_yield_errorlog_utf8.txt'
$temp=Join-Path $env:TEMP 'sqlcsi_non_yield_parser_test'
if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
New-Item -ItemType Directory -Path $temp -Force|Out-Null
$utf16=Join-Path $temp 'ERRORLOG.utf16'
$text=Get-Content -LiteralPath $fixture -Raw -Encoding UTF8
[IO.File]::WriteAllText($utf16,$text,[Text.Encoding]::Unicode)
foreach($input in @($fixture,$utf16)){
    $out=Join-Path $temp ((Split-Path -Leaf $input)+'.json')
    & $parser -CaseId 'fixture' -ErrorLog $input -OutJson $out
    if($LASTEXITCODE-ne0){throw "parser failed for $input"}
    $r=Get-Content -LiteralPath $out -Raw -Encoding UTF8|ConvertFrom-Json
    if($r.summary.incidentCount-ne4){throw "expected 4 incidents; got $($r.summary.incidentCount) for $input"}
    if($r.summary.sampleCount-ne5){throw "expected 5 samples; got $($r.summary.sampleCount) for $input"}
    $wait=@($r.incidents|Where-Object { $_.schedulerId -eq 42 })
    $cpu=@($r.incidents|Where-Object { $_.schedulerId -eq 17 })
    if($wait.Count-ne1-or$wait[0].sampleCount-ne3-or$wait[0].cpuShape-ne'wait-dominated'){throw "wait-dominated grouping failed for $input"}
    if($cpu.Count-ne1-or$cpu[0].sampleCount-ne2-or$cpu[0].cpuShape-ne'cpu-active'){throw "CPU-active grouping failed for $input"}
    if($wait[0].osTid-ne'0x3a8c'-or$wait[0].worker-ne'0x000003db2803c160'){throw "identity normalization failed for $input"}
    if($wait[0].matchedTriggers.Count-ne1){throw "trigger correlation failed for $input"}
    if($wait[0].matchedDumpReferences.Count-ne1){throw "dump correlation failed for $input"}
    $iocp=@($r.incidents|Where-Object { $_.incidentType -eq 'iocp' -and $_.detectionOnly })
    $resource=@($r.incidents|Where-Object { $_.incidentType -eq 'resource-monitor' -and $_.detectionOnly })
    if($iocp.Count-ne1-or$iocp[0].sampleCount-ne0){throw "trigger-only IOCP incident failed for $input"}
    if($resource.Count-ne1-or$resource[0].matchedErrors[0].errorNumber-ne17888){throw "error-only resource-monitor incident failed for $input"}
}
Write-Host '[test_parse_non_yield_errorlog] PASS: UTF-8 and UTF-16LE; grouping and CPU shape verified' -ForegroundColor Green
exit 0
