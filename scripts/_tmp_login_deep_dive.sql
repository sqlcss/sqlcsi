USE xevent_2606030030001166;
GO

-- 1) Detailed timing for successful logins: where is netread time spent?
PRINT '=== 1. Successful Login Detailed Timing ==='
SELECT
    application_name,
    total_time_ms,
    netread_time_ms,
    -- Pre-SSPI netread = netread - sspi_read (time waiting for client BEFORE auth)
    netread_time_ms - sspi_read_time_ms AS netread_excluding_sspi_read,
    ssl_time_ms,
    ssl_read_time_ms,
    ssl_write_time_ms,
    ssl_secure_call_time_ms,
    sspi_time_ms,
    sspi_read_time_ms,
    sspi_write_time_ms,
    sspi_secure_call_time_ms,
    login_time_ms,
    find_login_ms,
    enqueue_time_ms,
    total_time_ms - netread_time_ms - netwrite_time_ms - ssl_time_ms - sspi_time_ms - login_time_ms - enqueue_time_ms AS unaccounted_ms
FROM xe.login_events
WHERE is_success = 'true' AND application_name LIKE 'Microsoft SQL Server Management Studio'
ORDER BY event_time_utc;
GO

-- 2) Compare: successful SSMS vs IntelliSense vs CEIP
PRINT '=== 2. Side-by-Side: SSMS Main vs IntelliSense vs CEIP ==='
SELECT
    application_name,
    COUNT(*) AS cnt,
    AVG(total_time_ms) AS avg_total,
    AVG(netread_time_ms) AS avg_netread,
    AVG(netread_time_ms - sspi_read_time_ms) AS avg_netread_excl_sspi,
    AVG(ssl_time_ms) AS avg_ssl,
    AVG(sspi_time_ms) AS avg_sspi,
    AVG(sspi_read_time_ms) AS avg_sspi_read,
    AVG(sspi_secure_call_time_ms) AS avg_sspi_secure,
    AVG(login_time_ms) AS avg_login,
    AVG(find_login_ms) AS avg_find_login
FROM xe.login_events
WHERE is_success = 'true'
GROUP BY application_name
ORDER BY AVG(total_time_ms) DESC;
GO

-- 3) Check: do failed events have any SSPI activity at all?
PRINT '=== 3. Failed vs Successful: Auth Method Evidence ==='
SELECT
    is_success,
    COUNT(*) AS cnt,
    AVG(sspi_time_ms) AS avg_sspi,
    AVG(sspi_read_time_ms) AS avg_sspi_read,
    AVG(sspi_secure_call_time_ms) AS avg_sspi_secure,
    AVG(ssl_time_ms) AS avg_ssl,
    AVG(ssl_read_time_ms) AS avg_ssl_read,
    SUM(CASE WHEN sspi_time_ms > 0 THEN 1 ELSE 0 END) AS has_sspi_activity,
    SUM(CASE WHEN ssl_time_ms > 0 THEN 1 ELSE 0 END) AS has_ssl_activity
FROM xe.login_events
GROUP BY is_success;
GO

-- 4) Check peer_activity_seq pattern between fail/success pairs
PRINT '=== 4. Peer Activity Seq Pattern ==='
;WITH raw AS (
    SELECT 
        CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file(
        N'C:\Temp\2606030030001166\LoginTimerCapture_trace_0_134249432247960000.xel',
        NULL, NULL, NULL)
),
parsed AS (
    SELECT
        DATEADD(HOUR, 8, x.value('(event/@timestamp)[1]', 'datetime2(3)')) AS time_local,
        x.value('(event/data[@name="is_success"]/value)[1]', 'varchar(10)') AS success,
        x.value('(event/data[@name="peer_port"]/value)[1]', 'int') AS port,
        x.value('(event/data[@name="peer_activity_seq"]/value)[1]', 'int') AS seq,
        x.value('(event/data[@name="netread_time_ms"]/value)[1]', 'int') AS netread,
        x.value('(event/data[@name="sspi_time_ms"]/value)[1]', 'int') AS sspi,
        x.value('(event/data[@name="total_time_ms"]/value)[1]', 'int') AS total,
        ROW_NUMBER() OVER (ORDER BY x.value('(event/@timestamp)[1]', 'datetime2(3)')) AS rn
    FROM raw
)
SELECT 
    time_local, success, port, seq, total, netread, sspi
FROM parsed
ORDER BY rn;
GO
