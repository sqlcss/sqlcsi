USE [xevent_2604300030000700];
SET NOCOUNT ON;

-- Memory resource warnings
SELECT TOP 10 event_time,
    event_data.value('(/event/data[@name="data"]/value/resource/@lastNotification)[1]', 'nvarchar(100)') AS last_notification,
    event_data.value('(/event/data[@name="data"]/value/resource/@outOfMemoryExceptions)[1]', 'int') AS oom_exceptions,
    event_data.value('(/event/data[@name="data"]/value/resource/@isAnyPoolOutOfMemory)[1]', 'int') AS pool_oom,
    event_data.value('(/event/data[@name="data"]/value/resource/@processOutOfMemoryPeriod)[1]', 'int') AS oom_period
FROM xe.raw_events
WHERE case_id = '2604300030000700' AND event_name = 'sp_server_diagnostics_component_result'
  AND event_data.value('(/event/data[@name="component"]/text)[1]', 'nvarchar(50)') = 'RESOURCE'
  AND event_data.value('(/event/data[@name="state"]/text)[1]', 'nvarchar(20)') = 'WARNING'
  AND event_time >= '2026-04-27 16:00:00'
ORDER BY event_time;
