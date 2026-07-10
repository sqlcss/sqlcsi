SET NOCOUNT ON;
SELECT CAST(event_data AS XML) AS x
INTO #e
FROM sys.fn_xe_file_target_read_file(
  N'C:\Temp\2606230030003998\HKHDCWSDBA001\AlwaysOn_health*.xel', NULL, NULL, NULL)
WHERE object_name = 'hadr_db_partner_set_sync_state';

SELECT
  CONVERT(varchar(23), DATEADD(HOUR,8, x.value('(/event/@timestamp)[1]','datetime2')),121) AS ts_local,
  x.value('(/event/data[@name="database_id"]/value)[1]','int') AS dbid,
  x.value('(/event/data[@name="commit_policy"]/text)[1]','varchar(40)') AS commit_policy,
  x.value('(/event/data[@name="commit_policy_target"]/text)[1]','varchar(40)') AS commit_target,
  x.value('(/event/data[@name="sync_state"]/value)[1]','int') AS sync_val,
  x.value('(/event/data[@name="sync_state"]/text)[1]','varchar(40)') AS sync_state,
  x.value('(/event/data[@name="replica_id"]/value)[1]','varchar(40)') AS replica_id
FROM #e
ORDER BY ts_local;
