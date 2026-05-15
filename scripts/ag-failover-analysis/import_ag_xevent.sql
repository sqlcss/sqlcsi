-- =============================================================================
-- AG Failover Analysis: Import AlwaysOn_health + system_health XEL into SQL
-- Creates/uses database [ag_$(case_id)] with per-host AG event tables
--
-- Usage:
--   sqlcmd -S localhost -E -v case_id="2605110030000091" host="HKAZEPWDB0031" xel_path="C:\Temp\2605110030000091\HKAZEPWDB0031\AlwaysOn_health*.xel" -i scripts/ag-failover-analysis/import_ag_xevent.sql
--
-- Run once per host, once per XEL session type:
--   1. AlwaysOn_health for DB0031
--   2. AlwaysOn_health for DB0011
--   3. system_health for DB0031 (if available)
--   4. system_health for DB0011 (if available)
--   5. SQLDIAG for DB0031 (if available)
--   6. SQLDIAG for DB0011 (if available)
-- =============================================================================

-- Defaults — only used if not passed via sqlcmd -v
-- Comment out or change these for your case:
-- :setvar case_id "2605110030000091"
-- :setvar host "HKAZEPWDB0031"
-- :setvar xel_path "C:\Temp\2605110030000091\HKAZEPWDB0031\AlwaysOn_health*.xel"

USE master;
GO

IF DB_ID(N'ag_$(case_id)') IS NULL
BEGIN
    CREATE DATABASE [ag_$(case_id)];
    PRINT 'Created database [ag_$(case_id)]';
END
GO

USE [ag_$(case_id)];
GO

SET NOCOUNT ON;
IF SCHEMA_ID('xe') IS NULL EXEC('CREATE SCHEMA xe');
GO

-- =====================================================================
-- Raw events table (shared across all hosts and sessions)
-- =====================================================================
IF OBJECT_ID('xe.raw_events') IS NULL
CREATE TABLE xe.raw_events (
    id          INT IDENTITY PRIMARY KEY,
    host        NVARCHAR(50) NOT NULL,
    session     NVARCHAR(50) NOT NULL,
    event_name  NVARCHAR(100) NOT NULL,
    event_time  DATETIME2(3) NOT NULL,
    event_data  XML NOT NULL,
    INDEX ix_host_event (host, event_name),
    INDEX ix_event_time (event_time)
);

-- =====================================================================
-- Shredded tables (created once, appended per host)
-- =====================================================================

-- hadr_trace_message — Reverting begin/finished, AG internal messages
IF OBJECT_ID('xe.hadr_trace') IS NULL
CREATE TABLE xe.hadr_trace (
    id          INT IDENTITY PRIMARY KEY,
    host        NVARCHAR(50) NOT NULL,
    raw_id      INT NOT NULL,
    event_time  DATETIME2(3) NOT NULL,
    hadr_message NVARCHAR(MAX),
    INDEX ix_time (event_time),
    INDEX ix_host (host)
);

-- hadr_db_partner_set_sync_state — DB sync state changes
IF OBJECT_ID('xe.hadr_sync_state') IS NULL
CREATE TABLE xe.hadr_sync_state (
    id              INT IDENTITY PRIMARY KEY,
    host            NVARCHAR(50) NOT NULL,
    raw_id          INT NOT NULL,
    event_time      DATETIME2(3) NOT NULL,
    database_id     INT,
    sync_state      NVARCHAR(50),
    commit_policy   NVARCHAR(50),
    ag_database_id  NVARCHAR(100),
    INDEX ix_time (event_time),
    INDEX ix_host (host)
);

-- availability_replica_state_change — AG replica state transitions
IF OBJECT_ID('xe.hadr_replica_state') IS NULL
CREATE TABLE xe.hadr_replica_state (
    id              INT IDENTITY PRIMARY KEY,
    host            NVARCHAR(50) NOT NULL,
    raw_id          INT NOT NULL,
    event_time      DATETIME2(3) NOT NULL,
    ag_name         NVARCHAR(128),
    previous_state  NVARCHAR(50),
    current_state   NVARCHAR(50),
    INDEX ix_time (event_time),
    INDEX ix_host (host)
);

-- availability_replica_manager_state_change — AG manager ONLINE/OFFLINE
IF OBJECT_ID('xe.hadr_manager_state') IS NULL
CREATE TABLE xe.hadr_manager_state (
    id              INT IDENTITY PRIMARY KEY,
    host            NVARCHAR(50) NOT NULL,
    raw_id          INT NOT NULL,
    event_time      DATETIME2(3) NOT NULL,
    current_state   NVARCHAR(50),
    INDEX ix_time (event_time),
    INDEX ix_host (host)
);

-- alwayson_ddl_executed — DDL events
IF OBJECT_ID('xe.hadr_ddl') IS NULL
CREATE TABLE xe.hadr_ddl (
    id          INT IDENTITY PRIMARY KEY,
    host        NVARCHAR(50) NOT NULL,
    raw_id      INT NOT NULL,
    event_time  DATETIME2(3) NOT NULL,
    ddl_action  NVARCHAR(100),
    ddl_phase   NVARCHAR(50),
    statement   NVARCHAR(MAX),
    INDEX ix_time (event_time),
    INDEX ix_host (host)
);

-- sp_server_diagnostics (from system_health / SQLDIAG)
IF OBJECT_ID('xe.diagnostics') IS NULL
CREATE TABLE xe.diagnostics (
    id              INT IDENTITY PRIMARY KEY,
    host            NVARCHAR(50) NOT NULL,
    raw_id          INT NOT NULL,
    event_time      DATETIME2(3) NOT NULL,
    component       NVARCHAR(50),
    state           NVARCHAR(50),
    data_xml        NVARCHAR(MAX),
    INDEX ix_time (event_time),
    INDEX ix_host_comp (host, component)
);

-- errors (from system_health)
IF OBJECT_ID('xe.errors') IS NULL
CREATE TABLE xe.errors (
    id              INT IDENTITY PRIMARY KEY,
    host            NVARCHAR(50) NOT NULL,
    raw_id          INT NOT NULL,
    event_time      DATETIME2(3) NOT NULL,
    error_number    INT,
    severity        INT,
    message         NVARCHAR(MAX),
    INDEX ix_time (event_time),
    INDEX ix_host_err (host, error_number)
);

GO
-- =====================================================================
-- Step 1: Detect session type from xel_path
-- =====================================================================
DECLARE @xel_path NVARCHAR(500) = N'$(xel_path)';
DECLARE @host NVARCHAR(50) = N'$(host)';
DECLARE @session NVARCHAR(50);

IF @xel_path LIKE '%AlwaysOn_health%' SET @session = 'AlwaysOn_health';
ELSE IF @xel_path LIKE '%system_health%' SET @session = 'system_health';
ELSE IF @xel_path LIKE '%SQLDIAG%' SET @session = 'SQLDIAG';
ELSE SET @session = 'unknown';

PRINT '== Import XEL for AG Failover Analysis ==';
PRINT 'Host:    ' + @host;
PRINT 'Session: ' + @session;
PRINT 'Path:    ' + @xel_path;

-- =====================================================================
-- Step 2: Clear previous data for this host+session, then load raw
-- =====================================================================
DELETE FROM xe.raw_events WHERE host = @host AND session = @session;

DECLARE @t0 DATETIME2 = SYSDATETIME();

INSERT INTO xe.raw_events (host, session, event_name, event_time, event_data)
SELECT
    @host,
    @session,
    object_name,
    CAST(event_data AS XML).value('(event/@timestamp)[1]', 'datetime2(3)'),
    CAST(event_data AS XML)
FROM sys.fn_xe_file_target_read_file(@xel_path, NULL, NULL, NULL);

DECLARE @total INT = @@ROWCOUNT;
PRINT CONCAT('Loaded: ', @total, ' raw events (', DATEDIFF(ms, @t0, SYSDATETIME()), ' ms)');

-- Event type summary
SELECT event_name, COUNT(*) AS cnt
FROM xe.raw_events
WHERE host = @host AND session = @session
GROUP BY event_name
ORDER BY cnt DESC;

-- =====================================================================
-- Step 3: Shred events based on type
-- =====================================================================
DECLARE @step_start DATETIME2;

-- === hadr_trace_message ===
SET @step_start = SYSDATETIME();
DELETE FROM xe.hadr_trace WHERE host = @host;

INSERT INTO xe.hadr_trace (host, raw_id, event_time, hadr_message)
SELECT
    @host, id, event_time,
    event_data.value('(event/data[@name="hadr_message"]/value)[1]', 'nvarchar(max)')
FROM xe.raw_events
WHERE host = @host AND event_name = 'hadr_trace_message';

PRINT CONCAT('hadr_trace: ', @@ROWCOUNT, ' rows (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- === hadr_db_partner_set_sync_state ===
SET @step_start = SYSDATETIME();
DELETE FROM xe.hadr_sync_state WHERE host = @host;

INSERT INTO xe.hadr_sync_state (host, raw_id, event_time, database_id, sync_state, commit_policy, ag_database_id)
SELECT
    @host, id, event_time,
    event_data.value('(event/data[@name="database_id"]/value)[1]', 'int'),
    event_data.value('(event/data[@name="sync_state"]/text)[1]', 'nvarchar(50)'),
    event_data.value('(event/data[@name="commit_policy"]/text)[1]', 'nvarchar(50)'),
    event_data.value('(event/data[@name="ag_database_id"]/value)[1]', 'nvarchar(100)')
FROM xe.raw_events
WHERE host = @host AND event_name = 'hadr_db_partner_set_sync_state';

PRINT CONCAT('hadr_sync_state: ', @@ROWCOUNT, ' rows (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- === availability_replica_state_change ===
SET @step_start = SYSDATETIME();
DELETE FROM xe.hadr_replica_state WHERE host = @host;

INSERT INTO xe.hadr_replica_state (host, raw_id, event_time, ag_name, previous_state, current_state)
SELECT
    @host, id, event_time,
    event_data.value('(event/data[@name="availability_group_name"]/value)[1]', 'nvarchar(128)'),
    event_data.value('(event/data[@name="previous_state"]/text)[1]', 'nvarchar(50)'),
    event_data.value('(event/data[@name="current_state"]/text)[1]', 'nvarchar(50)')
FROM xe.raw_events
WHERE host = @host AND event_name = 'availability_replica_state_change';

PRINT CONCAT('hadr_replica_state: ', @@ROWCOUNT, ' rows (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- === alwayson_ddl_executed ===
SET @step_start = SYSDATETIME();
DELETE FROM xe.hadr_ddl WHERE host = @host;

INSERT INTO xe.hadr_ddl (host, raw_id, event_time, ddl_action, ddl_phase, statement)
SELECT
    @host, id, event_time,
    event_data.value('(event/data[@name="ddl_action"]/text)[1]', 'nvarchar(100)'),
    event_data.value('(event/data[@name="ddl_phase"]/text)[1]', 'nvarchar(50)'),
    event_data.value('(event/data[@name="statement"]/value)[1]', 'nvarchar(max)')
FROM xe.raw_events
WHERE host = @host AND event_name = 'alwayson_ddl_executed';

PRINT CONCAT('hadr_ddl: ', @@ROWCOUNT, ' rows (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- === availability_replica_manager_state_change ===
SET @step_start = SYSDATETIME();
DELETE FROM xe.hadr_manager_state WHERE host = @host;

INSERT INTO xe.hadr_manager_state (host, raw_id, event_time, current_state)
SELECT
    @host, id, event_time,
    event_data.value('(event/data[@name="current_state"]/text)[1]', 'nvarchar(50)')
FROM xe.raw_events
WHERE host = @host AND event_name = 'availability_replica_manager_state_change';

PRINT CONCAT('hadr_manager_state: ', @@ROWCOUNT, ' rows (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- === sp_server_diagnostics_component_result (system_health / SQLDIAG) ===
IF @session IN ('system_health', 'SQLDIAG')
BEGIN
    SET @step_start = SYSDATETIME();
    DELETE FROM xe.diagnostics WHERE host = @host;

    INSERT INTO xe.diagnostics (host, raw_id, event_time, component, state, data_xml)
    SELECT
        @host, id, event_time,
        event_data.value('(event/data[@name="component"]/text)[1]', 'nvarchar(50)'),
        event_data.value('(event/data[@name="state"]/text)[1]', 'nvarchar(50)'),
        CAST(event_data.query('event/data[@name="data"]') AS NVARCHAR(MAX))
    FROM xe.raw_events
    WHERE host = @host AND session = @session
      AND event_name = 'sp_server_diagnostics_component_result';

    PRINT CONCAT('diagnostics: ', @@ROWCOUNT, ' rows (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');
END

-- === error_reported (system_health) ===
IF @session = 'system_health'
BEGIN
    SET @step_start = SYSDATETIME();
    DELETE FROM xe.errors WHERE host = @host;

    INSERT INTO xe.errors (host, raw_id, event_time, error_number, severity, message)
    SELECT
        @host, id, event_time,
        event_data.value('(event/data[@name="error_number"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="severity"]/value)[1]', 'int'),
        event_data.value('(event/data[@name="message"]/value)[1]', 'nvarchar(max)')
    FROM xe.raw_events
    WHERE host = @host AND session = @session
      AND event_name = 'error_reported';

    PRINT CONCAT('errors: ', @@ROWCOUNT, ' rows (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');
END

-- =====================================================================
-- Step 4: Summary
-- =====================================================================
PRINT '';
PRINT '== Import Summary ==';

SELECT host, session, event_name, COUNT(*) AS cnt,
       MIN(event_time) AS earliest, MAX(event_time) AS latest
FROM xe.raw_events
WHERE host = @host AND session = @session
GROUP BY host, session, event_name
ORDER BY cnt DESC;

PRINT CONCAT('Total time: ', DATEDIFF(ms, @t0, SYSDATETIME()), ' ms');
GO
