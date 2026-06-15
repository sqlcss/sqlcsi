USE xevent_2606030030001166;
GO

;WITH raw AS (
    SELECT 
        CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file(
        N'C:\Temp\2606030030001166\LoginTimerCapture_trace_0_134249432247960000.xel',
        NULL, NULL, NULL)
)
SELECT
    DATEADD(HOUR, 8, x.value('(event/@timestamp)[1]', 'datetime2(3)')) AS time_local,
    x.value('(event/data[@name="is_success"]/value)[1]', 'varchar(10)') AS success,
    x.value('(event/data[@name="peer_port"]/value)[1]', 'int') AS port,
    x.value('(event/data[@name="connection_id"]/value)[1]', 'uniqueidentifier') AS connection_id,
    x.value('(event/data[@name="connection_peer_id"]/value)[1]', 'uniqueidentifier') AS connection_peer_id,
    x.value('(event/data[@name="peer_activity_id"]/value)[1]', 'uniqueidentifier') AS peer_activity_id,
    x.value('(event/data[@name="peer_activity_seq"]/value)[1]', 'int') AS peer_activity_seq
FROM raw
ORDER BY x.value('(event/@timestamp)[1]', 'datetime2(3)');
GO
