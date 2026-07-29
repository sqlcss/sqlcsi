# Dump Analysis — Shared Setup & Tooling Contract (single source)

> **This file is the ONE canonical source** for the setup mechanics shared by the two dump
> skills. It lives INSIDE the `dump-overall` skill (`.github/skills/dump-overall/reference/`)
> so that `dump-overall` stays self-contained whether it runs standalone or is invoked by
> the `dump-analysis` agent. Do NOT duplicate these blocks back into the SKILL files — link
> here instead.
>
> Referenced by:
> - **`dump-overall`** skill (`.github/skills/dump-overall/SKILL.md`, link `reference/setup.md`)
>   — the global snapshot pass. **DumpViewer-FIRST (PRIMARY)**; `mex.dll` / WinDbgCsExt are
>   used only in FALLBACK.
> - **`dump-analysis`** skill (`.github/skills/dump-analysis/SKILL.md`, link
>   `../dump-overall/reference/setup.md`) — the root-cause deep-dive pass. Uses cdb/mirrors +
>   DScript + `mex.dll` (Part 2 native walking / Part 3 DScript); it does **not** run
>   DumpViewer as primary. It always runs after `dump-overall`, so the cross-skill link is safe.
>
> Covers: **Symbol Path · Step 0 Pre-Check (tool inventory + install prompts) · Step 1
> Session Setup (cdb resolution + DScript COM registration + Path A/B) · Step 1 fallback
> (mirror-404 build-share load, SQLMirrors0003)**. Each skill notes which subset it uses.

---

## Symbol Path (read this FIRST — do NOT hardcode msdl)

For every cdb/WinDbg/DumpViewer session, use the machine's configured symbol path — on this
workstation the User env var `_NT_SYMBOL_PATH`:

```
srv*C:\Symbols*https://symweb.azurefd.net
```

- `symweb.azurefd.net` is the **internal** symbol server — it has SQL private PDBs **and** the
  SqlCsScripts/Mirrors packages. The public `msdl.microsoft.com` has neither the mirrors nor
  (reliably) SQL private symbols, so **do NOT hardcode
  `https://msdl.microsoft.com/download/symbols`** in scripts.
- `C:\Symbols` is the local downstream cache; private PDBs (sqllang/sqlmin/sqltses) get cached
  there and `.reload /f` loads them instantly.
- **sympath ordering rule**: an HTTP store must be the LAST store, and there can be only ONE
  HTTP store. `srv*C:\Symbols*https://symweb...*https://msdl...` fails with
  `SYMSRV: Any HTTP store must be the last store in the list`. Keep symweb last/alone.
- Resolve it at runtime (do not hardcode):
  ```powershell
  $sym = [Environment]::GetEnvironmentVariable('_NT_SYMBOL_PATH','User')
  if (-not $sym) { $sym = 'srv*C:\Symbols*https://symweb.azurefd.net' }
  ```
  then emit `.sympath $sym` into the `.cdb` script. Using `.symfix` is fine **only** if the
  machine default already points at symweb; prefer reading the env var.
- VPN required for symweb. If symweb is unreachable, private symbols (and mirrors) won't load
  — fall back to `kn` + `!analyze -v` (dump-analysis Part 2 decision table) only.

---

## Tool contract — the 5 surfaces (NOT interchangeable)

| Surface | Provided by | Used for | If missing |
|---------|-------------|----------|------------|
| **DumpViewer.exe** (self-hosted, no cdb) | user folder `{dumpviewer_path}` (default `C:\Users\lduan\tools\DumpViewer`) | **`dump-overall` PRIMARY** — 第一/二步 + most of the 附加步骤 (run first via `run_dumpviewer.ps1`) | ASK the user for the folder; if truly unavailable, `dump-overall` runs FALLBACK mode (full DScript/mirror pipeline) |
| **WinDbgCsExt** (`.load` into the **WinDbg GUI**) | NuGet `WinDbgCs.amd64` (`WinDbgCsExt.dll`) | Part 1 **mirrors** `!execute`/`!evaluate` (`Tasks.Enumerate`, ring buffers, schedulers, memory brokers) — **run MANUALLY in the WinDbg GUI** (or headless via `SqlScriptRepl.exe` / `run_windbgcs_direct.ps1`) | ASK the user for the folder (default `C:\Tools\WinDbgCs` = v3.2.7 for SQL 2019); still emit a manual WinDbg block |
| **SqlScriptRepl.exe** (self-hosted, no cdb) | built `SqlScriptRepl.exe` (sibling of DumpViewer) | The **automated** mirror path — arbitrary `Class.Method` REPL, out-of-process CodeGen (bypasses the cdb CodeGen `dynamic`-dispatch failure) | Prompt to build (see below) — optional |
| **DScript `.js` scripts** (`!dscript.run`) | **user folder** `{dscript_path}` (build-specific, e.g. `C:\Tools\dscript\sql2019`) | `task.js` / `tsqlstack.js` / `callstack.js` / `all_ios.js` / `dump_latch_contended_pages.js` — runs **headless in cdb** | ASK the user for the folder; without it 第三步 / task sweep can't run |
| **mex.dll** (`.load`, `!mex.us`) | **user folder** `{mex_path}` (e.g. `C:\Tools\mex`) | Thread inventory (`!mex.us`) — runs **headless in cdb** (`dump-overall` FALLBACK 第一步; dump-analysis 分析第一步) | ASK the user for the folder; without it the `!mex.us` thread inventory can't run |

> **⛔ ASK THE USER FOR THE TOOL PATHS FIRST** — these are machine-specific and differ on every
> box, so NEVER auto-guess or hardcode them. Collect up front: **`{dump_path}`,
> `{dumpviewer_path}`, `{dscript_path}`,** and — for the mirror/FALLBACK surfaces — **`{mex_path}`,
> `{wdbgcs}`**. The candidate lists below are only *suggested defaults* to pre-fill the question
> — the user's answer wins.

> **These are NOT interchangeable and NEITHER lives inside the other.** WinDbgCsExt is a dbgeng
> **extension**; DumpViewer / SqlScriptRepl are **standalone self-hosting apps**. Do NOT copy
> `DumpViewer.exe` into the `WinDbgCs.amd64` folder (or vice-versa) — DumpViewer needs its OWN
> full sibling set (`dbgeng.dll`, `dbghelp.dll`, `CsDebugScript.Engine.dll`, `ReportTemplate\`,
> `DumpViewerConfig.xml`) and version-matched CsDebugScript DLLs. Keep each tool self-contained.

> **Batch-vs-manual rule (important):** the cdb `-cf`/`-c` **batch** surface runs ONLY
> headless-safe commands — native DX/`dv`/`kn`/`.cxr` (Part 2), `mex` (`!mex.us`), and DScript
> `!dscript.run` `.js` (Part 3). The Part 1 **mirror** commands (`!dcs_initsymsvr` +
> `!execute`/`!evaluate`) do **not** batch reliably via `!dcs_initsymsvr` — for those, generate
> a manual WinDbg GUI block (preferred) or run `SqlScriptRepl.exe` / `run_windbgcs_direct.ps1`.
> (Exception: a **direct** `!execute <path>\SqlCsScripts.dll` load DOES batch cleanly under
> `cdb -cf` once the mirror pair is seeded — see "Step 1 fallback".)

---

## Step 0 — Pre-Check (RUN FIRST, before any analysis)

Detect / obtain every required surface up front. If a required one is **missing, STOP and
prompt the user** (install it, or provide its folder) — do NOT silently fall through to a
broken path.

### Preferred — committed verifier

`dump-overall` ships a single committed verifier. After collecting the paths from the user, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\pre_check.ps1 `
  -DumpPath    '{dump_path}' `
  -DumpViewer  '{dumpviewer_path}' `        # DumpViewer.exe folder (default C:\Users\lduan\tools\DumpViewer)
  -MexPath     '{mex_path}' `               # mex.dll folder (FALLBACK 第一步 / dump-analysis 分析第一步)
  -DscriptPath '{dscript_path}' `           # DScript .js folder (第三步 / task sweep — always)
  -Wdbgcs      '{wdbgcs}'                    # WinDbgCsExt folder (mirror Tasks.Enumerate + rings)
```

Each line reports `<surface> : OK (<path>)` or `<surface> : MISSING (<expected file>) — ASK USER`.

### Inline fallback pre-check (if the committed verifier is unavailable)

```powershell
# --- WinDbgCsExt (cdb/WinDbg mirror extension) — USER-PROVIDED, machine-specific ---
$wdbgcsCandidates = @(
    $env:WDBGCS_PATH,                                    # user/env override wins
    'C:\Tools\WinDbgCs\WinDbgCsExt.dll',                 # ✅ CONFIRMED WORKING v3.2.7 (2025-06) — PREFERRED for SQL 2019 + the 2023-04 prebuilt mirror pair
    'C:\Tools\windbgcs.3.0.8\WinDbgCsExt.dll',           # v3.0.8 — local codegen fallback
    'C:\Tools\WinDbgCs.amd64\WinDbgCsExt.dll',           # ⛔ v4.11.0 — TOO NEW: every row = "Missing from SqlDebugTypes" on the 2023-04 pair
    'C:\Users\lduan\tools\DumpViewer\WinDbgCsExt.dll'    # v3.79.0 — hard-fails when prebuilt pkg missing
)
if ($env:NugetMachineInstallRoot) {
    $wdbgcsCandidates += (Get-ChildItem "$env:NugetMachineInstallRoot\WinDbgCs*\WinDbgCsExt.dll" -ErrorAction SilentlyContinue | ForEach-Object FullName)
}
$wdbgcs = $wdbgcsCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

# --- DumpViewer + SqlScriptRepl (self-hosted REPL) ---
$dvDir   = 'C:\Users\lduan\tools\DumpViewer'
$dvExe   = Join-Path $dvDir 'DumpViewer.exe'
$replExe = Join-Path $dvDir 'SqlScriptRepl.exe'
$dvOk    = (Test-Path $dvExe) -and (Test-Path (Join-Path $dvDir 'dbgeng.dll')) -and (Test-Path (Join-Path $dvDir 'CsDebugScript.Engine.dll'))
$replOk  = Test-Path $replExe

# --- DScript .js scripts folder (USER-PROVIDED, build-specific) — ASK the user ---
$dscriptPath = $env:DSCRIPT_PATH
$dscriptOk = $dscriptPath -and (Test-Path (Join-Path $dscriptPath 'task.js'))

# --- mex.dll folder (USER-PROVIDED) — ASK the user ---
$mexPath = $env:MEX_PATH
$mexOk = $mexPath -and (Test-Path (Join-Path $mexPath 'mex.dll'))

"WinDbgCsExt  : " + ($(if ($wdbgcs)   { "INSTALLED  ($wdbgcs)" } else { 'MISSING' }))
"DumpViewer   : " + ($(if ($dvOk)     { "INSTALLED  ($dvExe)" } else { 'MISSING' }))
"SqlScriptRepl: " + ($(if ($replOk)   { "BUILT      ($replExe)" } else { 'NOT BUILT' }))
"DScript .js  : " + ($(if ($dscriptOk){ "PROVIDED   ($dscriptPath)" } else { 'NOT PROVIDED — ASK THE USER' }))
"mex.dll      : " + ($(if ($mexOk)    { "PROVIDED   ($mexPath)" } else { 'NOT PROVIDED — ASK THE USER' }))
```

### Decision & install prompts

- **WinDbgCsExt MISSING** → tell the user:
  > `WinDbgCsExt.dll` not found. Install the **`WinDbgCs.amd64`** NuGet package (internal feed)
  > and extract to `C:\Tools\WinDbgCs.amd64\`, or pull it from the CoreXT cache
  > (`%NugetMachineInstallRoot%\WinDbgCs*\`) / a built DsMainDev enlistment. v3.0.8+ preferred
  > (local on-the-fly codegen fallback); **for SQL 2019 dumps prefer v3.2.7** (`C:\Tools\WinDbgCs\`).

  Without it the mirror `!execute`/`!evaluate` path cannot run. Part 2 native dump-walking
  (cdb + symbols only) is still available.

- **DumpViewer MISSING** → tell the user:
  > DumpViewer not found at `C:\Users\lduan\tools\DumpViewer\`. Install/copy the **DumpViewer**
  > package (built from `SqlTelemetry/Src/Tools/DumpViewer`) as a **complete self-contained
  > folder** — it must include `DumpViewer.exe`, `dbgeng.dll`, `dbghelp.dll`, all
  > `CsDebugScript.*.dll`, `ReportTemplate\`, and `DumpViewerConfig.xml`.

  For `dump-overall` this is the PRIMARY surface; if unavailable, run FALLBACK mode.

- **DumpViewer INSTALLED but SqlScriptRepl NOT BUILT** → build it (do NOT block on this unless
  the user wants the interactive/automated mirror REPL):
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\build_sqlscriptrepl.ps1
  ```
  (Self-locating: compiles the sibling `scripts\SqlScriptRepl.cs`; outputs `SqlScriptRepl.exe`
  INTO the DumpViewer folder. See repo memory `sql_script_repl.md`.)

- **DScript `.js` scripts NOT PROVIDED** → **ASK the user** for the folder:
  > Which folder holds the DScript `.js` scripts (`task.js`, `tsqlstack.js`, `callstack.js`,
  > `all_ios.js`)? e.g. `C:\Tools\dscript\sql2019`. It is **build-specific** — pick the
  > sub-folder matching the dump's SQL major version. This becomes `{dscript_path}` in all
  > `!dscript.run` commands. Do NOT hardcode a path.

- **mex.dll NOT PROVIDED** → **ASK the user** for the folder:
  > Which folder holds `mex.dll`? e.g. `C:\Tools\mex`. This becomes `{mex_path}` in
  > `.load {mex_path}\mex.dll`. Do NOT hardcode a path — the `!mex.us` thread inventory needs it.

> If **both** mirror surfaces (WinDbgCsExt + SqlScriptRepl) are missing, do not proceed with
> mirror analysis — surface the install prompts and wait. Native Part 2 (cdb + symbols) is the
> only fallback and should be offered explicitly.

---

## Step 1 — Session Setup

### 1.1 Resolve cdb.exe (Windows Kits OR WinDbg Store/MSIX)

**ALWAYS check the WinDbg Store (Appx/MSIX) package too** — on machines with the modern WinDbg
(`Microsoft.WinDbg.Slow`/`Microsoft.WinDbg`) from the Store, `cdb.exe` lives under
`C:\Program Files\WindowsApps\Microsoft.WinDbg*\amd64\cdb.exe`, NOT in `Windows Kits\...\Debuggers`.
If you only check Kits paths you will wrongly conclude "cdb not found" and fall back to the GUI
path — do NOT do that.

Use the committed shared resolver. It checks an explicit path first, then AppX package
registration (Slow → standard → Fast → Preview), Windows SDK paths, and finally PATH. It
intentionally does not recursively enumerate `WindowsApps`, whose ACLs cause false negatives.

```powershell
. .github\skills\dump-overall\scripts\resolve_cdb.ps1
$cdb = Resolve-CdbPath -Required
"Found: $cdb"
```

### 1.2 DScript COM registration (do this BEFORE any `!dscript.run`)

The Store WinDbg package version changes on every auto-update, so register the 4 DScript CLSIDs
per-user (HKCU) pointing at the currently-installed `Microsoft.WinDbg*\amd64\pri\DScript.dll`.

Preferred — committed script:
```powershell
pwsh -NoProfile -File .github\skills\dump-overall\scripts\register_dscript.ps1
```

Otherwise `!dscript.run` fails with `not registered as a COM server`. **NEVER hardcode the
package version.** **NEVER `.load WinDbgCsExt.dll` / `!dcs_initsymsvr` in the SAME session you
run `!dscript.run`** — it poisons DScript (see repo memory `dscript-dump-analysis.md`).

> DScript's COM self-registration is a **one-time, admin-elevated** action the first time the
> DLL is `.load`ed inside an **elevated** cdb; afterwards it persists machine-wide in HKLM and
> every later run is non-elevated (no UAC). Check registration count:
> ```powershell
> $n = (Get-ChildItem 'HKLM:\SOFTWARE\Classes\CLSID' -EA SilentlyContinue |
>       Where-Object { (Get-ItemProperty $_.PSPath -EA SilentlyContinue).'(default)' -match 'DSCRIPT' }).Count
> "DScript CLSIDs in HKLM: $n"   # 4 == registered, ready to use non-elevated
> ```

### Path A — cdb.exe CLI (automated, headless-safe)

Preferred — committed script (resolves cdb, writes the headless-safe batch, runs it, verifies
the `_us.txt` + `_dump_output.txt` logs are written):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\run_mex_us.ps1 `
  -Dump    '{dump_path}' `
  -MexPath '{mex_path}' `
  -OutDir  'reports/{case_id}_dump_code_analysis' `
  -CaseId  '{case_id}'
```

Inline equivalent — the batch is **HEADLESS-SAFE ONLY** (native + `mex` + DScript; NO mirror
`!execute`/`!evaluate`/`!dcs_initsymsvr`):
```text
* ========================================
* SQL-CSI Dump — Case: {case_id}  (headless-safe cdb -cf batch)
* Mirror !execute/!evaluate are NOT here — see Path B (manual WinDbg) / Step 1 fallback.
* ========================================
.sympath srv*C:\Symbols*https://symweb.azurefd.net
.reload /f
* --- dump metadata (native) ---
vertarget
lmvm sqlservr
* --- thread inventory via mex → log ---
.load {mex_path}\mex.dll
.logopen reports/{case_id}_us.txt
!mex.us
.logclose
* --- (optional) DScript .js sweep; {dscript_path} is user-provided ---
* ~<TID> s ; !dscript.run {dscript_path}\task.js ; .echo ===TASK_<TID>_DONE===
q
```
Run + capture:
```powershell
& $cdb -z "{dump_path}" -cf "reports/{case_id}_dump_commands.cdb" -logo "reports/{case_id}_dump_output.txt" -G -lines
```
> `-z` open dump · `-cf` run command script · `-logo` log all output (overwrite) · `-G` ignore
> final breakpoint · `-lines` load line info. The final `q` exits cdb. Allow up to 5 min for
> large dumps (`run_mex_us.ps1 -TimeoutSec 300`).

### Path B — WinDbg GUI (manual, for the mirror `!execute`/`!evaluate`)

Generate a copy-pasteable block for the user:
```windbg
* Open dump: windbgx -z {dump_path}
.sympath srv*C:\Symbols*https://symweb.azurefd.net
.reload /f
!dcs_initsymsvr sqlservr
!dcs_initsymsvr sqldk
!execute
```

> **⚠ SQL 2022 / 2025 dumps — use `!dcs_initsymsvr`, NOT `!execute <path>\SqlCsScripts.dll`.**
> `!execute <full-path-to-SqlCsScripts.dll>` triggers WinDbgCsExt v3.2.7's **in-process Roslyn
> CodeGen** to build a per-dump `SqlDebugTypes.dll` (writes DIA-exported source ~100–200 MB,
> then compiles); on SQL 2022/2025 dumps this often fails silently as `Codegen failed with
> exception` with a misleading `File.Move ... Could not find file '<dump>\output\SqlDebugTypes.dll'`
> at `CodeGenHelper.cs Line 861`. The **designed entry point** is `!dcs_initsymsvr`, which
> downloads the mirror assemblies from symweb via `SymFindFileInPathW` — bypassing CodeGen —
> and works for SQL 2019 / 2022 / 2025. (`.reload /f sbs.dll` "was not found in the image list"
> is HARMLESS.)

---

## Step 1 (fallback) — `!dcs_initsymsvr` 404 → load Mirrors from the build share (SQLMirrors0003)

> **A Step 1 setup addendum, not an analysis step.** Only run it if `!dcs_initsymsvr` 404s. It
> never reorders ahead of the analysis steps — once mirrors load (or you fall back to Part 2
> native walking), resume the normal step order.

> **Split of responsibilities:** the **acquisition** of the mirror DLLs is **AUTOMATED — the
> agent does it** (either `!dcs_initsymsvr` auto-download, or the auto-copy-from-build-share
> script below). Only the mirror **`!execute`/`!evaluate`** commands are run **manually in the
> WinDbg GUI** (or via `SqlScriptRepl.exe` / `run_windbgcs_direct.ps1`). Do NOT ask the user to
> copy DLLs by hand.

`!dcs_initsymsvr sqlservr` pulls the managed **mirror** assemblies for the dump's exact build
via a symbol-server **SymSvrManifest** (keyed on the `sqlservr.exe` build signature). If that
manifest was **never published for the build** (e.g. SQL 2019 CU20), the fetch returns **404**
and the Mirrors path looks dead. A newer `WinDbgCsExt.dll` does **not** fix this — the manifest
is missing **server-side**.

**Workaround: bypass symweb and load the mirror DLLs directly from the released-build file
share.** Version must match the dump **exactly**.

1. Get the dump's exact build: `lmDvm sqlservr` (e.g. `15.0.4312.2`) — **do NOT guess from CU
   number**; the file/product version is authoritative.
2. **AUTO-COPY the mirror pair into a per-build sub-folder** under
  `{wdbgcs}\NetStandard20Refs\build_<version>\` (side-by-side with the default pair — do
  **NOT overwrite** the default `NetStandard20Refs\` pair). Prefer the committed helper; it
  tries the build share first and, when the case package already contains `SqlCsScripts.dll`
  + `SqlDebugTypes.dll`, can use that folder as a fallback source:

  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\acquire_mirrors.ps1 `
    -Wdbgcs  '{wdbgcs}' `
    -Build   '{build_version}' `
    -Product SQLServer2019 `
    -CaseDir '{folder_containing_SqlCsScripts_and_SqlDebugTypes}'
  ```

  The resulting direct-load script path is always:

  ```text
  {wdbgcs}\NetStandard20Refs\build_{build_version}\SqlCsScripts.dll
  ```

  Manual equivalent / share details: two share paths are equivalent:
   - `\\sqlbuilds\Released\SQLServer<year>\RTM\Hotfixes\<build>\bin\retail\x64\` (retail)
   - `\\sqlbuilds\Released\SQLServer<year>\RTM\Hotfixes\<build>\debug\amd64\`  (debug — verified 2026-07)

  The agent can also run the copy manually when needed:
   ```powershell
   $wdbgcsDir = 'C:\Tools\WinDbgCs'    # user-provided WinDbgCs folder
   $build     = '15.0.4312.2'          # from `lmDvm sqlservr` — RESOLVE, don't guess
   $dst       = Join-Path $wdbgcsDir "NetStandard20Refs\build_$build"
   New-Item -ItemType Directory -Force -Path $dst | Out-Null
   $share     = "\\sqlbuilds\Released\SQLServer2019\RTM\Hotfixes\$build\debug\amd64"
   foreach ($f in 'SqlDebugTypes.dll','SqlCsScripts.dll','SqlDebugTypesPartial.cs') {
     $src = Join-Path $share $f
     if (Test-Path $src) { Copy-Item $src $dst -Force; "copied $f -> $dst" }
     else { Write-Warning "missing on share: $src (verify build/branch)" }
   }
   ```
   Available SQL2019 hotfix builds in the share (verified 2026-07): `4312.2, 4316.3, 4318.3,
   4322.2, 4326.1, 4335.1, 4338.1, 4345.5, 4355.3, 4365.2, 4375.4, 4384.2, 4385.2, 4392.2,
   4405.4, 4415.2, 4420.2, 4430.1`.
3. In a **dedicated** cdb/WinDbg session (do NOT mix with DScript — see Part 3), load the
   extension, then **explicitly register the script assembly with `!execute <full
   path>\SqlCsScripts.dll` BEFORE any `Tasks.Enumerate` expression**. This registration is
   **session-scoped and lost on every WinDbg restart** — skipping it gives `No results to
   process` or `Could not load SqlDebugTypes`. These `!execute`/`!evaluate` commands **DO batch
   cleanly in headless `cdb -cf`** (verified 2026-07 on SQL 2019 15.0.4312.2): one command per
   line, terminate with `q`, pass with `-cf`. Use per-query `.echo == MARKER ==` fences to
   segment the log (the `TaskOutput:` sentinel only appears if `!dcs_initsymsvr` succeeded).

   > **AUTOMATED DIRECT-LOAD (preferred once the mirror pair is seeded):**
   > `.github/skills/dump-overall/scripts/run_windbgcs_direct.ps1` — writes the batch, runs
   > cdb, pass/fail-reports each expression by marker fence. Example:
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
   > **Verified working `!execute` methods (SQL 2019 15.0.4312.2, 2026-07):** `Tasks.Enumerate`,
   > `SOSRingBuffers.EnumerateExceptionRingRecords`, `SOSRingBuffers.EnumerateSchedulerMonitorRecords`,
   > `SOSRingBuffers.EnumerateMemoryBrokerRingRecords`, `SOSRingBuffers.EnumerateResourceMonitorRecords`.
   > **Confirmed WRONG class names** (return `No results to process`): `Times.DumpTime`,
   > `Times.SqlUptime`, `ProcessSummary.Enumerate`. When in doubt, run bare `!execute` (no arg)
   > to dump the A-Z catalog for the current build.
   >
   > Both `run_windbgcs_tasks.ps1` and `run_windbgcs_direct.ps1` auto-resolve cdb.exe
   > (`Get-Command` → Windows Kits → `Get-AppxPackage *WinDbg*` → WindowsApps glob). If none
   > work, pass `-Cdb` explicitly. **Requires `pwsh` (PowerShell 7)**, not 5.1.

   Interactive WinDbg GUI is only required for **exploratory** LINQ:
   ```powershell
   # AUTO: seed the mirror pair next to WinDbgCsExt.dll (one-time)
   Copy-Item $dumpFolder\SqlCsScripts.dll,$dumpFolder\SqlDebugTypes.dll `
     (Join-Path (Split-Path -Parent $wdbgcs) 'NetStandard20Refs') -Force
   ```
   ```text
   .load <path>\WinDbgCsExt.dll                                          * full path required
   !execute <path>\NetStandard20Refs\build_<version>\SqlCsScripts.dll    * REGISTER build-matched assembly (session-scoped; lost on restart)
   !execute                                                              * (NO ARG) prints full A-Z script menu — authoritative catalog for this build
   !execute Tasks.Enumerate                                              * now the method resolves
   ```

**Gotchas:**
- `The type initializer for 'SqlDebugTypes.NodeManager' threw an exception` = the DLLs are from
  a **different build** than the dump. Re-verify with `lmDvm sqlservr` and re-copy the match.
- **EVERY row = `Missing from SqlDebugTypes`** (in `!execute enumerateall`), or a wall of
  `InvalidMemoryAddressException ... SqlDebugTypes.SOS_Task.get_...` for **ALL** tasks = the
  loaded **WinDbgCsExt is too new for the prebuilt mirror pair**. On this box the 2023-04
  `SqlCsScripts.dll`/`SqlDebugTypes.dll` pair works with `C:\Tools\WinDbgCs\WinDbgCsExt.dll`
  (**v3.2.7**) but NOT with `C:\Tools\WinDbgCs.amd64\WinDbgCsExt.dll` (**v4.11.0** — all types
  Missing). Fix: `.load` the older compatible WinDbgCsExt, then `!execute
  <NetStandard20Refs>\SqlCsScripts.dll`, then the expression. **For SQL 2019 dumps prefer
  v3.2.7.** **Distinguish:** *ALL* rows Missing = version mismatch (fix the ext version); a
  *few* `InvalidMemoryAddressException` rows on a **minidump** = uncaptured pages = **benign**.
- `Debug types dll out of date` → CodeGen kicks in: on WinDbgCs **< 3.1.2** rename
  `SqlDebugTypesPartial.cs` → `SqlCsScripts.SqlDebugTypesPartial.cs`; on **≥ 3.1.2** no rename.
- `WinDbgCsExt.dll` comes from NuGet (`WinDbgCs.amd64`), CoreXT cache
  (`%NugetMachineInstallRoot%\WinDbgCs*\`), or a built DsMainDev enlistment.
- **This only fixes the 404 (can't-load-scripts) problem — it does NOT recover pages missing
  from a minidump.** If the data lives in an uncaptured page, manual mirrors read the same
  fault as DScript (see Part 3 minidump note).
