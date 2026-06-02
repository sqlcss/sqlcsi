USE [xevent_2604300030000700];
SET NOCOUNT ON;

-- SYSTEM WARNING timeline
PRINT '=== SYSTEM WARNING Timeline ==='
SELECT TOP 5 event_time,
    event_data.value('(/event/data[@name="data"]/value/system/@nonYieldingTasksReported)[1]', 'int') AS ny_reported,
    event_data.value('(/event/data[@name="data"]/value/system/@latchWarnings)[1]', 'int') AS latch_warnings,
    event_data.value('(/event/data[@name="data"]/value/system/@totalDumpRequests)[1]', 'int') AS dump_requests,
    event_data.value('(/event/data[@name="data"]/value/system/@isAccessViolationOccurred)[1]', 'int') AS av_occurred
FROM xe.raw_events
WHERE case_id = '2604300030000700' AND event_name = 'sp_server_diagnostics_component_result'
  AND event_data.value('(/event/data[@name="component"]/text)[1]', 'nvarchar(50)') = 'SYSTEM'
  AND event_data.value('(/event/data[@name="state"]/text)[1]', 'nvarchar(20)') = 'WARNING'
  AND event_time >= '2026-04-29 14:00:00'
ORDER BY event_time;

-- RESOURCE_SEMAPHORE hourly distribution
PRINT '=== RESOURCE_SEMAPHORE Hourly ==='
SELECT CAST(event_time AS DATE) AS day, DATEPART(HOUR, event_time) AS hr,
       COUNT(*) AS cnt, SUM(duration_ms) AS total_ms, AVG(duration_ms) AS avg_ms, MAX(duration_ms) AS max_ms
FROM xe.waits WHERE case_id = '2604300030000700' AND wait_type = 'RESOURCE_SEMAPHORE'
  AND event_time >= '2026-04-27 16:00:00'
GROUP BY CAST(event_time AS DATE), DATEPART(HOUR, event_time) ORDER BY day, hr;

-- LATCH_EX hourly distribution
PRINT '=== LATCH_EX Hourly ==='
SELECT CAST(event_time AS DATE) AS day, DATEPART(HOUR, event_time) AS hr,
       COUNT(*) AS cnt, SUM(duration_ms) AS total_ms, AVG(duration_ms) AS avg_ms, MAX(duration_ms) AS max_ms
FROM xe.waits WHERE case_id = '2604300030000700' AND wait_type = 'LATCH_EX'
  AND event_time >= '2026-04-27 16:00:00'
GROUP BY CAST(event_time AS DATE), DATEPART(HOUR, event_time) ORDER BY day, hr;

-- LATCH_EX wait_resource top
PRINT '=== LATCH_EX wait_resource ==='
SELECT wait_resource, COUNT(*) AS cnt, SUM(duration_ms) AS total_ms
FROM xe.waits WHERE case_id = '2604300030000700' AND wait_type = 'LATCH_EX'
  AND event_time >= '2026-04-27 16:00:00'
GROUP BY wait_resource ORDER BY total_ms DESC;
