SET NOCOUNT ON;
SELECT
  CAST(event_data AS XML).value('(/event/@name)[1]','varchar(100)') AS evt,
  CAST(event_data AS XML).value('(/event/@timestamp)[1]','datetime2') AS ts_utc
INTO #e
FROM sys.fn_xe_file_target_read_file(
  N'C:\Temp\2606230030003998\HKHDCWSDBA001\AlwaysOn_health*.xel', NULL, NULL, NULL);

SELECT evt, COUNT(*) AS cnt,
  CONVERT(varchar(19), DATEADD(HOUR,8, MIN(ts_utc)),121) AS first_local,
  CONVERT(varchar(19), DATEADD(HOUR,8, MAX(ts_utc)),121) AS last_local
FROM #e
GROUP BY evt
ORDER BY cnt DESC;
