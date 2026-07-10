SET NOCOUNT ON;
SELECT CAST(event_data AS XML) AS x
INTO #e
FROM sys.fn_xe_file_target_read_file(
  N'C:\Temp\2606230030003998\HKHDCWSDBA001\AlwaysOn_health*.xel', NULL, NULL, NULL)
WHERE object_name = 'availability_replica_state_change';

SELECT
  CONVERT(varchar(23), DATEADD(HOUR,8, x.value('(/event/@timestamp)[1]','datetime2')),121) AS ts_local,
  x.value('(/event/data[@name="availability_replica_name"]/value)[1]','varchar(60)') AS replica,
  x.value('(/event/data[@name="previous_state"]/text)[1]','varchar(40)') AS prev_state,
  x.value('(/event/data[@name="current_state"]/text)[1]','varchar(40)') AS curr_state
FROM #e
ORDER BY ts_local;
