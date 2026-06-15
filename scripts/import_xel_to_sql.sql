-- =============================================================================
-- SQL-CSI: Import XEvent (.xel) into SQL Server for analysis
-- Creates database [xevent_$(case_id)] with physical tables.
-- All system_health event types are shredded into dedicated tables.
--
-- Usage:
--   sqlcmd -S localhost -E -v case_id="2604300030000700" xel_path="C:\Temp\...\system_health*.xel" days=3 -i scripts/import_xel_to_sql.sql
--   Or edit the :setvar defaults below and run directly.
-- =============================================================================

-- Defaults (overridden by sqlcmd -v)
:setvar case_id "2606010030001676"
:setvar xel_path "C:\Temp\2606010030001676\db02log0601\db02log519\system_health_0_*.xel"
:setvar days "30"

USE master;
GO

-- Create database per case
IF DB_ID(N'xevent_$(case_id)') IS NULL
BEGIN
    CREATE DATABASE [xevent_$(case_id)];
    PRINT 'Created database [xevent_$(case_id)]';
END
ELSE
    PRINT 'Database [xevent_$(case_id)] already exists';
GO

USE [xevent_$(case_id)];
GO

SET NOCOUNT ON;
DECLARE @t0 DATETIME2 = SYSDATETIME(), @step_start DATETIME2;
DECLARE @rc INT;

-- =====================================================================
-- Step 0: Create schema + tables (DROP+CREATE for clean re-runs)
-- =====================================================================
IF SCHEMA_ID('xe') IS NULL EXEC('CREATE SCHEMA xe');

-- Raw events (preserve across re-runs of same case by DELETE)
IF OBJECT_ID('xe.raw_events') IS NULL
CREATE TABLE xe.raw_events (
    id          INT IDENTITY PRIMARY KEY,
    case_id     NVARCHAR(50) NOT NULL,
    event_name  NVARCHAR(100) NOT NULL,
    event_time  DATETIME2(3) NOT NULL,
    event_data  XML NOT NULL,
    INDEX ix_case_event (case_id, event_name),
    INDEX ix_event_time (event_time)
);
DELETE FROM xe.raw_events WHERE case_id = N'$(case_id)';

-- Shredded tables: DROP+CREATE for schema evolution
IF OBJECT_ID('xe.errors') IS NOT NULL DROP TABLE xe.errors;
CREATE TABLE xe.errors (
    id              INT IDENTITY PRIMARY KEY,
    case_id         NVARCHAR(50) NOT NULL,
    raw_id          INT NOT NULL,
    event_time      DATETIME2(3) NOT NULL,
    error_number    INT NOT NULL,
    severity        INT,
    state           INT,
    message         NVARCHAR(MAX),
    database_name   NVARCHAR(128),
    session_id      INT,
    client_hostname NVARCHAR(128),
    INDEX ix_error (case_id, error_number),
    INDEX ix_time  (event_time),
    INDEX ix_sev   (severity)
);

IF OBJECT_ID('xe.waits') IS NOT NULL DROP TABLE xe.waits;
CREATE TABLE xe.waits (
    id                  INT IDENTITY PRIMARY KEY,
    case_id             NVARCHAR(50) NOT NULL,
    raw_id              INT NOT NULL,
    event_name          NVARCHAR(100),
    event_time          DATETIME2(3) NOT NULL,
    wait_type           NVARCHAR(100),
    duration_ms         BIGINT,
    signal_duration_ms  BIGINT,
    wait_resource       NVARCHAR(256),
    session_id          INT,
    database_name       NVARCHAR(128),
    INDEX ix_wait (case_id, wait_type),
    INDEX ix_time (event_time)
);

IF OBJECT_ID('xe.diagnostics') IS NOT NULL DROP TABLE xe.diagnostics;
CREATE TABLE xe.diagnostics (
    id          INT IDENTITY PRIMARY KEY,
    case_id     NVARCHAR(50) NOT NULL,
    raw_id      INT NOT NULL,
    event_time  DATETIME2(3) NOT NULL,
    component   NVARCHAR(50),
    state_desc  NVARCHAR(20),
    data_xml    NVARCHAR(MAX),
    INDEX ix_comp  (case_id, component),
    INDEX ix_state (state_desc),
    INDEX ix_time  (event_time)
);

IF OBJECT_ID('xe.scheduler') IS NOT NULL DROP TABLE xe.scheduler;
CREATE TABLE xe.scheduler (
    id                  INT IDENTITY PRIMARY KEY,
    case_id             NVARCHAR(50) NOT NULL,
    raw_id              INT NOT NULL,
    event_name          NVARCHAR(100),
    event_time          DATETIME2(3) NOT NULL,
    sql_cpu_pct         INT,
    system_idle_pct     INT,
    scheduler_id        INT,
    nonyielding_count   INT,
    INDEX ix_time (event_time)
);

IF OBJECT_ID('xe.deadlocks') IS NOT NULL DROP TABLE xe.deadlocks;
CREATE TABLE xe.deadlocks (
    id              INT IDENTITY PRIMARY KEY,
    case_id         NVARCHAR(50) NOT NULL,
    raw_id          INT NOT NULL,
    event_time      DATETIME2(3) NOT NULL,
    deadlock_xml    NVARCHAR(MAX),
    INDEX ix_time (event_time)
);

IF OBJECT_ID('xe.connectivity') IS NOT NULL DROP TABLE xe.connectivity;
CREATE TABLE xe.connectivity (
    id                      INT IDENTITY PRIMARY KEY,
    case_id                 NVARCHAR(50) NOT NULL,
    raw_id                  INT NOT NULL,
    event_time              DATETIME2(3) NOT NULL,
    conn_type               NVARCHAR(50),
    source_text             NVARCHAR(50),
    os_error                BIGINT,
    sni_error               BIGINT,
    sni_consumer_error      BIGINT,
    sni_provider            INT,
    state                   INT,
    session_id              INT,
    local_port              INT,
    remote_port             INT,
    local_host              NVARCHAR(50),
    remote_host             NVARCHAR(50),
    tds_flags               NVARCHAR(200),
    -- Login Timer: Top-level
    total_login_time_ms     INT,
    login_task_enqueued_ms  INT,
    network_writes_ms       INT,
    network_reads_ms        INT,
    -- Login Timer: SSL breakdown
    ssl_processing_ms       INT,
    ssl_net_reads_ms        INT,
    ssl_net_writes_ms       INT,
    ssl_secure_calls_ms     INT,
    ssl_enqueue_ms          INT,
    -- Login Timer: SSPI breakdown (AD/Windows auth)
    sspi_processing_ms      INT,
    sspi_net_reads_ms       INT,
    sspi_net_writes_ms      INT,
    sspi_secure_calls_ms    INT,
    sspi_enqueue_ms         INT,
    -- Login Timer: Server-side processing
    login_trigger_and_rg_ms INT,
    find_login_ms           INT,
    logon_triggers_ms       INT,
    exec_classifier_ms      INT,
    session_recover_ms      INT,
    -- Connection metadata
    connection_id           NVARCHAR(100),
    connection_peer_id      NVARCHAR(100),
    INDEX ix_time    (event_time),
    INDEX ix_sni_err (sni_consumer_error),
    INDEX ix_os_err  (os_error),
    INDEX ix_remote  (remote_host)
);

IF OBJECT_ID('xe.security_errors') IS NOT NULL DROP TABLE xe.security_errors;
CREATE TABLE xe.security_errors (
    id              INT IDENTITY PRIMARY KEY,
    case_id         NVARCHAR(50) NOT NULL,
    raw_id          INT NOT NULL,
    event_time      DATETIME2(3) NOT NULL,
    error_code      BIGINT,
    api_name        NVARCHAR(200),
    calling_api     NVARCHAR(200),
    session_id      INT,
    INDEX ix_time   (event_time),
    INDEX ix_err    (error_code),
    INDEX ix_api    (api_name)
);

IF OBJECT_ID('xe.memory_broker') IS NOT NULL DROP TABLE xe.memory_broker;
CREATE TABLE xe.memory_broker (
    id              INT IDENTITY PRIMARY KEY,
    case_id         NVARCHAR(50) NOT NULL,
    raw_id          INT NOT NULL,
    event_time      DATETIME2(3) NOT NULL,
    broker_type     NVARCHAR(100),
    notification    NVARCHAR(50),
    memory_ratio    FLOAT,
    last_target_kb  BIGINT,
    current_target_kb BIGINT,
    INDEX ix_time   (event_time),
    INDEX ix_broker (broker_type)
);

-- process_login_finish: captures ALL logins (success+failure) with full timer breakdown
-- Source: custom XEvent session (NOT system_health). Import only if events exist in raw_events.
IF OBJECT_ID('xe.login_timers') IS NOT NULL DROP TABLE xe.login_timers;
CREATE TABLE xe.login_timers (
    id                              INT IDENTITY PRIMARY KEY,
    case_id                         NVARCHAR(50) NOT NULL,
    raw_id                          INT NOT NULL,
    event_time                      DATETIME2(3) NOT NULL,
    is_success                      BIT,
    error                           INT,
    spid                            INT,
    session_id                      INT,
    -- Login Timer: Top-level
    total_login_time_ms             INT,
    login_task_enqueued_ms          INT,
    network_writes_ms               INT,
    network_reads_ms                INT,
    -- Login Timer: SSL breakdown
    ssl_processing_ms               INT,
    ssl_net_reads_ms                INT,
    ssl_net_writes_ms               INT,
    ssl_secure_calls_ms             INT,
    ssl_enqueue_ms                  INT,
    -- Login Timer: SSPI breakdown (AD/Windows auth)
    sspi_processing_ms              INT,
    sspi_net_reads_ms               INT,
    sspi_net_writes_ms              INT,
    sspi_secure_calls_ms            INT,
    sspi_enqueue_ms                 INT,
    -- Login Timer: Server-side processing
    login_trigger_and_rg_ms         INT,
    find_login_ms                   INT,
    logon_triggers_ms               INT,
    exec_classifier_ms              INT,
    session_recover_ms              INT,
    -- Login Timer: FedAuth / Azure AD
    fedauth_processing_ms           INT,
    fedauth_net_reads_ms            INT,
    fedauth_net_writes_ms           INT,
    fedauth_secure_calls_ms         INT,
    fedauth_enqueue_ms              INT,
    fedauth_aad_processing_ms       INT,
    fedauth_aad_retry_count         INT,
    -- Login Timer: Misc
    contained_auth_ms               INT,
    db_firewall_rules_ms            INT,
    dosguard_check_ms               INT,
    -- Connection metadata
    application_name                NVARCHAR(256),
    driver_name                     NVARCHAR(256),
    client_hostname                 NVARCHAR(128),
    connection_id                   NVARCHAR(100),
    INDEX ix_time    (event_time),
    INDEX ix_success (is_success),
    INDEX ix_total   (total_login_time_ms)
);

PRINT CONCAT('Tables ready. (', DATEDIFF(ms, @t0, SYSDATETIME()), ' ms)');

-- =====================================================================
-- Step 1: Load raw events
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '';
PRINT '== Step 1: Load raw events ==';
PRINT 'Path: ' + N'$(xel_path)';

-- NOTE: XEL @timestamp is always UTC. Stored as-is.
-- Convert to source server local time during ANALYSIS, not here.
INSERT INTO xe.raw_events (case_id, event_name, event_time, event_data)
SELECT
    N'$(case_id)',
    object_name,
    CAST(event_data AS XML).value('(event/@timestamp)[1]', 'datetime2(3)'),
    CAST(event_data AS XML)
FROM sys.fn_xe_file_target_read_file(N'$(xel_path)', NULL, NULL, NULL);

SET @rc = @@ROWCOUNT;
PRINT CONCAT('  Loaded: ', @rc, ' events (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- Time filter using $(days)
IF $(days) > 0
BEGIN
    DECLARE @cutoff DATETIME2(3);
    SELECT @cutoff = DATEADD(DAY, -$(days), MAX(event_time)) FROM xe.raw_events WHERE case_id = N'$(case_id)';
    DELETE FROM xe.raw_events WHERE case_id = N'$(case_id)' AND event_time < @cutoff;
    DECLARE @kept INT;
    SELECT @kept = COUNT(*) FROM xe.raw_events WHERE case_id = N'$(case_id)';
    PRINT CONCAT('  After -', $(days), 'd filter: ', @kept, ' (cutoff ', FORMAT(@cutoff, 'yyyy-MM-dd HH:mm:ss'), ')');
END

-- Distribution
SELECT event_name, COUNT(*) AS cnt
FROM xe.raw_events WHERE case_id = N'$(case_id)'
GROUP BY event_name ORDER BY cnt DESC;

-- =====================================================================
-- Step 2: error_reported
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '';
PRINT '== Step 2: error_reported ==';

INSERT INTO xe.errors (case_id, raw_id, event_time, error_number, severity, state, message, database_name, session_id, client_hostname)
SELECT N'$(case_id)', id, event_time,
    event_data.value('(event/data[@name="error_number"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="severity"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="state"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="message"]/value)[1]', 'nvarchar(max)'),
    event_data.value('(event/action[@name="database_name"]/value)[1]', 'nvarchar(128)'),
    event_data.value('(event/action[@name="session_id"]/value)[1]', 'int'),
    event_data.value('(event/action[@name="client_hostname"]/value)[1]', 'nvarchar(128)')
FROM xe.raw_events WHERE case_id = N'$(case_id)' AND event_name = 'error_reported';

PRINT CONCAT('  Rows: ', @@ROWCOUNT, ' (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- =====================================================================
-- Step 3: wait_info / wait_info_external
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '== Step 3: wait_info ==';

INSERT INTO xe.waits (case_id, raw_id, event_name, event_time, wait_type, duration_ms, signal_duration_ms, wait_resource, session_id, database_name)
SELECT N'$(case_id)', id, event_name, event_time,
    event_data.value('(event/data[@name="wait_type"]/text)[1]', 'nvarchar(100)'),
    event_data.value('(event/data[@name="duration"]/value)[1]', 'bigint'),
    event_data.value('(event/data[@name="signal_duration"]/value)[1]', 'bigint'),
    event_data.value('(event/data[@name="wait_resource"]/value)[1]', 'nvarchar(256)'),
    event_data.value('(event/action[@name="session_id"]/value)[1]', 'int'),
    event_data.value('(event/action[@name="database_name"]/value)[1]', 'nvarchar(128)')
FROM xe.raw_events WHERE case_id = N'$(case_id)' AND event_name IN ('wait_info', 'wait_info_external');

PRINT CONCAT('  Rows: ', @@ROWCOUNT, ' (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- =====================================================================
-- Step 4: sp_server_diagnostics_component_result
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '== Step 4: sp_server_diagnostics ==';

INSERT INTO xe.diagnostics (case_id, raw_id, event_time, component, state_desc, data_xml)
SELECT N'$(case_id)', id, event_time,
    event_data.value('(event/data[@name="component"]/text)[1]', 'nvarchar(50)'),
    COALESCE(
        event_data.value('(event/data[@name="state"]/text)[1]', 'nvarchar(20)'),
        event_data.value('(event/data[@name="state_desc"]/text)[1]', 'nvarchar(20)')
    ),
    event_data.value('(event/data[@name="data"]/value)[1]', 'nvarchar(max)')
FROM xe.raw_events WHERE case_id = N'$(case_id)' AND event_name = 'sp_server_diagnostics_component_result';

PRINT CONCAT('  Rows: ', @@ROWCOUNT, ' (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- =====================================================================
-- Step 5: scheduler_monitor_*
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '== Step 5: scheduler_monitor ==';

INSERT INTO xe.scheduler (case_id, raw_id, event_name, event_time, sql_cpu_pct, system_idle_pct, scheduler_id, nonyielding_count)
SELECT N'$(case_id)', id, event_name, event_time,
    event_data.value('(event/data[@name="process_utilization"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="system_idle"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="scheduler_id"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="nonyielding_workers_count"]/value)[1]', 'int')
FROM xe.raw_events WHERE case_id = N'$(case_id)' AND event_name LIKE 'scheduler_monitor%';

PRINT CONCAT('  Rows: ', @@ROWCOUNT, ' (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- =====================================================================
-- Step 6: xml_deadlock_report
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '== Step 6: deadlocks ==';

INSERT INTO xe.deadlocks (case_id, raw_id, event_time, deadlock_xml)
SELECT N'$(case_id)', id, event_time,
    event_data.value('(event/data[@name="xml_report"]/value)[1]', 'nvarchar(max)')
FROM xe.raw_events WHERE case_id = N'$(case_id)' AND event_name = 'xml_deadlock_report';

PRINT CONCAT('  Rows: ', @@ROWCOUNT, ' (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- =====================================================================
-- Step 7: connectivity_ring_buffer_recorded (rich fields)
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '== Step 7: connectivity ==';

INSERT INTO xe.connectivity (
    case_id, raw_id, event_time, conn_type, source_text,
    os_error, sni_error, sni_consumer_error, sni_provider, state, session_id,
    local_port, remote_port, local_host, remote_host, tds_flags,
    total_login_time_ms, login_task_enqueued_ms, network_writes_ms, network_reads_ms,
    ssl_processing_ms, ssl_net_reads_ms, ssl_net_writes_ms, ssl_secure_calls_ms, ssl_enqueue_ms,
    sspi_processing_ms, sspi_net_reads_ms, sspi_net_writes_ms, sspi_secure_calls_ms, sspi_enqueue_ms,
    login_trigger_and_rg_ms, find_login_ms, logon_triggers_ms, exec_classifier_ms, session_recover_ms,
    connection_id, connection_peer_id)
SELECT N'$(case_id)', id, event_time,
    event_data.value('(event/data[@name="type"]/text)[1]', 'nvarchar(50)'),
    event_data.value('(event/data[@name="source"]/text)[1]', 'nvarchar(50)'),
    event_data.value('(event/data[@name="os_error"]/value)[1]', 'bigint'),
    event_data.value('(event/data[@name="sni_error"]/value)[1]', 'bigint'),
    event_data.value('(event/data[@name="sni_consumer_error"]/value)[1]', 'bigint'),
    event_data.value('(event/data[@name="sni_provider"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="state"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="session_id"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="local_port"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="remote_port"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="local_host"]/value)[1]', 'nvarchar(50)'),
    event_data.value('(event/data[@name="remote_host"]/value)[1]', 'nvarchar(50)'),
    event_data.value('(event/data[@name="tds_flags"]/text)[1]', 'nvarchar(200)'),
    -- Top-level login timers
    event_data.value('(event/data[@name="total_login_time_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="login_task_enqueued_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="network_writes_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="network_reads_ms"]/value)[1]', 'int'),
    -- SSL breakdown
    event_data.value('(event/data[@name="ssl_processing_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="ssl_net_reads_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="ssl_net_writes_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="ssl_secure_calls_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="ssl_enqueue_ms"]/value)[1]', 'int'),
    -- SSPI breakdown
    event_data.value('(event/data[@name="sspi_processing_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="sspi_net_reads_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="sspi_net_writes_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="sspi_secure_calls_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="sspi_enqueue_ms"]/value)[1]', 'int'),
    -- Server-side processing
    event_data.value('(event/data[@name="login_trigger_and_resource_governor_processing_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="find_login_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="logon_triggers_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="exec_classifier_ms"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="session_recover_ms"]/value)[1]', 'int'),
    -- Connection metadata
    event_data.value('(event/data[@name="connection_id"]/value)[1]', 'nvarchar(100)'),
    event_data.value('(event/data[@name="connection_peer_id"]/value)[1]', 'nvarchar(100)')
FROM xe.raw_events WHERE case_id = N'$(case_id)' AND event_name = 'connectivity_ring_buffer_recorded';

PRINT CONCAT('  Rows: ', @@ROWCOUNT, ' (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- =====================================================================
-- Step 8: security_error_ring_buffer_recorded
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '== Step 8: security_errors ==';

INSERT INTO xe.security_errors (case_id, raw_id, event_time, error_code, api_name, calling_api, session_id)
SELECT N'$(case_id)', id, event_time,
    event_data.value('(event/data[@name="error_code"]/value)[1]', 'bigint'),
    event_data.value('(event/data[@name="api_name"]/value)[1]', 'nvarchar(200)'),
    event_data.value('(event/data[@name="calling_api_name"]/value)[1]', 'nvarchar(200)'),
    event_data.value('(event/data[@name="session_id"]/value)[1]', 'int')
FROM xe.raw_events WHERE case_id = N'$(case_id)' AND event_name = 'security_error_ring_buffer_recorded';

PRINT CONCAT('  Rows: ', @@ROWCOUNT, ' (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- =====================================================================
-- Step 9: memory_broker_ring_buffer_recorded
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '== Step 9: memory_broker ==';

INSERT INTO xe.memory_broker (case_id, raw_id, event_time, broker_type, notification, memory_ratio, last_target_kb, current_target_kb)
SELECT N'$(case_id)', id, event_time,
    event_data.value('(event/data[@name="broker_type"]/value)[1]', 'nvarchar(100)'),
    event_data.value('(event/data[@name="notification_type"]/text)[1]', 'nvarchar(50)'),
    event_data.value('(event/data[@name="memory_ratio"]/value)[1]', 'float'),
    event_data.value('(event/data[@name="last_target_kb"]/value)[1]', 'bigint'),
    event_data.value('(event/data[@name="current_target_kb"]/value)[1]', 'bigint')
FROM xe.raw_events WHERE case_id = N'$(case_id)' AND event_name = 'memory_broker_ring_buffer_recorded';

PRINT CONCAT('  Rows: ', @@ROWCOUNT, ' (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- =====================================================================
-- Step 10: process_login_finish (custom XEvent session, not system_health)
-- Captures ALL logins (success + failure) with full timer breakdown.
-- Only imports if events exist in raw_events.
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '== Step 10: process_login_finish ==';

IF EXISTS (SELECT 1 FROM xe.raw_events WHERE case_id = N'$(case_id)' AND event_name = 'process_login_finish')
BEGIN
    INSERT INTO xe.login_timers (
        case_id, raw_id, event_time, is_success, error, spid, session_id,
        total_login_time_ms, login_task_enqueued_ms, network_writes_ms, network_reads_ms,
        ssl_processing_ms, ssl_net_reads_ms, ssl_net_writes_ms, ssl_secure_calls_ms, ssl_enqueue_ms,
        sspi_processing_ms, sspi_net_reads_ms, sspi_net_writes_ms, sspi_secure_calls_ms, sspi_enqueue_ms,
        login_trigger_and_rg_ms, find_login_ms, logon_triggers_ms, exec_classifier_ms, session_recover_ms,
        fedauth_processing_ms, fedauth_net_reads_ms, fedauth_net_writes_ms, fedauth_secure_calls_ms,
        fedauth_enqueue_ms, fedauth_aad_processing_ms, fedauth_aad_retry_count,
        contained_auth_ms, db_firewall_rules_ms, dosguard_check_ms,
        application_name, driver_name, client_hostname, connection_id)
    SELECT N'$(case_id)', id, event_time,
        event_data.value('(event/data[@name="is_success"]/value)[1]', 'bit'),
        event_data.value('(event/data[@name="error"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="spid"]/value)[1]', 'int'),
        event_data.value('(event/action[@name="session_id"]/value)[1]', 'int'),
        -- Top-level login timers
        event_data.value('(event/data[@name="total_time_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="enqueue_time_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="netwrite_time_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="netread_time_ms"]/value)[1]', 'int'),
        -- SSL breakdown
        event_data.value('(event/data[@name="ssl_time_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="ssl_net_reads_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="ssl_net_writes_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="ssl_secure_call_time_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="ssl_enqueue_ms"]/value)[1]', 'int'),
        -- SSPI breakdown
        event_data.value('(event/data[@name="sspi_time_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="sspi_net_reads_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="sspi_net_writes_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="sspi_secure_call_time_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="sspi_enqueue_ms"]/value)[1]', 'int'),
        -- Server-side processing
        event_data.value('(event/data[@name="login_trigger_and_resource_governor_processing_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="find_login_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="logon_triggers_time_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="exec_classifier_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="session_recover_ms"]/value)[1]', 'int'),
        -- FedAuth / Azure AD
        event_data.value('(event/data[@name="fedauth_processing_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="fedauth_net_reads_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="fedauth_net_writes_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="fedauth_secure_calls_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="fedauth_enqueue_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="fedauth_aad_processing_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="fedauth_aad_retry_count"]/value)[1]', 'int'),
        -- Misc
        event_data.value('(event/data[@name="contained_authentication_time_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="database_firewall_rules_time_ms"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="dosguard_check_time_ms"]/value)[1]', 'int'),
        -- Connection metadata
        event_data.value('(event/action[@name="client_app_name"]/value)[1]', 'nvarchar(256)'),
        event_data.value('(event/data[@name="driver_name"]/value)[1]', 'nvarchar(256)'),
        event_data.value('(event/action[@name="client_hostname"]/value)[1]', 'nvarchar(128)'),
        event_data.value('(event/data[@name="connection_id"]/value)[1]', 'nvarchar(100)')
    FROM xe.raw_events WHERE case_id = N'$(case_id)' AND event_name = 'process_login_finish';

    PRINT CONCAT('  Rows: ', @@ROWCOUNT, ' (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');
END
ELSE
    PRINT '  Skipped (no process_login_finish events in raw_events)';

-- =====================================================================
-- Summary
-- =====================================================================
DECLARE @elapsed_ms INT = DATEDIFF(ms, @t0, SYSDATETIME());
PRINT '';
PRINT '========================================';
PRINT '  Import Complete — ' + N'$(case_id)';
PRINT '========================================';
DECLARE @c1 INT, @c2 INT, @c3 INT, @c4 INT, @c5 INT, @c6 INT, @c7 INT, @c8 INT, @c9 INT, @c10 INT;
SELECT @c1 = COUNT(*) FROM xe.raw_events    WHERE case_id = N'$(case_id)';
SELECT @c2 = COUNT(*) FROM xe.errors        WHERE case_id = N'$(case_id)';
SELECT @c3 = COUNT(*) FROM xe.waits         WHERE case_id = N'$(case_id)';
SELECT @c4 = COUNT(*) FROM xe.diagnostics   WHERE case_id = N'$(case_id)';
SELECT @c5 = COUNT(*) FROM xe.scheduler     WHERE case_id = N'$(case_id)';
SELECT @c6 = COUNT(*) FROM xe.deadlocks     WHERE case_id = N'$(case_id)';
SELECT @c7 = COUNT(*) FROM xe.connectivity  WHERE case_id = N'$(case_id)';
SELECT @c8 = COUNT(*) FROM xe.security_errors WHERE case_id = N'$(case_id)';
SELECT @c9 = COUNT(*) FROM xe.memory_broker WHERE case_id = N'$(case_id)';
SELECT @c10 = COUNT(*) FROM xe.login_timers WHERE case_id = N'$(case_id)';
PRINT CONCAT('  Raw events:      ', @c1);
PRINT CONCAT('  Errors:          ', @c2);
PRINT CONCAT('  Waits:           ', @c3);
PRINT CONCAT('  Diagnostics:     ', @c4);
PRINT CONCAT('  Scheduler:       ', @c5);
PRINT CONCAT('  Deadlocks:       ', @c6);
PRINT CONCAT('  Connectivity:    ', @c7);
PRINT CONCAT('  Security errors: ', @c8);
PRINT CONCAT('  Memory broker:   ', @c9);
PRINT CONCAT('  Login timers:    ', @c10);
PRINT '';
PRINT CONCAT('  Total elapsed: ', @elapsed_ms / 1000, '.', RIGHT('000' + CAST(@elapsed_ms % 1000 AS VARCHAR), 3), ' s');
GO

