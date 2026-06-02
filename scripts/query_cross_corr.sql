USE [xevent_2604300030000700];
SET NOCOUNT ON;

-- Cross-correlation: All events around the latch timeout (04-29 21:00 ~ 04-30 00:30 UTC = local 05:00~08:30)
PRINT '=== Timeline around latch timeout (UTC 04-29 21:00 ~ 04-30 01:00) ==='
SELECT day, hr,
       MAX(rs_cnt) AS resource_sem, MAX(rs_total_ms) AS rs_total_ms,
       MAX(latch_cnt) AS latch_ex, MAX(latch_total_ms) AS latch_total_ms,
       MAX(err_cnt) AS errors,
       MAX(avg_cpu) AS avg_cpu, MAX(max_cpu) AS max_cpu,
       MAX(ny_cnt) AS non_yielding,
       MAX(warn_cnt) AS diag_warnings
FROM (
    SELECT CAST(event_time AS DATE) day, DATEPART(HOUR,event_time) hr,
           COUNT(*) rs_cnt, SUM(duration_ms) rs_total_ms, NULL latch_cnt, NULL latch_total_ms,
           NULL err_cnt, NULL avg_cpu, NULL max_cpu, NULL ny_cnt, NULL warn_cnt
    FROM xe.waits WHERE case_id='2604300030000700' AND wait_type='RESOURCE_SEMAPHORE'
      AND event_time >= '2026-04-29 16:00:00'
    GROUP BY CAST(event_time AS DATE), DATEPART(HOUR,event_time)
    UNION ALL
    SELECT CAST(event_time AS DATE), DATEPART(HOUR,event_time),
           NULL, NULL, COUNT(*), SUM(duration_ms), NULL, NULL, NULL, NULL, NULL
    FROM xe.waits WHERE case_id='2604300030000700' AND wait_type='LATCH_EX'
      AND event_time >= '2026-04-29 16:00:00'
    GROUP BY CAST(event_time AS DATE), DATEPART(HOUR,event_time)
    UNION ALL
    SELECT CAST(event_time AS DATE), DATEPART(HOUR,event_time),
           NULL, NULL, NULL, NULL, COUNT(*), NULL, NULL, NULL, NULL
    FROM xe.errors WHERE case_id='2604300030000700'
      AND event_time >= '2026-04-29 16:00:00'
    GROUP BY CAST(event_time AS DATE), DATEPART(HOUR,event_time)
    UNION ALL
    SELECT CAST(event_time AS DATE), DATEPART(HOUR,event_time),
           NULL, NULL, NULL, NULL, NULL, AVG(sql_cpu_pct), MAX(sql_cpu_pct),
           SUM(CASE WHEN event_name LIKE '%non_yielding%' THEN 1 ELSE 0 END), NULL
    FROM xe.scheduler WHERE case_id='2604300030000700'
      AND event_time >= '2026-04-29 16:00:00'
    GROUP BY CAST(event_time AS DATE), DATEPART(HOUR,event_time)
    UNION ALL
    SELECT CAST(event_time AS DATE), DATEPART(HOUR,event_time),
           NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
           SUM(CASE WHEN state_desc IN ('WARNING','warning') THEN 1 ELSE 0 END)
    FROM xe.diagnostics WHERE case_id='2604300030000700'
      AND event_time >= '2026-04-29 16:00:00'
    GROUP BY CAST(event_time AS DATE), DATEPART(HOUR,event_time)
) x GROUP BY day, hr ORDER BY day, hr;

-- RESOURCE_SEMAPHORE per-session for the latch window (UTC 04-29 21:00 ~ 04-30 00:00)
PRINT '=== RESOURCE_SEMAPHORE sessions in latch window ==='
SELECT session_id, COUNT(*) AS cnt, SUM(duration_ms) AS total_ms,
       AVG(duration_ms) AS avg_ms, MAX(duration_ms) AS max_ms
FROM xe.waits WHERE case_id = '2604300030000700' AND wait_type = 'RESOURCE_SEMAPHORE'
  AND event_time BETWEEN '2026-04-29 21:00:00' AND '2026-04-30 01:00:00'
GROUP BY session_id ORDER BY total_ms DESC;
