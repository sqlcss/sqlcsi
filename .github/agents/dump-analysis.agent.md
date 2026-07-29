---
name: dump-analysis
description: >-
  Analyze SQL Server crash dumps via cdb.exe CLI automation or WinDbg GUI command
  generation. Uses SqlCsScripts/Mirrors to query ring buffers, DMV-equivalents, and
  subsystem state; falls back to native symbol/stack walking when mirrors are
  unavailable. Use when the user says "analyze dump", "分析 dump", provides a
  .mdmp file path, or asks to generate WinDbg commands for a SQL Server dump.
tools: [read, edit, search, execute, agent]
agents: [callstack-research]
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
| `upstream_log_report` | No | Immutable ERRORLOG/XEvent report generated before dump detection |
| `upstream_log_completion_receipt` | No | PASS receipt/hash binding required when supplied by a non-yield handoff |

> At least one of `error_numbers`, `subsystem`, or `call_stack_functions` should be
> provided. If none are given, run a general-purpose triage script.

## Orchestration Steps

## Supported Entry Paths and Gate Ownership

`dump-analysis` owns Gate A/B/C generation in both entry paths:

- **Path 1 — chained from `non-yielding-analysis`:** input may contain a PASS upstream
  log report/receipt and a receipt-gated matched dump. Gate A/B/C will normally be absent.
  Validate only the upstream handoff first, then generate Gate A → Gate B → Gate C.
- **Path 2 — direct dump invocation:** no upstream log report or receipt is required. Start
  directly with setup and generate Gate A → Gate B → Gate C.

Gate A/B/C are outputs of this agent, never invocation prerequisites. Their absence is the
normal fresh-run state and must not cause failure. Existing artifacts may be reused only by an
explicit reuse path after dump identity and every relevant receipt/hash are verified.

### Phase -1: Validate Optional Upstream Log-Analysis Handoff

When the handoff contains `log_report` / `log_completion_receipt`:

1. require receipt `status=PASS`;
2. recompute and validate the receipt, log report, ERRORLOG findings, XEvent findings, and
  workflow-ledger hashes;
3. confirm the selected dump path came from receipt-gated
  `detect_non_yield_dump.ps1` with match status `matched`;
4. treat all upstream artifacts as read-only — never regenerate or edit them;
5. link the upstream log-analysis report from the downstream dump final report.

Phase -1 validates only the upstream log/detection handoff; it must not require Gate A/B/C.
If validation fails, stop before dump-overall. A later dump failure must not delete or
invalidate the already-PASS upstream log report/receipt.

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

For a fresh Path 1 or Path 2 invocation, create the Gate A output directory, reports,
workflow ledger, and completion receipt in this phase. The caller is not expected to have
generated any dump-overall or Gate A/B/C artifact.

For latch-timeout dumps, the overall snapshot is not complete until the dump-overall
completion verifier passes with `-RequireSchedulerInventory -RequireLatchContendedPages`.
That gate forces both `sys.schedulers.js` / `Schedulers.Enumerate` and
`dump_latch_contended_pages.js` output to exist and be linked from the MAIN overall report.

### Phase 1.5: Gate B — machine-readable route selection

After Gate A Completion PASS, run the dump-overall post-overall entry point and require Gate B
PASS. Read `<case>_first_pass_branch_hints.json`; use `routingStatus`, not row existence:

- `route-signal` → mandatory Phase 2 route;
- `context-only` → background evidence only;
- `no-route-signal` → do not start that route;
- `unavailable-with-evidence` → retain the limitation.

Do not manually repeat the same subsystem decision when Gate B exists. User-explicit subsystem
requests may add a route, but must be recorded as `user-explicit`.

### Phase 2: Gate C — execute every selected subsystem route

Initialize `<case>_route_execution_ledger.json` from the Gate B JSON using
`initialize_route_execution_ledger.ps1`. Execute every selected route using SKILL.md
§深挖第一步 subsystem→script mapping + error-specific queries, and close every required check
with `set_route_execution_check.ps1` plus non-empty raw evidence. If no route signal exists,
execute the generated General triage route.

Related routes should share one debugger session but retain separate checklists. In particular,
`Scheduler / non-yield` + `Blocking / latch / locking` becomes one combined investigation:

1. Run `non_yield_analysis.js` and retain complete or partial output. If minidump/symbol limits
  stop its extended section, mark that check `unavailable-with-evidence` and continue with the
  required native fallback; do not silently hide the script error.
2. Recover/validate `pTrack`, timing, worker/task/scheduler, current and copied stacks.
3. If current and copied stacks are both on spinlock acquisition/backoff, let
  `run_non_yield_route.ps1` invoke optional `run_spinlock_owner_sweep.ps1`. The sweep must run
  `!us -l -i Spinlock` through headless cdb/MEX; it must not use WinDbg MCP, DumpViewer
  ThreadDetails, or a prior `!mex.us` artifact. Preserve all waiters and group them by every
  distinct lock address. If this extension fails, retain failure evidence and continue the
  base Scheduler route; never block reports produced by the nine mandatory checks.
4. Follow the offending stack into the lock/latch/spinlock resource.
5. Decode resource layout, owner namespace/identity, owner stack, query/database context,
   parent-object coherence, wait/ring surfaces, and matching source semantics.

For the Scheduler route, invoke `run_non_yield_route.ps1` rather than issuing ad-hoc commands.
It dynamically discovers callback/offender/frame identities, emits structured findings, and
closes nine mandatory checks plus two optional Spinlock inventory/owner checks. After route execution, `finalize_route_execution.ps1` must
render the structured findings in the Scheduler route subreport. Phase 5 automatically injects
the same findings into the final HTML and runs `verify_non_yield_route.ps1`.

Do **not** invoke `callstack-research` inside this Phase 2 route executor. Full source/bug/PR/CU
research is intentionally deferred until the overall report and a base final root-cause HTML
already exist; it is the Scheduler route's post-final continuation in Phase 4.5.

- **Mirrors available** → Part 1 deep-dive blocks (HADR / Memory / Scheduler / Locking).
- **Mirrors unavailable** → Part 2 native methods:
  - **Latch timeout** → **read [reference/latch_timeout.md](../skills/dump-analysis/reference/latch_timeout.md) FIRST**, then Method 2
    (`m_count` decode + waiter-list walk + **walk the EX owner's real stack** to find why
    it won't release — log/data IO, preemptive, etc.; the latch timeout is usually a
    symptom). Return a latch-native summary containing owner/waiter mapping,
    `m_count` decode, owner real stack, self-blocking vs cross-session/chain
    classification, minidump limitations, and raw evidence paths. This summary is the
    required Step 4 input for the final latch report and must explicitly distinguish
    owner/waiter/`m_count` evidence, owner real stack evidence, classification, and
    minidump/full-dump limitations. ⚠️ In minidumps trust the owner thread stack, NOT the stale
    `SOS_Task.m_State`/`m_LastWaitType` fields.
  - **Non-yield / 17883 / 17884** → **read [reference/non_yielding.md](../skills/dump-analysis/reference/non_yielding.md) FIRST**, then Method 3
    (`pTrack` + copied-stack `.cxr`).
  - "What is every thread doing?" → Method 4 (`!uniqstack` + categorization).
  - Scheduler/worker enumeration → Method 1; enum names → Method 5.

Run `finalize_route_execution.ps1` after all route checks. It must emit Gate C PASS,
`<case>_route_execution_report.html`, one `<case>_route_<route-key>.html` report per selected
route, and `route_execution_completion_receipt.json` containing their hashes.
Never proceed to Phase 4 while a selected route or required check is pending, in-progress, or
failed. Optional extension checks (`required=false`) do not block the base route or reports.

### Phase 3: Targeted Follow-up & Parse Results

Run specific queries for task addresses / session IDs found in Phase 2
(SKILL.md §深挖第二步). For deep frame inspection use the DX frame/locals technique
(SKILL.md §Inspecting Per-Frame Local Variables).

### Phase 4: Compile Findings

Hard prerequisite: Gate C receipt status is `PASS`. The final report must link or cite the route
execution report so a reader can see which selected routes were actually completed. It must also
link the authoritative Gate A overall report. Include only a concise Gate A handoff summary;
do not copy the full overall tables into the root-cause report.

Write findings per SKILL.md §深挖第二步 (4.4 Compile Findings) → `reports/{case_id}_dump_findings.md`.
Return structured `DUMP_FINDINGS` (errors / call_stack_functions / server_state)
for downstream source-code search.

Generate the base final root-cause HTML now. At this point the user can already inspect both
the authoritative overall report and the base final report. Do not run the final completion
gate yet when `scheduler_non_yield` is selected.

### Phase 4.5: Deferred post-final copied-stack callstack research

Run this phase only when Gate C selected `scheduler_non_yield`, and only after Phase 4 has
generated the base final HTML. This is deliberately outside Gate A and Gate C because the
multi-source callstack research is high latency.

1. Create and verify the post-final handoff request:

  ```powershell
  pwsh -File .github\skills\dump-analysis\scripts\prepare_non_yield_callstack_research.ps1 `
    -CaseId '{case_id}' -AnalysisDir '{case_analysis_dir}' `
    -OverallDir '{case_dump_overall}' -FinalReport '{base_final_report}' `
    -Dump '{dump_path}' -SqlVersion '{sql_version_and_build}' `
    -Branch '{source_branch}' -Changeset '{changeset}'
  ```

2. Invoke the **`callstack-research`** agent exactly once with the emitted
  `<case>_non_yield_callstack_research_request.json`. The request makes the
  FIRST-DETECTED copied stack primary, reserves the output directory and exact three report
  names, and forbids mutation of Gate A/B/C or the base final.
3. Verify and hash the three reports:

  ```powershell
  pwsh -File .github\skills\dump-analysis\scripts\finalize_non_yield_callstack_research.ps1 `
    -Request '{case_analysis_dir}\{case_id}_non_yield_callstack_research_request.json'
  ```

On success this emits `non_yield_callstack_research_completion_receipt.json`. Research failures
must not rewrite, invalidate, or block the already completed Gate A/B/C or base final reports.
Retain the error, skip link publication, and continue to Phase 5; the final receipt records the
optional extension as `unavailable-with-evidence`.

### Phase 5: Final completion gate

Ensure the final report links `<case>_route_execution_report.html`, then run
`finalize_dump_analysis.ps1`. For a Scheduler/non-yield route it attempts to validate Phase 4.5
and, when successful, injects the full-report and `#narration` links. Missing or invalid Phase
4.5 artifacts are fail-open and recorded in the final receipt. It must publish
`dump_analysis_completion_receipt.json` with `status=PASS`, binding mandatory Gate A/B/C and the
final report by hashes. Do not call `task_complete` before Phase 5 PASS.

## Output Files

1. `reports/{case_id}_dump_code_analysis/` + `dumpviewer_out/` — overall snapshot outputs from the `dump-overall` skill (Phase 1)
2. `<case>_first_pass_branch_hints.json` — Gate B machine-readable route selection
3. `<case>_route_execution_ledger.json` / `<case>_route_execution_report.html` / `<case>_route_<route-key>.html` / `route_execution_completion_receipt.json` — Gate C route execution proof and per-route reports
4. `reports/{case_id}_deepdive.cdb` / `_deepdive.txt` — deep-dive script + output
5. `reports/{case_id}_dump_findings.md` — parsed findings report
6. `<case>_non_yield_callstack_research_request.json` / `callstack_research_copied_stack/` /
  `non_yield_callstack_research_completion_receipt.json` — deferred Scheduler route extension
7. `dump_analysis_completion_receipt.json` — mandatory Gate A/B/C + final report proof, with optional-extension publication status

## Error Handling

If any mandatory cdb.exe command fails or symbols won't load, stop and report verbatim — do
NOT retry silently or fabricate results. If private symbols won't load at all,
fall back to `kn` + `!analyze -v` only (SKILL.md Part 2 decision table).
The explicitly optional Spinlock owner sweep is the exception: capture its error as
`unavailable-with-evidence` and continue the pre-existing Scheduler report pipeline.
