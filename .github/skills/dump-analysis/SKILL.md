---
name: dump-analysis
description: >-
  Analyze SQL Server crash dumps via cdb.exe CLI automation or WinDbg GUI command
  generation. Uses SqlCsScripts/Mirrors to query ring buffers, DMV-equivalents, and
  subsystem state. Use when the user says "analyze dump", "分析 dump", provides a
  .mdmp file path, or asks to generate WinDbg commands for a SQL Server dump.
context: fork
---

# Dump Analysis Skill

## Overview

This skill analyzes SQL Server crash dumps using two execution paths:

- **Path A — cdb.exe CLI (preferred)**: Run debugger commands directly from the
  terminal via `cdb.exe`. Output is captured automatically for parsing. No manual
  copy-paste needed.
- **Path B — WinDbg GUI (fallback)**: Generate a command block for the user to
  execute in WinDbg manually. Use when cdb.exe is unavailable or when the user
  explicitly wants GUI interaction.

Both paths use the same SqlCsScripts/Mirrors LINQ queries. The difference is
only in how commands are dispatched and output is collected.

## Activation Triggers

Activate when the user:
- Says "analyze dump", "分析 dump", "debug dump"
- Provides a dump file path (`.mdmp`, `.dmp`)
- Asks for WinDbg commands for a specific error
- Pastes WinDbg/Mirrors output for parsing

## Path Selection

```
IF dump_path is provided AND cdb.exe is reachable:
  → Path A (cdb.exe CLI)
ELSE IF user says "generate commands" or "WinDbg":
  → Path B (WinDbg GUI)
ELSE IF user pastes WinDbg output:
  → Step 4 (Parse Results) directly
ELSE:
  → Ask user which path to use
```

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

## Symbol Path (read this FIRST — do NOT hardcode msdl)

**Always use the machine's configured symbol path** — on this workstation it is the
User environment variable `_NT_SYMBOL_PATH`:

```
srv*C:\Symbols*https://symweb.azurefd.net
```

- `symweb.azurefd.net` is the **internal** symbol server — it has SQL private PDBs
  **and** the SqlCsScripts/Mirrors packages. The public `msdl.microsoft.com` has
  neither the mirrors nor (reliably) SQL private symbols, so **do not hardcode
  `https://msdl.microsoft.com/download/symbols`** in scripts.
- In a `.cdb` script use `.sympath` with the value from `_NT_SYMBOL_PATH`, e.g.
  `.sympath srv*C:\Symbols*https://symweb.azurefd.net`. Using `.symfix` is fine
  **only** if the machine default already points at symweb; prefer reading the env
  var so the path is correct everywhere.
- **sympath ordering rule**: an HTTP store must be the LAST store, and there can be
  only ONE HTTP store. `srv*C:\Symbols*https://symweb...*https://msdl...` fails with
  `SYMSRV: Any HTTP store must be the last store in the list`. Keep symweb last/alone.
- Resolve it at runtime:
  ```powershell
  $sym = [Environment]::GetEnvironmentVariable('_NT_SYMBOL_PATH','User')
  if (-not $sym) { $sym = 'srv*C:\Symbols*https://symweb.azurefd.net' }
  ```
  then emit `.sympath $sym` into the `.cdb` script.
- VPN required for symweb. If symweb is unreachable, private symbols (and mirrors)
  won't load — fall back to `kn` + `!analyze -v` only (Part 2 decision table).

---

## Step 1: Session Setup

### Path A — cdb.exe CLI Automated

#### 1.1 Verify cdb.exe availability

```powershell
$cdbPaths = @(
    (Get-Command cdb.exe -ErrorAction SilentlyContinue).Source,
    "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe",
    "${env:ProgramFiles}\Windows Kits\10\Debuggers\x64\cdb.exe"
) | Where-Object { $_ -and (Test-Path $_) }

if ($cdbPaths) { $cdb = $cdbPaths[0]; "Found: $cdb" }
else { "cdb.exe not found — fall back to Path B (WinDbg GUI)" }
```

#### 1.2 Generate .cdb script file

Create a temp script file with all commands. cdb.exe reads one command per line.
Lines starting with `*` are comments.

```powershell
$scriptPath = "reports/{case_id}_dump_commands.cdb"
```

Script file content:

```text
* ========================================
* SQL-CSI Dump Analysis — Case: {case_id}
* ========================================
.sympath srv*C:\Symbols*https://symweb.azurefd.net
.reload /f
!dcs_initsymsvr sqlservr
!dcs_initsymsvr sqldk
!execute Times.DumpTime
!execute Times.SqlUptime
!execute ProcessSummary.Enumerate
!evaluate (execute SOSRingBuffers.EnumerateExceptionRingRecords).OrderByDescending(r => r.position).Take(50)
!evaluate (execute Sessions.Enumerate).Where(s => s.is_user_process == true).Take(50)
!evaluate (execute MemoryClerks.Enumerate).GroupBy(m => m.clerk_type_name, q => q.pages_kb).Select(m => new {m.key, m.Sum(y => y)}).OrderByDescending(m => m.item2).Take(10)
!execute Schedulers.Enumerate
!execute OSWaitStatistics.Enumerate
!execute TraceFlags.Enumerate
{subsystem_commands}
q
```

> The final `q` exits cdb.exe after all commands finish.

#### 1.3 Run cdb.exe and capture output

```powershell
$dumpPath  = "{dump_path}"
$scriptFile = "reports/{case_id}_dump_commands.cdb"
$outputFile = "reports/{case_id}_dump_output.txt"

# -z   open dump file
# -cf  run commands from script file
# -logo  log all output to file (overwrite)
# -G   ignore final breakpoint on process exit
# -lines  load line number info
& $cdb -z $dumpPath -cf $scriptFile -logo $outputFile -G -lines
```

> **Timeout**: Allow up to 5 minutes for large dumps.

#### 1.4 Read and parse output

After cdb.exe completes, read the output file and proceed to **Step 4 (Parse Results)**.

```powershell
$output = Get-Content $outputFile -Raw
```

### Path B — WinDbg GUI (Manual)

Generate a copy-pasteable command block for the user:

```windbg
* ========================================
* SQL-CSI Dump Analysis Script
* Case: {case_id}
* Generated: {timestamp}
* ========================================

* Open dump: windbgx -z {dump_path}

.sympath srv*C:\Symbols*https://symweb.azurefd.net
.reload /f
!dcs_initsymsvr sqlservr
!dcs_initsymsvr sqldk
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

Save to `reports/{case_id}_dump_findings.md` (workspace-relative path).

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

## cdb.exe CLI Reference

### Command-Line Flags

| Flag | Purpose | Example |
|------|---------|--------|
| `-z <path>` | Open dump file | `-z C:\Temp\SQLDump.mdmp` |
| `-cf <file>` | Run commands from script file | `-cf analysis.cdb` |
| `-c "<cmds>"` | Run inline commands (`;`-separated) | `-c ".symfix;.reload /f;q"` |
| `-logo <file>` | Log output to file (overwrite) | `-logo output.txt` |
| `-loga <file>` | Log output to file (append) | `-loga output.txt` |
| `-G` | Ignore final breakpoint | Always use |
| `-lines` | Enable source line info | Optional |
| `-QY` | Suppress save workspace dialog | Optional |

### Script File Format (.cdb)

- One command per line
- Comments start with `*`
- Empty lines are ignored
- End with `q` to exit cdb.exe
- LINQ queries go on a single line (no line breaks within `!evaluate`)

### Multi-Phase Pattern

```
Phase 1: Triage
  cdb -z dump.mdmp -G -logo triage.txt -c ".sympath srv*C:\Symbols*https://symweb.azurefd.net;.reload /f;!dcs_initsymsvr sqlservr;!dcs_initsymsvr sqldk;!execute Times.DumpTime;!execute ProcessSummary.Enumerate;!evaluate (execute SOSRingBuffers.EnumerateExceptionRingRecords).OrderByDescending(r => r.position).Take(50);q"
  → Parse triage.txt → extract error numbers, subsystem

Phase 2: Deep Dive
  → Generate subsystem-specific .cdb script based on Phase 1 findings
  cdb -z dump.mdmp -G -logo deepdive.txt -cf deepdive.cdb
  → Parse deepdive.txt → extract detailed findings

Phase 3: Targeted Follow-up
  → Run specific queries for task addresses, session IDs found in Phase 2
```

### Printing the Call Stack (DX model preferred)

To print a thread's call stack, **prefer the DX data model over `kn`** — DX gives
every frame (including inline functions) a stable, contiguous `[0xNN]` index that
matches the index used later to inspect that frame's locals (see next section).
`kn` collapses/annotates inline frames differently, causing index mismatch.

**Faulting thread (current thread):**
```text
dx -r1 @$curthread.Stack.Frames
```

**Grid form (nicer table, one row per frame):**
```text
dx -g @$curthread.Stack.Frames.Select(f => new { Frame = f.ToDisplayString() })
```

**A specific thread (by PID/TID):**
```text
dx -r1 Debugger.Sessions[0].Processes[<PID>].Threads[<TID>].Stack.Frames
```
> Run `dx Debugger.Sessions[0].Processes` and `.First().Threads` first to obtain
> the `[PID]` / `[TID]` indices. Pipe to a `-logo` file and parse the `[0xNN]`
> column for the frame map.

### Inspecting Per-Frame Local Variables (DX model preferred)

To examine local variables / memory values of each call-stack frame, **prefer the
DX data model `Frames[N]` index over `.frame /c N`**.

**Why DX is more reliable:** `.frame /c N` renumbers frames whenever inline
functions are present (the log shows `Reset base frame from N to 0, which points
to the inner-most inline function frame`). This causes index drift and can skip
frames (e.g. `DBTABLE::Startup` / `DBMgr::StartupDB`). The DX `Frames[N]` index
treats every inline frame as its own stable, contiguous entry, so `dv` lands on
the correct frame every time.

**Step 1 — enumerate indices (get PID/TID and frame numbers):**
```text
dx Debugger.Sessions[0].Processes
dx Debugger.Sessions[0].Processes.First().Threads
dx -r1 @$curthread.Stack.Frames
```
> `@$curthread.Stack.Frames` lists every frame (including inline) with its `[0xNN]`
> index. Note the `[PID]` and `[TID]` from the first two commands.

**Step 2 — switch to a frame and dump its locals:**
```text
dx Debugger.Sessions[0].Processes[<PID>].Threads[<TID>].Stack.Frames[<N>].SwitchTo()
dv /t /v
```
Repeat for each frame of interest. `dv /t /v` prints type + address + value for
every local. Combine multiple frames in one `.cdb` script with `.echo ===Fxx===`
separators for easy parsing.

**Fallback when a local shows `<value unavailable>`** (common in minidumps):
search the thread stack region directly for known strings/pointers, e.g. find the
failing database's data file:
```text
s -su <stack_lo> L<range> ".mdf"
```

### Output Parsing Notes

cdb.exe output includes debugger chrome (prompts, module load messages).
When parsing output:
- Skip lines starting with `Microsoft (R)`, `Copyright`, `Loading`, `Opened log file`
- Look for table-formatted output between command echo and next prompt `0:000>`
- SqlCsScripts output is typically pipe-delimited or formatted as tables
- Errors appear as `*** ERROR:` or `Error in ...`

---

## Output Format

### Path A — cdb.exe CLI (Automated)

Files generated:
1. `reports/{case_id}_dump_commands.cdb` — script file sent to cdb.exe
2. `reports/{case_id}_dump_output.txt` — raw cdb.exe output
3. `reports/{case_id}_dump_findings.md` — parsed findings report

### Path B — WinDbg GUI (Manual)

Output a single, copy-pasteable command block with:
1. Setup commands (symbols, extension loading)
2. Always-include commands (dump metadata, exception ring, memory top 10)
3. Error-specific commands (filtered by error numbers)
4. Subsystem deep-dive commands
5. `*` comments explaining what each command does

### For Workflow (Programmatic)

Return structured findings for source code search:
```
DUMP_FINDINGS:
  errors: [19433, 35206]
  call_stack_functions: ["WsfcIsAgIntactInWsfc", "ComputeInitialStateInWsfc"]
  server_state: {memory_pressure: false, scheduler_pressure: false, hadr_state: "RESOLVING"}
```

---

# Part 2: Native Dump-Walking Methods (SqlCsScripts-independent)

Everything in Part 1 relies on **SqlCsScripts/Mirrors** (`!execute` / `!evaluate` LINQ).
Those mirrors are version-matched managed assemblies downloaded from the symbol
server — when they are missing, fail to load, or the dump is an unsupported build
(e.g. SQL 2019), the mirror queries return nothing.

This part extracts the analysis methodology used by the **DumpViewer** tool
(`SqlTelemetry/Src/Tools/DumpViewer`, namespace `CsDebugScript.DumpViewer`). Unlike
the mirrors path, DumpViewer reconstructs state by **walking raw symbols and stack
local variables** — so these methods work on any dump where private symbols load,
with no SqlCsScripts dependency. All techniques below are expressed as plain
cdb.exe commands.

## Reference Knowledge Base

Deep, source-grounded methods live in separate reference files so they can be
extended independently. **Read the relevant file before analyzing that dump type:**

| File | Content |
|------|---------|
| [reference/latch_timeout.md](reference/latch_timeout.md) | Full latch timeout analysis — `LatchBase::Suspend` locals, complete `m_count` 64-bit mask table, latch class decode, circular waiter-list walk, self-wait (parallel-query) deadlock detection, insight checklist. Grounded in `LatchTimeout.cs`. |
| [reference/non_yielding.md](reference/non_yielding.md) | Full non-yielding / stall analysis — incident-type ↔ callback-frame table, `pTrack` validation, diagnostics fields (`m_pass`, wall/kernel/user time, preemptive), copied-stack `.cxr` capture, interpretation table. Grounded in `NonYieldStallAnalysis.cs`. |

> Methods 1, 4, 5 below are general-purpose and stay inline. Methods 2 (latch) and 3
> (non-yield) are summarized below with a pointer to their reference file.

## How DumpViewer Loads the Dump

DumpViewer does **not** invent a new loader. It hosts `DbgEng.dll` (the same engine
behind cdb.exe/WinDbg) through the managed `CsDebugScript` wrapper:

1. `CodeGenHelper.OpenDumpFileBasic(dumpPath, symbolPath)` → `IDebugClient::OpenDumpFile`
   (equivalent to `cdb -z <dump>`).
2. Sets `DBGHELP_DIA_PATH` so `msdia140.dll` resolves PDB type info.
3. `.reload /f` on the key modules: `sqlservr.exe`, `sqlos.dll`, `sqldk.dll`,
   `sqlmin.dll`, `sqllang.dll` (the `SqlKeyModules` list).
4. **Separately**, it memory-maps the dump file and parses the MINIDUMP stream
   directory itself (`MiniDumpReadDumpStream`) to read header / comment /
   `MiscInfoStream` / `SystemInfoStream` / `SystemMemoryInfoStream`.

> **cdb equivalent of step 4** — you don't need the MMF code; the same metadata is
> available directly:
> ```text
> .dumpdebug                 * stream directory, flags, comment, system info
> ||                          * dump target summary
> vertarget                  * OS build / uptime / dump time
> !envvar                    * (comment stream often carries the dump reason)
> ```

## The Core Technique: Stack-Frame Local-Variable Navigation

This is the single most important DumpViewer idea and it is **not** in the mirrors
path. Instead of reading global manager tables, DumpViewer walks **every thread's
stack**, finds a frame whose function matches a target, and reads that frame's
**local variables** (which hold pointers to the live objects). This survives
minidumps where global tables are paged out, because the pointer lives on the stack.

cdb pattern (repeat per thread, or scripted with `~* e`):
```text
* 1. list frames of current thread with stable indices (DX preferred over kn)
dx -r1 @$curthread.Stack.Frames
* 2. switch to the frame whose function matches the target, then dump its locals
dx Debugger.Sessions[0].Processes[<PID>].Threads[<TID>].Stack.Frames[<N>].SwitchTo()
dv /t /v
* 3. follow the pointer found in a local (e.g. pWorker) into the struct
dt sqldk!SOS_Worker <pWorker_addr>
```
> Minidump fallback when a local shows `<value unavailable>`: search the thread's
> stack memory for the pointer, e.g. `s -q <stack_lo> L<range> <candidate>` or scan
> for the vtable.

### Target functions DumpViewer keys off (memorize these)

| Object to recover | Frame function (`module!Class::Method`) | Local variable name |
|-------------------|------------------------------------------|---------------------|
| Scheduler | `sqldk!SystemThreadDispatcher::ProcessWorker` | `pScheduler` / `scheduler` |
| Worker (+Task) | `sqldk!Worker::EntryPoint` (via ProcessWorker) | `pWorker` |
| Latch waiter | `sqlmin!LatchBase::Suspend` | `this` (latch), `latchWait`, `waitType` |
| Latch timeout | `sqlmin!LatchBase::DumpOnTimeoutIfNeeded` | `timeoutInfo` |
| Non-yield track | `sqlmin!SQL_SOSNonYield*Callback` / `ExecuteNonYield*Callbacks` | `pTrack` |

## Method 1 — Enumerate Schedulers / Workers / Tasks from Thread Locals

DumpViewer's `MiniDumpData.GetSchedulers` / `GetThreadDetails` algorithm:

1. For each thread, find the frame at `sqldk!SystemThreadDispatcher::ProcessWorker`.
2. Read local `pScheduler` → dedupe by pointer → that's the live scheduler set.
3. Read local `pWorker`; from the worker follow fields:

| Field path | Meaning |
|------------|---------|
| `m_state` | worker state (RUNNING / SUSPENDED / …) |
| `m_LastWaitType` | last wait (index into `PWAIT_enum`, see Method 5) |
| `m_pSched->m_id` | owning scheduler id |
| `m_pTask->m_State` | task state |
| `m_pTask->m_pWorker->m_pSysThread->m_Id` | OS thread id → maps to debugger thread |

cdb realization:
```text
* worker fields
dt sqldk!SOS_Worker <pWorker> m_state m_LastWaitType m_pSched m_pTask m_status
* scheduler id
dt sqldk!SOS_Scheduler <m_pSched> m_id
* task state + back-link to OS thread
dt sqldk!SOS_Task <m_pTask> m_State m_pWorker
dt sqldk!SystemThread <m_pSysThread> m_Id
```
> **Map OS thread id → debugger thread**: `GetThreadIdByTask` walks
> `task → m_pWorker → m_pSysThread → m_Id`, then matches `m_Id` against each
> debugger thread's system id. In cdb: `~` lists threads with their TIDs; match the
> `m_Id` value to the `Id:` column.
>
> ⚠️ **Worker type name (build-specific):** on SQL 2016 the worker object is type
> **`Worker`** (NOT `SOS_Worker`), `SOS_Task.m_pWorker` is at `+0x98`, and
> `Worker.m_pSysThread` is at `+0x208`. The reliable one-liner to get an owner task's
> OS thread id is: `dx ((sqldk!Worker*)<m_pWorker>)->m_pSysThread->m_Id`. If
> `SOS_Worker`/a field name fails to bind, dump the struct first
> (`dt sqldk!Worker <addr>`) to find the correct field offsets for the build.

> ⚠️ **Minidump caveat (applies to ALL methods):** `SOS_Task.m_State`,
> `m_LastWaitType`, and `SOS_Worker.m_state` are point-in-time fields that are often
> **stale or zeroed** in a minidump (e.g. a thread blocked on IO may show
> `m_State=ACTIVE_QUEUE` / `m_LastWaitType=0`). When determining what a thread/worker
> is *actually* doing, **walk its thread stack (`~<TID>s; kn`) — the stack is
> authoritative**, the task/worker state fields are only a hint.

## Method 2 — Latch Timeout Analysis (no mirrors)

DumpViewer's `LatchTimeout` algorithm. **Summary:**

1. Scan threads for `sqlmin!LatchBase::Suspend` frames → read frame locals (`this`
   = latch, `latchWait` → `pTask`/`acquired`/`releasor`, `waitType`). The
   `LatchBase::DumpOnTimeoutIfNeeded` frame's `timeoutInfo` local holds the timing.
2. Decode the latch `m_count` 64-bit bit-field (UP/EX/DT/SH/KP/SuperLatch + holder
   counts) and resolve the latch class.
3. Walk the circular `m_waiter` list; attribute each `pTask` to a thread via Method 1.
4. **Self-wait detection**: if the exclusive-owner thread is also in its own waiter
   list → parallel-query latch self-deadlock (root cause).
5. **Walk the EX owner's REAL stack** (`~<ownerTID> s; kn 40`) to find *why it won't
   release* — log IO (`CheckLogBlockReadComplete`/`CatchupPageRedos`), data IO,
   preemptive call, etc. The latch timeout is usually a **symptom**; the owner's
   blocker is the actual root cause. ⚠️ In minidumps, `SOS_Task.m_State`/
   `m_LastWaitType` are often stale — **trust the owner thread stack, not the task
   fields**.
6. **⭐ Check the owner worker's `m_state`** (`dx ((sqldk!Worker*)<pWorker>)->m_state`;
   `WORKER_STATE`: 1=RUNNING, 2=RUNNABLE, 3=SUSPENDED). A `LatchBase::Suspend` frame
   alone does NOT prove the owner is stuck — only **SUSPENDED** owners are truly
   waiting. **RUNNABLE** owners have already been signaled out of the wait and are
   just queued for CPU (the Suspend frame is their resume point). Many RUNNABLE
   owners ⇒ **CPU/scheduler pressure**, not latch self-deadlock or IO storm.

**→ See [reference/latch_timeout.md](reference/latch_timeout.md) for the complete
`m_count` mask table, waiter-list walk, self-wait detection, owner-stack root-cause
table, and output checklist — grounded in `LatchTimeout.cs` source.**

## Method 3 — Non-Yielding / Stalled-Thread Analysis (no mirrors)

DumpViewer's `NonYieldStallAnalysis` algorithm. **Summary:**

1. Scan threads for a scheduler-monitor callback frame (`SQL_SOSNonYield*Callback`,
   fallback `ExecuteNonYield*Callbacks`) → read frame local `pTrack`.
2. Validate `pTrack->m_pWorker->m_pSched` is one of the Method-1 schedulers.
3. Extract `m_pass`/`m_diagnosedPass`, wall/kernel/user time, preemptive flag.
4. Compare the SQLOS copied stack (`.cxr @@(&sqlmin!g_copiedStackInfo.threadContext)`)
   against the thread's current stack.

**→ See [reference/non_yielding.md](reference/non_yielding.md) for the complete
incident-type / callback-frame table, validation, diagnostics fields, copied-stack
capture, and interpretation — grounded in `NonYieldStallAnalysis.cs` source.**

## Method 4 — Thread Categorization by Stack Pattern

DumpViewer's `ThreadCategorize` buckets every thread by substring-matching its call
stack against known function names. Pure string matching — no symbols-as-data needed,
works on any dump. Reproduce by capturing all stacks (`~* kn`) and grepping:

| Category | Match any of (case-insensitive substring) |
|----------|-------------------------------------------|
| Busy (not waiting) | **absence** of any wait fn below |
| File I/O | `ReadFile`, `WriteFile`, `CreateFile`, `DeleteFile` |
| Latch | `!LatchBase` |
| Network I/O | `ws2_32!WSARecv`, `ws2_32!WSASend`, `ws2_32!recv`, `ws2_32!send`, `!AcceptEx`, `WaitOnWriteAsyncToFinish`, `!Tcp::` |
| Backup | `!BackupOperation`, `!BackupThread` |
| Memory clerk | `!MemoryClerkInternal` |
| Lock blocking | `!lck_lockInternal` |
| Spinlock | `!Spinlock` |
| Exception | `KiUserExceptionDispatch`, `utassert_fail`, `ex_raise2`, `ExceptionPassOn`, `RtlDispatchException`, `DumpOnCryptoException`, `RaiseException` |
| Parallel | `!SubprocEntrypoint` |
| Critical section | `RtlEnterCriticalSection` |
| LazyWriter | `LazyWriter` |
| IOCP | `ListenOnIOCompletionPort` |
| Monitor | `Monitor` |
| Checkpoint | `CheckpointThread`, `!checkpoint` |

**Wait/sleep functions** (a thread is "busy" if its stack contains NONE of these):
`ZwSignalAndWaitForSingleObject`, `ZwWaitForMultipleObjects`, `ZwDelayExecution`,
`ZwWaitForSingleObject`, `ZwRemoveIoCompletion`, `ZwWaitForWorkViaWorkerFactory`,
`ZwUserGetMessage`, `ZwAlpcSendWaitReceivePort`, `NtpThreadSuspensionRoutine`,
`RtlWaitOnAddress`, `WaitOnAddress`, `SleepConditionVariableSRW`.

> Triage value: **Exception** threads ⇒ likely crash origin; **Busy** threads ⇒
> CPU/non-yield suspects; collapsing identical stacks (`!uniqstack` or group by stack
> text) shows the dominant pattern fast.

## Method 5 — Resolve SQLOS Enums from the Dump (`dt`)

Latch/wait names are not strings in the struct — they are enum indices. DumpViewer
resolves them by parsing `dt` output of the enum types:

```text
dt sqlmin!PWAIT_enum            * wait type index → name  (worker m_LastWaitType, waiter waitType)
dt sqlmin!PWAIT_indexes         * alt form: __index<Name> = 0n<value>
dt sqlmin!LatchBase::LatchClass * latch class id → name
dt sqlmin!LatchBase::LATCH_TYPE * latch wait type id → name (timeoutInfo m_currentWaitType)
```
Build the `value → name` map once, then translate every numeric `waitType` /
`LatchClass` you pull from structs.

## When to Use Part 2 vs the Mirrors Path (Part 1)

| Situation | Use |
|-----------|-----|
| Mirrors load, supported build | Part 1 Mirrors (`!execute`/`!evaluate`) — richer, faster |
| `!dcs_initsymsvr` fails / no mirrors / SQL 2019 | Part 2 (native walking) |
| Latch timeout dump | Method 2 (works even when mirrors lack latch detail) |
| Non-yield / 17883 / 17884 dump | Method 3 + copied-stack `.cxr` |
| "What is every thread doing?" triage | Method 4 (`!uniqstack` + categorization) |
| Per-thread task / Worker-state / blocker-chain | **Part 3 DScript `task.js`** (fast, authoritative) |
| Pending IO enumeration / per-IO latency | **Part 3 DScript `all_ios.js`** — **full/filter dump only** |
| Private symbols won't load | Neither — fall back to `kn` + `!analyze -v` only |

---

# Part 3: DScript — SQL2016 JavaScript debug scripts (`!dscript.run`)

A third analysis surface, independent of Mirrors. The SQL product ships an
encrypted JavaScript debug library (`C:\Tools\SQL2016\*.js` — `task.js`,
`all_ios.js`, `callstack.js`, …) that runs **inside cdb/WinDbg** via the **DScript**
extension. DScript decrypts and runs the scripts at runtime against private symbols,
giving SOS-style, source-grounded per-thread / task / IO analysis even where Mirrors
don't load. Very effective as an **independent cross-check** of native walking
(Part 2) — e.g. confirming a latch owner's Worker state and blocker chain.

## Prepare (one-time COM registration — then no UAC)

DScript needs a one-time COM self-registration (admin). Once done it persists in
**HKLM machine-wide** and **every later run is non-elevated (no UAC)**.

1. **Check if already registered** (no admin):
   ```powershell
   $n = (Get-ChildItem 'HKLM:\SOFTWARE\Classes\CLSID' -EA SilentlyContinue |
         Where-Object { (Get-ItemProperty $_.PSPath -EA SilentlyContinue).'(default)' -match 'DSCRIPT' }).Count
   "DScript CLSIDs: $n"   # 4 == ready, run non-elevated
   ```
2. **Locate the DLL** (ships with the WinDbg Store build):
   ```powershell
   $dscript = Get-ChildItem 'C:\Program Files\WindowsApps' -Recurse -Filter 'DScript.dll' -EA SilentlyContinue |
              Where-Object FullName -match '\\amd64\\pri\\' | Select-Object -First 1 -Expand FullName
   ```
3. **If count < 4 → register once, ELEVATED.** DScript self-registers when first
   `.load`ed inside an **elevated** cdb. Run a throwaway elevated cdb that loads the
   DLL and runs any `!dscript.run` (UAC appears **once**); afterward the 4 CLSIDs are
   in HKLM permanently and all later runs are non-elevated.

## Running a script

```text
.sympath srv*C:\Symbols*https://symweb.azurefd.net
.reload /f
~<TID> s                                  * task.js targets the CURRENT thread — switch first
!dscript.run C:\Tools\SQL2016\task.js
```
> `!dscript.run` **auto-loads DScript** (prints `--- Loading DScript`). An explicit
> `.load "<path with spaces>"` line may fail (cdb mangles quoted spaces) — harmless,
> auto-load covers it.

## Key scripts

| Script | What it gives | Dump requirement |
|--------|---------------|------------------|
| `task.js` | Per-thread `SOS_Task`: **SPID**, scheduler, **Worker state** (SUSPENDED/RUNNABLE/RUNNING), wait type + group, elapsed/CPU time, task function, **BLOCKERS** chain | minidump OK |
| `all_ios.js` | Enumerates pending IOs + per-IO latency | **FULL/filter dump only** |
| `callstack.js` | Annotated SQL call stack | minidump OK |

### `task.js` — decisive fields for latch/stall analysis

- **`Worker state`**: `WORKER_STATE_SUSPENDED` = truly stuck; `RUNNING`/`RUNNABLE` =
  not stuck (RUNNABLE = signaled out of wait, queued for CPU). This is the same
  RUNNABLE-vs-SUSPENDED distinction as Method 2 step 6, but from the official script.
- **`Wait type description`** + **`BLOCKERS`**: `No blockers were found` together
  with `PWAIT_IO_COMPLETION` ⇒ stuck on async IO, **root cause in the IO subsystem**
  (not a SQL-layer self-deadlock). `task.js` walks the SQL blocker chain for you.
- Run it on **each owner thread** identified in Method 2/Step 0 to confirm
  SUSPENDED-vs-RUNNABLE across all latch owners in one pass.

### `all_ios.js` — REQUIRES A FULL/FILTER DUMP

On a **minidump** it fails:
`ERROR 0x8007001E - Cannot read from virtual address` (pending-IO global structures
are not captured; the dump header says *"Only registers, stack and portions of
memory are available"*). To enumerate pending IOs / per-IO latency you need a
`.dump /ma` full dump or a filter dump. **Minidump-safe alternative** for the
one-slow-IO-vs-many-IO question: read the owner worker's IO counters
(`m_NumberOfIOs` vs `m_NumberOfContextSwitches`) — see latch_timeout reference Step 5.

