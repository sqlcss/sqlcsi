# detect_non_yield_dump.ps1
# Detect/match SQLDump files only after the ERRORLOG+XEvent log-analysis receipt is PASS.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$CaseDir,
    [Parameter(Mandatory)][string]$ReportDir,
    [Parameter(Mandatory)][string]$LogCompletionReceipt,
    [Parameter(Mandatory)][string]$ErrorLogFindings,
    [string]$OutJson = '',
    [int]$MaxMatchMinutes = 15
)
$ErrorActionPreference='Stop'
if (-not $OutJson) { $OutJson = Join-Path $ReportDir "${CaseId}_non_yield_dump_detection.json" }
function Need([string]$Path,[string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Label missing: $Path" }
    $item = Get-Item -LiteralPath $Path
    if (-not $item.PSIsContainer -and $item.Length -eq 0) { throw "$Label empty: $Path" }
}
function Resolve-ReportArtifact([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $ReportDir $Path.Replace('/','\'))
}
function Validate-ReceiptArtifact($Artifact,[string]$Label) {
    $p = Resolve-ReportArtifact ([string]$Artifact.path)
    Need $p $Label
    if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne [string]$Artifact.sha256) { throw "$Label hash mismatch" }
    return (Resolve-Path -LiteralPath $p).Path
}
function RelReport([string]$Path) { return [IO.Path]::GetRelativePath($ReportDir,(Resolve-Path -LiteralPath $Path).Path).Replace('\','/') }
function Trigger-Type([string]$Text) {
    if ($Text -match '(?i)Non[- ]yielding\s+Scheduler') { return 'scheduler' }
    if ($Text -match '(?i)Non[- ]yielding\s+IOCP') { return 'iocp' }
    if ($Text -match '(?i)Non[- ]yielding\s+(?:Resource\s+Monitor|RM)') { return 'resource-monitor' }
    if ($Text -match '(?i)Stalled\s+Dispatcher|Stuck\s+Dispatcher') { return 'stalled-dispatcher' }
    return 'unknown'
}
function Compatible([string]$Incident,[string]$Dump) {
    if ($Incident -eq 'unknown' -or $Dump -eq 'unknown') { return $true }
    if ($Incident -eq 'io-completion' -and $Dump -eq 'iocp') { return $true }
    return ($Incident -eq $Dump)
}
function Get-TextEncoding([string]$Path) {
    $s=[IO.File]::OpenRead($Path)
    try {$b=[byte[]]::new([Math]::Min(256,[int]$s.Length));[void]$s.Read($b,0,$b.Length)} finally {$s.Dispose()}
    if ($b.Length -ge 2 -and $b[0] -eq 0xff -and $b[1] -eq 0xfe) { return [Text.Encoding]::Unicode }
    if ($b.Length -ge 2 -and $b[0] -eq 0xfe -and $b[1] -eq 0xff) { return [Text.Encoding]::BigEndianUnicode }
    $odd=0;$slots=0
    for($i=1;$i-lt$b.Length;$i+=2){$slots++;if($b[$i]-eq0){$odd++}}
    if ($slots -gt 0 -and ($odd/$slots) -gt .6) { return [Text.Encoding]::Unicode }
    return [Text.UTF8Encoding]::new($false,$false)
}
function Read-DumpMetadata([string]$Path) {
    $enc=Get-TextEncoding $Path;$reader=[IO.StreamReader]::new($Path,$enc,$true,64KB);$lines=[Collections.Generic.List[string]]::new()
    try {for($i=0;$i-lt120-and-not$reader.EndOfStream;$i++){$lines.Add($reader.ReadLine())|Out-Null}} finally {$reader.Dispose()}
    $text=$lines -join "`n";$time=$null
    $tm=[regex]::Match($text,'(?im)^Current time is\s+(\d{2}:\d{2}:\d{2})\s+(\d{2}/\d{2}/\d{2})\.')
    if($tm.Success){$parsed=[datetime]::MinValue;if([datetime]::TryParseExact(($tm.Groups[1].Value+' '+$tm.Groups[2].Value),'HH:mm:ss MM/dd/yy',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)){$time=$parsed}}
    $spid=$null;$sm=[regex]::Match($text,'(?im)^\*\s+\d{2}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+spid\s+(\d+)');if($sm.Success){$spid=[int]$sm.Groups[1].Value}
    return [pscustomobject]@{textPath=$Path;baseName=[IO.Path]::GetFileNameWithoutExtension($Path);dumpTimeLocal=$time;incidentType=(Trigger-Type $text);headerSpid=$spid;encoding=$enc.WebName}
}
function Write-Atomic([string]$Path,$Object) {
    $parent=Split-Path -Parent $Path;if($parent-and-not(Test-Path $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $tmp="$Path.tmp";[IO.File]::WriteAllText($tmp,($Object|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false));[IO.File]::Move($tmp,$Path,$true)
}
Need $CaseDir 'case directory';Need $ReportDir 'report directory';Need $LogCompletionReceipt 'log-analysis completion receipt';Need $ErrorLogFindings 'ERRORLOG findings'
$receipt=Get-Content -LiteralPath $LogCompletionReceipt -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$receipt.status-ne'PASS'){throw "log-analysis receipt is not PASS: $($receipt.status)"}
if([string]$receipt.completionBoundary-ne'Log Gate'){throw "unsupported completion boundary: $($receipt.completionBoundary)"}
if(-not[bool]$receipt.logAnalysisComplete){throw 'Log Gate receipt does not mark log analysis complete'}
if(-not[bool]$receipt.reportPublicationAllowed){throw 'Log Gate report is not publishable'}
if([bool]$receipt.downstreamDumpRequiredForLogCompletion){throw 'Log Gate incorrectly depends on downstream dump work'}
if(-not[bool]$receipt.receiptIsImmutableAfterPublication){throw 'Log Gate receipt does not declare post-publication immutability'}
if([bool]$receipt.downstream.affectsLogGateStatus){throw 'Post-log continuation is allowed to alter Log Gate status'}
$logReport=Validate-ReceiptArtifact $receipt.report 'locked log-analysis report'
$receiptErrorlog=Validate-ReceiptArtifact $receipt.errorlogFindings 'receipt ERRORLOG findings'
if((Resolve-Path -LiteralPath $ErrorLogFindings).Path-ne$receiptErrorlog){throw 'provided ERRORLOG findings differ from the locked receipt artifact'}
$ledgerPath=Validate-ReceiptArtifact $receipt.workflowLedger 'locked workflow ledger'
$xeventPath=Validate-ReceiptArtifact $receipt.xeventFindings 'locked XEvent findings'
$findings=Get-Content -LiteralPath $ErrorLogFindings -Raw -Encoding UTF8|ConvertFrom-Json
$txtFiles=@(Get-ChildItem -LiteralPath $CaseDir -Recurse -File -Filter 'SQLDump*.txt' -ErrorAction SilentlyContinue)
$mdmpFiles=@(Get-ChildItem -LiteralPath $CaseDir -Recurse -File -Filter 'SQLDump*.mdmp' -ErrorAction SilentlyContinue)
$mdmpByBase=@{};foreach($file in $mdmpFiles){$key=[IO.Path]::GetFileNameWithoutExtension($file.Name).ToLowerInvariant();if(-not$mdmpByBase.ContainsKey($key)){$mdmpByBase[$key]=[Collections.Generic.List[string]]::new()};$mdmpByBase[$key].Add($file.FullName)|Out-Null}
$metadata=@($txtFiles|ForEach-Object{Read-DumpMetadata $_.FullName})
$explicitBases=@($findings.dumpReferences|ForEach-Object{if([string]$_.dumpReference-match'(?i)(SQLDump\d+)\.(?:txt|mdmp)'){$Matches[1].ToLowerInvariant()}}|Sort-Object -Unique)
$matches=[Collections.Generic.List[object]]::new()
foreach($incident in @($findings.incidents)){
    $anchor=[datetime]$incident.estimatedStartLocal
    $candidates=[Collections.Generic.List[object]]::new()
    foreach($meta in $metadata){
        $base=$meta.baseName.ToLowerInvariant();$explicit=$explicitBases-contains$base
        $delta=if($meta.dumpTimeLocal){[Math]::Abs((([datetime]$meta.dumpTimeLocal)-$anchor).TotalMinutes)}else{$null}
        $compatible=Compatible ([string]$incident.incidentType) ([string]$meta.incidentType)
        if(-not$explicit-and(-not$compatible-or$null-eq$delta-or$delta-gt$MaxMatchMinutes)){continue}
        $dumpPaths=if($mdmpByBase.ContainsKey($base)){@($mdmpByBase[$base])}else{@()}
        $score=0;if($explicit){$score+=100};if($compatible){$score+=30};if($null-ne$delta){if($delta-le2){$score+=50}elseif($delta-le10){$score+=30}else{$score+=10}};if($dumpPaths.Count){$score+=20}
        $candidates.Add([pscustomobject][ordered]@{baseName=$meta.baseName;textPath=$meta.textPath;mdmpPaths=$dumpPaths;dumpTimeLocal=if($meta.dumpTimeLocal){([datetime]$meta.dumpTimeLocal).ToString('yyyy-MM-ddTHH:mm:ss')}else{$null};incidentType=$meta.incidentType;headerSpid=$meta.headerSpid;explicitReference=$explicit;timeDeltaMinutes=if($null-ne$delta){[Math]::Round($delta,3)}else{$null};score=$score})|Out-Null
    }
    $ordered=@($candidates|Sort-Object @{Expression='score';Descending=$true},@{Expression='timeDeltaMinutes';Descending=$false},baseName)
    $selected=$null;$status='not-found';$reason='No compatible SQLDump text+mdmp pair within the configured time window.'
    if($ordered.Count){$topScore=$ordered[0].score;$ties=@($ordered|Where-Object score-eq$topScore);if($ties.Count-gt1){$status='ambiguous';$reason="$($ties.Count) candidates share top score $topScore; manual selection required."}elseif(@($ordered[0].mdmpPaths).Count-eq1){$selected=$ordered[0];$status='matched';$reason='Unique top-scoring trigger/time candidate with one matching mdmp.'}elseif(@($ordered[0].mdmpPaths).Count-gt1){$status='ambiguous';$reason='Top SQLDump base has multiple mdmp paths.'}else{$status='text-only';$reason='Matching SQLDump text exists but corresponding mdmp is missing.'}}
    $handoff=$null
    if($status-eq'matched'){$handoff=[ordered]@{case_id=$CaseId;case_dir=(Resolve-Path $CaseDir).Path;invocationPath='path1-non-yielding-to-dump-analysis';dumpPipelineMode='fresh';preexistingGateArtifactsRequired=$false;requiredGateSequence=@('Gate A - dump-overall','Gate B - branch hints','Gate C - route execution');log_report=$logReport;log_completion_receipt=(Resolve-Path $LogCompletionReceipt).Path;log_completion_receipt_sha256=(Get-FileHash $LogCompletionReceipt -Algorithm SHA256).Hash;workflow_ledger=$ledgerPath;errorlog_evidence=$receiptErrorlog;xevent_evidence=$xeventPath;dump_path=[string]@($selected.mdmpPaths)[0];dump_text=[string]$selected.textPath;trigger=[string]$incident.incidentType;estimated_start_local=[string]$incident.estimatedStartLocal;window_start_local=[string]$incident.windowStartLocal;window_end_local=[string]$incident.windowEndLocal;scheduler_id=$incident.schedulerId;os_tid=$incident.osTid;worker=$incident.worker;worker_cpu_ratio_pct=$incident.workerCpuDeltaRatioPct;required_dump_workflow='Generate Gate A from the matched dump, then Gate B, then Gate C Scheduler/non-yield using reference/non_yielding.md. No pre-existing Gate artifact is required.'}}
    $matches.Add([pscustomobject][ordered]@{incidentId=$incident.incidentId;incidentType=$incident.incidentType;anchorLocal=$incident.estimatedStartLocal;status=$status;reason=$reason;selected=$selected;candidates=$ordered;dumpAnalysisHandoff=$handoff})|Out-Null
}
$result=[ordered]@{analysisType='sql-csi-non-yield-dump-detection';schemaVersion=1;caseId=$CaseId;generatedAt=(Get-Date).ToString('o');prerequisite=[ordered]@{completionBoundary='Log Gate';logAnalysisComplete=$true;reportPublicationAllowed=$true;downstreamDumpRequiredForLogCompletion=$false;receiptIsImmutableAfterPublication=$true;logCompletionReceipt=(RelReport $LogCompletionReceipt);logCompletionReceiptSha256=(Get-FileHash -LiteralPath $LogCompletionReceipt -Algorithm SHA256).Hash;status='PASS';report=(RelReport $logReport);reportSha256=[string]$receipt.report.sha256};inventory=[ordered]@{dumpTextCount=$txtFiles.Count;mdmpCount=$mdmpFiles.Count};summary=[ordered]@{incidentCount=@($findings.incidents).Count;matchedDumpCount=@($matches|Where-Object { $_.status -eq 'matched' }).Count;ambiguousCount=@($matches|Where-Object { $_.status -eq 'ambiguous' }).Count;textOnlyCount=@($matches|Where-Object { $_.status -eq 'text-only' }).Count};matches=@($matches);rule='Only matches with status=matched may be delegated to dump-analysis. Store Post-Log state in this separate artifact; never mutate the Log Gate report or receipt.'}
Write-Atomic $OutJson $result
Write-Host "[detect_non_yield_dump] PASS: matched=$($result.summary.matchedDumpCount) ambiguous=$($result.summary.ambiguousCount) -> $OutJson" -ForegroundColor Green
exit 0
