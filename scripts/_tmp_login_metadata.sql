USE xevent_2606030030001166;
GO

-- 1) All connection metadata for successful vs failed logins
PRINT '=== 1. Connection Metadata: Failed vs Successful ==='
;WITH raw AS (
    SELECT CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file(
        N'C:\Temp\2606030030001166\LoginTimerCapture_trace_0_134249432247960000.xel',
        NULL, NULL, NULL)
)
SELECT
    DATEADD(HOUR, 8, x.value('(event/@timestamp)[1]', 'datetime2(3)')) AS time_local,
    x.value('(event/data[@name="is_success"]/value)[1]', 'varchar(10)') AS success,
    x.value('(event/data[@name="peer_port"]/value)[1]', 'int') AS port,
    x.value('(event/data[@name="server_name"]/value)[1]', 'nvarchar(256)') AS server_name,
    x.value('(event/data[@name="instance_name"]/value)[1]', 'nvarchar(256)') AS instance_name,
    x.value('(event/data[@name="peer_address"]/value)[1]', 'nvarchar(50)') AS peer_address,
    x.value('(event/data[@name="sni_server_name"]/value)[1]', 'nvarchar(256)') AS sni_server_name,
    x.value('(event/data[@name="database_name"]/value)[1]', 'nvarchar(256)') AS database_name,
    x.value('(event/data[@name="application_name"]/value)[1]', 'nvarchar(256)') AS app_name,
    x.value('(event/data[@name="driver_name"]/value)[1]', 'nvarchar(256)') AS driver_name,
    x.value('(event/data[@name="total_time_ms"]/value)[1]', 'int') AS total_ms,
    x.value('(event/data[@name="netread_time_ms"]/value)[1]', 'int') AS netread_ms,
    x.value('(event/data[@name="sspi_time_ms"]/value)[1]', 'int') AS sspi_ms,
    x.value('(event/data[@name="sspi_secure_call_time_ms"]/value)[1]', 'int') AS sspi_secure_ms,
    x.value('(event/data[@name="ssl_protocol"]/text)[1]', 'nvarchar(50)') AS ssl_protocol,
    x.value('(event/data[@name="tds_version"]/value)[1]', 'bigint') AS tds_version,
    x.value('(event/data[@name="error"]/value)[1]', 'int') AS error_code,
    x.value('(event/data[@name="state_desc"]/text)[1]', 'nvarchar(200)') AS state_desc
FROM raw
ORDER BY x.value('(event/@timestamp)[1]', 'datetime2(3)');
GO
