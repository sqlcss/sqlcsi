# Dump Analysis — DScript / SQL2016 JS scripts

## DScript extension (`!dscript.run`)
- DLL: `C:\Program Files\WindowsApps\Microsoft.WinDbg.Slow_*\amd64\pri\DScript.dll`
- Encrypted JS library: `C:\Tools\SQL2016\*.js` (task.js, all_ios.js, callstack.js, ...). Decrypted by DScript at runtime — cannot read as text.
- **COM registration is now permanent in HKLM** (4 CLSIDs: Object Model Root / Tabular Output / Scripting Host / Arguments Collection, all → dscript.dll). Done once via an elevated cdb run; now **non-elevated cdb runs `!dscript.run` fine — NO MORE UAC needed**.
- `!dscript.run` auto-loads DScript (prints `--- Loading DScript`). The explicit `.load "<path with spaces>"` line fails (cdb eats quotes/spaces) but is harmless.
- task.js takes **current thread context** — must `~<TID>s` first to target a specific thread.

## task.js output fields (per-thread)
- `Worker state`: WORKER_STATE_SUSPENDED = truly stuck; RUNNING/RUNNABLE = not stuck.
- `Wait type description` + `BLOCKERS` section (walks SQL blocker chain). `No blockers were found` + PWAIT_IO_COMPLETION = stuck on async IO, root cause in IO subsystem (not SQL self-deadlock).

## all_ios.js — REQUIRES FULL/FILTER DUMP
- On a **minidump** it fails: `ERROR 0x8007001E - Cannot read from virtual address` (pending-IO global structures not captured).
- minidump comment: `Only registers, stack and portions of memory are available`.
- To enumerate pending IOs / per-IO latency, need `.dump /ma` full dump or a filter dump.

## Worker IO counters (minidump-safe, from `dt sqldk!Worker`/`SOS_Worker`)
- `m_NumberOfIOs` vs `m_NumberOfContextSwitches` ~1:1 + low `m_NumberOfTasksProcessed` ⇒ many small serial IOs (e.g. per-PFS-page log-redo catch-up), not one giant IO.

## Case 2604300030000700 (SQLDump0004.mdmp, SQL2016 SP2 CU14)
- Latch timeout `0x3E0DE3C9178` (Heap DATASET_PARENT). EX owner = thread 449, SPID 261, Sch23.
- 449 + 471 (dump trigger) both SPID 261 — same parallel query (DOP=40).
- 449: SUSPENDED + PWAIT_IO_COMPLETION (0x61), No blockers; stack CatchupPageRedos→CheckLogBlockReadComplete.
- 449 worker: NumberOfIOs=17094, ContextSwitches=17193, TasksProcessed=2 → many small IOs.
