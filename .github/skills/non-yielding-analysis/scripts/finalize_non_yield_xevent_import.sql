-- finalize_non_yield_xevent_import.sql
-- Required sqlcmd variable: case_id
-- Run after the shared system_health import has committed raw_events, errors,
-- waits, diagnostics, scheduler, and deadlocks. Populates memory_broker and emits
-- the non-yield profile completion inventory. Connectivity/security tables are
-- intentionally outside this profile.
USE [xevent_$(case_id)];
GO
SET NOCOUNT ON;

IF OBJECT_ID('xe.raw_events') IS NULL THROW 51000, 'xe.raw_events missing', 1;
IF OBJECT_ID('xe.errors') IS NULL THROW 51000, 'xe.errors missing', 1;
IF OBJECT_ID('xe.waits') IS NULL THROW 51000, 'xe.waits missing', 1;
IF OBJECT_ID('xe.diagnostics') IS NULL THROW 51000, 'xe.diagnostics missing', 1;
IF OBJECT_ID('xe.scheduler') IS NULL THROW 51000, 'xe.scheduler missing', 1;
IF OBJECT_ID('xe.deadlocks') IS NULL THROW 51000, 'xe.deadlocks missing', 1;
IF OBJECT_ID('xe.memory_broker') IS NULL THROW 51000, 'xe.memory_broker missing', 1;
IF NOT EXISTS (SELECT 1 FROM xe.raw_events WHERE case_id=N'$(case_id)')
    THROW 51000, 'No raw events for requested case', 1;

TRUNCATE TABLE xe.memory_broker;
INSERT INTO xe.memory_broker
    (case_id,raw_id,event_time,broker_type,notification,memory_ratio,last_target_kb,current_target_kb)
SELECT N'$(case_id)',id,event_time,
    event_data.value('(event/data[@name="broker_type"]/value)[1]','nvarchar(100)'),
    event_data.value('(event/data[@name="notification_type"]/text)[1]','nvarchar(50)'),
    event_data.value('(event/data[@name="memory_ratio"]/value)[1]','float'),
    event_data.value('(event/data[@name="last_target_kb"]/value)[1]','bigint'),
    event_data.value('(event/data[@name="current_target_kb"]/value)[1]','bigint')
FROM xe.raw_events
WHERE case_id=N'$(case_id)' AND event_name='memory_broker_ring_buffer_recorded';
DECLARE @memory_rows bigint=@@ROWCOUNT;

PRINT 'NON_YIELD_XEVENT_IMPORT_PROFILE=PASS';
PRINT 'DATABASE=xevent_$(case_id)';
PRINT CONCAT('MEMORY_BROKER_ROWS=',@memory_rows);

SELECT 'raw_events' AS table_name,COUNT_BIG(*) AS row_count,MIN(event_time) AS min_utc,MAX(event_time) AS max_utc
FROM xe.raw_events WHERE case_id=N'$(case_id)'
UNION ALL SELECT 'errors',COUNT_BIG(*),MIN(event_time),MAX(event_time) FROM xe.errors WHERE case_id=N'$(case_id)'
UNION ALL SELECT 'waits',COUNT_BIG(*),MIN(event_time),MAX(event_time) FROM xe.waits WHERE case_id=N'$(case_id)'
UNION ALL SELECT 'diagnostics',COUNT_BIG(*),MIN(event_time),MAX(event_time) FROM xe.diagnostics WHERE case_id=N'$(case_id)'
UNION ALL SELECT 'scheduler',COUNT_BIG(*),MIN(event_time),MAX(event_time) FROM xe.scheduler WHERE case_id=N'$(case_id)'
UNION ALL SELECT 'deadlocks',COUNT_BIG(*),MIN(event_time),MAX(event_time) FROM xe.deadlocks WHERE case_id=N'$(case_id)'
UNION ALL SELECT 'memory_broker',COUNT_BIG(*),MIN(event_time),MAX(event_time) FROM xe.memory_broker WHERE case_id=N'$(case_id)';

SELECT event_name,COUNT_BIG(*) AS event_count,MIN(event_time) AS first_utc,MAX(event_time) AS last_utc
FROM xe.raw_events WHERE case_id=N'$(case_id)'
GROUP BY event_name ORDER BY event_count DESC;
GO
