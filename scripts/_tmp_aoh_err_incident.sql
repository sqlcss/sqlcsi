SET NOCOUNT ON;
SELECT CAST(event_data AS XML) AS x, CAST(event_data AS XML).value('(/event/@timestamp)[1]','datetime2') AS ts
INTO #e
FROM sys.fn_xe_file_target_read_file(
  N'C:\Temp\2606230030003998\HKHDCWSDBA001\AlwaysOn_health*.xel', NULL, NULL, NULL)
WHERE object_name = 'error_reported';

SELECT
  CONVERT(varchar(23), DATEADD(HOUR,8, ts),121) AS ts_local,
  x.value('(/event/data[@name="error_number"]/value)[1]','int') AS err,
  x.value('(/event/data[@name="severity"]/value)[1]','int') AS sev,
  LEFT(x.value('(/event/data[@name="message"]/value)[1]','varchar(400)'),300) AS msg
FROM #e
WHERE ts >= '2026-06-22T03:00:00' AND ts < '2026-06-22T05:30:00'
ORDER BY ts;
