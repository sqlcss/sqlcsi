-- =============================================================================
-- SQL-CSI: Import additional XEL files (e.g. SQLDIAG) into existing case
-- Appends to xe.raw_events + shreds sqldiag-specific event types
--
-- Usage:
--   sqlcmd -S localhost -E -v case_id="xxx" xel_path="C:\...\*SQLDIAG*.xel" days="3" -i scripts/import_xel_sqldiag.sql
-- =============================================================================

:setvar case_id "2604300030000700"
:setvar xel_path "C:\Temp\2604300030000700\*SQLDIAG*.xel"
:setvar days "3"

USE [xevent_$(case_id)];
SET NOCOUNT ON;

DECLARE @t0 DATETIME2 = SYSDATETIME(), @step_start DATETIME2;

-- =====================================================================
-- Create AG events table if not exists
-- =====================================================================
IF OBJECT_ID('xe.ag_events') IS NOT NULL DROP TABLE xe.ag_events;
CREATE TABLE xe.ag_events (
    id              INT IDENTITY PRIMARY KEY,
    case_id         NVARCHAR(50) NOT NULL,
    raw_id          INT NOT NULL,
    event_name      NVARCHAR(100) NOT NULL,
    event_time      DATETIME2(3) NOT NULL,
    ag_name         NVARCHAR(128),
    ag_id           NVARCHAR(100),
    reason          NVARCHAR(100),
    target_state    NVARCHAR(50),
    failure_condition NVARCHAR(100),
    data_xml        NVARCHAR(MAX),
    INDEX ix_time (event_time),
    INDEX ix_ag (ag_name)
);

-- =====================================================================
-- Step 1: Load raw events from SQLDIAG XEL
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '== Step 1: Load SQLDIAG raw events ==';
PRINT 'Path: ' + N'$(xel_path)';

-- Remove any previously loaded SQLDIAG events for this case
-- (raw_events may have system_health already — only delete sqldiag event names)
DELETE FROM xe.raw_events
WHERE case_id = N'$(case_id)'
  AND event_name IN ('component_health_result', 'info_message',
                     'availability_group_is_alive_failure',
                     'availability_group_state_change');

INSERT INTO xe.raw_events (case_id, event_name, event_time, event_data)
SELECT
    N'$(case_id)',
    object_name,
    CAST(event_data AS XML).value('(event/@timestamp)[1]', 'datetime2(3)'),
    CAST(event_data AS XML)
FROM sys.fn_xe_file_target_read_file(N'$(xel_path)', NULL, NULL, NULL);

DECLARE @total INT = @@ROWCOUNT;
PRINT CONCAT('  Loaded: ', @total, ' events (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- Time filter
IF $(days) > 0
BEGIN
    DECLARE @cutoff DATETIME2(3);
    -- Use existing case's max time as anchor (from system_health)
    SELECT @cutoff = DATEADD(DAY, -$(days), MAX(event_time))
    FROM xe.raw_events WHERE case_id = N'$(case_id)';
    DELETE FROM xe.raw_events
    WHERE case_id = N'$(case_id)' AND event_time < @cutoff
      AND event_name IN ('component_health_result', 'info_message',
                         'availability_group_is_alive_failure',
                         'availability_group_state_change');
    DECLARE @kept INT;
    SELECT @kept = COUNT(*) FROM xe.raw_events
    WHERE case_id = N'$(case_id)'
      AND event_name IN ('component_health_result', 'info_message',
                         'availability_group_is_alive_failure',
                         'availability_group_state_change');
    PRINT CONCAT('  After -', $(days), 'd filter: ', @kept, ' SQLDIAG events');
END

-- Distribution of new events
SELECT event_name, COUNT(*) AS cnt
FROM xe.raw_events
WHERE case_id = N'$(case_id)'
  AND event_name IN ('component_health_result', 'info_message',
                     'availability_group_is_alive_failure',
                     'availability_group_state_change')
GROUP BY event_name ORDER BY cnt DESC;

-- =====================================================================
-- Step 2: Shred component_health_result → xe.diagnostics
-- (same schema as sp_server_diagnostics_component_result)
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '';
PRINT '== Step 2: component_health_result → xe.diagnostics ==';

INSERT INTO xe.diagnostics (case_id, raw_id, event_time, component, state_desc, data_xml)
SELECT N'$(case_id)', id, event_time,
    event_data.value('(event/data[@name="component"]/text)[1]', 'nvarchar(50)'),
    COALESCE(
        event_data.value('(event/data[@name="state"]/text)[1]', 'nvarchar(20)'),
        event_data.value('(event/data[@name="state_desc"]/text)[1]', 'nvarchar(20)')
    ),
    event_data.value('(event/data[@name="data"]/value)[1]', 'nvarchar(max)')
FROM xe.raw_events
WHERE case_id = N'$(case_id)' AND event_name = 'component_health_result';

PRINT CONCAT('  Rows: ', @@ROWCOUNT, ' (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- =====================================================================
-- Step 3: Shred AG events
-- =====================================================================
SET @step_start = SYSDATETIME();
PRINT '== Step 3: AG events ==';

INSERT INTO xe.ag_events (case_id, raw_id, event_name, event_time,
    ag_name, ag_id, reason, target_state, failure_condition, data_xml)
SELECT N'$(case_id)', id, event_name, event_time,
    event_data.value('(event/data[@name="availability_group_name"]/value)[1]', 'nvarchar(128)'),
    COALESCE(
        event_data.value('(event/data[@name="availability_group_id"]/value)[1]', 'nvarchar(100)'),
        event_data.value('(event/data[@name="ag_id"]/value)[1]', 'nvarchar(100)')
    ),
    event_data.value('(event/data[@name="reason"]/text)[1]', 'nvarchar(100)'),
    event_data.value('(event/data[@name="target_state"]/text)[1]', 'nvarchar(50)'),
    event_data.value('(event/data[@name="failure_condition_level"]/text)[1]', 'nvarchar(100)'),
    CAST(event_data AS NVARCHAR(MAX))
FROM xe.raw_events
WHERE case_id = N'$(case_id)'
  AND event_name IN ('availability_group_is_alive_failure', 'availability_group_state_change');

PRINT CONCAT('  Rows: ', @@ROWCOUNT, ' (', DATEDIFF(ms, @step_start, SYSDATETIME()), ' ms)');

-- =====================================================================
-- Summary
-- =====================================================================
DECLARE @elapsed_ms INT = DATEDIFF(ms, @t0, SYSDATETIME());
PRINT '';
PRINT '========================================';
PRINT '  SQLDIAG Import Complete';
PRINT '========================================';
DECLARE @d1 INT, @d2 INT;
SELECT @d1 = COUNT(*) FROM xe.diagnostics WHERE case_id = N'$(case_id)';
SELECT @d2 = COUNT(*) FROM xe.ag_events WHERE case_id = N'$(case_id)';
PRINT CONCAT('  Diagnostics (total): ', @d1, ' (system_health + sqldiag)');
PRINT CONCAT('  AG events:           ', @d2);
PRINT CONCAT('  Elapsed: ', @elapsed_ms / 1000, '.', RIGHT('000' + CAST(@elapsed_ms % 1000 AS VARCHAR), 3), ' s');
GO

