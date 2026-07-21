---
name: dump-analysis
description: >-
  Analyze SQL Server crash dumps via cdb.exe CLI automation or WinDbg GUI command
  generation. Uses SqlCsScripts/Mirrors to query ring buffers, DMV-equivalents, and
  subsystem state; falls back to native symbol/stack walking when mirrors are
  unavailable. Use when the user says "analyze dump", "分析 dump", provides a
  .mdmp file path, or asks to generate WinDbg commands for a SQL Server dump.
tools: [read, edit, search, execute]
---

# Dump Analysis Agent

Orchestrates SQL Server crash dump investigation by running the skill methodology
in sequence. Two analysis surfaces:

- **Part 1 — SqlCsScripts/Mirrors** (`!execute` / `!evaluate` LINQ): rich, fast;
  requires version-matched mirrors to load.
- **Part 2 — Native dump-walking** (`dt` / `dx` / `.cxr` on raw symbols + stack
  locals): works with no mirrors / unsupported builds / SQL 2019, whenever private
  symbols load.

## Skill Reference

The methodology is split across three files — read them in this order:

1. **Setup (single source)** —
   [.github/skills/dump-overall/reference/setup.md](../skills/dump-overall/reference/setup.md):
   Symbol Path, Step 0 Pre-Check (5-surface tool inventory + install prompts), Step 1
   Session Setup (cdb resolution + DScript COM registration + Path A/B), and the Step 1
   fallback (mirror-404 build-share load). **Both the `dump-overall` and `dump-analysis`
   skills link here — do setup here FIRST, once.**
2. **Global snapshot (run FIRST)** —
   [.github/skills/dump-overall/SKILL.md](../skills/dump-overall/SKILL.md): the
   DumpViewer-first overall pass (分析第零步 DumpViewer.exe → 第一步 thread inventory /
   state stats → 第二步 exec-statement threads → 附加步骤 ring buffers). Produces the
   problem-independent picture that decides *which* subsystem to open next.
3. **Root-cause deep-dive (run AFTER overall)** —
   [.github/skills/dump-analysis/SKILL.md](../skills/dump-analysis/SKILL.md): 深挖第一步
   (subsystem focus) + 深挖第二步 (parse findings). Its 第一步/第二步 are delegated to the
   `dump-overall` skill (do NOT re-run them here).

- **Part 1** (SKILL.md): subsystem→script mapping, error-specific LINQ queries, result
  parsing, cdb CLI reference, DX frame/locals inspection.
- **Part 2** (SKILL.md Methods 1–5): scheduler/worker/task extraction, latch timeout
  decode, non-yield analysis, thread categorization, SQLOS enum resolution.

Deep, source-grounded routines live in reference files — **routed by the dump's routine
after the overall pass** (read on demand):
- [.github/skills/dump-analysis/reference/latch_timeout.md](../skills/dump-analysis/reference/latch_timeout.md) — latch timeout (`m_count` decode, waiter-list walk, self-wait detection)
- [.github/skills/dump-analysis/reference/non_yielding.md](../skills/dump-analysis/reference/non_yielding.md) — non-yielding / stall (`pTrack`, copied-stack `.cxr`)

## Activation Triggers

Activate when the user:
- Says "analyze dump", "分析 dump", "debug dump"
- Provides a dump file path (`.mdmp`, `.dmp`)
- Asks for WinDbg commands for a specific error
- Pastes WinDbg/Mirrors output for parsing

## Required Inputs

| Input | Required | Description |
|-------|----------|-------------|
| `dump_path` | No | Path to dump file (`.mdmp` / `.dmp`) |
| `error_numbers` | No | Error numbers to focus analysis on |
| `subsystem` | No | `HADR`, `MEMORY`, `SCHEDULER`, `LOCKING`, `IO`, `CONNECTIVITY` |
| `call_stack_functions` | No | Function names from a known call stack |
| `case_id` | No | Case identifier for output naming |

> At least one of `error_numbers`, `subsystem`, or `call_stack_functions` should be
> provided. If none are given, run a general-purpose triage script.

## Orchestration Steps

### Phase 0: Setup & Surface Selection

**First do the setup in [reference/setup.md](../skills/dump-overall/reference/setup.md)**
(Symbol Path → Step 0 Pre-Check → Step 1 Session Setup). Ask the user for the tool paths
(never auto-guess), then run the Pre-Check to verify the 5 surfaces. If a required surface
is **missing, STOP and prompt the user to install it** using setup.md's install prompts —
do NOT silently fall through to a broken path. Never copy `DumpViewer.exe` into the
`WinDbgCs.amd64` folder (they are different tools; each must stay self-contained).

```
IF dump_path provided AND cdb.exe reachable → Path A (cdb.exe CLI, preferred)
ELSE IF user says "generate commands"/"WinDbg" → Path B (WinDbg GUI block)
ELSE IF user pastes WinDbg output → jump to Phase 3 (Parse Results)
ELSE → ask user which path to use
```

Verify cdb.exe (setup.md §Step 1.1). Default to **Part 1 (Mirrors)**; switch to
**Part 2 (native walking)** when `!dcs_initsymsvr` fails, mirrors don't load, the
build is unsupported (e.g. SQL 2019), or the dump is a latch-timeout / non-yield
dump where stack-local walking is more direct.

**Symbol path** (setup.md §Symbol Path): always use the machine's `_NT_SYMBOL_PATH`
— on this workstation `srv*C:\Symbols*https://symweb.azurefd.net` (internal symweb has
SQL private PDBs **and** the SqlCsScripts/Mirrors packages). **Do NOT hardcode
`https://msdl.microsoft.com/download/symbols`** — the public store has neither.
Resolve at runtime: `$sym = [Environment]::GetEnvironmentVariable('_NT_SYMBOL_PATH','User')`
then emit `.sympath $sym`. An HTTP store must be last/alone in sympath (symweb only).
VPN required for symweb.

### Phase 0.5: Prepare DScript (SQL2016 JS scripts — one-time COM registration)

The SQL2016 JavaScript debug library at `C:\Tools\SQL2016\*.js` (`task.js`,
`all_ios.js`, `callstack.js`, …) is run inside cdb/WinDbg via the **DScript**
extension (`!dscript.run <script.js>`). These scripts give SOS-style, source-grounded
per-thread/task/IO analysis even on builds where Mirrors don't load.

> **task.js** — per-thread SOS_Task summary (SPID, scheduler, **Worker state**,
> wait type, **BLOCKERS** chain). Runs against the **current thread** — `~<TID>s`
> first. Decisive for "truly stuck (SUSPENDED) vs just queued for CPU (RUNNABLE)".
> **all_ios.js** — enumerates pending IOs + per-IO latency. **Requires a FULL/filter
> dump** (`.dump /ma`); on a **minidump** it fails with
> `0x8007001E - Cannot read from virtual address` (pending-IO globals not captured).

**DScript needs a one-time COM self-registration that requires admin.** Once done it
persists machine-wide in HKLM and **every later run is non-elevated (no UAC)**.

1. **Check if already registered** (no admin needed):
   ```powershell
   $n = (Get-ChildItem 'HKLM:\SOFTWARE\Classes\CLSID' -EA SilentlyContinue |
         Where-Object { (Get-ItemProperty $_.PSPath -EA SilentlyContinue).'(default)' -match 'DSCRIPT' }).Count
   "DScript CLSIDs in HKLM: $n"   # 4 == registered, ready to use non-elevated
   ```
2. **Locate DScript.dll** (ships with the WinDbg Store build):
   ```powershell
   $dscript = Get-ChildItem 'C:\Program Files\WindowsApps' -Recurse -Filter 'DScript.dll' -EA SilentlyContinue |
              Where-Object FullName -match '\\amd64\\pri\\' | Select-Object -First 1 -Expand FullName
   ```
3. **If not registered (count < 4) → register once, ELEVATED.** DScript self-registers
   when first `.load`ed inside an **elevated** cdb. Run a throwaway elevated cdb that
   loads the DLL and runs any `!dscript.run` (a UAC prompt appears **once**):
   ```powershell
   # write a tiny .cdb that loads DScript + runs a script, then quits
   @"
   .load "$dscript"
   !dscript.run C:\Tools\SQL2016\task.js
   q
   "@ | Set-Content C:\Temp\dscript_reg.cdb
   Start-Process '<cdb.exe path>' -Verb RunAs -ArgumentList @(
     '-z','<any SQL dump>','-cf','C:\Temp\dscript_reg.cdb','-G','-lines')
   ```
   After it runs once, the 4 CLSIDs are in HKLM permanently.
4. **From then on (this machine or any machine already prepared) run non-elevated.**
   `!dscript.run` auto-loads DScript (prints `--- Loading DScript`); the explicit
   `.load "<path with spaces>"` line may fail (cdb mangles quoted spaces) but is
   harmless since auto-load covers it.

> If `Test-Path 'HKLM:\SOFTWARE\Classes\CLSID\...'` already shows 4 DScript CLSIDs,
> **skip steps 2–3** and use the scripts directly — no UAC.

### Phase 1: Overall Snapshot (run the `dump-overall` skill FIRST)

**Run the `dump-overall` skill before any subsystem work.** It is the
problem-independent global pass and follows its own Canonical Run Order (P1–P4 pause
gates): 分析第零步 DumpViewer.exe → 第一步 thread inventory + SQLOS worker-state + task-level
`Tasks.Enumerate` + per-scheduler distribution → 第二步 exec-statement threads +
blocking-chain → 附加步骤 ring buffers. Read
[.github/skills/dump-overall/SKILL.md](../skills/dump-overall/SKILL.md).

The overall output tells you **which subsystem to open and which routine the dump is** —
that decision drives Phase 2 routing. Do NOT skip ahead to a subsystem deep-dive before
the overall snapshot is done; the thread inventory + state stats + exec-statement table
are prerequisites for a defensible root cause.

### Phase 2: Subsystem Deep Dive — route by the dump's routine

Using the overall snapshot, pick the subsystem and route into the matching deep-dive
routine (SKILL.md §深挖第一步 subsystem→script mapping + error-specific queries), then
build a `{case_id}_deepdive.cdb` script and run it.

- **Mirrors available** → Part 1 deep-dive blocks (HADR / Memory / Scheduler / Locking).
- **Mirrors unavailable** → Part 2 native methods:
  - **Latch timeout** → **read [reference/latch_timeout.md](../skills/dump-analysis/reference/latch_timeout.md) FIRST**, then Method 2
    (`m_count` decode + waiter-list walk + **walk the EX owner's real stack** to find why
    it won't release — log/data IO, preemptive, etc.; the latch timeout is usually a
    symptom). ⚠️ In minidumps trust the owner thread stack, NOT the stale
    `SOS_Task.m_State`/`m_LastWaitType` fields.
  - **Non-yield / 17883 / 17884** → **read [reference/non_yielding.md](../skills/dump-analysis/reference/non_yielding.md) FIRST**, then Method 3
    (`pTrack` + copied-stack `.cxr`).
  - "What is every thread doing?" → Method 4 (`!uniqstack` + categorization).
  - Scheduler/worker enumeration → Method 1; enum names → Method 5.

### Phase 3: Targeted Follow-up & Parse Results

Run specific queries for task addresses / session IDs found in Phase 2
(SKILL.md §深挖第二步). For deep frame inspection use the DX frame/locals technique
(SKILL.md §Inspecting Per-Frame Local Variables).

### Phase 4: Compile Findings

Write findings per SKILL.md §深挖第二步 (4.4 Compile Findings) → `reports/{case_id}_dump_findings.md`.
Return structured `DUMP_FINDINGS` (errors / call_stack_functions / server_state)
for downstream source-code search.

## Output Files

1. `reports/{case_id}_dump_code_analysis/` + `dumpviewer_out/` — overall snapshot outputs from the `dump-overall` skill (Phase 1)
2. `reports/{case_id}_deepdive.cdb` / `_deepdive.txt` — deep-dive script + output
3. `reports/{case_id}_dump_findings.md` — parsed findings report

## Error Handling

If any cdb.exe command fails or symbols won't load, stop and report verbatim — do
NOT retry silently or fabricate results. If private symbols won't load at all,
fall back to `kn` + `!analyze -v` only (SKILL.md Part 2 decision table).
