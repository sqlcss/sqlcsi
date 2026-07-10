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

## Symbol Server Path (ALWAYS USE THIS)

For every cdb/WinDbg session in this skill, use this symbol path:

```
srv*C:\Symbols*https://symweb.azurefd.net
```

- Set it at launch (`-y "srv*C:\Symbols*https://symweb.azurefd.net"`) or via `.sympath srv*C:\Symbols*https://symweb.azurefd.net` before `.reload`.
- `C:\Symbols` is the local downstream cache; private PDBs (sqllang/sqlmin/sqltses) get cached there and `.reload /f` loads them instantly.

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
  → 分析第四步 (Parse & Compile Findings) directly
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
| `dscript_path` | string | When running `.js` (Part 3) | Folder holding the DScript `.js` scripts (`task.js`, `tsqlstack.js`, `callstack.js`, `all_ios.js`), e.g. `C:\Tools\dscript\sql2019`. **Build-specific** — must match the dump's product major version. |
| `mex_path` | string | When running `!mex.us` (分析第一步) | Folder holding `mex.dll`, e.g. `C:\Tools\mex`. Used by `.load {mex_path}\mex.dll`. |

> At least one of `error_numbers`, `subsystem`, or `call_stack_functions` should be provided.
> If none are provided, generate a general-purpose diagnostic script.
> **`dscript_path`**: whenever a step needs a DScript `.js` (Part 3 / 分析第二步 sweep),
> **ASK the user for the scripts folder** if it wasn't provided — do NOT hardcode
> `C:\Tools\dscript\sql2019`. Pick the sub-folder matching the dump's SQL major
> version (`...\sql2019\`, `...\SQL2016\`, …). All `!dscript.run` examples below use
> `{dscript_path}` as the placeholder for this user-provided path.
> **`mex_path`**: whenever a step needs `!mex.us` (分析第一步 thread inventory),
> **ASK the user for the `mex.dll` folder** if it wasn't provided — do NOT hardcode
> `C:\Tools\mex`. All `.load` examples below use `{mex_path}\mex.dll` as the placeholder.

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

## Analysis Workflow (report-aligned)

The analysis produces a report whose sections ARE the steps below, in this order.
Do the **setup** first (Step 0 → Step 1), then walk the **analysis steps** — each one
emits one report section. Follow this linear narrative (it is the proven structure of
the `<case>_report.html` deliverable):

| Report section | Skill step | What it delivers |
|----------------|-----------|------------------|
| *(header meta cards)* | Step 0–1 (setup) | dump metadata: bugcheck, build, PID, MemoryLoad, uptime, capture time |
| **第一步：线程清单与状态统计** | → **`dump-overall`** skill | thread inventory + SQLOS worker-state (stack-inferred) + authoritative TaskState (`Tasks.Enumerate`) + per-scheduler distribution + 关键观察/下一步 |
| **第二步：执行语句线程统计** | → **`dump-overall`** skill | main/child exec-statement threads, runtime-state (blocking-chain) table, `sql_exec_thread.html` detail page |
| **第三步：子系统聚焦 & 深挖** | **分析第三步** (§ below) | pick the subsystem the observations point to, run its deep-dive commands |
| *(findings / root cause)* | **分析第四步** | parse outputs, compile errors + call-stack functions + server state |

> **第一步 & 第二步 have been split into the standalone `dump-overall` skill** (the
> DumpViewer-style global snapshot: `!mex.us`, `!execute Tasks.Enumerate`, `task.js`,
> `tsqlstack.js`). **Run `dump-overall` first**, then return here for the problem-specific
> 分析第三步 (subsystem deep-dive) + 分析第四步 (root cause).

> **Ordering rule:** never jump to a subsystem deep-dive before 分析第一步/第二步.
> The thread inventory + state statistics decide *which* subsystem to open, and the
> exec-statement table reveals *who blocks whom* — both are prerequisites for a
> defensible root cause. Setup fallbacks (mirrors 404, manual build-share load) are
> addenda to Step 1 and never reorder ahead of the analysis steps.

---

## Step 0: Pre-Check — verify tooling installation (RUN FIRST, before any analysis)

**Four tools power this skill:** `mex.dll`, the DScript `.js` scripts, `WinDbgCsExt`,
and `DumpViewer` (+ `SqlScriptRepl.exe`). Detect / obtain all four up front. If a
required one is **missing, STOP and prompt the user** (install it, or provide its
folder) — do NOT silently fall through to a broken path.

> **⛔ STEP 0 = ASK THE USER FOR THE TOOL PATHS FIRST — these are machine-specific and
> differ on every box, so NEVER auto-guess or hardcode them.** Before running anything,
> STOP and collect from the user: **`{wdbgcs}` (WinDbgCsExt folder), `{dscript_path}`
> (DScript `.js` folder), `{mex_path}` (mex.dll folder), and `{dump_path}` (the dump
> file)**. The candidate lists below are only *suggested defaults* to pre-fill the
> question — the user's answer wins. Do not proceed to 分析第一步 until all four are
> confirmed.

- **mex.dll** + **DScript `.js`** → user-provided folders (`{mex_path}`, `{dscript_path}`);
  both run **headless in cdb** (分析第一步 thread inventory, 分析第二步 task sweep).
- **WinDbgCsExt** → Part 1 mirrors `!execute`/`!evaluate`, run **manually in the WinDbg GUI**.
- **DumpViewer + SqlScriptRepl** → the **automated** mirror path (self-hosted REPL).

| Surface | Provided by | Used for | If missing |
|---------|-------------|----------|------------|
| **WinDbgCsExt** (`.load` into the **WinDbg GUI**) | NuGet `WinDbgCs.amd64` (`WinDbgCsExt.dll`) | Part 1 mirrors `!execute`/`!evaluate` — **run MANUALLY in the WinDbg GUI** (cdb `-cf`/`-c` batch is unreliable: `!dcs_initsymsvr` + `!execute` stall at the DML script-selection menu / 404 / error out) | **ASK the user for the folder** (machine-specific; default `C:\Tools\WinDbgCs` = v3.2.7 for SQL 2019); still generate a **manual WinDbg block** for the user |
| **DumpViewer + SqlScriptRepl** (self-hosted, no cdb) | DumpViewer package + built `SqlScriptRepl.exe` | The **automated** mirror path: arbitrary `Class.Method` REPL, out-of-process CodeGen (bypasses the cdb CodeGen dynamic-dispatch failure). Uses `CsDebugScript.Engine` directly — does **not** load WinDbgCsExt | Prompt to install/build (see below) |
| **DScript `.js` scripts** (`!dscript.run`, Part 3) | **User-provided** folder `{dscript_path}` (e.g. `C:\Tools\dscript\sql2019`) — build-specific | `task.js` / `tsqlstack.js` / `callstack.js` / `all_ios.js` — runs headless in cdb | **ASK the user for the folder** (see below); without it 分析第二步 (task sweep) can't run |
| **mex.dll** (`.load`, `!mex.us`) | **User-provided** folder `{mex_path}` (e.g. `C:\Tools\mex`) | Thread inventory in 分析第一步 (`!mex.us`) — runs headless in cdb | **ASK the user for the folder** (see below); without it 分析第一步 (thread inventory) can't run |

> **These are NOT interchangeable and NEITHER lives inside the other.** WinDbgCsExt is
> a dbgeng **extension**; DumpViewer is a **standalone self-hosting app**. Do NOT copy
> `DumpViewer.exe` into the `WinDbgCs.amd64` folder (or vice-versa) — DumpViewer needs
> its OWN full sibling set (`dbgeng.dll`, `dbghelp.dll`, `CsDebugScript.Engine.dll`,
> `ReportTemplate\`, `DumpViewerConfig.xml`) and version-matched CsDebugScript DLLs.
> Keep each tool self-contained in its own folder.

> **Batch-vs-manual rule (important):** the cdb `-cf`/`-c` **batch** surface runs ONLY
> headless-safe commands — native DX/`dv`/`kn`/`.cxr` (Part 2), `mex` (分析第一步), and
> DScript `!dscript.run` `.js` (Part 3). The Part 1 **mirror** commands
> (`!dcs_initsymsvr` + `!execute`/`!evaluate`) do **not** batch reliably — for those,
> **generate a manual WinDbg GUI block for the user** (preferred) or run
> `SqlScriptRepl.exe`. Never assume `!execute`/`!evaluate` will work under `cdb -cf`.

### Pre-Check script

```powershell
# --- WinDbgCsExt (cdb/WinDbg mirror extension) — USER-PROVIDED, machine-specific ---
# ASK the user for {wdbgcs}. Accept an env override; the candidate list is only a
# suggested default to pre-fill the question — the user's answer wins.
$wdbgcsCandidates = @(
    $env:WDBGCS_PATH,                                    # user/env override wins
    'C:\Tools\WinDbgCs\WinDbgCsExt.dll',                  # ✅ CONFIRMED WORKING v3.2.7 (2025-06 build) — PREFERRED; best for SQL 2019 dumps + the 2023-04 prebuilt mirror pair. Register from C:\Tools\WinDbgCs\NetStandard20Refs\
    'C:\Tools\windbgcs.3.0.8\WinDbgCsExt.dll',            # v3.0.8 — local codegen fallback
    'C:\Tools\WinDbgCs.amd64\WinDbgCsExt.dll',            # ⛔ v4.11.0 — TOO NEW: every row = "Missing from SqlDebugTypes" on the 2023-04 prebuilt pair
    'C:\Users\lduan\tools\DumpViewer\WinDbgCsExt.dll'     # v3.79.0 — hard-fails when prebuilt pkg missing
)
if ($env:NugetMachineInstallRoot) {
    $wdbgcsCandidates += (Get-ChildItem "$env:NugetMachineInstallRoot\WinDbgCs*\WinDbgCsExt.dll" -ErrorAction SilentlyContinue | ForEach-Object FullName)
}
$wdbgcs = $wdbgcsCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

# --- DumpViewer + SqlScriptRepl (self-hosted REPL) ---
$dvDir  = 'C:\Users\lduan\tools\DumpViewer'
$dvExe  = Join-Path $dvDir 'DumpViewer.exe'
$replExe = Join-Path $dvDir 'SqlScriptRepl.exe'
$dvOk   = (Test-Path $dvExe) -and (Test-Path (Join-Path $dvDir 'dbgeng.dll')) -and (Test-Path (Join-Path $dvDir 'CsDebugScript.Engine.dll'))
$replOk = Test-Path $replExe

# --- DScript .js scripts folder (USER-PROVIDED, build-specific) ---
# Not auto-discoverable — ASK the user for it (e.g. C:\Tools\dscript\sql2019).
# Accept an env override, else leave null and prompt.
$dscriptPath = $env:DSCRIPT_PATH
$dscriptOk = $dscriptPath -and (Test-Path (Join-Path $dscriptPath 'task.js'))

# --- mex.dll folder (USER-PROVIDED) ---
# Not auto-discoverable — ASK the user for it (e.g. C:\Tools\mex).
$mexPath = $env:MEX_PATH
$mexOk = $mexPath -and (Test-Path (Join-Path $mexPath 'mex.dll'))

"WinDbgCsExt : " + ($(if ($wdbgcs) { "INSTALLED  ($wdbgcs)" } else { 'MISSING' }))
"DumpViewer  : " + ($(if ($dvOk)   { "INSTALLED  ($dvExe)" } else { 'MISSING' }))
"SqlScriptRepl: " + ($(if ($replOk){ "BUILT      ($replExe)" } else { 'NOT BUILT' }))
"DScript .js : " + ($(if ($dscriptOk){ "PROVIDED   ($dscriptPath)" } else { 'NOT PROVIDED — ASK THE USER' }))
"mex.dll     : " + ($(if ($mexOk){ "PROVIDED   ($mexPath)" } else { 'NOT PROVIDED — ASK THE USER' }))
```

### Decision & install prompts

- **WinDbgCsExt MISSING** → tell the user:
  > `WinDbgCsExt.dll` not found. Install the **`WinDbgCs.amd64`** NuGet package (internal
  > feed) and extract to `C:\Tools\WinDbgCs.amd64\`, or pull it from the CoreXT cache
  > (`%NugetMachineInstallRoot%\WinDbgCs*\`) / a built DsMainDev enlistment. v3.0.8+
  > (`C:\Tools\windbgcs.3.0.8\`) is preferred (local on-the-fly codegen fallback).

  Without it, the cdb `!execute`/`!evaluate` mirrors path (Path A / Part 1) cannot run.
  You can still do Part 2 native dump-walking with cdb + symbols only.

- **DumpViewer MISSING** → tell the user:
  > DumpViewer not found at `C:\Users\lduan\tools\DumpViewer\`. Install/copy the
  > **DumpViewer** package (built from `SqlTelemetry/Src/Tools/DumpViewer`) as a
  > **complete self-contained folder** — it must include `DumpViewer.exe`, `dbgeng.dll`,
  > `dbghelp.dll`, all `CsDebugScript.*.dll`, `ReportTemplate\`, and `DumpViewerConfig.xml`.

  This is the reliable path for arbitrary `Class.Method` mirror scripts (the cdb batch
  path fails on CodeGen `dynamic` dispatch — see repo memory `sql_script_repl.md`).

- **DumpViewer INSTALLED but SqlScriptRepl NOT BUILT** → build it (do NOT block on this
  unless the user wants the interactive REPL):
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-analysis\scripts\build_sqlscriptrepl.ps1
  ```
  (Self-locating: compiles the sibling `scripts\SqlScriptRepl.cs`; outputs
  `SqlScriptRepl.exe` INTO the DumpViewer folder. See repo memory `sql_script_repl.md`.)

- **DScript `.js` scripts NOT PROVIDED** → **ASK the user** for the folder:
  > Which folder holds the DScript `.js` scripts (`task.js`, `tsqlstack.js`,
  > `callstack.js`, `all_ios.js`)? e.g. `C:\Tools\dscript\sql2019`. It is
  > **build-specific** — pick the sub-folder matching the dump's SQL major version
  > (`...\sql2019\`, `...\SQL2016\`, …). This becomes `{dscript_path}` in all
  > `!dscript.run` commands. Do NOT hardcode a path — 分析第二步 (task.js sweep) needs it.

- **mex.dll NOT PROVIDED** → **ASK the user** for the folder:
  > Which folder holds `mex.dll`? e.g. `C:\Tools\mex`. This becomes `{mex_path}` in the
  > `.load {mex_path}\mex.dll` command. Do NOT hardcode a path — 分析第一步 (`!mex.us`
  > thread inventory) needs it.

> If **both** surfaces are missing, do not proceed with mirror analysis — surface the
> install prompts and wait. Native Part 2 (cdb + symbols) is the only fallback and
> should be offered explicitly.

---

## Step 1: Session Setup

### Path A — cdb.exe CLI Automated

#### 1.1 Verify cdb.exe availability

**ALWAYS check the WinDbg Store (Appx/MSIX) package too** — on machines with the modern WinDbg
(`Microsoft.WinDbg.Slow`/`Microsoft.WinDbg`) installed from the Store, `cdb.exe` lives under
`C:\Program Files\WindowsApps\Microsoft.WinDbg*\amd64\cdb.exe`, NOT in `Windows Kits\...\Debuggers`.
If you only check Kits paths you will wrongly conclude "cdb not found" and fall back to Path B — do NOT
do that. Enumerate the Appx location as well and run cdb.exe yourself.

```powershell
$cdbCandidates = @(
    (Get-Command cdb.exe -ErrorAction SilentlyContinue).Source,
    "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe",
    "${env:ProgramFiles}\Windows Kits\10\Debuggers\x64\cdb.exe"
)
# WinDbg Store/MSIX package (most common on dev boxes) — dynamic version, so resolve at runtime
$wdbg = (Get-AppxPackage *WinDbg* | Select-Object -First 1).InstallLocation
if ($wdbg) { $cdbCandidates += (Join-Path $wdbg 'amd64\cdb.exe') }

$cdbPaths = $cdbCandidates | Where-Object { $_ -and (Test-Path $_) }
if ($cdbPaths) { $cdb = $cdbPaths[0]; "Found: $cdb" }
else { "cdb.exe not found — fall back to Path B (WinDbg GUI)" }
```

**DScript COM registration (do this before `!dscript.run`)**: the Store WinDbg package version changes
on every auto-update. Run the HKCU registration script (dynamically resolves the current
`Microsoft.WinDbg*\amd64\pri\DScript.dll` via `Get-AppxPackage`) so the 4 DScript CLSIDs point at the
installed package — otherwise `!dscript.run` fails with `not registered as a COM server`. NEVER hardcode
the package version. NEVER `.load WinDbgCsExt.dll` / `!dcs_initsymsvr` in the SAME session you run
`!dscript.run` — it poisons DScript (see repo memory `dscript-dump-analysis.md`).

#### 1.2 Generate .cdb script file

Create a temp script file with all commands. cdb.exe reads one command per line.
Lines starting with `*` are comments.

```powershell
$scriptPath = "reports/{case_id}_dump_commands.cdb"
```

Script file content — **HEADLESS-SAFE ONLY**. Put NO mirror `!execute`/`!evaluate`
(or `!dcs_initsymsvr`) here — they stall/error under `cdb -cf` batch. Emit those as the
Path B manual WinDbg block instead. This batch carries native + `mex` + DScript only:

```text
* ========================================
* SQL-CSI Dump Analysis — Case: {case_id}  (headless-safe cdb -cf batch)
* Mirror !execute/!evaluate are NOT here — see Path B (manual WinDbg) / Step 2.2.
* ========================================
.sympath srv*C:\Symbols*https://symweb.azurefd.net
.reload /f
* --- dump metadata (native) ---
vertarget
lmvm sqlservr
* --- thread inventory (分析第一步) via mex → log ---
.load {mex_path}\mex.dll
.logopen reports/{case_id}_us.txt
!mex.us
.logclose
* --- (optional) DScript .js sweep (Part 3); {dscript_path} is user-provided ---
* ~<TID> s ; !dscript.run {dscript_path}\task.js ; .echo ===TASK_<TID>_DONE===
q
```

> The final `q` exits cdb.exe after all commands finish.
>
> **Mirror commands** (dump-time, exception ring, sessions, memory clerks, schedulers,
> wait stats, trace flags, `{subsystem_commands}`) are delivered as the **Path B manual
> WinDbg block** (paste into the WinDbg GUI) or run via `SqlScriptRepl.exe` — NOT in this
> cdb `-cf` batch. The mirror-DLL **acquisition** (`!dcs_initsymsvr` / build-share copy)
> stays automated — see "Step 1 (fallback)".

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

After cdb.exe completes, read the output file and proceed to **分析第一步** (thread
inventory) — or, if the user pasted pre-captured output, jump to **分析第四步 (Parse &
Compile Findings)**.

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

## Step 1 (fallback): When `!dcs_initsymsvr` fails (404) — load Mirrors manually from the build share

> **This is a Step 1 setup addendum, not an analysis step.** Only run it if
> `!dcs_initsymsvr` 404s. It does not reorder ahead of 分析第一步 — once mirrors load
> (or you fall back to Part 2 native walking), resume at 分析第一步.

> **Split of responsibilities (important):** the **acquisition** of the mirror DLLs is
> **AUTOMATED — the agent does it** (either `!dcs_initsymsvr` auto-download, or the
> auto-copy-from-build-share script below). Only the mirror **`!execute`/`!evaluate`**
> commands are run **manually in the WinDbg GUI** (or via `SqlScriptRepl.exe`). Do NOT
> ask the user to copy DLLs by hand — resolve the build and copy them programmatically.

`!dcs_initsymsvr sqlservr` pulls the managed **mirror** assemblies for the dump's
exact build via a symbol-server **SymSvrManifest** (produced at build time by
`SqlCsScripts.SymSvrManifest.proj` + `SymSvrManifestConfig.xml`, keyed on the
`sqlservr.exe` build signature). If that manifest was **never published for the build**
(e.g. SQL 2019 CU20), the fetch returns **404** and the Mirrors path looks dead. A newer
`WinDbgCsExt.dll` does **not** fix this — the manifest is missing **server-side**.

**Workaround (per SOP `SQLMirrors0003`): bypass symweb and load the mirror DLLs
directly from the released-build file share.** Version must match the dump **exactly**.

1. Get the dump's exact build: `lmDvm sqlservr` (e.g. `15.0.4312.2`) — **do NOT guess
   from CU number**; the file/product version is authoritative.
2. **AUTO-COPY the mirror pair into a per-build sub-folder** under `{wdbgcs}\NetStandard20Refs\build_<version>\`
   (side-by-side with the default pair — do **NOT overwrite** the default `NetStandard20Refs\`
   pair, which may be pinned to a different build for other dumps). Two paths on the share
   are equivalent — either works:
   - `\\sqlbuilds\Released\SQLServer<year>\RTM\Hotfixes\<build>\bin\retail\x64\` (retail)
   - `\\sqlbuilds\Released\SQLServer<year>\RTM\Hotfixes\<build>\debug\amd64\`  (debug — verified 2026-07)

   The agent runs this automatically (do NOT hand it to the user as manual `copy` commands):
   ```powershell
   # --- AUTO: resolve build + copy mirror DLLs from the build share into a per-build sub-folder ---
   $wdbgcsDir  = 'C:\Tools\WinDbgCs'    # user-provided WinDbgCs folder
   $build      = '15.0.4312.2'          # from `lmDvm sqlservr` — RESOLVE, don't guess
   $dst        = Join-Path $wdbgcsDir "NetStandard20Refs\build_$build"
   New-Item -ItemType Directory -Force -Path $dst | Out-Null
   # Branch varies by product/release: SQLServer2019\RTM\Hotfixes, SQLServer2022\..., etc.
   $share      = "\\sqlbuilds\Released\SQLServer2019\RTM\Hotfixes\$build\debug\amd64"
   foreach ($f in 'SqlDebugTypes.dll','SqlCsScripts.dll','SqlDebugTypesPartial.cs') {
     $src = Join-Path $share $f
     if (Test-Path $src) { Copy-Item $src $dst -Force; "copied $f -> $dst" }
     else { Write-Warning "missing on share: $src (verify build/branch)" }
   }
   ```
   Available SQL2019 hotfix builds in the share (verified 2026-07): `4312.2, 4316.3,
   4318.3, 4322.2, 4326.1, 4335.1, 4338.1, 4345.5, 4355.3, 4365.2, 4375.4, 4384.2,
   4385.2, 4392.2, 4405.4, 4415.2, 4420.2, 4430.1`.
3. In a **dedicated** cdb/WinDbg session (do NOT mix with DScript — see Part 3), load
   the extension, then **explicitly register the script assembly with `!execute <full
   path>\SqlCsScripts.dll` BEFORE any `Tasks.Enumerate` expression**. This registration is
   **session-scoped and is lost on every WinDbg restart** — skipping it gives `No results
   to process` (the SCRIPTS menu with nothing bound) or `Could not load SqlDebugTypes`.
   `WinDbgCsExt` resolves the pair's dependency (`SqlDebugTypes.dll`) from a
   `NetStandard20Refs\` sub-folder **next to `WinDbgCsExt.dll`**, so on a 404/offline build
   copy the mirror pair into that sub-folder FIRST (one-time on disk; persists), then
   `.load`, then `!execute <SqlCsScripts.dll>`, then the expression. **These `!execute`
   / `!evaluate` commands DO batch cleanly in headless `cdb -cf <batch>`** (verified
   2026-07 on SQL 2019 15.0.4312.2): put the sequence into a `.cdb` file, one command
   per line, terminate with `q`, and pass with `-cf`. The `TaskOutput:` sentinel only
   appears if `!dcs_initsymsvr` succeeds; for direct `!execute <path>\SqlCsScripts.dll`
   loads use per-query `.echo == MARKER ==` fences instead to segment the log.

   > **AUTOMATED DIRECT-LOAD (preferred once mirror pair is seeded):** use
   > `.github/skills/dump-overall/scripts/run_windbgcs_direct.ps1`. It writes the batch,
   > runs cdb, and pass/fail-reports each expression by marker fence. Example:
   > ```powershell
   > pwsh -NoProfile -Command "& '.\.github\skills\dump-overall\scripts\run_windbgcs_direct.ps1' `
   >   -Dump    'C:\Temp\<case>\SQLDump0001.mdmp' `
   >   -OutDir  'C:\Users\lduan\sqlcsi-archive\reports\<case>_dump_code_analysis' `
   >   -CaseId  '<case>' `
   >   -Scripts 'C:\Tools\WinDbgCs\NetStandard20Refs\build_<version>\SqlCsScripts.dll' `
   >   -Expr @('Tasks.Enumerate',
   >           'SOSRingBuffers.EnumerateExceptionRingRecords',
   >           'SOSRingBuffers.EnumerateSchedulerMonitorRecords',
   >           'SOSRingBuffers.EnumerateMemoryBrokerRingRecords')"
   > ```
   > **Verified working `!execute` methods (SQL 2019 15.0.4312.2, 2026-07):**
   > `Tasks.Enumerate`, `SOSRingBuffers.EnumerateExceptionRingRecords`,
   > `SOSRingBuffers.EnumerateSchedulerMonitorRecords`,
   > `SOSRingBuffers.EnumerateMemoryBrokerRingRecords`,
   > `SOSRingBuffers.EnumerateResourceMonitorRecords`.
   > **Confirmed WRONG class names** (do NOT try — return `No results to process`):
   > `Times.DumpTime`, `Times.SqlUptime`, `ProcessSummary.Enumerate`. When in doubt,
   > run bare `!execute` (no arg) once to dump the A-Z catalog for the current build.
   >
   > Both scripts (`run_windbgcs_tasks.ps1` and `run_windbgcs_direct.ps1`) auto-resolve
   > cdb.exe via `Get-Command` → Windows Kits → `Get-AppxPackage *WinDbg*` →
   > `${env:ProgramFiles}\WindowsApps\Microsoft.WinDbg*_x64_*\amd64\cdb.exe` glob (matches
   > `.Slow` / `.Fast` / `.Preview` variants). If none work, pass `-Cdb` explicitly.
   > **Requires `pwsh` (PowerShell 7)**, not Windows PowerShell 5.1.

   Interactive WinDbg GUI is only required for **exploratory** LINQ:
   ```powershell
   # AUTO: seed the mirror pair next to WinDbgCsExt.dll (one-time)
   Copy-Item $dumpFolder\SqlCsScripts.dll,$dumpFolder\SqlDebugTypes.dll `
     (Join-Path (Split-Path -Parent $wdbgcs) 'NetStandard20Refs') -Force
   ```
   ```text
   .load <path>\WinDbgCsExt.dll                                              * full path required
   !execute <path>\NetStandard20Refs\build_<version>\SqlCsScripts.dll        * REGISTER build-matched script assembly (session-scoped; lost on restart)
   !execute                                                                  * (NO ARG) prints full A-Z script menu — authoritative catalog for this build
   !execute Tasks.Enumerate                                                  * now the method resolves
   ```

   > **Enumerate all available scripts:** after registering the assembly, run `!execute`
   > with **no argument** to get the full A-Z catalog. This is the definitive way to see
   > what canned expressions are valid for the current build — much broader than
   > `SqlScriptRepl.exe`'s ~11-item auto-discovery filter (the headless REPL uses a
   > stricter `ScriptDiscovery.DiscoverRunnableScripts` gate; many `[Script]`-attributed
   > classes like `Sessions/Schedulers/Databases/MemoryClerks/Locks/Connections/
   > SOSActiveTasks/HadronManager/SOSNodes/SOSTicks/ExecRequests` return `not found`
   > under SqlScriptRepl but resolve fine under WinDbg GUI `!execute`).

**Gotchas:**
- `The type initializer for 'SqlDebugTypes.NodeManager' threw an exception` = the
  DLLs are from a **different build** than the dump. Re-verify with `lmDvm sqlservr`
  and re-copy the matching version.
- **EVERY row = `Missing from SqlDebugTypes`** (in `!execute enumerateall`), or a wall of
  `InvalidMemoryAddressException ... SqlDebugTypes.SOS_Task.get_...` for **ALL** tasks =
  the loaded **WinDbgCsExt is too new for the prebuilt mirror pair**. On this box the
  2023-04 `SqlCsScripts.dll`/`SqlDebugTypes.dll` pair works with
  `C:\Tools\WinDbgCs\WinDbgCsExt.dll` (**v3.2.7**, 2025-06 build) but NOT with
  `C:\Tools\WinDbgCs.amd64\WinDbgCsExt.dll` (**v4.11.0** — all types Missing). Fix: `.load`
  the older compatible WinDbgCsExt, then `!execute <NetStandard20Refs>\SqlCsScripts.dll`,
  then the expression. **For SQL 2019 dumps, prefer WinDbgCsExt v3.2.7.** **Distinguish:**
  *ALL* rows Missing = version mismatch (fix the
  ext version); a *few* `InvalidMemoryAddressException` rows on a **minidump** =
  uncaptured pages = **benign** (the main table is still complete).
- `Debug types dll out of date` → CodeGen kicks in: on WinDbgCs **< 3.1.2** rename
  `SqlDebugTypesPartial.cs` → `SqlCsScripts.SqlDebugTypesPartial.cs`; on **≥ 3.1.2**
  no rename needed.
- `WinDbgCsExt.dll` comes from NuGet (`WinDbgCs.amd64`), CoreXT cache
  (`%NugetMachineInstallRoot%\WinDbgCs*\`), or a built DsMainDev enlistment.
- **This only fixes the 404 (can't-load-scripts) problem — it does NOT recover pages
  missing from a minidump.** If the data you want lives in an uncaptured page, manual
  mirrors read the same fault as DScript (see Part 3, minidump note).

---

## 分析第一步 & 第二步 → 已拆分至 `dump-overall` skill

> **线程清单与状态统计(第一步)** 与 **执行语句线程统计(第二步)** —— 即 `!mex.us`、
> `!execute Tasks.Enumerate`、`task.js`、`tsqlstack.js` 这些 **与具体问题无关、跑整体
> dump 全局结果** 的步骤 —— 已抽出为独立的 **`dump-overall`** skill
> (`.github/skills/dump-overall/SKILL.md`,复刻 `SqlTelemetry/Src/Tools/DumpViewer` 的整体快照)。
>
> **先运行 `dump-overall`** 得到:①SQLOS worker 状态分布 + 任务级权威状态
> (`Tasks.Enumerate`) + 按调度器分布 + 关键观察/下一步(第一步);②`task.js` 扫描 +
> `tsqlstack.js` + 运行时状态(阻塞链)表(第二步)。拿到「下一步」指向的子系统后,
> **再回到本 skill** 继续 **分析第三步(子系统聚焦)** 与 **分析第四步(根因)**。
>
> 本 skill 保留 Step 0/Step 1(工具与会话设置)、Part 2(native dump-walking)、
> Part 3(DScript)、cdb/LINQ 命令参考,供第三步/第四步深挖复用。

<!-- The 线程清单与状态统计 (第一步) & 执行语句线程统计 (第二步) content moved to .github/skills/dump-overall/SKILL.md -->

---

## 分析第三步（报告「第三步」）：子系统聚焦 · Determine Analysis Focus

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

## 分析第三步（续）：生成错误专属命令 & 深挖 · Error-Specific Commands & Deep Dives

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

## 分析第四步：解析结果 & 汇总发现 · Parse & Compile Findings (Manual Handoff)

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

### Final report structure — **match the current report as-is**

The customer-facing report follows the **existing report format** (do NOT redesign it).
Keep the same section order and headings as the report we align to:

1. **第一步：线程清单与状态统计** — `!mex.us` thread inventory + worker-state stats +
   authoritative `Tasks.Enumerate` TaskState + 按调度器分布 + 关键观察/下一步.
2. **第二步：执行语句线程统计** — task.js sweep + tsqlstack + 运行时状态表 (blocking chain).
3. **第三步：子系统聚焦** — subsystem-specific mirror queries (HADR/Memory/Scheduler/…).
4. **第四步：解析结果 & 汇总发现** — findings, call-stack functions, server state, root cause.

> Ask the user for **language** (English / 中文) and **format** (HTML / Markdown) before
> generating — but the **section layout stays as the current report**. HTML uses the
> Catppuccin Mocha theme from `copilot-instructions.md`.

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

## Prepare (one-time per-user registration — no admin, no UAC, persists)

DScript hosts **4 COM objects**; cdb refuses `!dscript.run` until their CLSIDs are
registered, else: `*** ERROR: The DSCRIPT extension is not registered as a COM server
... dscript!DebugExtensionInitialize failed with 0x80070005`.

**Register them per-user (HKCU) — no elevation needed. COM resolves HKCU before HKLM.**

```powershell
pwsh -NoProfile -File .github\skills\dump-analysis\scripts\register_dscript.ps1
```

The script auto-detects the newest `DScript.dll` (running debugger proc → WindowsApps
`Microsoft.WinDbg*` package → Windows Kits), re-extracts the 4 CLSIDs from the dll's
own Unicode strings, and writes `HKCU\Software\Classes\CLSID\{guid}\InprocServer32`.
The keys **persist across reboots** and take effect in an **already-running cdb** (COM
activates lazily). The 4 CLSIDs are: `7cadfd15-…-981951734836`, `931a9cec-…-eb9a785aee3d`,
`987f2c24-…-1b4a6688169f`, `ff9f7123-…-21df9dc1dedc`.

> **WinDbg auto-updates break it** — the package version in the path changes, so the
> HKCU value points to the old (gone) dll → `not registered as a COM server` returns.
> **Fix: just re-run `register_dscript.ps1`** (it re-detects the new path). The skill
> relies on dscript long-term, so re-run this whenever dscript starts failing.
>
> The legacy elevated-HKLM self-registration also works but needs a UAC click and
> hard-codes one version path — prefer the HKCU script above.

## Running a script

```text
.sympath srv*C:\Symbols*https://symweb.azurefd.net
.reload /f
~<TID> s                                  * task.js targets the CURRENT thread — switch first
!dscript.run {dscript_path}\task.js ; .echo ===DONE===   * {dscript_path} = user-provided scripts folder; wait for the marker — see "⛔ CRITICAL" below
```
> `!dscript.run` **auto-loads DScript** (prints `--- Loading DScript`). An explicit
> `.load "<path with spaces>"` line may fail (cdb mangles quoted spaces) — harmless,
> auto-load covers it.
>
> **Do NOT `.load WinDbgCsExt` or run `!dcs_initsymsvr` / `!dcs_initlocal` before ANY
> `!dscript.run`** — WinDbgCsExt is a separate C#/CsDebugScript extension that poisons
> the DScript COM session (`0x800A0030 [Error in loading DLL]`). See the **⛔ CRITICAL**
> subsection at the end of Part 3 for why.

## Key scripts

| Script | What it gives | Dump requirement | Speed |
|--------|---------------|------------------|-------|
| `task.js` | Per-thread `SOS_Task`: **SPID**, scheduler, **Worker state** (SUSPENDED/RUNNABLE/RUNNING), wait type + group, elapsed/CPU time, task function, **BLOCKERS** chain | minidump OK | **fast (~12 s GUI)** |
| `tsqlstack.js` | The actual **T-SQL statement text** (`Input string:`) + parameters for the thread's active batch | minidump OK (tail param bytes may be missing) | **slow (~290 s / 5 min)** |
| `all_ios.js` | Enumerates pending IOs + per-IO latency | **FULL/filter dump only** | fast |
| `callstack.js` | Annotated SQL call stack | minidump OK | fast |

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

## ⛔ CRITICAL — how to run `.js` scripts WITHOUT breaking the session

Every DScript `.js` (`task.js`, `tsqlstack.js`, `callstack.js`, `all_ios.js`, and any
future script) runs **purely through the DScript extension against private symbols**.
It does **NOT** use the WinDbgCs / SqlCsScripts / Mirrors mechanism at all. Hard-won
lessons — follow exactly:

1. **NEVER `.load WinDbgCsExt.dll` and NEVER run `!dcs_initsymsvr` / `!dcs_initlocal`
   before ANY `!dscript.run` (task.js, tsqlstack.js, callstack.js, all_ios.js, …).**
   The Mirrors init (Part 1) and DScript (Part 3) are **two completely separate
   surfaces — do not mix them in the same session.** If you already ran `.load
   WinDbgCsExt` / `!dcs_init*` and dscript now errors, **quit and start a fresh cdb.**

   **Why loading WinDbgCsExt breaks `!dscript.run`:** `WinDbgCsExt.dll` (newest at
   `C:\Tools\WinDbgCs\WinDbgCsExt.dll`; older `C:\Tools\windbgcs.3.0.8\`) is a
   *different* extension — the **CsDebugScript** engine: managed **C# / Roslyn**
   (`Microsoft.CodeAnalysis*.dll`) + `CsDebugScript.Engine` + its own `msdia140.dll`.
   It is unrelated to DScript, and **a newer build does NOT change this** — same
   mechanism, same poisoning. Two failure modes result:
   - `!dcs_initsymsvr` pulls **managed "mirror" assemblies** for the target build via a
     symbol-server manifest (`CsDebugScript.SymSrvManifestGen`). On a build with **no
     published SqlCsScripts manifest → 404**; on a **minidump** the mirrors can't bind
     to process memory anyway.
   - Loading WinDbgCsExt into the same process pulls in its own managed engine +
     `msdia140.dll`, which **disturbs DScript's COM object-model / DIA activation**, so
     the *next* `!dscript.run` fails with `0x800A0030 [Error in loading DLL]`. This is
     the poisoned-session symptom — the DLL loaded fine, but it broke DScript.
   - (Even a bare `.load WinDbgCsExt.dll` fails unless you give the full
     `C:\Tools\WinDbgCs\WinDbgCsExt.dll` path or set `.extpath`.)


2. **Clean run procedure (the only thing you need):**
   ```text
   cdb -z <dump>.mdmp -lines            * fresh session, symbols srv*C:\Symbols*https://symweb.azurefd.net
   ~<TID> s                             * dscript targets the CURRENT thread — switch first
   !dscript.run {dscript_path}\task.js ; .echo ===TASK_<TID>_DONE===
   ```
   `!dscript.run` auto-loads DScript (`--- Loading DScript`). No other setup is needed
   beyond the one-time `register_dscript.ps1` (HKCU COM registration).
   > `{dscript_path}` is **user-provided and build-specific** — **ASK the user** for the
   > scripts folder (e.g. `C:\Tools\dscript\sql2019\`, or `...\SQL2016\`); do NOT
   > hardcode it. Pick the folder matching the dump's product major version.

3. **Always append an explicit `.echo ===..._DONE===` marker and WAIT for it. Do NOT
   kill the session early.** Headless cdb is **not** inherently slow — with **warm
   symbols** (`C:\Symbols` already populated) and the correct invocation (1.7.2 (B):
   `-y` for symbols, `$$><`/`-cf` for the command file, `q` inside the file) `task.js`
   runs in **~1–2 s/thread**. Prior "hangs" were the cdb `-c` parsing traps (1.7.2 (B))
   and cold symbol downloads — **not** the script:
   | Script | WinDbg GUI (S_OK) | Headless cdb (warm sym) | Notes |
   |--------|-------------------|--------------|-------|
   | `task.js` | ~12–13 s | ~1–2 s/thread | fast; safe to `waitForOutput` |
   | `tsqlstack.js` | ~290 s (~5 min) | **≥ 5 min** | the line `Input string:(` is **in-progress**, NOT a hang |

   Idle-detection can return in ~1 min while the script is still running — that is
   **not** completion. Poll for the `===..._DONE===` marker (or `----- Script Complete
   -----`) before reading results. Killing at the first idle signal was the #1
   self-inflicted "hang". `tsqlstack.js` does **not** hang; it is just slow.

4. **Minidump read faults are a dump limitation, not a script/procedure error.** On a
   minidump, `tsqlstack.js` reads whatever pages were captured, then may end with
   `0x80020101` / `0x8007001E (ERROR_READ_FAULT)` / `0x800A0030`, often with
   `Cannot read from virtual address 0x...`, `<CORRUPTED>`, or `Null MXC`. Two cases:
   - **Tail-only fault (common):** the `Input string:` statement text is **fully
     captured**; only trailing **parameter values** aren't. Use the statement text;
     ignore the tail error.
   - **Truncated statement (e.g. thread 370):** the fault hits **mid-string** —
     `(@P0 int,...,@P20 nvarchar(40)<CORRUPTED>` then `Cannot read virtual address`.
     The page holding the rest of the batch body + parameter values simply **isn't in
     the minidump**, so the full T-SQL is **unrecoverable from this dump**. Record what
     you got as `[PARTIAL]` (e.g. "large parameterized RPC, ~21 params") and move on;
     a `.dump /ma` full/filter dump is the only way to get the rest. Manual Mirrors
     (Step 1 fallback) would hit the **same** fault — it's a missing page, not a bind issue.

5. **If headless cdb is impractical or fails, hand the user a paste-ready MANUAL WinDbg
   block** (see 1.7.2 (C) for the sweep template) — same `!dscript.run` command, same
   symbols; the GUI completes `tsqlstack.js` in ~5 min and `task.js` in ~13 s with
   `returned S_OK`. **This is a deliverable you print into the reply** (placeholders
   resolved: real `{dump_path}`, `{dscript_path}`, TIDs) — not just a suggestion to
   "open WinDbg". In the GUI omit the trailing `q` and never `.load WinDbgCsExt`.

6. **`task.js` is the fast, high-value first choice** — gives SPID, scheduler, Worker
   state, wait type, and the **BLOCKERS chain** in seconds (e.g. it surfaced a
   `PWAIT_HADR_CLUSAPI_CALL` blocker monopolizing a scheduler). Run `tsqlstack.js`
   (slow) only when you need the actual T-SQL statement text + parameters.

