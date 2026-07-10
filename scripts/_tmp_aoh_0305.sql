SET NOCOUNT ON;
;WITH raw AS (
    SELECT CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file(
        N'C:\Temp\2606230030003998\HKHDCWSDBA001\AlwaysOn_health_0_*.xel',
        NULL, NULL, NULL)
)
SELECT
    DATEADD(HOUR,8, x.value('(/event/@timestamp)[1]','datetime2'))                  AS ts_local_dt,
    CONVERT(varchar(23), DATEADD(HOUR,8, x.value('(/event/@timestamp)[1]','datetime2')),121) AS ts_local,
    x.value('(/event/@name)[1]','nvarchar(128)')                                    AS event_name,
    x.value('(/event/data[@name="availability_replica_name"]/value)[1]','nvarchar(256)') AS replica_name,
    x.value('(/event/data[@name="previous_state"]/text)[1]','nvarchar(64)')         AS previous_state,
    x.value('(/event/data[@name="current_state"]/text)[1]','nvarchar(64)')          AS current_state,
    x.value('(/event/data[@name="ddl_phase"]/text)[1]','nvarchar(64)')              AS ddl_phase,
    x.value('(/event/data[@name="statement"]/value)[1]','nvarchar(max)')            AS statement
INTO #e
FROM raw
WHERE x.value('(/event/@name)[1]','nvarchar(128)') IN
      (N'availability_replica_state_change', N'availability_replica_manager_state_change', N'alwayson_ddl_executed');

SELECT ts_local, event_name, replica_name, previous_state, current_state, ddl_phase,
       LEFT(REPLACE(REPLACE(ISNULL(statement,''),CHAR(13),' '),CHAR(10),' '),120) AS stmt
FROM #e
WHERE ts_local_dt >= '2026-03-04 00:00:00' AND ts_local_dt < '2026-03-06 12:00:00'
ORDER BY ts_local_dt;
