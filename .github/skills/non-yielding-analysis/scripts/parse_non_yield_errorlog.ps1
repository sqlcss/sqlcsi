# parse_non_yield_errorlog.ps1
# Stream-parse SQL Server ERRORLOG files for non-yielding scheduler/IOCP/resource
# monitor/stalled-dispatcher incidents. Produces a compact machine-readable handoff.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$ErrorLog,
    [string]$CaseId = 'case',
    [string]$OutJson = '',
    [datetime]$From,
    [datetime]$To,
    [int]$ContextHours = 2
)
$ErrorActionPreference = 'Stop'
$hasFrom = $PSBoundParameters.ContainsKey('From')
$hasTo = $PSBoundParameters.ContainsKey('To')
if (-not $OutJson) { $OutJson = Join-Path (Get-Location) "${CaseId}_non_yield_errorlog.json" }

function Get-LogEncoding([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $length = [Math]::Min(512,[int]$stream.Length)
        $bytes = [byte[]]::new($length)
        [void]$stream.Read($bytes,0,$length)
    } finally { $stream.Dispose() }
    if ($length -ge 2 -and $bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe) { return [Text.Encoding]::Unicode }
    if ($length -ge 2 -and $bytes[0] -eq 0xfe -and $bytes[1] -eq 0xff) { return [Text.Encoding]::BigEndianUnicode }
    $oddNulls = 0; $oddSlots = 0
    for ($i=1; $i -lt $length; $i+=2) { $oddSlots++; if ($bytes[$i] -eq 0) { $oddNulls++ } }
    if ($oddSlots -gt 0 -and ($oddNulls / $oddSlots) -gt 0.60) { return [Text.Encoding]::Unicode }
    return [Text.UTF8Encoding]::new($false,$false)
}
function Try-LogTimestamp([string]$Value,[ref]$Result) {
    return [datetime]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AllowWhiteSpaces,$Result)
}
function In-Window([datetime]$Timestamp) {
    if ($hasFrom -and $Timestamp -lt $From) { return $false }
    if ($hasTo -and $Timestamp -gt $To) { return $false }
    return $true
}
function Ptr([string]$Value) {
    if (-not $Value) { return $null }
    $v = ($Value -replace '`','').ToLowerInvariant()
    if (-not $v.StartsWith('0x')) { $v = '0x' + $v }
    return $v
}
function Classify-Trigger([string]$Message) {
    if ($Message -match '(?i)Non-yielding\s+Scheduler') { return 'scheduler' }
    if ($Message -match '(?i)Non-yielding\s+IOCP') { return 'iocp' }
    if ($Message -match '(?i)Non-yielding\s+(?:Resource\s+Monitor|RM)') { return 'resource-monitor' }
    if ($Message -match '(?i)Stalled\s+Dispatcher|Stuck\s+Dispatcher') { return 'stalled-dispatcher' }
    return 'unknown'
}
function Classify-Error([int]$ErrorNumber) {
    switch ($ErrorNumber) {
        17883 { return 'scheduler' }
        17884 { return 'iocp' }
        17887 { return 'io-completion' }
        17888 { return 'resource-monitor' }
        default { return 'unknown' }
    }
}
function Cpu-Class([double]$Ratio) {
    if ($Ratio -ge 70) { return 'cpu-active' }
    if ($Ratio -le 20) { return 'wait-dominated' }
    return 'mixed'
}
function Average([object[]]$Values) {
    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($numbers.Count -eq 0) { return $null }
    return [Math]::Round(($numbers | Measure-Object -Average).Average,2)
}
function Write-AtomicJson([string]$Path,$Object) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temp = "$Path.tmp"
    [IO.File]::WriteAllText($temp,($Object | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp,$Path,$true)
}

$progress = [Collections.Generic.List[object]]::new()
$triggers = [Collections.Generic.List[object]]::new()
$errors = [Collections.Generic.List[object]]::new()
$dumpPaths = [Collections.Generic.List[object]]::new()
$yielded = [Collections.Generic.List[object]]::new()
$sourceInfo = [Collections.Generic.List[object]]::new()
$linePattern = '^(?<ts>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+(?<source>\S+)\s+(?<message>.*)$'
$samplePattern = '(?i)Process\s+(?<process>\d+:\d+:\d+)\s+\((?<tid>0x[0-9a-f`]+)\)\s+Worker\s+(?<worker>0x[0-9a-f`]+)\s+appears\s+to\s+be\s+non-yielding\s+on\s+Scheduler\s+(?<scheduler>\d+)\.\s+Thread\s+creation\s+time:\s*(?<created>\d+)\.\s+Approx\s+Thread\s+CPU\s+Used:\s+kernel\s+(?<kernel>\d+)\s+ms,\s+user\s+(?<user>\d+)\s+ms\.\s+Process\s+Utilization\s+(?<processCpu>\d+)%\.\s+System\s+Idle\s+(?<idle>\d+)%\.\s+Interval:\s+(?<interval>\d+)\s+ms'

foreach ($path in $ErrorLog) {
    $resolved = (Resolve-Path -LiteralPath $path).Path
    $encoding = Get-LogEncoding $resolved
    $reader = [IO.StreamReader]::new($resolved,$encoding,$true,1MB)
    $lineNumber = 0; $matched = 0
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine(); $lineNumber++
            # ERRORLOG files can contain millions of backup/login rows. Avoid a
            # timestamp regex/date parse unless the line can contribute evidence.
            $candidate =
                $line.IndexOf('non-yield',[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $line.IndexOf('yielded',[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $line.IndexOf('Stalled Dispatcher',[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $line.IndexOf('Stuck Dispatcher',[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $line.IndexOf('SQLDump',[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $line.IndexOf('17883',[StringComparison]::Ordinal) -ge 0 -or
                $line.IndexOf('17884',[StringComparison]::Ordinal) -ge 0 -or
                $line.IndexOf('17887',[StringComparison]::Ordinal) -ge 0 -or
                $line.IndexOf('17888',[StringComparison]::Ordinal) -ge 0
            if (-not $candidate) { continue }
            $lm = [regex]::Match($line,$linePattern)
            if (-not $lm.Success) { continue }
            $timestamp = [datetime]::MinValue
            if (-not (Try-LogTimestamp $lm.Groups['ts'].Value ([ref]$timestamp))) { continue }
            if (-not (In-Window $timestamp)) { continue }
            $source = $lm.Groups['source'].Value
            $message = $lm.Groups['message'].Value

            $sm = [regex]::Match($message,$samplePattern)
            if ($sm.Success) {
                $kernel = [long]$sm.Groups['kernel'].Value; $user = [long]$sm.Groups['user'].Value; $interval = [long]$sm.Groups['interval'].Value
                $ratio = if ($interval -gt 0) { [Math]::Round(100.0 * ($kernel + $user) / $interval,2) } else { $null }
                $progress.Add([pscustomobject][ordered]@{
                    timestamp=$timestamp.ToString('yyyy-MM-ddTHH:mm:ss.fff');source=$source;file=$resolved;line=$lineNumber
                    process=$sm.Groups['process'].Value;osTid=(Ptr $sm.Groups['tid'].Value);worker=(Ptr $sm.Groups['worker'].Value)
                    schedulerId=[int]$sm.Groups['scheduler'].Value;threadCreationTime=[string]$sm.Groups['created'].Value
                    kernelMs=$kernel;userMs=$user;workerCpuMs=($kernel+$user);processUtilizationPct=[int]$sm.Groups['processCpu'].Value
                    systemIdlePct=[int]$sm.Groups['idle'].Value;intervalMs=$interval;workerCpuRatioPct=$ratio;cpuShape=(Cpu-Class $ratio)
                    raw=$message
                }) | Out-Null
                $matched++; continue
            }

            if ($message -match '(?i)appears\s+to\s+have\s+yielded|non-yielding.*resolved|scheduler.*resumed') {
                $yielded.Add([pscustomobject]@{timestamp=$timestamp.ToString('yyyy-MM-ddTHH:mm:ss.fff');source=$source;file=$resolved;line=$lineNumber;message=$message}) | Out-Null
                $matched++
            }
            if ($message -match '(?i)\*\s*(Non-yielding\s+(?:Scheduler|IOCP|Resource\s+Monitor|RM)|Stalled\s+Dispatcher|Stuck\s+Dispatcher)\s*$') {
                $triggers.Add([pscustomobject]@{timestamp=$timestamp.ToString('yyyy-MM-ddTHH:mm:ss.fff');source=$source;file=$resolved;line=$lineNumber;incidentType=(Classify-Trigger $message);message=$message}) | Out-Null
                $matched++
            }
            $em = [regex]::Match($message,'(?i)(?:Error|错误)\s*[:：]\s*(17883|17884|17887|17888)\b[^\r\n]*?(?:Severity|严重性)\s*[:：]\s*(\d+)')
            if ($em.Success) {
                $errors.Add([pscustomobject]@{timestamp=$timestamp.ToString('yyyy-MM-ddTHH:mm:ss.fff');source=$source;file=$resolved;line=$lineNumber;errorNumber=[int]$em.Groups[1].Value;severity=[int]$em.Groups[2].Value;message=$message}) | Out-Null
                $matched++
            }
            $dm = [regex]::Match($message,'(?i)(?<path>(?:[A-Z]:\\|\\\\)[^\r\n]*?SQLDump\d+\.(?:txt|mdmp))|(?<name>SQLDump\d+\.(?:txt|mdmp))')
            if ($dm.Success) {
                $dumpPaths.Add([pscustomobject]@{timestamp=$timestamp.ToString('yyyy-MM-ddTHH:mm:ss.fff');source=$source;file=$resolved;line=$lineNumber;dumpReference=if($dm.Groups['path'].Success){$dm.Groups['path'].Value}else{$dm.Groups['name'].Value};message=$message}) | Out-Null
                $matched++
            }
        }
    } finally { $reader.Dispose() }
    $sourceInfo.Add([pscustomobject]@{path=$resolved;encoding=$encoding.WebName;lines=$lineNumber;matchedRecords=$matched}) | Out-Null
}

$orderedSamples = @($progress | Sort-Object timestamp)
$segments = [Collections.Generic.List[object]]::new()
foreach ($group in @($orderedSamples | Group-Object { "$($_.osTid)|$($_.worker)|$($_.schedulerId)" })) {
    $current = [Collections.Generic.List[object]]::new(); $prior = $null
    foreach ($sample in @($group.Group | Sort-Object timestamp)) {
        $ts = [datetime]$sample.timestamp
        $reset = $false
        if ($prior) {
            $priorTs = [datetime]$prior.timestamp
            if (($ts-$priorTs).TotalMinutes -gt 15 -or $sample.intervalMs -lt $prior.intervalMs) { $reset = $true }
        }
        if ($reset -and $current.Count -gt 0) { $segments.Add(@($current)) | Out-Null; $current = [Collections.Generic.List[object]]::new() }
        $current.Add($sample) | Out-Null; $prior=$sample
    }
    if ($current.Count -gt 0) { $segments.Add(@($current)) | Out-Null }
}

$incidents = [Collections.Generic.List[object]]::new(); $incidentNumber=0
foreach ($segment in $segments) {
    $incidentNumber++
    $samples = @($segment | Sort-Object timestamp); $first=$samples[0]; $last=$samples[-1]
    $firstTs=[datetime]$first.timestamp; $lastTs=[datetime]$last.timestamp
    $estimatedStart=$firstTs.AddMilliseconds(-[double]$first.intervalMs)
    $ratio = if ($samples.Count -gt 1) {
        $cpuDelta=[double]($last.workerCpuMs-$first.workerCpuMs);$wallDelta=[double]($last.intervalMs-$first.intervalMs)
        if($wallDelta-gt0){[Math]::Round(100*$cpuDelta/$wallDelta,2)}else{[double]$last.workerCpuRatioPct}
    } else { [double]$last.workerCpuRatioPct }
    $nearTriggers=@($triggers|Where-Object{[Math]::Abs((([datetime]$_.timestamp)-$estimatedStart).TotalMinutes)-le10}|Sort-Object timestamp)
    $nearErrors=@($errors|Where-Object{[Math]::Abs((([datetime]$_.timestamp)-$estimatedStart).TotalMinutes)-le10}|Sort-Object timestamp)
    $nearDumps=@($dumpPaths|Where-Object{[Math]::Abs((([datetime]$_.timestamp)-$estimatedStart).TotalMinutes)-le15}|Sort-Object timestamp)
    $incidentType=if($nearTriggers.Count){[string]$nearTriggers[0].incidentType}else{'scheduler'}
    $incidents.Add([pscustomobject][ordered]@{
        incidentId=("NY-{0:D3}" -f $incidentNumber);incidentType=$incidentType
        estimatedStartLocal=$estimatedStart.ToString('yyyy-MM-ddTHH:mm:ss.fff');firstSampleLocal=$first.timestamp;lastSampleLocal=$last.timestamp
        windowStartLocal=$estimatedStart.AddHours(-$ContextHours).ToString('yyyy-MM-ddTHH:mm:ss.fff')
        windowEndLocal=$lastTs.AddHours($ContextHours).ToString('yyyy-MM-ddTHH:mm:ss.fff')
        process=$first.process;osTid=$first.osTid;worker=$first.worker;schedulerId=$first.schedulerId;threadCreationTime=$first.threadCreationTime
        sampleCount=$samples.Count;maxIntervalMs=[long]$last.intervalMs;lastWorkerCpuMs=[long]$last.workerCpuMs
        workerCpuDeltaRatioPct=$ratio;cpuShape=(Cpu-Class $ratio)
        processUtilizationPct=[ordered]@{min=($samples.processUtilizationPct|Measure-Object -Minimum).Minimum;max=($samples.processUtilizationPct|Measure-Object -Maximum).Maximum;avg=(Average $samples.processUtilizationPct)}
        systemIdlePct=[ordered]@{min=($samples.systemIdlePct|Measure-Object -Minimum).Minimum;max=($samples.systemIdlePct|Measure-Object -Maximum).Maximum;avg=(Average $samples.systemIdlePct)}
        matchedTriggers=@($nearTriggers);matchedErrors=@($nearErrors);matchedDumpReferences=@($nearDumps);samples=$samples
    }) | Out-Null
}

# IOCP/resource-monitor/stalled-dispatcher records do not always include the
# scheduler progress message. Preserve them as detection-only incidents.
foreach ($trigger in @($triggers | Sort-Object timestamp)) {
    $triggerTs=[datetime]$trigger.timestamp
    $covered=@($incidents|Where-Object{[Math]::Abs((([datetime]$_.estimatedStartLocal)-$triggerTs).TotalMinutes)-le10}).Count-gt0
    if($covered){continue}
    $incidentNumber++
    $nearErrors=@($errors|Where-Object{[Math]::Abs((([datetime]$_.timestamp)-$triggerTs).TotalMinutes)-le10}|Sort-Object timestamp)
    $nearDumps=@($dumpPaths|Where-Object{[Math]::Abs((([datetime]$_.timestamp)-$triggerTs).TotalMinutes)-le15}|Sort-Object timestamp)
    $incidents.Add([pscustomobject][ordered]@{
        incidentId=("NY-{0:D3}" -f $incidentNumber);incidentType=[string]$trigger.incidentType;detectionOnly=$true
        estimatedStartLocal=$trigger.timestamp;firstSampleLocal=$null;lastSampleLocal=$trigger.timestamp
        windowStartLocal=$triggerTs.AddHours(-$ContextHours).ToString('yyyy-MM-ddTHH:mm:ss.fff')
        windowEndLocal=$triggerTs.AddHours($ContextHours).ToString('yyyy-MM-ddTHH:mm:ss.fff')
        process=$null;osTid=$null;worker=$null;schedulerId=$null;threadCreationTime=$null
        sampleCount=0;maxIntervalMs=$null;lastWorkerCpuMs=$null;workerCpuDeltaRatioPct=$null;cpuShape='unavailable'
        processUtilizationPct=[ordered]@{min=$null;max=$null;avg=$null};systemIdlePct=[ordered]@{min=$null;max=$null;avg=$null}
        matchedTriggers=@($trigger);matchedErrors=$nearErrors;matchedDumpReferences=$nearDumps;samples=@()
    })|Out-Null
}

# Preserve standalone 1788x errors not already covered by a trigger/progress
# incident. Do not infer thread identity or CPU shape from the error number.
foreach ($errorRecord in @($errors | Sort-Object timestamp)) {
    $errorTs=[datetime]$errorRecord.timestamp
    $covered=@($incidents|Where-Object{[Math]::Abs((([datetime]$_.estimatedStartLocal)-$errorTs).TotalMinutes)-le10}).Count-gt0
    if($covered){continue}
    $incidentNumber++
    $nearDumps=@($dumpPaths|Where-Object{[Math]::Abs((([datetime]$_.timestamp)-$errorTs).TotalMinutes)-le15}|Sort-Object timestamp)
    $incidents.Add([pscustomobject][ordered]@{
        incidentId=("NY-{0:D3}" -f $incidentNumber);incidentType=(Classify-Error ([int]$errorRecord.errorNumber));detectionOnly=$true
        estimatedStartLocal=$errorRecord.timestamp;firstSampleLocal=$null;lastSampleLocal=$errorRecord.timestamp
        windowStartLocal=$errorTs.AddHours(-$ContextHours).ToString('yyyy-MM-ddTHH:mm:ss.fff')
        windowEndLocal=$errorTs.AddHours($ContextHours).ToString('yyyy-MM-ddTHH:mm:ss.fff')
        process=$null;osTid=$null;worker=$null;schedulerId=$null;threadCreationTime=$null
        sampleCount=0;maxIntervalMs=$null;lastWorkerCpuMs=$null;workerCpuDeltaRatioPct=$null;cpuShape='unavailable'
        processUtilizationPct=[ordered]@{min=$null;max=$null;avg=$null};systemIdlePct=[ordered]@{min=$null;max=$null;avg=$null}
        matchedTriggers=@();matchedErrors=@($errorRecord);matchedDumpReferences=$nearDumps;samples=@()
    })|Out-Null
}
$incidents=@($incidents|Sort-Object estimatedStartLocal)

$result=[ordered]@{
    analysisType='sql-csi-non-yield-errorlog';schemaVersion=1;caseId=$CaseId;generatedAt=(Get-Date).ToString('o')
    timeBasis='ERRORLOG source-server local time; no UTC conversion applied'
    filters=[ordered]@{from=if($hasFrom){$From.ToString('o')}else{$null};to=if($hasTo){$To.ToString('o')}else{$null};contextHours=$ContextHours}
    summary=[ordered]@{incidentCount=$incidents.Count;sampleCount=$progress.Count;triggerCount=$triggers.Count;error1788xCount=$errors.Count;dumpReferenceCount=$dumpPaths.Count;yieldRecoveryMarkerCount=$yielded.Count}
    sourceFiles=@($sourceInfo);incidents=@($incidents);orphanTriggers=@($triggers|Where-Object{$trigger=$_;@($incidents|Where-Object{[Math]::Abs((([datetime]$_.estimatedStartLocal)-([datetime]$trigger.timestamp)).TotalMinutes)-le10}).Count-eq0})
    error1788x=@($errors|Sort-Object timestamp);dumpReferences=@($dumpPaths|Sort-Object timestamp);yieldRecoveryMarkers=@($yielded|Sort-Object timestamp)
    limitations=@(
        'ERRORLOG identifies detection/progress but does not prove the blocked function or resource.',
        'Approx Thread CPU Used and Interval are used to classify CPU shape; low CPU does not identify a specific wait.',
        'Absence of a recovery marker or later sample is not proof that the incident remained active.',
        'Stack-dump header SPID is not automatically the offending SQL session SPID.'
    )
}
Write-AtomicJson $OutJson $result
Write-Host "[parse_non_yield_errorlog] PASS: incidents=$($incidents.Count) samples=$($progress.Count) triggers=$($triggers.Count) -> $OutJson" -ForegroundColor Green
exit 0
