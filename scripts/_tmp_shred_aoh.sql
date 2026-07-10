SET NOCOUNT ON;
DECLARE @path nvarchar(400) = N'$(AOHPATH)';
;WITH x AS (
    SELECT object_name,
           CAST(event_data AS XML) AS ev
    FROM sys.fn_xe_file_target_read_file(@path, NULL, NULL, NULL)
)
SELECT
    CONVERT(varchar(27), DATEADD(HOUR,8, ev.value('(/event/@timestamp)[1]','datetime2')), 121) AS ts_local,
    object_name AS evt,
    LEFT(
        ISNULL(ev.value('(/event/data[@name="message"]/value)[1]','nvarchar(max)'),
        ISNULL(ev.value('(/event/data[@name="current_state"]/text)[1]','nvarchar(max)'),
               ev.value('(/event/data[@name="state"]/text)[1]','nvarchar(max)')))
    , 400) AS info
FROM x
WHERE ev.value('(/event/@timestamp)[1]','datetime2') >= '2026-06-22T00:00:00'
  AND ev.value('(/event/@timestamp)[1]','datetime2') <  '2026-06-23T00:00:00'
ORDER BY ts_local;
