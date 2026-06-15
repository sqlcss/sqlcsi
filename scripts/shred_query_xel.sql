USE [xevent_2606010030001676];
SET NOCOUNT ON;

IF OBJECT_ID('xe.queries') IS NOT NULL DROP TABLE xe.queries;

-- Safe string extraction helper: returns NULL if field not found
-- We extract from the NVARCHAR(MAX) cast because XQuery fails on large XML

;WITH src AS (
    SELECT event_name, event_time_utc,
           CAST(event_data AS NVARCHAR(MAX)) AS x
    FROM xe.query_raw
    WHERE event_name IN ('sql_batch_completed','rpc_completed')
),
parsed AS (
    SELECT event_name, event_time_utc, x,
        CHARINDEX('cpu_time', x) AS p_cpu,
        CHARINDEX('"duration"', x) AS p_dur,
        CHARINDEX('logical_reads', x) AS p_lr,
        CHARINDEX('row_count', x) AS p_rc,
        CHARINDEX('batch_text', x) AS p_bt,
        CHARINDEX('"statement"', x) AS p_st,
        CHARINDEX('session_id', x) AS p_sid
    FROM src
    WHERE CHARINDEX('cpu_time', x) > 0
)
SELECT 
    event_name, event_time_utc,
    -- cpu_time
    CASE WHEN p_cpu > 0 AND CHARINDEX('</value>', x, p_cpu) > CHARINDEX('<value>', x, p_cpu)
         THEN TRY_CAST(SUBSTRING(x, CHARINDEX('<value>', x, p_cpu)+7,
              CHARINDEX('</value>', x, p_cpu) - CHARINDEX('<value>', x, p_cpu) - 7) AS BIGINT) END AS cpu_time,
    -- duration
    CASE WHEN p_dur > 0 AND CHARINDEX('</value>', x, p_dur) > CHARINDEX('<value>', x, p_dur)
         THEN TRY_CAST(SUBSTRING(x, CHARINDEX('<value>', x, p_dur)+7,
              CHARINDEX('</value>', x, p_dur) - CHARINDEX('<value>', x, p_dur) - 7) AS BIGINT) END AS duration,
    -- logical_reads
    CASE WHEN p_lr > 0 AND CHARINDEX('</value>', x, p_lr) > CHARINDEX('<value>', x, p_lr)
         THEN TRY_CAST(SUBSTRING(x, CHARINDEX('<value>', x, p_lr)+7,
              CHARINDEX('</value>', x, p_lr) - CHARINDEX('<value>', x, p_lr) - 7) AS BIGINT) END AS logical_reads,
    -- row_count
    CASE WHEN p_rc > 0 AND CHARINDEX('</value>', x, p_rc) > CHARINDEX('<value>', x, p_rc)
         THEN TRY_CAST(SUBSTRING(x, CHARINDEX('<value>', x, p_rc)+7,
              CHARINDEX('</value>', x, p_rc) - CHARINDEX('<value>', x, p_rc) - 7) AS BIGINT) END AS row_count,
    -- sql_text (batch_text or statement)
    CASE WHEN p_bt > 0 AND CHARINDEX('</value>', x, p_bt) > CHARINDEX('<value>', x, p_bt)
         THEN LEFT(SUBSTRING(x, CHARINDEX('<value>', x, p_bt)+7,
              CHARINDEX('</value>', x, p_bt) - CHARINDEX('<value>', x, p_bt) - 7), 500)
         WHEN p_st > 0 AND CHARINDEX('</value>', x, p_st) > CHARINDEX('<value>', x, p_st)
         THEN LEFT(SUBSTRING(x, CHARINDEX('<value>', x, p_st)+7,
              CHARINDEX('</value>', x, p_st) - CHARINDEX('<value>', x, p_st) - 7), 500)
         END AS sql_text,
    -- session_id
    CASE WHEN p_sid > 0 AND CHARINDEX('</value>', x, p_sid) > CHARINDEX('<value>', x, p_sid)
         THEN TRY_CAST(SUBSTRING(x, CHARINDEX('<value>', x, p_sid)+7,
              CHARINDEX('</value>', x, p_sid) - CHARINDEX('<value>', x, p_sid) - 7) AS INT) END AS session_id
INTO xe.queries
FROM parsed;

PRINT 'Rows: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

CREATE INDEX ix_cpu ON xe.queries(cpu_time DESC);
CREATE INDEX ix_dur ON xe.queries(duration DESC);
PRINT 'Done';
GO
