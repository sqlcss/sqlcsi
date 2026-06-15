USE [xevent_2606010030001676];
SET NOCOUNT ON;

DECLARE @x NVARCHAR(MAX);
SELECT TOP 1 @x = CAST(event_data AS NVARCHAR(MAX))
FROM xe.query_raw
WHERE event_name = 'query_post_execution_showplan'
  AND event_time_utc >= '2026-06-01 03:16:56.357'
  AND event_time_utc < '2026-06-01 03:16:56.358'
  AND CAST(event_data AS NVARCHAR(MAX)) LIKE '%<value>1143</value>%';

-- Extract ShowPlanXML portion
DECLARE @start INT = CHARINDEX('<ShowPlanXML', @x);
DECLARE @end INT = CHARINDEX('</ShowPlanXML>', @x);
IF @start > 0 AND @end > 0
BEGIN
    DECLARE @plan NVARCHAR(MAX) = SUBSTRING(@x, @start, @end - @start + 14);
    -- Write to file via BCP
    SELECT @plan AS plan_xml;
END
ELSE
    PRINT 'ShowPlanXML not found';
GO
