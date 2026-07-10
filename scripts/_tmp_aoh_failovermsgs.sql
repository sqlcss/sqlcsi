SET NOCOUNT ON;
SELECT CAST(event_data AS XML) AS x, CAST(event_data AS XML).value('(/event/@timestamp)[1]','datetime2') AS ts
INTO #e
FROM sys.fn_xe_file_target_read_file(
  N'C:\Temp\2606230030003998\HKHDCWSDBA001\AlwaysOn_health*.xel', NULL, NULL, NULL)
WHERE object_name = 'error_reported';

-- look for explicit force-failover / synchronization-state messages
SELECT CONVERT(varchar(23), DATEADD(HOUR,8, ts),121) AS ts_local,
  x.value('(/event/data[@name="error_number"]/value)[1]','int') AS err,
  LEFT(x.value('(/event/data[@name="message"]/value)[1]','varchar(500)'),420) AS msg
FROM #e
WHERE x.value('(/event/data[@name="error_number"]/value)[1]','int') IN (1480,41091,41092,41093,41094,41131,41142,41406,41414,19405,19406,19407)
ORDER BY ts_local;
