# analyze_imported_non_yield_xevent.ps1
# Deterministic Path A fallback after import-xevent: query the imported xe tables
# for immediate and persistence windows and emit structured non-yield evidence.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][datetime]$ImmediateStartUtc,
    [Parameter(Mandatory)][datetime]$ImmediateEndUtc,
    [Parameter(Mandatory)][datetime]$PersistenceStartUtc,
    [Parameter(Mandatory)][datetime]$PersistenceEndUtc,
    [Parameter(Mandatory)][string]$OutJson,
    [string]$ServerInstance='localhost',
    [string]$Database=''
)
$ErrorActionPreference='Stop'
if(-not$Database){$Database="xevent_$CaseId"}
if($ImmediateEndUtc-le$ImmediateStartUtc){throw 'ImmediateEndUtc must be after ImmediateStartUtc'}
if($PersistenceEndUtc-le$PersistenceStartUtc){throw 'PersistenceEndUtc must be after PersistenceStartUtc'}
$sqlcmd=(Get-Command sqlcmd -ErrorAction Stop).Source
$tempRoot=Join-Path $env:TEMP "sqlcsi_non_yield_xe_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force|Out-Null
function Sql-Date([datetime]$Value){return $Value.ToString('yyyy-MM-ddTHH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)}
function Sql-String([string]$Value){return "N'"+($Value-replace"'","''")+"'"}
function Invoke-JsonQuery([string]$Name,[string]$Query){
    $sqlPath=Join-Path $tempRoot "$Name.sql";$outPath=Join-Path $tempRoot "$Name.out"
    $sql="SET NOCOUNT ON; SET ANSI_WARNINGS ON; SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;`r`n$Query`r`n"
    [IO.File]::WriteAllText($sqlPath,$sql,[Text.UTF8Encoding]::new($false))
    & $sqlcmd -b -r 1 -u -S $ServerInstance -E -d $Database -h -1 -w 65535 -y 0 -i $sqlPath -o $outPath
    if($LASTEXITCODE-ne0){$raw=if(Test-Path $outPath){Get-Content $outPath -Raw -Encoding Unicode}else{''};throw "XEvent query '$Name' failed: $raw"}
    # FOR JSON may arrive as multiple result chunks/physical lines. Concatenate
    # them without adding characters so the JSON document remains valid.
    $raw=((Get-Content -LiteralPath $outPath -Encoding Unicode) -join '').Trim()
    if(-not$raw){return @()}
    $jsonStart=$raw.IndexOf('[');$jsonEnd=$raw.LastIndexOf(']')
    if($jsonStart-ge0-and$jsonEnd-ge$jsonStart){$raw=$raw.Substring($jsonStart,$jsonEnd-$jsonStart+1)}
    try{return @($raw|ConvertFrom-Json)}catch{throw "XEvent query '$Name' returned invalid JSON: $($_.Exception.Message)`n$($raw.Substring(0,[Math]::Min(1000,$raw.Length)))"}
}
function Window([datetime]$Start,[datetime]$End){return "event_time >= CONVERT(datetime2(3),'$(Sql-Date $Start)') AND event_time <= CONVERT(datetime2(3),'$(Sql-Date $End)' )"}
$case=Sql-String $CaseId
$immediate=Window $ImmediateStartUtc $ImmediateEndUtc
$persistence=Window $PersistenceStartUtc $PersistenceEndUtc
try{
    $databaseCheck=Invoke-JsonQuery 'database_check' @"
SELECT DB_NAME() AS database_name,
       (SELECT MIN(event_time) FROM xe.raw_events WHERE case_id=$case) AS min_event_utc,
       (SELECT MAX(event_time) FROM xe.raw_events WHERE case_id=$case) AS max_event_utc,
       (SELECT COUNT_BIG(*) FROM xe.raw_events WHERE case_id=$case) AS raw_event_count
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    if($databaseCheck.Count-eq0-or[long]$databaseCheck[0].raw_event_count-eq0){throw "No imported raw events for case $CaseId in $Database"}
    $eventDistribution=Invoke-JsonQuery 'event_distribution' @"
SELECT event_name, COUNT_BIG(*) AS event_count, MIN(event_time) AS first_utc, MAX(event_time) AS last_utc
FROM xe.raw_events WHERE case_id=$case AND $persistence
GROUP BY event_name ORDER BY event_count DESC
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $schedulerImmediate=Invoke-JsonQuery 'scheduler_immediate' @"
SELECT event_name,event_time,sql_cpu_pct,system_idle_pct,scheduler_id,nonyielding_count
FROM xe.scheduler WHERE case_id=$case AND $immediate
ORDER BY event_time
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $schedulerAnomalies=Invoke-JsonQuery 'scheduler_anomalies' @"
SELECT TOP (1000) event_name,event_time,sql_cpu_pct,system_idle_pct,scheduler_id,nonyielding_count
FROM xe.scheduler WHERE case_id=$case AND $persistence
  AND (event_name LIKE '%non_yielding%' OR event_name LIKE '%deadlock%'
       OR ISNULL(nonyielding_count,0)>0 OR ISNULL(sql_cpu_pct,0)>75)
ORDER BY event_time
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $schedulerSummary=Invoke-JsonQuery 'scheduler_summary' @"
SELECT COUNT_BIG(*) AS sample_count,AVG(CONVERT(float,sql_cpu_pct)) AS avg_sql_cpu_pct,
       MAX(sql_cpu_pct) AS max_sql_cpu_pct,AVG(CONVERT(float,system_idle_pct)) AS avg_system_idle_pct,
       MIN(system_idle_pct) AS min_system_idle_pct,
       SUM(CASE WHEN ISNULL(sql_cpu_pct,0)>75 THEN 1 ELSE 0 END) AS high_cpu_sample_count,
       SUM(CASE WHEN event_name LIKE '%non_yielding%' THEN 1 ELSE 0 END) AS non_yield_event_count,
       MIN(event_time) AS first_utc,MAX(event_time) AS last_utc
FROM xe.scheduler WHERE case_id=$case AND $persistence
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $schedulerHourly=Invoke-JsonQuery 'scheduler_hourly' @"
SELECT CONVERT(varchar(13),event_time,126) AS hour_utc,COUNT_BIG(*) AS sample_count,
       AVG(CONVERT(float,sql_cpu_pct)) AS avg_sql_cpu_pct,MAX(sql_cpu_pct) AS max_sql_cpu_pct,
       MIN(system_idle_pct) AS min_system_idle_pct,MAX(nonyielding_count) AS max_nonyielding_count,
       SUM(CASE WHEN event_name LIKE '%non_yielding%' THEN 1 ELSE 0 END) AS non_yield_event_count
FROM xe.scheduler WHERE case_id=$case AND $persistence
GROUP BY CONVERT(varchar(13),event_time,126) ORDER BY hour_utc
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $rawNonYield=Invoke-JsonQuery 'raw_non_yield' @"
SELECT TOP (200) event_name,event_time,CONVERT(nvarchar(max),event_data) AS event_xml
FROM xe.raw_events WHERE case_id=$case AND $persistence
    AND (event_name LIKE '%non_yielding%' OR event_name LIKE '%nonyield%'
             OR event_name LIKE 'scheduler_monitor%deadlock%')
ORDER BY event_time
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
        $copiedStackSummary=Invoke-JsonQuery 'copied_stack_summary' @"
WITH copied AS (
        SELECT event_time,
            event_data.value('(event/data[@name="nonyield_type"]/value)[1]','int') AS nonyield_type,
            event_data.value('(event/data[@name="scheduler_id"]/value)[1]','int') AS scheduler_id,
            event_data.value('(event/data[@name="thread_id"]/value)[1]','bigint') AS thread_id,
            event_data.value('(event/data[@name="task"]/value)[1]','nvarchar(64)') AS task,
            event_data.value('(event/data[@name="worker"]/value)[1]','nvarchar(64)') AS worker,
            event_data.value('(event/data[@name="session_id"]/value)[1]','int') AS session_id
        FROM xe.raw_events WHERE case_id=$case AND $persistence
            AND event_name='nonyield_copiedstack_ring_buffer_recorded'
)
SELECT nonyield_type,scheduler_id,thread_id,task,worker,session_id,COUNT_BIG(*) AS event_count,
             MIN(event_time) AS first_utc,MAX(event_time) AS last_utc
FROM copied GROUP BY nonyield_type,scheduler_id,thread_id,task,worker,session_id
ORDER BY first_utc
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $diagnosticSummary=Invoke-JsonQuery 'diagnostic_summary' @"
SELECT component,state_desc,COUNT_BIG(*) AS event_count,MIN(event_time) AS first_utc,MAX(event_time) AS last_utc
FROM xe.diagnostics WHERE case_id=$case AND $persistence
GROUP BY component,state_desc ORDER BY component,state_desc
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $diagnosticAlerts=Invoke-JsonQuery 'diagnostic_alerts' @"
SELECT TOP (500) event_time,component,state_desc,LEFT(data_xml,12000) AS data_xml
FROM xe.diagnostics WHERE case_id=$case AND $persistence
  AND LOWER(ISNULL(state_desc,'')) IN ('warning','error')
ORDER BY event_time,component
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
        $resourceWarnings=Invoke-JsonQuery 'resource_warnings' @"
SELECT event_time,component,state_desc,LEFT(data_xml,12000) AS data_xml
FROM xe.diagnostics WHERE case_id=$case AND $persistence
    AND component='RESOURCE' AND LOWER(ISNULL(state_desc,''))='warning'
ORDER BY event_time
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $waitImmediate=Invoke-JsonQuery 'wait_immediate' @"
SELECT TOP (100) wait_type,COUNT_BIG(*) AS event_count,SUM(duration_ms) AS total_duration_ms,
       SUM(signal_duration_ms) AS total_signal_ms,MAX(duration_ms) AS max_duration_ms,
       MIN(event_time) AS first_utc,MAX(event_time) AS last_utc
FROM xe.waits WHERE case_id=$case AND $immediate
GROUP BY wait_type ORDER BY total_duration_ms DESC
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $waitPersistence=Invoke-JsonQuery 'wait_persistence' @"
SELECT TOP (100) wait_type,COUNT_BIG(*) AS event_count,SUM(duration_ms) AS total_duration_ms,
       SUM(signal_duration_ms) AS total_signal_ms,MAX(duration_ms) AS max_duration_ms,
       MIN(event_time) AS first_utc,MAX(event_time) AS last_utc
FROM xe.waits WHERE case_id=$case AND $persistence
GROUP BY wait_type ORDER BY total_duration_ms DESC
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $errors=Invoke-JsonQuery 'errors' @"
SELECT error_number,severity,state,COUNT_BIG(*) AS event_count,MIN(event_time) AS first_utc,
       MAX(event_time) AS last_utc,MAX(LEFT(message,1000)) AS message_sample
FROM xe.errors WHERE case_id=$case AND $persistence
GROUP BY error_number,severity,state ORDER BY event_count DESC
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $memoryBroker=Invoke-JsonQuery 'memory_broker' @"
SELECT TOP (500) event_time,broker_type,notification,memory_ratio,last_target_kb,current_target_kb
FROM xe.memory_broker WHERE case_id=$case AND $persistence
ORDER BY event_time
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $memoryBrokerSummary=Invoke-JsonQuery 'memory_broker_summary' @"
SELECT COUNT_BIG(*) AS sample_count,MIN(memory_ratio) AS min_memory_ratio,MAX(memory_ratio) AS max_memory_ratio,
       MIN(last_target_kb) AS min_last_target_kb,MAX(last_target_kb) AS max_last_target_kb,
       MIN(current_target_kb) AS min_current_target_kb,MAX(current_target_kb) AS max_current_target_kb,
       MIN(event_time) AS first_utc,MAX(event_time) AS last_utc
FROM xe.memory_broker WHERE case_id=$case AND $persistence
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $deadlocks=Invoke-JsonQuery 'deadlocks' @"
SELECT event_time,LEFT(deadlock_xml,12000) AS deadlock_xml
FROM xe.deadlocks WHERE case_id=$case AND $persistence
ORDER BY event_time
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    $result=[ordered]@{
        analysisType='sql-csi-imported-non-yield-xevent';schemaVersion=1;caseId=$CaseId;generatedAt=(Get-Date).ToString('o')
        source=[ordered]@{server=$ServerInstance;database=$Database;timeBasis='UTC as stored by import-xevent';databaseCheck=$databaseCheck[0]}
        windows=[ordered]@{immediate=[ordered]@{startUtc=(Sql-Date $ImmediateStartUtc);endUtc=(Sql-Date $ImmediateEndUtc)};persistence=[ordered]@{startUtc=(Sql-Date $PersistenceStartUtc);endUtc=(Sql-Date $PersistenceEndUtc)}}
        eventDistribution=$eventDistribution;scheduler=[ordered]@{summary=if($schedulerSummary.Count){$schedulerSummary[0]}else{$null};immediate=$schedulerImmediate;anomalies=$schedulerAnomalies;hourly=$schedulerHourly;rawNonYield=$rawNonYield;copiedStackSummary=$copiedStackSummary}
        diagnostics=[ordered]@{summary=$diagnosticSummary;alerts=$diagnosticAlerts;resourceWarnings=$resourceWarnings};waits=[ordered]@{immediate=$waitImmediate;persistence=$waitPersistence}
        errors=$errors;memoryBroker=[ordered]@{summary=if($memoryBrokerSummary.Count){$memoryBrokerSummary[0]}else{$null};samples=$memoryBroker};deadlocks=$deadlocks
        limitations=@('Imported XEvent sessions are thresholded and may omit short waits or event types not enabled in the source session.','This extractor summarizes imported evidence; causal interpretation belongs in analyze-xevent/non-yielding-analysis.','All timestamps are UTC and require explicit alignment to ERRORLOG local time.')
    }
    $parent=Split-Path -Parent $OutJson;if($parent-and-not(Test-Path $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $tmp="$OutJson.tmp";[IO.File]::WriteAllText($tmp,($result|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false));[IO.File]::Move($tmp,$OutJson,$true)
    Write-Host "[analyze_imported_non_yield_xevent] PASS: scheduler=$($schedulerImmediate.Count) anomalies=$($schedulerAnomalies.Count) diagnosticsAlerts=$($diagnosticAlerts.Count) -> $OutJson" -ForegroundColor Green
} finally {if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force}}
exit 0
