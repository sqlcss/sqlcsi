USE xevent_2606030030001166;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'xe') EXEC('CREATE SCHEMA xe');
GO

IF OBJECT_ID('xe.login_events') IS NOT NULL DROP TABLE xe.login_events;
GO

;WITH raw AS (
    SELECT 
        CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file(
        N'C:\Temp\2606030030001166\LoginTimerCapture_trace_0_134249432247960000.xel',
        NULL, NULL, NULL)
)
SELECT
    x.value('(event/@timestamp)[1]', 'datetime2(3)') AS event_time_utc,
    DATEADD(HOUR, 8, x.value('(event/@timestamp)[1]', 'datetime2(3)')) AS event_time_local,
    -- Success / Error
    x.value('(event/data[@name="is_success"]/value)[1]', 'varchar(10)') AS is_success,
    x.value('(event/data[@name="error"]/value)[1]', 'int') AS error_code,
    x.value('(event/data[@name="state"]/value)[1]', 'int') AS state,
    x.value('(event/data[@name="state_desc"]/text)[1]', 'nvarchar(200)') AS state_desc,
    x.value('(event/data[@name="is_user_error"]/value)[1]', 'varchar(10)') AS is_user_error,
    -- Main timings
    x.value('(event/data[@name="total_time_ms"]/value)[1]', 'int') AS total_time_ms,
    x.value('(event/data[@name="enqueue_time_ms"]/value)[1]', 'int') AS enqueue_time_ms,
    x.value('(event/data[@name="netwrite_time_ms"]/value)[1]', 'int') AS netwrite_time_ms,
    x.value('(event/data[@name="netread_time_ms"]/value)[1]', 'int') AS netread_time_ms,
    x.value('(event/data[@name="ssl_time_ms"]/value)[1]', 'int') AS ssl_time_ms,
    x.value('(event/data[@name="sspi_time_ms"]/value)[1]', 'int') AS sspi_time_ms,
    x.value('(event/data[@name="login_time_ms"]/value)[1]', 'int') AS login_time_ms,
    x.value('(event/data[@name="logon_triggers_time_ms"]/value)[1]', 'int') AS logon_triggers_time_ms,
    x.value('(event/data[@name="find_login_ms"]/value)[1]', 'int') AS find_login_ms,
    x.value('(event/data[@name="exec_classifier_ms"]/value)[1]', 'int') AS exec_classifier_ms,
    -- SSL sub-timings
    x.value('(event/data[@name="ssl_read_time_ms"]/value)[1]', 'int') AS ssl_read_time_ms,
    x.value('(event/data[@name="ssl_write_time_ms"]/value)[1]', 'int') AS ssl_write_time_ms,
    x.value('(event/data[@name="ssl_secure_call_time_ms"]/value)[1]', 'int') AS ssl_secure_call_time_ms,
    x.value('(event/data[@name="ssl_enqueue_time_ms"]/value)[1]', 'int') AS ssl_enqueue_time_ms,
    -- SSPI sub-timings (Windows/Kerberos auth)
    x.value('(event/data[@name="sspi_read_time_ms"]/value)[1]', 'int') AS sspi_read_time_ms,
    x.value('(event/data[@name="sspi_write_time_ms"]/value)[1]', 'int') AS sspi_write_time_ms,
    x.value('(event/data[@name="sspi_secure_call_time_ms"]/value)[1]', 'int') AS sspi_secure_call_time_ms,
    x.value('(event/data[@name="sspi_enqueue_time_ms"]/value)[1]', 'int') AS sspi_enqueue_time_ms,
    -- FedAuth timings
    x.value('(event/data[@name="fedauth_group_expansion_time_ms"]/value)[1]', 'int') AS fedauth_group_expansion_ms,
    x.value('(event/data[@name="fedauth_token_process_time_ms"]/value)[1]', 'int') AS fedauth_token_process_ms,
    -- Connection metadata
    x.value('(event/data[@name="spid"]/value)[1]', 'int') AS spid,
    x.value('(event/data[@name="client_pid"]/value)[1]', 'int') AS client_pid,
    x.value('(event/data[@name="peer_port"]/value)[1]', 'int') AS peer_port,
    x.value('(event/data[@name="concurrent_logins"]/value)[1]', 'int') AS concurrent_logins,
    x.value('(event/data[@name="provider_type"]/text)[1]', 'nvarchar(50)') AS provider_type,
    x.value('(event/data[@name="peer_address"]/value)[1]', 'nvarchar(50)') AS peer_address,
    x.value('(event/data[@name="application_name"]/value)[1]', 'nvarchar(256)') AS application_name,
    x.value('(event/data[@name="driver_name"]/value)[1]', 'nvarchar(256)') AS driver_name,
    x.value('(event/data[@name="server_name"]/value)[1]', 'nvarchar(256)') AS server_name,
    x.value('(event/data[@name="database_name"]/value)[1]', 'nvarchar(256)') AS database_name,
    x.value('(event/data[@name="connection_id"]/value)[1]', 'uniqueidentifier') AS connection_id
INTO xe.login_events
FROM raw;

PRINT 'Imported: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' login events';
GO
