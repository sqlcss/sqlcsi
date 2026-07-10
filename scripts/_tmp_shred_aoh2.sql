SET NOCOUNT ON;
DECLARE @path nvarchar(400) = N'$(AOHPATH)';
;WITH x AS (
    SELECT object_name,
           CAST(event_data AS XML) AS ev
    FROM sys.fn_xe_file_target_read_file(@path, NULL, NULL, NULL)
), y AS (
    SELECT
        ev.value('(/event/@timestamp)[1]','datetime2') AS ts_utc,
        object_name AS evt,
        COALESCE(
            ev.value('(/event/data[@name="hadr_message"]/value)[1]','nvarchar(max)'),
            ev.value('(/event/data[@name="message"]/value)[1]','nvarchar(max)'),
            ev.value('(/event/data[@name="current_state"]/text)[1]','nvarchar(max)'),
            ev.value('(/event/data[@name="state"]/text)[1]','nvarchar(max)'),
            ev.value('(/event/data[@name="current_state"]/value)[1]','nvarchar(max)')
        ) AS info
    FROM x
    WHERE object_name IN ('hadr_trace_message','error_reported','availability_replica_state_change','availability_replica_manager_state_change')
)
SELECT
    CONVERT(varchar(27), DATEADD(HOUR,8,ts_utc), 121) AS ts_local,
    evt,
    LEFT(REPLACE(REPLACE(info, CHAR(13),' '), CHAR(10),' '), 500) AS info
FROM y
WHERE ts_utc >= '2026-06-22T03:10:00' AND ts_utc < '2026-06-22T05:30:00'
ORDER BY ts_utc;
