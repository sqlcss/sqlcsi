SET NOCOUNT ON;
;WITH raw AS (
    SELECT CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file(
        N'C:\Temp\2606230030003998\HKHDCWSDBA001\AlwaysOn_health_0_*.xel',
        NULL, NULL, NULL)
)
SELECT
    CONVERT(varchar(23), DATEADD(HOUR,8, x.value('(/event/@timestamp)[1]','datetime2')),121) AS ts_local,
    x.value('(/event/data[@name="ddl_phase"]/text)[1]','nvarchar(64)')             AS ddl_phase,
    x.value('(/event/data[@name="availability_group_name"]/value)[1]','nvarchar(256)') AS ag_name,
    x.value('(/event/data[@name="ddl_action"]/text)[1]','nvarchar(64)')            AS ddl_action,
    x.value('(/event/data[@name="statement"]/value)[1]','nvarchar(max)')           AS statement
INTO #d
FROM raw
WHERE x.value('(/event/@name)[1]','nvarchar(128)') = N'alwayson_ddl_executed';

SELECT ts_local, ddl_phase, ddl_action, ag_name, statement
FROM #d
ORDER BY ts_local;
