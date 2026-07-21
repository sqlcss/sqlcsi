# Latch Timeout Analysis — Reference

Source-code-grounded methodology for analyzing **latch timeout** dumps without
SqlCsScripts/Mirrors. Extracted from DumpViewer
`SqlTelemetry/Src/Tools/DumpViewer/SQLInsight/LatchTimeout.cs`
(namespace `CsDebugScript.DumpViewer`). All steps expressed as cdb.exe commands.

> Prerequisite: scheduler/worker/task mapping from Method 1 (SKILL.md Part 2) and
> SQLOS enum resolution from Method 5. Latch class / wait-type values are enum
> indices that must be resolved to names.
>
> Symbol path: use `_NT_SYMBOL_PATH` (this machine: `srv*C:\Symbols*https://symweb.azurefd.net`).
> Do NOT hardcode `msdl.microsoft.com` — symweb (internal) has the SQL private PDBs.

> **DumpViewer latch pages are side evidence only.** Do not use
> `LatchTimeoutInsight.html`, `LatchListAndTree.html`, or `LatchWaiters.html` as the
> source of truth for this deep-dive unless they contain a complete latch tree. If
> DumpViewer does not generate a usable latch tree, the report must say so and use
> the native flow below: DX enumerate `LatchBase::Suspend`, `dt sqlmin!LatchBase`
> for `m_count` / owner, owner worker `m_state`, owner real stack, plus the
> dump-overall `sys.schedulers.js` and `dump_latch_contended_pages.js` outputs.
> A final latch report that only repeats DumpViewer latch text has not completed
> this reference workflow.

## Required Step-4 Output Contract

When this reference is invoked by the latch-timeout workflow, return a structured
`latch_native_summary` with these fields. The final latch report verifier treats
this as mandatory dump evidence when a `.mdmp` exists:

| Field | Required content |
|-------|------------------|
| `owner_waiter_map` | latch address/class, waiter threads/tasks, EX owner task/thread, owner blocked-on target |
| `m_count_decode` | raw `m_count`, mode bits, waiter bit, EX/UP/DT flags, SH/KP counts where readable |
| `owner_real_stack` | stack from the owner thread, not just the timeout reporter, with subsystem interpretation |
| `classification` | self-blocking, cross-session/chain, CPU-starved RUNNABLE owner, IO/log root, or inconclusive |
| `minidump_limitations` | unreadable memory, missing globals, stale task fields, partial stacks, or why a full dump is needed |
| `raw_evidence_paths` | cdb / DX / DT / DScript / DumpViewer paths that support each claim |

Do not let Step 4 pass if `owner_waiter_map`, `m_count_decode`, `owner_real_stack`,
`classification`, or `minidump_limitations` is only implied. Each item must appear
as an explicit row or subsection in the returned summary and in the final report's
evidence mapping.

---

## Source Objects (DumpViewer classes)

| DumpViewer class | Role |
|------------------|------|
| `Latch` | Decoded latch: class, owner, mode flags, holder counts, waiter count |
| `LatchWaiter` | One thread/task waiting on a latch: `ThreadId`, `Task`, `WaitType`, `Acquired`, `Releasor`, `CallStack` |
| `LatchTimeoutInfo` | The timed-out wait: current/owner wait type, wait time, owner task/thread |
| `WaitingTreeItem` | Node in the latch→waiter tree (for output) |

Driver: `LatchTimeout.Analyze()` →
`PickupLatchFromThreadLocal()` → `ScanWaiterList()` → `UpdateWaiterCount()` →
`GenerateWaitingTree()`.

---

## Step 0 — OVERALL first: enumerate ALL latch waiters (do NOT analyze only the dump thread) ⭐

The thread that wrote the dump (`LatchBase::DumpOnTimeoutIfNeeded`) is just ONE
waiter on ONE latch. A real incident usually has **many threads waiting on several
different latches**, each with its own EX owner. Always build the global picture
first — otherwise you misdiagnose a server-wide IO storm as a single-query problem.

**One DX command enumerates every waiting thread and the latch it waits on** (reads
the implicit `this` local of each `LatchBase::Suspend` frame — works without
`SwitchTo`, survives minidumps):
```text
dx -g Debugger.Sessions[0].Processes.First().Threads.Where(t => t.Stack.Frames.Any(f => f.ToDisplayString().Contains("LatchBase::Suspend"))).Select(t => new { TID = t.Id, Latch = t.Stack.Frames.Where(f => f.ToDisplayString().Contains("LatchBase::Suspend")).First().LocalVariables.this })
```
> Ignore interleaved `Managed frame processing failed, HRESULT 0x80131C49` noise —
> the table rows are still emitted. `LocalVariables.this` binds reliably (it's the
> implicit param); other locals like `pWorker` may NOT bind if the build's frame
> function/parameter names differ.

Then **group by latch** (agent side) to get the contention distribution, e.g.:
```
0x3e0de3c9178  x39   0x4f13215c9d8  x32   0x6654d3c3178  x16
0x60d090e0578  x11   0x29a2db1df48  x1    0x29a301bf508  x1
```
For **each distinct latch**, read its class + count + owner:
```text
dt sqlmin!LatchBase <latch_addr> m_count m_pExclusiveOwner m_waiter m_classAndSuperLatchBits
```
Build an overall table: `latch | waiter count | class | m_count(mode) | EX owner task`.

**Resolve each EX owner task → owner thread (TID), then check what the OWNER waits on.**
The owner task's worker is type **`Worker`** (NOT `SOS_Worker`); `m_pSysThread` →
`m_Id` is the OS thread id:
```text
* owner task -> worker pointer (SOS_Task m_pWorker is at +0x98 on SQL2016)
dt sqlmin!SOS_Task <owner_task & ~1> m_pWorker
* worker -> OS thread id (CORRECT type is Worker, m_pSysThread @ +0x208)
dx ((sqldk!Worker*)<m_pWorker>)->m_pSysThread->m_Id
```
Then for that owner TID, find the latch IT is waiting on (its own `Suspend` frame):
```text
~~[<ownerTID>] s
dx @$curthread.Stack.Frames.Where(f => f.ToDisplayString().Contains("LatchBase::Suspend")).First().LocalVariables.this
```

### ⭐ CRITICAL — check the owner worker's SCHEDULER STATE (`m_state`), not just its stack

**A stack showing `LatchBase::Suspend` does NOT prove the owner is still waiting.** The
stack may be the owner's **resume point** — it could already have been signaled out of
the wait and merely be queued for CPU. The authoritative signal is the worker's
`m_state` (`Worker.m_state`, type `WORKER_STATE`):

```text
dx ((sqldk!Worker*)<m_pWorker>)->m_state
* WORKER_STATE enum: 0 INIT | 1 RUNNING | 2 RUNNABLE | 3 SUSPENDED | 4 LAST
```

| Owner `m_state` | Meaning | Verdict |
|-----------------|---------|---------|
| **SUSPENDED (3)** | genuinely parked in the wait — the latch is truly held & stuck | 🔴 real blocker — drill its Step-5 stack (IO / preemptive) |
| **RUNNABLE (2)** | already **signaled out of the wait**, just queued for a CPU quantum; the `Suspend` frame is its **resume point**, NOT a live wait | ⚡ NOT a deadlock — this owner is making progress; latch will release as soon as it gets CPU |
| **RUNNING (1)** | currently executing on a scheduler | actively progressing |

**Implication for root cause:**
- Many owners **RUNNABLE** ⇒ the incident is **CPU / scheduler-quantum pressure**
  (workers can't get CPU to release their latches), **NOT** latch self-deadlock and
  **NOT** an IO storm. Lots of RUNNABLE workers across schedulers = CPU saturation.
- Only owners that are **SUSPENDED** are truly stuck — those are the real blockers;
  follow each one's Step-5 stack to find IO / preemptive / etc.
- A real incident is often: a few **SUSPENDED** owners (real IO/blocking roots) +
  many **RUNNABLE** owners (CPU-starved, not stuck). Report it that way.

> ⚠️ This supersedes a naive "the owner's Suspend frame is on the same latch ⇒
> self-wait deadlock" reading. Confirm with `m_state` first — a RUNNABLE owner whose
> resume point is its own latch is **not** self-deadlocked; it's CPU-starved.

**Classify every owner** (only meaningful for **SUSPENDED** owners):

| SUSPENDED owner is waiting on… | Meaning |
|----------------------|---------|
| **its own latch** (same addr it holds EX) | 🔴 **self-wait** — parallel-query latch self-deadlock (owner holds EX, then re-acquires the SAME latch in a child sub-scan, e.g. `IndexDataSetSession::SetupNextChildSubScan` / `HeapDataSetSession::GetNextRangeForChildScan`). Confirm m_state=SUSPENDED before claiming this. |
| **a different latch** | latch dependency chain — follow to the next owner |
| **not a latch** (Step 5: log/data IO, preemptive) | the chain ROOT — real blocker (IO etc.) |

Interpretation hints:
- **Always read `m_state` for every owner first** — RUNNABLE owners are CPU-starved,
  not deadlocked; do not count them as stuck.
- Multiple SUSPENDED `LATCH_DATASET_PARENT` owners each self-waiting ⇒ genuine
  parallel-query latch self-deadlocks.
- An owner stalled on IO (Step 5, SUSPENDED) is a chain root — that branch is IO-driven.
- Many RUNNABLE owners ⇒ CPU / scheduler pressure (check `Schedulers` runnable counts).
- Real incidents often **mix**: e.g. one SUSPENDED `DATASET_PARENT` blocked on log IO
  + several RUNNABLE owners just waiting for CPU.

> Owner releasor bit: `m_pExclusiveOwner & 0x1` = releasor flag; mask it off to get
> the real owner task (`...c29` → `...c28`).

Only after the overall map, drill into the specific latch(es) below.

### Step 0 — complete end-to-end recipe (overall view → owners → worker state)

The whole overall pass as a reusable sequence. Run **(A)** first, parse the table,
then template **(B)/(C)** per distinct latch / per owner.

**(A) Enumerate every latch waiter → (TID, latch) table** (one DX command):
```text
dx -g Debugger.Sessions[0].Processes.First().Threads.Where(t => t.Stack.Frames.Any(f => f.ToDisplayString().Contains("LatchBase::Suspend"))).Select(t => new { TID = t.Id, Latch = t.Stack.Frames.Where(f => f.ToDisplayString().Contains("LatchBase::Suspend")).First().LocalVariables.this })
```
Group by `Latch` (agent side) → distinct latches + waiter counts.

**(B) Per distinct latch — class + count + EX owner task:**
```text
dt sqlmin!LatchBase <latch_addr> m_count m_pExclusiveOwner m_waiter m_classAndSuperLatchBits
* resolve class id (m_classAndSuperLatchBits & 0x3fffffff) via:  dt sqlmin!LatchBase::LatchClass
```

**(C) Per EX owner task — TID + worker scheduler state + (if SUSPENDED) what it waits on:**
```text
* owner task -> worker (mask releasor bit; SOS_Task.m_pWorker @ +0x98)
dt sqlmin!SOS_Task <owner_task & ~1> m_pWorker
* worker -> OS thread id   (type is Worker, m_pSysThread @ +0x208)
dx ((sqldk!Worker*)<m_pWorker>)->m_pSysThread->m_Id
* ⭐ worker scheduler state — decides RUNNABLE(CPU-starved) vs SUSPENDED(stuck)
dx ((sqldk!Worker*)<m_pWorker>)->m_state
* if SUSPENDED: which latch is the owner itself waiting on?
~~[<ownerTID>] s
dx @$curthread.Stack.Frames.Where(f => f.ToDisplayString().Contains("LatchBase::Suspend")).First().LocalVariables.this
* if SUSPENDED and NOT on a latch: walk the real blocker stack (Step 5)
~~[<ownerTID>] s
kn 40
```

**Final overall table** to produce: `latch | class | #waiters | EX owner task | owner TID | owner m_state | owner blocked on`.

**Worked example (real case 2604300030000700, SQL 2016, 100 waiters / 6 latches):**

| Latch | Class | #wait | Owner TID | `m_state` | Owner blocked on |
|-------|-------|-------|-----------|-----------|------------------|
| `0x3e0de3c9178` | DATASET_PARENT | 39 | 449 | **SUSPENDED** | log-block read IO (`CheckLogBlockReadComplete`←`CatchupPageRedos`) → real root |
| `0x4f13215c9d8` | DATASET_PARENT | 32 | 0x4cfc | **RUNNABLE** | nothing — signaled out, CPU-starved |
| `0x6654d3c3178` | DATASET_PARENT | 16 | 0xc71c | **RUNNABLE** | nothing — CPU-starved |
| `0x60d090e0578` | DATASET_PARENT | 11 | 0x56bc | **RUNNABLE** | nothing — CPU-starved |
| `0x29a301bf508` | LATCH_BUF | 1 | 0xe3f4 | **SUSPENDED** | BUF latch |

Verdict for that case: **CPU/scheduler-quantum pressure** (3 RUNNABLE owners can't get
CPU to release their latches) **+ one genuine log-IO blocker** (the SUSPENDED owner) —
NOT 4 self-wait deadlocks. Only the m_state check distinguishes them; the stacks alone
all show `LatchBase::Suspend` and would mislead.

---

## Step 1 — Find latch waiters from thread stacks

`PickupLatchFromThreadLocal()` scans every thread; for any frame whose function
contains **`sqlmin!LatchBase::Suspend`**, the frame locals carry the live objects
(this works on minidumps because the pointers live on the stack, not in paged-out
global tables):

| Frame local | Meaning |
|-------------|---------|
| `this` | the `LatchBase*` being waited on |
| `latchWait` | the wait record → fields `pTask`, `acquired`, `releasor` |
| `waitType` | wait type index (resolve via `PWAIT_enum`, Method 5) |

If a **`sqlmin!LatchBase::DumpOnTimeoutIfNeeded`** frame is also present on the same
thread (the timeout reporter), its local **`timeoutInfo`** holds the timing:
`m_currentWaitTime`, `m_currentWaitType`, `m_ownerWaitType`, `m_ownerWaitString`.

cdb:
```text
* per thread: list frames, find the LatchBase::Suspend frame index N
dx -r1 @$curthread.Stack.Frames
dx Debugger.Sessions[0].Processes[<PID>].Threads[<TID>].Stack.Frames[<N>].SwitchTo()
dv /t /v
* read the timeout reporter frame's local (if DumpOnTimeoutIfNeeded present)
dt sqlmin!LatchBase::TimeoutInfo <timeoutInfo_addr> m_currentWaitTime m_currentWaitType m_ownerWaitType m_ownerWaitString
```

---

## Step 2 — Decode the latch `m_count` bit-field (64-bit)

`ParseLatchMCount()` decodes the heart of the latch. Read the struct:
```text
dt sqlmin!LatchBase <latch_addr> m_count m_pExclusiveOwner m_waiter
```

`m_count` bit-field layout (from `latchp.h`, **64-bit only**):
`cKP | cSH | Unused | SuperLatch | Poisoned | SpinLock | Waiters | DT | EX | UP`

| Flag | Mask / formula | Meaning |
|------|----------------|---------|
| UP | `m_count & 0x0000000000000001` | held in Update mode |
| EX | `m_count & 0x0000000000000002` | held in Exclusive mode |
| DT | `m_count & 0x0000000000000004` | held in Destroy mode |
| HasWaiters | `m_count & 0x0000000000000008` | waiter list non-empty |
| SpinLock | `m_count & 0x0000000000000010` | latch spinlock held |
| Poisoned | `m_count & 0x0000000000000020` | a waiter timed out / aborted since last release |
| SuperLatch | `m_count & 0x0000000000000040` | superlatch (all other bits meaningless) |
| Promoting | `m_count & 0x0000000000000080` | promoting to superlatch |
| SpinUnfair | `m_count & 0x0000000000000100` | unfair spin bit |
| SH count | `(m_count & 0x0000000FFFFFF000) / 0x1000` | # of shared (SH) holders |
| KP count | `(m_count & 0xFFFFFFF000000000) / 0x1000000000` | # of keep (KP) holders |

**Latch class** — from the class word `ClassAndSuperLatchBits`:

| Super-latch bit | Mask | Meaning |
|-----------------|------|---------|
| Demoting | `& 0x80000000` | superlatch demoting |
| SubLatch | `& 0x40000000` | this is a sublatch of a superlatch |
| SharedPLocked | `& 0x20000000` | shared partition lock |
| ExclusivePLocked | `& 0x10000000` | exclusive partition lock |

Class id = `ClassAndSuperLatchBits & 0x3fffffff` (or `& 0x0fffffff` when
SharedPLocked/ExclusivePLocked is set). Resolve the id to a name via
`dt sqlmin!LatchBase::LatchClass` (Method 5).

---

## Step 3 — Walk the waiter linked list

`ScanWaiterList()` walks the circular waiter list off the latch's `m_waiter`:
```text
dt sqlmin!LatchBase <latch_addr> m_waiter
* each node:
dt sqlmin!LatchWaitInfo <m_waiter> pTask acquired releasor waitType link
* follow `link` until it returns to the head pointer (circular list terminator)
```

Per node:
- `pTask` → map to a debugger thread via Method 1 (`task → m_pWorker →
  m_pSysThread → m_Id`, then match against `~` thread system ids).
- `acquired` (bool) → this waiter already holds the latch (acquired bit set).
- `releasor` (uint) → who may release.
- `waitType` → resolve via `PWAIT_enum` (Method 5).

**Owner releasor bit**: `m_pExclusiveOwner & 0x1` → `1` = ANY_TASK, `0` = SAME_TASK.
The exclusive owner task is `m_pExclusiveOwner` with the low bit masked off.

---

## Step 4 — Self-wait (parallel-query latch deadlock) detection

`GenerateWaitingTree()` builds latch → waiting-threads tree with the owner as parent.
**Critical pattern**: if the latch's **exclusive-owner thread also appears in its own
waiter list**, that thread is blocking itself — the classic parallel-query
self-deadlock on a latch. Flag it explicitly (DumpViewer marks the node `(self)` and
re-parents the latch under the self-waiting thread to break the loop).

Detection:
1. Resolve owner thread id = `GetThreadIdByTask(m_pExclusiveOwner & ~1)`.
2. Check whether any `LatchWaiter` on the **same** latch has `ThreadId == ownerThreadId`.
3. If yes → self-wait. Report it as the root cause.

---

## Step 5 — Walk the EX owner's REAL stack (find why it won't release) ⭐

This is the single most important step for actionable root cause, and it is **not**
in DumpViewer's insight page (which only reports the owner's `waitType`). Knowing
*who* holds the latch is not enough — you must find *why the owner won't release it*.

1. Resolve the owner thread id from the task (Method 1):
   `task → m_pWorker → m_pSysThread → m_Id` → match to a debugger thread (`~`).
2. **Switch to that thread and print its full stack** — this reveals the true blocker:
```text
~<ownerTID> s
kn 40
```
3. Read the top SQL frames. The owner is almost always blocked on something the
   latch waiters can't see. Common real causes found this way:

| Owner stack contains | Real root cause (the latch is a symptom) |
|----------------------|------------------------------------------|
| `CheckLogBlockReadComplete` / `LogConsumer::Close` / `CatchupPageRedos` | **transaction-log read IO latency** (owner front-rolling a page) |
| `WriteFile` / `ReadFile` / `FCB::` / `GetIoCompletion` | **data-file IO latency** |
| `PreemptiveOS*` / external call | stuck in an OS/external preemptive call |
| `Spinlock` / busy CPU frames | CPU/spinlock contention upstream |
| same parallel-scan path (`GetNextRangeForChildScan`, `FnProducerThread`) as the waiters | **same parallel query** self-contending; the EX holder simply hit a slow page first |

> ⚠️ **Minidump caveat — DO NOT trust the task fields for owner state.** In a
> minidump, `SOS_Task.m_LastWaitType` and `m_State` (e.g. `ACTIVE_QUEUE`,
> `m_LastWaitType=0`) are frequently **stale or zeroed snapshots** and will mislead
> you into thinking the owner "is running / not waiting". The **owner's actual thread
> stack is authoritative** — always walk it (Step 5) before concluding contention vs
> IO vs deadlock. (Real case: task showed `ACTIVE_QUEUE` but the thread stack showed
> it parked in `CheckLogBlockReadComplete` waiting on log IO.)

### Step 5a — one slow IO vs many small IOs (owner worker IO counters, minidump-safe)

When the owner is stuck on IO, the owner **worker** counters help characterize its
IO behavior (readable in a minidump):
```text
dt sqldk!Worker <pWorker> m_NumberOfIOs m_NumberOfContextSwitches m_NumberOfTasksProcessed
```
> ⚠️ **`m_NumberOfIOs` is a WORKER-LIFETIME cumulative counter** (incremented in
> `SOS_Scheduler::AddIOCompletionRequest` for **every** async IO — data/PFS page
> reads AND log-block reads — across all tasks the worker ran; task only reports a
> delta). A large value (e.g. 17094) is mostly the scan's own **data/page reads over
> the worker's whole life**, NOT proof that "the current wait is N serial IOs". The
> **current** stall at the `PWAIT_IO_COMPLETION` suspend point is typically **one
> outstanding IO** (the block being drained). Do not equate the lifetime counter with
> the current latch-hold duration.
- `m_NumberOfIOs` ≈ `m_NumberOfContextSwitches` (1:1) ⇒ the worker yields once per
  async IO (normal for an IO-heavy scan) — a behavior signal, not a root cause.
- Precise per-IO latency / which single IO is stuck needs `all_ios.js` on a
  **full/filter dump** (fails on minidump with `0x8007001E`). (SKILL.md Part 3.)

### Step 5b — `CatchupPageRedos` / `CheckLogBlockReadComplete` (AG secondary log-read) ⭐

A frequent latch-owner stall on an **AG secondary**: a scan fixes a page
(`PFSPageRef::Fix` → `PageRef::Fix` → `PageRef::CatchupPageRedos`) that has
**pending redo in the DPT**, so the engine must roll the page forward by reading the
transaction log before the page can be read. Precise mechanism (source-verified,
SQL2016):
- **Where the latch is acquired (do NOT skip this):** for the DATASET_PARENT case,
  the EX latch is taken at the **top of `HeapDataSetSession::GetNextRangeForChildScan`**
  (`CAutoLatch latch(&m_parentLatch); latch.GetAccess()` — default **EX/INFINITE**;
  `m_parentLatch` = `LATCH_DATASET_PARENT` = `ACCESS_METHODS_DATASET_PARENT`). It
  serializes the **shared scan-range cursor** among all parallel child producers. The
  refill work (`GetNextRange → SetupNextCachedRange → GetNextPageId → AllocScan →
  PFSPageRef::Fix → CatchupPageRedos → log read`) runs **entirely while the latch is
  held**; `CAutoLatch` releases only when the function returns. So the latch is held
  for the WHOLE page-fix + redo-catchup + log-read duration → siblings needing the
  same parent latch all time out. **The acquire frame is several frames ABOVE the fix
  — always trace up the owner stack to find where the latch was taken, not just where
  it's blocked.**
- **IAM vs PFS:** allocation-order scans are two-tiered — IAM (already SH-latched)
  enumerates the object's extents; the **PFS** is fixed per-extent to check per-page
  allocation/type (`ProcessExtent` → `TestAllocState`/`GetPageProperty`). A PFS fix is
  a normal buffer-page fix that can trigger redo catch-up on a secondary.
- `CatchupPageRedos`'s **inner `while (NullLSN != lsn)` redo loop** declares a
  **loop-local `LogIterForward logScan`**. The dump frame `CatchupPageRedos+0x8xx`
  (pageref.cpp ~10021) is the **loop's closing brace** → the local **destructs each
  iteration**. Even though the code calls `logScan.EndScan()`, the **destructor
  re-enters `Close()`** and drains any read still in flight → the stack parks in
  `~SQLServerLogIterForward → SQLServerLogIter::Close → LogConsumer::Close →
  CheckLogBlockReadComplete → EventInternal::Wait(INFINITE)` tagged
  `PWAIT_IO_COMPLETION`. **So the wait is in the iterator destructor, NOT an active
  `StartScan`/`GetNext` read.**
- The drained read is the **log block actually required** for this redo
  (`is_read_ahead=false`), **not a prefetch** — `CatchupPageRedos` inits the iterator
  with `readAheadCnt=0` (`m_readAheadTarget=0`), disabling read-ahead.
- Interpretation: this is **log-read IO latency on the secondary**, surfaced through a
  data/allocation page fix held under the scan-coordination latch. It is NOT the scan
  reading data pages, and the ~300s is **one stuck log read** under the held latch
  (not N serial reads — see Step 5a counter caveat).
- Cross-check with **`task.js`** (SKILL.md Part 3): owner shows
  `WORKER_STATE_SUSPENDED` + `PWAIT_IO_COMPLETION` + `No blockers were found` ⇒
  confirms IO-subsystem root cause, not SQL self-deadlock.

> Aside: this path also carries the parallel-redo latch-deadlock mitigation
> (`WaitTranRedoOrder(dependentLsn, 180000)` → `ABORT_RECOVERYMGR_CATCHUP_REDO` after
> 3 min). If the owner is parked at `PWAIT_IO_COMPLETION` (log read) rather than
> `WaitTranRedoOrder`, the root cause is storage/log-read IO latency, not redo-order
> dependency.

---

## Output / Insight checklist

Build the timeout insight from (mirrors DumpViewer `GetLatchTimeoutInsight()`):

- Latch address + **latch class** (or "superLatch" if `SuperLatch`/`SubLatch`).
- **Timeout thread id**, current wait type + desc, current wait time (ms).
- Latch wait type of the timeout waiter.
- Whether **timeout thread == owner thread** (self-wait → strong signal).
- **Waiter count** on the same latch.
- Holders by mode: SH count, KP count, and DT / EX / UP flags.
- If exclusive owner exists: owner thread id, owner task, owner wait type + desc,
  releasor (ANY_TASK / SAME_TASK).
- **Owner's real blocker** (Step 5): the top SQL frames of the owner thread's stack,
  and the classification (log IO / data IO / preemptive / self-contention). This is
  what makes the finding actionable — state it as the root cause, with the latch
  timeout as the symptom.
- If no exclusive owner but a waiter has `acquired` set: report that acquired thread
  and its call stack instead.

## When this applies

- ERRORLOG **Error 846 / 847** (latch timeout), or a dump auto-generated on latch
  timeout (`LatchBase::DumpOnTimeoutIfNeeded`).
- Mirrors missing or lacking latch detail, or unsupported build.
- Suspected parallel-query self-blocking on `ACCESS_METHODS_*` / page latches.
- Many waiters on `LATCH_DATASET_PARENT` / `ACCESS_METHODS_DATASET_PARENT` during a
  parallel heap/table scan — almost always the EX owner is stalled on **IO** (Step 5),
  not pure latch design contention.
