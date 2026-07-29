# Non-Yielding / Stalled-Thread Analysis — Reference

Source-code-grounded methodology for analyzing **non-yielding scheduler / IOCP /
resource-monitor / stuck-dispatcher** dumps without SqlCsScripts/Mirrors. Extracted
from DumpViewer `SqlTelemetry/Src/Tools/DumpViewer/SQLInsight/NonYieldStallAnalysis.cs`
(namespace `CsDebugScript.DumpViewer`). All steps expressed as cdb.exe commands.

> Prerequisite: scheduler list from Method 1 (SKILL.md Part 2) — used to validate the
> recovered `pTrack`.
>
> Symbol path: use `_NT_SYMBOL_PATH` (this machine: `srv*C:\Symbols*https://symweb.azurefd.net`).
> Do NOT hardcode `msdl.microsoft.com` — symweb (internal) has the SQL private PDBs.

## Canonical Gate C entry point

For a Gate B `Scheduler / non-yield` route, read the technical methodology below, then execute
[run_non_yield_route.ps1](../scripts/run_non_yield_route.ps1). It implements the `pTrack`,
current-stack, and first-detected copied-stack method without hardcoded case-specific thread or
frame IDs and emits `<case>_non_yield_findings.json`.

Workflow ownership intentionally lives elsewhere to avoid duplicated contracts:

- Gate C sequencing, optional Spinlock sweep, fail-open behavior, report publication, and
  deferred copied-stack research: [SKILL.md](../SKILL.md).
- Executable behavior: [run_non_yield_route.ps1](../scripts/run_non_yield_route.ps1),
  [run_spinlock_owner_sweep.ps1](../scripts/run_spinlock_owner_sweep.ps1), and the finalization
  scripts. The scripts, not this reference, are authoritative for exact commands and artifacts.

---

## Incident types (`NonYieldIncidentType`)

| Incident | Primary callback frame | Fallback frame |
|----------|------------------------|----------------|
| Non-yielding IOCP | `SQL_SOSNonYieldIOCPCallback` | `ExecuteNonYieldIOCPCallbacks` |
| Non-yielding scheduler | `SQL_SOSNonYieldSchedulerCallback` | `ExecuteNonYieldSchedulerCallbacks` |
| Non-yielding resource monitor | `SQL_SOSNonYieldRMCallback` | `ExecuteNonYieldRMCallbacks` |
| Stalled dispatcher | `SQL_SOSStuckDispatcherCallback` | `ExecuteStuckDispatcherCallbacks` |

Driver: `NonYieldStallAnalysis` ctor →
`GetValidPtrack()` (primary, then fallback callbacks) →
`TrackDataExtraction()` → `GetCopiedStack()`.

---

## Step 1 — Find the SchedulerMonitor::Track pointer

`ScanThreadsForTrackData()` scans every thread; when a frame's function **contains**
one of the callback names above, it reads that frame's local **`pTrack`** (a
`SchedulerMonitor::Track*`). The scheduler-monitor thread's full stack is captured as
`SchedulerMonitorStack`.

cdb:
```text
* per thread: list frames, find the callback frame index N
dx -r1 @$curthread.Stack.Frames
dx Debugger.Sessions[0].Processes[<PID>].Threads[<TID>].Stack.Frames[<N>].SwitchTo()
dv /t /v          * read local pTrack
```

If no primary callback matches, retry with the **fallback** `ExecuteNonYield*` frames.

---

## Step 2 — Validate the pTrack

`ValidatePTrack()` rejects garbage pointers. A `pTrack` is valid only if:
1. `pTrack` not null,
2. `pTrack->m_pWorker` not null,
3. `pTrack->m_pWorker->m_pSched` not null,
4. that scheduler is **one of the schedulers found in Method 1** (match by pointer).

```text
dt sqlmin!SchedulerMonitor::Track <pTrack> m_pWorker
dt sqldk!SOS_Worker <m_pWorker> m_pSched
* confirm m_pSched is in the Method-1 scheduler set
```

---

## Step 3 — Extract diagnostics

`TrackDataExtraction()` pulls the incident metrics:

```text
dt sqlmin!SchedulerMonitor::Track <pTrack> m_pWorker m_pass m_diagnosedPass m_sysDiff m_workerDiff
* timings are microseconds in the dump → divide by 1000 for ms
dt <m_sysDiff_addr>    m_WallClockTime
dt <m_workerDiff_addr> m_KernelTime m_UserTime
* worker → task, sys thread, preemptive flag
dt sqldk!SOS_Worker <m_pWorker> m_status m_pTask m_pSysThread
dt sqldk!SystemThread <m_pSysThread> m_Id      * OS thread id → map via Method 1
```

| Field | Meaning |
|-------|---------|
| `m_pass` | # of scheduler-monitor passes that observed the condition |
| `m_diagnosedPass` | # of passes where diagnostics were captured |
| `m_sysDiff.m_WallClockTime` | elapsed wall-clock since first detection (µs → ms) |
| `m_workerDiff.m_KernelTime` | worker kernel CPU time (µs → ms) |
| `m_workerDiff.m_UserTime` | worker user CPU time (µs → ms) |
| `m_status & 0x4` | `WORKER_STATUS_PREEMPTIVE` → stuck in an external/preemptive call |
| `m_status & 0x1` | `WORKER_STATUS_NONPREEMPTIVE` |

---

## Step 4 — Capture the "first-detected" copied stack

When the scheduler monitor first flags a non-yield, SQLOS snapshots the offending
thread's context into a global. `GetCopiedStack()` walks it via `.cxr`:

```text
.cxr @@(&sqlmin!g_copiedStackInfo.threadContext)
kn
.cxr
```

Compare this **copied stack** (state when the monitor first flagged the stall)
against the thread's **current** stack (`~<TID>s; kn`) to see whether it has moved.
Same stack across passes ⇒ truly stuck at that spot; different ⇒ slow progress.

---

## Interpretation

| Signal | Interpretation |
|--------|----------------|
| High `WallTime`, low `Kernel+User` | blocked / sleeping (waiting on something off-CPU) |
| High `Kernel+User` ≈ `WallTime` | spinning / runaway CPU (real non-yield) |
| `IsPreemptive == true` | stuck inside an external/preemptive call (e.g. OS API, XP, CLR) |
| Copied stack == current stack across passes | genuinely wedged at that frame |
| Many `m_pass` | long-running stall (monitor saw it repeatedly) |

## When this applies

- ERRORLOG **17883** (non-yielding scheduler), **17884** (non-yielding IOCP),
  **17887** (IO completion), **17888** (non-yielding resource monitor), or a stuck
  dispatcher.
- Dump auto-generated by the scheduler monitor on non-yield.
- Mirrors missing / unsupported build / SQL 2019.
