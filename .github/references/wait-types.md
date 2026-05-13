# SQL Server Wait Types Reference

Shared reference for all sql-csi agents. Use this to classify wait types during ERRORLOG, XEvent, and dump analysis.

Source: [Paul Randal — SQLskills Wait Statistics](https://www.sqlskills.com/blogs/paul/wait-statistics-or-please-tell-me-where-it-hurts/), [sys.dm_os_wait_stats](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-os-wait-stats-transact-sql)

---

## Benign / Ignorable Wait Types

These are background idle waits. Filter them out when analyzing wait statistics — they accumulate even on a healthy, idle server.

### Broker
- `BROKER_EVENTHANDLER`
- `BROKER_RECEIVE_WAITFOR`
- `BROKER_TASK_STOP`
- `BROKER_TO_FLUSH`
- `BROKER_TRANSMITTER`

### Checkpoint / CLR
- `CHECKPOINT_QUEUE`
- `CHKPT`
- `CLR_AUTO_EVENT`
- `CLR_MANUAL_EVENT`
- `CLR_SEMAPHORE`

### Database Mirroring
- `DBMIRROR_DBM_EVENT`
- `DBMIRROR_EVENTS_QUEUE`
- `DBMIRROR_WORKER_QUEUE`
- `DBMIRRORING_CMD`

### System Maintenance
- `DIRTY_PAGE_POLL`
- `DISPATCHER_QUEUE_SEMAPHORE`
- `FSAGENT`
- `FT_IFTS_SCHEDULER_IDLE_WAIT`
- `FT_IFTSHC_MUTEX`

### HADR Background (⚠️ do NOT ignore if investigating AG issues)
- `HADR_CLUSAPI_CALL`
- `HADR_FILESTREAM_IOMGR_IOCOMPLETION`
- `HADR_LOGCAPTURE_WAIT`
- `HADR_NOTIFICATION_DEQUEUE`
- `HADR_TIMER_TASK`
- `HADR_WORK_QUEUE`

### Memory / Task Management
- `KSOURCE_WAKEUP`
- `LAZYWRITER_SLEEP`
- `LOGMGR_QUEUE`
- `MEMORY_ALLOCATION_EXT`
- `ONDEMAND_TASK_QUEUE`

### Parallel Redo (AG secondary)
- `PARALLEL_REDO_DRAIN_WORKER`
- `PARALLEL_REDO_LOG_CACHE`
- `PARALLEL_REDO_TRAN_LIST`
- `PARALLEL_REDO_WORKER_SYNC`
- `PARALLEL_REDO_WORKER_WAIT_WORK`
- `REDO_THREAD_PENDING_WORK`

### Query Store
- `QDS_PERSIST_TASK_MAIN_LOOP_SLEEP`
- `QDS_ASYNC_QUEUE`
- `QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP`
- `QDS_SHUTDOWN_QUEUE`

### Preemptive OS (background)
- `PREEMPTIVE_OS_FLUSHFILEBUFFERS`
- `PREEMPTIVE_XE_GETTARGETSTATE`

### PVS (Accelerated Database Recovery)
- `PVS_PREALLOCATE`

### Sleep / Startup
- `PWAIT_ALL_COMPONENTS_INITIALIZED`
- `PWAIT_DIRECTLOGCONSUMER_GETNEXT`
- `PWAIT_EXTENSIBILITY_CLEANUP_TASK`
- `REQUEST_FOR_DEADLOCK_SEARCH`
- `RESOURCE_QUEUE`
- `SERVER_IDLE_CHECK`
- `SLEEP_BPOOL_FLUSH`
- `SLEEP_DBSTARTUP`
- `SLEEP_DCOMSTARTUP`
- `SLEEP_MASTERDBREADY`
- `SLEEP_MASTERMDREADY`
- `SLEEP_MASTERUPGRADED`
- `SLEEP_MSDBSTARTUP`
- `SLEEP_SYSTEMTASK`
- `SLEEP_TASK`
- `SLEEP_TEMPDBSTARTUP`

### Network / Trace
- `SNI_HTTP_ACCEPT`
- `SOS_WORK_DISPATCHER`
- `SP_SERVER_DIAGNOSTICS_SLEEP`
- `SQLTRACE_BUFFER_FLUSH`
- `SQLTRACE_INCREMENTAL_FLUSH_SLEEP`
- `SQLTRACE_WAIT_ENTRIES`

### XTP / VDI
- `VDI_CLIENT_OTHER`
- `WAIT_FOR_RESULTS`
- `WAITFOR`
- `WAITFOR_TASKSHUTDOWN`
- `WAIT_XTP_RECOVERY`
- `WAIT_XTP_HOST_WAIT`
- `WAIT_XTP_OFFLINE_CKPT_NEW_LOG`
- `WAIT_XTP_CKPT_CLOSE`

### Extended Events
- `XE_DISPATCHER_JOIN`
- `XE_DISPATCHER_WAIT`
- `XE_TIMER_EVENT`

### Parallelism (⚠️ do NOT ignore if investigating parallelism issues)
- `CXCONSUMER`

---

## Actionable Wait Types — Classification & Thresholds

When these waits appear with significant duration or count, they indicate real performance issues.

### CPU / Scheduler Pressure

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `SOS_SCHEDULER_YIELD` | Consistently top wait | CPU pressure — queries consuming excessive CPU |
| `THREADPOOL` | Any occurrence | Worker thread exhaustion — max worker threads reached |
| `CMEMTHREAD` | High count | Memory object contention — too many concurrent allocations |

### Disk I/O

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `PAGEIOLATCH_SH` | avg > 10-15 ms | Read I/O latency — slow storage or insufficient memory (buffer pool too small) |
| `PAGEIOLATCH_EX` | avg > 10-15 ms | Write I/O latency — slow storage |
| `PAGEIOLATCH_UP` | avg > 10-15 ms | Update I/O latency |
| `WRITELOG` | avg > 5 ms | Transaction log write latency — log disk bottleneck |
| `IO_COMPLETION` | avg > 50 ms | Non-data-page I/O (sort spill, tempdb, log read) |
| `ASYNC_IO_COMPLETION` | max > 60000 ms | Severe storage stall (backup, bulk insert) |
| `BACKUPIO` | High duration | Backup I/O bottleneck |

### Locking / Blocking

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `LCK_M_S` | max > 30000 ms | Shared lock wait — blocked by X lock holder |
| `LCK_M_X` | max > 30000 ms | Exclusive lock wait — blocked readers/writers |
| `LCK_M_U` | max > 30000 ms | Update lock wait |
| `LCK_M_IX` | max > 30000 ms | Intent exclusive lock wait |
| `LCK_M_IS` | max > 30000 ms | Intent shared lock wait |
| `LCK_M_SCH_M` | Any occurrence | Schema modification lock — DDL blocked |
| `LCK_M_SCH_S` | High count | Schema stability lock wait |
| `LCK_M_BU` | High duration | Bulk update lock contention |

### Latch Contention

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `PAGELATCH_EX` | High count on 2:1:1, 2:1:2, etc. | TempDB PFS/GAM/SGAM contention (add tempdb files) |
| `PAGELATCH_SH` | High count | Page latch contention |
| `PAGELATCH_UP` | High count | Last-page insert contention (consider OPTIMIZE_FOR_SEQUENTIAL_KEY) |
| `LATCH_EX` / `LATCH_SH` | total > 10M ms | Non-buffer latch contention (check sys.dm_os_latch_stats for class) |

### Memory

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `RESOURCE_SEMAPHORE` | Any occurrence (avg > 5000 ms critical) | Queries waiting for memory grant — insufficient memory or oversized grants |
| `RESOURCE_SEMAPHORE_QUERY_COMPILE` | Any occurrence | Compilation memory throttle — too many concurrent compilations |
| `RESOURCE_SEMAPHORE_MUTEX` | High duration | Memory resource mutex contention |

### Network / Client

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `ASYNC_NETWORK_IO` | Top wait, high avg | Client not consuming results fast enough (app-side bottleneck, large result sets) |
| `NET_WAITFOR_PACKET` | High duration | Network layer delays |

### HADR / Availability Groups

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `HADR_SYNC_COMMIT` | avg > 10 ms | Synchronous commit latency — network or secondary I/O |
| `HADR_LOGCAPTURE_SYNC` | High duration | Log capture sync delay |
| `HADR_TRANSPORT_SESSION` | High duration | AG transport layer issue |
| `HADR_DB_COMMAND` | High duration | AG database command timeout |
| `HADR_DATABASE_FLOW_CONTROL` | High duration | Log send queue full — secondary too slow |

### Parallelism

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `CXPACKET` | Top wait (high avg) | Parallel query skew — uneven distribution of work across threads |
| `CXSYNC_PORT` | High duration | Exchange iterator port sync (long sort/hash before exchange) |
| `CXSYNC_CONSUMER` | High duration | Consumer thread synchronization |

### Compilation / Optimization

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `RESOURCE_SEMAPHORE_QUERY_COMPILE` | Any occurrence | Too many concurrent compilations |
| `COMPILATION` | High duration | Query compilation overhead |
| `OPTIMIZATION` | High duration | Query optimization time |

### Transaction Log

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `WRITELOG` | avg > 5 ms | Log disk latency |
| `LOGBUFFER` | Any significant occurrence | Log buffer contention — log write throughput saturated |
| `LOG_RATE_GOVERNOR` | Any occurrence (Azure SQL / MI) | Log rate governance throttle |

### Preemptive OS Calls (non-benign)

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `PREEMPTIVE_OS_AUTHENTICATIONOPS` | avg > 5000 ms | AD authentication slow — DC unreachable or slow |
| `PREEMPTIVE_OS_AUTHORIZATIONOPS` | avg > 5000 ms | AD authorization slow |
| `PREEMPTIVE_OS_LOOKUPACCOUNTSID` | avg > 5000 ms | SID lookup slow — DNS/AD issue |
| `PREEMPTIVE_OS_GETPROCADDRESS` | High duration | DLL function resolution delay |
| `PREEMPTIVE_OS_WRITEFILE` | High duration | External file write slow |
| `PREEMPTIVE_OS_WRITEFILEGATHER` | High duration | Scatter/gather write slow |
| `PREEMPTIVE_OLEDB_*` | High duration | Linked server / OLEDB provider slow |

### Replication

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `REPL_*` | High duration | Replication latency |

### In-Memory OLTP (non-benign)

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `WAIT_XTP_OFFLINE_CKPT_BEFORE_REDO` | High duration | In-memory checkpoint delay |
| `WAIT_XTP_CKPT_AGENT_GONE` | Any occurrence | Checkpoint agent crash |

### Miscellaneous

| Wait Type | Red Flag Threshold | Root Cause |
|-----------|-------------------|------------|
| `OLEDB` | High duration | OLEDB provider calls (linked server, full-text) |
| `EXCHANGE` | High duration | Parallel query exchange spill |
| `EXECSYNC` | High duration | Parallel plan synchronization |
| `MSQL_XP` | High duration | Extended stored procedure (xp_cmdshell, etc.) |
| `TRACEWRITE` | High duration | SQL Trace / Profiler overhead |

---

## Quick Decision Tree

```
Is the wait in the Benign list?
├── YES → Filter out, ignore
└── NO → Check category:
    ├── CPU (SOS_SCHEDULER_YIELD, THREADPOOL, CMEMTHREAD)
    │   └── Check CPU %, scheduler count, max worker threads
    ├── I/O (PAGEIOLATCH_*, WRITELOG, IO_COMPLETION)
    │   └── Check disk latency (sys.dm_io_virtual_file_stats)
    ├── Locking (LCK_M_*)
    │   └── Check blocking chains (sys.dm_exec_requests, sys.dm_tran_locks)
    ├── Memory (RESOURCE_SEMAPHORE)
    │   └── Check memory grants (sys.dm_exec_query_memory_grants)
    ├── Network (ASYNC_NETWORK_IO)
    │   └── Check client app, result set size, network latency
    ├── HADR (HADR_SYNC_COMMIT, etc.)
    │   └── Check AG dashboard, log send/redo queue
    └── Other → Look up specific wait type in sys.dm_os_wait_stats docs
```
