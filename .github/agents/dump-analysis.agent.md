---
name: dump-analysis
description: >-
  Generate WinDbg Mirrors commands for SQL Server crash dump analysis. Maps errors
  to subsystem-specific ring buffers and DMV-equivalent commands. Use when the user
  says "analyze dump", "分析 dump", provides a .mdmp file path, or asks to generate
  WinDbg commands for a SQL Server dump.
---

# Dump Analysis Skill

## Overview

This skill generates WinDbg Mirrors/SqlCsScripts commands for analyzing SQL Server
crash dumps, and optionally parses dump analysis results pasted back by the user.
It maps error subsystems to the correct ring buffer scripts and LINQ queries.

## Activation Triggers

Activate this skill when the user:
- Says "analyze dump", "分析 dump", "debug dump"
- Provides a dump file path (`.mdmp`, `.dmp`)
- Asks for WinDbg commands for a specific error
- Pastes WinDbg/Mirrors output for parsing

## Required Inputs

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `dump_path` | string | No | Path to dump file (for WinDbg launch command) |
| `error_numbers` | int[] | No | Error numbers to focus analysis on |
| `subsystem` | string | No | Subsystem hint: `HADR`, `MEMORY`, `SCHEDULER`, `LOCKING`, `IO`, `CONNECTIVITY` |
| `call_stack_functions` | string[] | No | Function names from a known call stack |
| `case_id` | string | No | Case identifier for output naming |

> At least one of `error_numbers`, `subsystem`, or `call_stack_functions` should be provided.
> If none are provided, generate a general-purpose diagnostic script.

---

## Step 1: Generate Session Setup Commands

Always start with extension loading and symbol setup:

```windbg
-- ========================================
-- SQL-CSI Dump Analysis Script
-- Case: {case_id}
-- Generated: {timestamp}
-- ========================================

-- Open dump (if not already open)
-- windbgx /startmcp -z {dump_path}

-- Load symbols
.symfix
.reload /f

-- Load SqlCsScripts from symbol server
!dcs_initsymsvr sqlservr
!dcs_initsymsvr sqldk

-- Verify scripts loaded
!execute
```

---

## Step 2: Determine Analysis Focus

### 2.1 Subsystem-to-Script Mapping

Based on error numbers or explicit subsystem, select the appropriate Mirrors scripts:

| Subsystem | Error Ranges | Primary Ring Buffers | Primary Scripts | Secondary Scripts |
|-----------|-------------|---------------------|-----------------|-------------------|
| **HADR / AG** | 19001-19599, 35001-35999 | `EnumerateHadrDbMgrStateRingBufferRecords`, `EnumerateHadrArSignalStateRecords`, `EnumerateHadrDbMgrAPIRingBufferRecords`, `EnumerateHadrDbMgrCommitRingBufferRecords`, `EnumerateHadrTransportStateRingBufferRecords`, `EnumerateHadrLeaseWorkerRingBufferRecords`, `EnumerateHadrArPubishEventsRecords` | `HadronManager.Enumerate`, `HadronSyncWaiters.Enumerate` | `EnumerateConnectivityTraceRecords` |
| **Memory / OOM** | 701-899, 8645, 17300 | `EnumerateMemoryNodeOOMRingRecords`, `EnumerateMemoryBrokerRingRecords`, `EnumerateMemoryBrokerClerkRingRecords` | `MemoryClerks.Enumerate`, `MemoryGrants.Enumerate`, `MemoryNodes.Enumerate`, `MemoryObjects.Enumerate` | `EnumerateSOSMemoryObjectRingRecords` |
| **Scheduler / CPU** | 17883, 17884, 17888 | `EnumerateSchedulerRingRecords`, `EnumerateSchedulerMonitorRecords`, `EnumerateCpuPressureRingRecords`, `EnumerateCpuQuantumThiefRecords`, `EnumerateCpuStarvationStatsRecords`, `EnumerateNonYieldCopiedStackRecords` | `Schedulers.Enumerate`, `Workers.Enumerate`, `AnalyzeNonYieldingSchedulers.Enumerate` | `EnumerateAggSchedStatRecords` |
| **Locking / Deadlock** | 1101-1299, 1205 | `EnumerateSpinlockBackoffRecords` | `Locks.Enumerate`, `Deadlocks.GetDeadlockDetails`, `WaitingTask.Enumerate`, `LatchContendedPages.Enumerate`, `LatchOwnership.Counts` | `OSWaitStatistics.Enumerate`, `OSLatchStatistics.Enumerate` |
| **Connectivity / Login** | 17801-17830, 18401-18499 | `EnumerateConnectivityTraceRecords`, `EnumerateSNIRingBufferRecords` | `Sessions.Enumerate`, `Connections.Enumerate`, `SNIListeners.Enumerate`, `SNIErrors.Enumerate` | `Logins.Enumerate` |
| **Storage / IO** | 601-699, 823, 824, 825, 833 | `EnumerateVirtualFileIoStatsRingBufferRecords` | `PendingIOs.Enumerate`, `Databases.Enumerate`, `Indexes.Enumerate` | `EnumerateHoBtFactoryRingBufferRecords` |
| **Transaction Log** | 9001-9100 | — | `Databases.Enumerate`, `LogMgrLogRecords.Enumerate` | `PendingIOs.Enumerate` |
| **Query Execution** | 8601-8699 | — | `CachedPlans.Enumerate`, `QueryPlans.Enumerate`, `QueryExecutionTrees.Enumerate`, `MemoryGrants.Enumerate` | `QueryStats.Enumerate` |
| **General** | (any) | `EnumerateExceptionRingRecords` | `Sessions.Enumerate`, `Threads.All`, `Schedulers.Enumerate`, `DbccInputBuffers.Enumerate` | `ProcessSummary.Enumerate`, `Times.DumpTime` |

### 2.2 Always-Include Commands

These commands provide essential context regardless of subsystem:

```windbg
-- Dump metadata
!execute Times.DumpTime
!execute Times.SqlUptime
!execute ProcessSummary.Enumerate

-- Exception ring buffer (always check first)
!evaluate (execute SOSRingBuffers.EnumerateExceptionRingRecords).OrderByDescending(r => r.position).Take(50)

-- Active sessions
!evaluate (execute Sessions.Enumerate).Where(s => s.is_user_process == true).Take(50)

-- Top memory consumers
!evaluate (execute MemoryClerks.Enumerate).GroupBy(m => m.clerk_type_name, q => q.pages_kb).Select(m => new {m.key, m.Sum(y => y)}).OrderByDescending(m => m.item2).Take(10)

-- Scheduler overview
!execute Schedulers.Enumerate

-- Wait stats snapshot
!execute OSWaitStatistics.Enumerate

-- Trace flags
!execute TraceFlags.Enumerate
```

---

## Step 3: Generate Error-Specific Commands

For each error number, generate targeted queries:

### 3.1 Exception Ring Buffer — Filtered by Error

```windbg
-- All occurrences of error {error_number}
!evaluate (execute SOSRingBuffers.EnumerateExceptionRingRecords).Where(r => r.m_error == {error_number}).OrderByDescending(r => r.position)

-- With call stack expansion
!evaluate (execute SOSRingBuffers.EnumerateExceptionRingRecords).Where(r => r.m_error == {error_number}).Select(r => new {r.position, r.m_error, r.m_severity, r.m_state, r.m_throwing_task, r.m_origin, r.stack_frames.Nested()})

-- By severity range (find related high-severity errors)
!evaluate (execute SOSRingBuffers.EnumerateExceptionRingRecords).Where(r => r.m_severity >= 16).OrderByDescending(r => r.position).Take(30)
```

### 3.2 Exception Ring — Cross-Reference by Task

When a specific task address is known (from previous query results):

```windbg
-- All exceptions from the same task
!evaluate (execute SOSRingBuffers.EnumerateExceptionRingRecords).Where(r => r.m_throwing_task == {task_address}).OrderByDescending(r => r.position)

-- Follow task → worker → scheduler chain
!evaluate (execute SOSRingBuffers.EnumerateExceptionRingRecords).Where(r => r.m_throwing_task != nullptr && r.m_throwing_task.m_pWorker != nullptr && r.m_throwing_task.m_pWorker.m_pSched != nullptr && r.m_throwing_task.m_pWorker.m_pSched.m_id == {scheduler_id}).OrderByDescending(r => r.position)
```

### 3.3 Subsystem-Specific Deep Dives

**HADR Deep Dive:**
```windbg
-- AG manager state
!execute HadronManager.Enumerate

-- DB manager state transitions
!evaluate (execute SOSRingBuffers.EnumerateHadrDbMgrStateRingBufferRecords).OrderByDescending(r => r.position).Take(50)

-- AR API calls (function entry/exit)
!evaluate (execute SOSRingBuffers.EnumerateHadrDbMgrAPIRingBufferRecords).OrderByDescending(r => r.position).Take(50)

-- Transport state (network issues between replicas)
!evaluate (execute SOSRingBuffers.EnumerateHadrTransportStateRingBufferRecords).OrderByDescending(r => r.position).Take(30)

-- Lease worker (cluster communication)
!evaluate (execute SOSRingBuffers.EnumerateHadrLeaseWorkerRingBufferRecords).OrderByDescending(r => r.position).Take(30)

-- Commit ring buffer (commit latency)
!evaluate (execute SOSRingBuffers.EnumerateHadrDbMgrCommitRingBufferRecords).OrderByDescending(r => r.position).Take(30)

-- Sync waiters (sessions waiting for sync commit)
!execute HadronSyncWaiters.Enumerate
```

**Memory Deep Dive:**
```windbg
-- OOM ring buffer
!evaluate (execute SOSRingBuffers.EnumerateMemoryNodeOOMRingRecords).OrderByDescending(r => r.position)

-- Memory broker notifications
!evaluate (execute SOSRingBuffers.EnumerateMemoryBrokerRingRecords).OrderByDescending(r => r.position).Take(30)

-- Memory clerks grouped by type
!evaluate (execute MemoryClerks.Enumerate).GroupBy(m => m.clerk_type_name, q => q.pages_kb).Select(m => new {m.key, m.Sum(y => y)}).OrderByDescending(m => m.item2).Take(20)

-- Memory grants waiting
!evaluate (execute MemoryGrants.Enumerate).Where(g => g.grant_memory_kb == 0)

-- Memory nodes
!execute MemoryNodes.Enumerate
```

**Scheduler Deep Dive:**
```windbg
-- Non-yielding scheduler analysis
!execute AnalyzeNonYieldingSchedulers.Enumerate

-- Scheduler ring buffer
!evaluate (execute SOSRingBuffers.EnumerateSchedulerRingRecords).OrderByDescending(r => r.position).Take(50)

-- CPU pressure
!evaluate (execute SOSRingBuffers.EnumerateCpuPressureRingRecords).OrderByDescending(r => r.position).Take(20)

-- Workers by status
!evaluate (execute Workers.Enumerate).GroupBy(w => w.status, q => q).Select(q => new {q.key, q.Count()})

-- Scheduler details
!evaluate (execute Schedulers.Enumerate).Where(s => s.is_hidden == false)
```

**Locking Deep Dive:**
```windbg
-- Deadlock details
!execute Deadlocks.GetDeadlockDetails

-- Waiting tasks
!execute WaitingTask.Enumerate

-- Lock contention
!evaluate (execute Locks.Enumerate).Where(l => l.lock_count > 0).Take(50)

-- Latch contended pages
!execute LatchContendedPages.Enumerate

-- Spinlock backoff
!evaluate (execute SOSRingBuffers.EnumerateSpinlockBackoffRecords).OrderByDescending(r => r.position).Take(30)
```

---

## Step 4: Parse Dump Results (Manual Handoff)

When the user pastes WinDbg output back, extract:

### 4.1 From Exception Ring Buffer Output

Look for patterns:
```
| record | position | m_error | m_severity | m_state | ... | m_throwing_task | m_origin | stack_frames |
```

Extract:
- `error_numbers` — unique error numbers found
- `task_addresses` — unique throwing task addresses
- `call_stack_functions` — function names from stack frames
- `error_origins` — EX_ORIGIN_RAISE, EX_ORIGIN_THROW, etc.

### 4.2 From HADR Ring Buffer Output

Look for state transitions:
- `PRIMARY → RESOLVING` — failover initiated
- `RESOLVING → SECONDARY` — became secondary
- `SECONDARY → PRIMARY` — failover completed
- Note timestamps for correlation with errorlog timeline

### 4.3 From Memory/Scheduler Output

Flag:
- `runnable_tasks_count > 0` on multiple schedulers → CPU pressure
- `work_queue_count > 0` → worker thread exhaustion
- Memory clerks with unusually large allocations
- Memory grants waiting (grant_memory_kb == 0)

### 4.4 Compile Findings

```markdown
## Dump Analysis Findings

### Exception Summary
- {N} unique errors found in exception ring buffer
- Most frequent: Error {XXXX} ({count} occurrences)
- Most recent: Error {YYYY} at position {pos}

### Call Stack Functions (for source code search)
- {ClassName::FunctionName} — raises Error {XXXX}
- {ClassName::FunctionName2} — caller of above

### Server State at Dump Time
- Memory pressure: {YES/NO}
- Scheduler pressure: {YES/NO}
- HADR state: {state}
- Active sessions: {count}

### Errors for Code Search
- HIGH: {error_number} (from call stack, confirmed in ring buffer)
- MEDIUM: {error_number} (in ring buffer, no call stack)
```

Save to `reports/{case_id}_dump_findings.md`

---

## LINQ Query Rules Reference

### Value Comparison Syntax

| Type | Syntax | Example |
|------|--------|---------|
| Numeric | `==`, `!=`, `>`, `<` | `r.m_error == 19433` |
| Hex address | `0x` prefix | `r.m_throwing_task == 0x00000228c8b30008` |
| Enum string | Double quotes | `r.m_origin == "EX_ORIGIN_RAISE"` |
| String | Single quotes | `r.name == 'value'` |
| String search | `.Contains()` | `b.text.Text.Contains("keyword")` |
| Null pointer | `== nullptr` | `w.task == nullptr` |
| Boolean | `== true/false` | `r.is_hidden == true` |

### Column Names

> **CRITICAL**: Use **snake_case** in LINQ `.Where()` filters, NOT PascalCase C++ names.
> Example: `m_throwing_task` (correct), NOT `m_ThrowingTask` (wrong).
>
> Alternative: access raw C++ names via `.Record`: `r.Record.m_ThrowingTask`

### Sorting

> **Ring buffers**: ALWAYS sort by `position` descending.
> **Other enumerations**: Sort by meaningful key (session_id, timestamp, etc.).

### Chaining with `lastResult`

```windbg
!execute Sessions.Enumerate
!evaluate lastResult.Where(s => s.session_id == 87)
!evaluate lastResult.GroupBy(s => s.HostName, q => q).Select(q => new {q.Key, q.Count()})
```

---

## Output Format

### For User (Manual Execution)

Output a single, copy-pasteable command block with:
1. Setup commands (symbols, extension loading)
2. Always-include commands (dump metadata, exception ring, memory top 10)
3. Error-specific commands (filtered by error numbers)
4. Subsystem deep-dive commands
5. Comments explaining what each command does

### For Workflow 4 (Programmatic)

Return structured findings for source code search:
```
DUMP_FINDINGS:
  errors: [19433, 35206]
  call_stack_functions: ["WsfcIsAgIntactInWsfc", "ComputeInitialStateInWsfc"]
  server_state: {memory_pressure: false, scheduler_pressure: false, hadr_state: "RESOLVING"}
```
