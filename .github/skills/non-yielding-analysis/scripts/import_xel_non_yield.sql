-- import_xel_non_yield.sql
-- Optimized import-xevent Path A profile for non-yield investigations.
-- Required sqlcmd variables: case_id, xel_path, days.
-- Example:
-- sqlcmd -S localhost -E -v case_id="case" xel_path="C:\logs\system_health_0_*.xel" days="30" -i import_xel_non_yield.sql

USE master;
GO
IF DB_ID(N'xevent_$(case_id)') IS NULL CREATE DATABASE [xevent_$(case_id)];
GO
USE [xevent_$(case_id)];
GO
SET NOCOUNT ON;
DECLARE @started datetime2=SYSDATETIME();
IF SCHEMA_ID('xe') IS NULL EXEC('CREATE SCHEMA xe');

IF OBJECT_ID('xe.raw_events') IS NULL
CREATE TABLE xe.raw_events(
 id int IDENTITY PRIMARY KEY,case_id nvarchar(50) NOT NULL,event_name nvarchar(100) NOT NULL,
 event_time datetime2(3) NOT NULL,event_data xml NOT NULL,
 INDEX ix_case_event(case_id,event_name),INDEX ix_event_time(event_time));
DELETE FROM xe.raw_events WHERE case_id=N'$(case_id)';

DROP TABLE IF EXISTS xe.errors;
CREATE TABLE xe.errors(
 id int IDENTITY PRIMARY KEY,case_id nvarchar(50) NOT NULL,raw_id int NOT NULL,event_time datetime2(3) NOT NULL,
 error_number int NOT NULL,severity int,state int,message nvarchar(max),database_name nvarchar(128),session_id int,client_hostname nvarchar(128),
 INDEX ix_error(case_id,error_number),INDEX ix_time(event_time),INDEX ix_sev(severity));
DROP TABLE IF EXISTS xe.waits;
CREATE TABLE xe.waits(
 id int IDENTITY PRIMARY KEY,case_id nvarchar(50) NOT NULL,raw_id int NOT NULL,event_name nvarchar(100),event_time datetime2(3) NOT NULL,
 wait_type nvarchar(100),duration_ms bigint,signal_duration_ms bigint,wait_resource nvarchar(256),session_id int,database_name nvarchar(128),
 INDEX ix_wait(case_id,wait_type),INDEX ix_time(event_time));
DROP TABLE IF EXISTS xe.diagnostics;
CREATE TABLE xe.diagnostics(
 id int IDENTITY PRIMARY KEY,case_id nvarchar(50) NOT NULL,raw_id int NOT NULL,event_time datetime2(3) NOT NULL,
 component nvarchar(50),state_desc nvarchar(20),data_xml nvarchar(max),INDEX ix_comp(case_id,component),INDEX ix_state(state_desc),INDEX ix_time(event_time));
DROP TABLE IF EXISTS xe.scheduler;
CREATE TABLE xe.scheduler(
 id int IDENTITY PRIMARY KEY,case_id nvarchar(50) NOT NULL,raw_id int NOT NULL,event_name nvarchar(100),event_time datetime2(3) NOT NULL,
 sql_cpu_pct int,system_idle_pct int,scheduler_id int,nonyielding_count int,INDEX ix_time(event_time));
DROP TABLE IF EXISTS xe.deadlocks;
CREATE TABLE xe.deadlocks(
 id int IDENTITY PRIMARY KEY,case_id nvarchar(50) NOT NULL,raw_id int NOT NULL,event_time datetime2(3) NOT NULL,
 deadlock_xml nvarchar(max),INDEX ix_time(event_time));
DROP TABLE IF EXISTS xe.memory_broker;
CREATE TABLE xe.memory_broker(
 id int IDENTITY PRIMARY KEY,case_id nvarchar(50) NOT NULL,raw_id int NOT NULL,event_time datetime2(3) NOT NULL,
 broker_type nvarchar(100),notification nvarchar(50),memory_ratio float,last_target_kb bigint,current_target_kb bigint,
 INDEX ix_time(event_time),INDEX ix_broker(broker_type));

PRINT '== non-yield profile: load raw events ==';
INSERT INTO xe.raw_events(case_id,event_name,event_time,event_data)
SELECT N'$(case_id)',object_name,
 CAST(event_data AS xml).value('(event/@timestamp)[1]','datetime2(3)'),CAST(event_data AS xml)
FROM sys.fn_xe_file_target_read_file(N'$(xel_path)',NULL,NULL,NULL);
PRINT CONCAT('RAW_ROWS=',@@ROWCOUNT);

IF $(days)>0
BEGIN
 DECLARE @cutoff datetime2(3);
 SELECT @cutoff=DATEADD(day,-$(days),MAX(event_time)) FROM xe.raw_events WHERE case_id=N'$(case_id)';
 DELETE FROM xe.raw_events WHERE case_id=N'$(case_id)' AND event_time<@cutoff;
 PRINT CONCAT('CUTOFF_UTC=',CONVERT(varchar(30),@cutoff,126));
END;

PRINT '== shred errors ==';
INSERT INTO xe.errors(case_id,raw_id,event_time,error_number,severity,state,message,database_name,session_id,client_hostname)
SELECT N'$(case_id)',id,event_time,
 event_data.value('(event/data[@name="error_number"]/value)[1]','int'),
 event_data.value('(event/data[@name="severity"]/value)[1]','int'),
 event_data.value('(event/data[@name="state"]/value)[1]','int'),
 event_data.value('(event/data[@name="message"]/value)[1]','nvarchar(max)'),
 event_data.value('(event/action[@name="database_name"]/value)[1]','nvarchar(128)'),
 event_data.value('(event/action[@name="session_id"]/value)[1]','int'),
 event_data.value('(event/action[@name="client_hostname"]/value)[1]','nvarchar(128)')
FROM xe.raw_events WHERE case_id=N'$(case_id)' AND event_name='error_reported';
PRINT CONCAT('ERROR_ROWS=',@@ROWCOUNT);

PRINT '== shred waits ==';
INSERT INTO xe.waits(case_id,raw_id,event_name,event_time,wait_type,duration_ms,signal_duration_ms,wait_resource,session_id,database_name)
SELECT N'$(case_id)',id,event_name,event_time,
 event_data.value('(event/data[@name="wait_type"]/text)[1]','nvarchar(100)'),
 event_data.value('(event/data[@name="duration"]/value)[1]','bigint'),
 event_data.value('(event/data[@name="signal_duration"]/value)[1]','bigint'),
 event_data.value('(event/data[@name="wait_resource"]/value)[1]','nvarchar(256)'),
 event_data.value('(event/action[@name="session_id"]/value)[1]','int'),
 event_data.value('(event/action[@name="database_name"]/value)[1]','nvarchar(128)')
FROM xe.raw_events WHERE case_id=N'$(case_id)' AND event_name IN('wait_info','wait_info_external');
PRINT CONCAT('WAIT_ROWS=',@@ROWCOUNT);

PRINT '== shred diagnostics ==';
INSERT INTO xe.diagnostics(case_id,raw_id,event_time,component,state_desc,data_xml)
SELECT N'$(case_id)',id,event_time,
 event_data.value('(event/data[@name="component"]/text)[1]','nvarchar(50)'),
 COALESCE(event_data.value('(event/data[@name="state"]/text)[1]','nvarchar(20)'),event_data.value('(event/data[@name="state_desc"]/text)[1]','nvarchar(20)')),
 event_data.value('(event/data[@name="data"]/value)[1]','nvarchar(max)')
FROM xe.raw_events WHERE case_id=N'$(case_id)' AND event_name='sp_server_diagnostics_component_result';
PRINT CONCAT('DIAGNOSTIC_ROWS=',@@ROWCOUNT);

PRINT '== shred scheduler ==';
INSERT INTO xe.scheduler(case_id,raw_id,event_name,event_time,sql_cpu_pct,system_idle_pct,scheduler_id,nonyielding_count)
SELECT N'$(case_id)',id,event_name,event_time,
 event_data.value('(event/data[@name="process_utilization"]/value)[1]','int'),
 event_data.value('(event/data[@name="system_idle"]/value)[1]','int'),
 event_data.value('(event/data[@name="scheduler_id"]/value)[1]','int'),
 event_data.value('(event/data[@name="nonyielding_workers_count"]/value)[1]','int')
FROM xe.raw_events WHERE case_id=N'$(case_id)' AND event_name LIKE 'scheduler_monitor%';
PRINT CONCAT('SCHEDULER_ROWS=',@@ROWCOUNT);

PRINT '== shred deadlocks ==';
INSERT INTO xe.deadlocks(case_id,raw_id,event_time,deadlock_xml)
SELECT N'$(case_id)',id,event_time,event_data.value('(event/data[@name="xml_report"]/value)[1]','nvarchar(max)')
FROM xe.raw_events WHERE case_id=N'$(case_id)' AND event_name='xml_deadlock_report';
PRINT CONCAT('DEADLOCK_ROWS=',@@ROWCOUNT);

PRINT '== shred memory broker ==';
INSERT INTO xe.memory_broker(case_id,raw_id,event_time,broker_type,notification,memory_ratio,last_target_kb,current_target_kb)
SELECT N'$(case_id)',id,event_time,
 event_data.value('(event/data[@name="broker_type"]/value)[1]','nvarchar(100)'),
 event_data.value('(event/data[@name="notification_type"]/text)[1]','nvarchar(50)'),
 event_data.value('(event/data[@name="memory_ratio"]/value)[1]','float'),
 event_data.value('(event/data[@name="last_target_kb"]/value)[1]','bigint'),
 event_data.value('(event/data[@name="current_target_kb"]/value)[1]','bigint')
FROM xe.raw_events WHERE case_id=N'$(case_id)' AND event_name='memory_broker_ring_buffer_recorded';
PRINT CONCAT('MEMORY_BROKER_ROWS=',@@ROWCOUNT);

PRINT 'NON_YIELD_XEVENT_IMPORT_PROFILE=PASS';
PRINT 'DATABASE=xevent_$(case_id)';
PRINT CONCAT('ELAPSED_MS=',DATEDIFF_BIG(ms,@started,SYSDATETIME()));
SELECT 'raw_events' table_name,COUNT_BIG(*) row_count,MIN(event_time) min_utc,MAX(event_time) max_utc FROM xe.raw_events WHERE case_id=N'$(case_id)'
UNION ALL SELECT 'errors',COUNT_BIG(*),MIN(event_time),MAX(event_time) FROM xe.errors WHERE case_id=N'$(case_id)'
UNION ALL SELECT 'waits',COUNT_BIG(*),MIN(event_time),MAX(event_time) FROM xe.waits WHERE case_id=N'$(case_id)'
UNION ALL SELECT 'diagnostics',COUNT_BIG(*),MIN(event_time),MAX(event_time) FROM xe.diagnostics WHERE case_id=N'$(case_id)'
UNION ALL SELECT 'scheduler',COUNT_BIG(*),MIN(event_time),MAX(event_time) FROM xe.scheduler WHERE case_id=N'$(case_id)'
UNION ALL SELECT 'deadlocks',COUNT_BIG(*),MIN(event_time),MAX(event_time) FROM xe.deadlocks WHERE case_id=N'$(case_id)'
UNION ALL SELECT 'memory_broker',COUNT_BIG(*),MIN(event_time),MAX(event_time) FROM xe.memory_broker WHERE case_id=N'$(case_id)';
GO
