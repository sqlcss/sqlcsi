# Dump Analysis (cdb) — verified facts

## Tooling paths (this machine)
- cdb.exe: `C:\Program Files\WindowsApps\Microsoft.WinDbg.Slow_1.2604.24001.1_x64__8wekyb3d8bbwe\amd64\cdb.exe`
  - Find dynamically via: `(Get-AppxPackage *WinDbg*).InstallLocation` then `amd64\cdb.exe`
  - NOT in Windows Kits or tools/DumpViewer
- WinDbgCs extension (provides `!execute`/`!evaluate`):
  - `C:\Tools\windbgcs.3.0.8\WinDbgCsExt.dll` (v3.0.8 — has local on-the-fly codegen fallback; PREFERRED)
  - `C:\Users\lduan\tools\DumpViewer\WinDbgCsExt.dll` (v3.79.0 — hard-fails when prebuilt pkg missing)
- Symbol path: `srv*C:\Symbols*https://symweb.azurefd.net` (env `_NT_SYMBOL_PATH`)
- Source server ini: env `SRCSRV_INI_FILE = C:\SRC\srcsrv.default.ini` (TFS URLs stripped of :8443)

## DCS/Mirrors limitation
- `!dcs_initsymsvr sqlservr` needs WinDbgCsExt.dll loaded first (`.load <path>`).
- Even loaded, it downloads a pre-built script assembly keyed to the sqlservr build
  timestamp from symweb. For older builds (e.g. SQL19 15.0.4249, 2022) the package
  is NOT on symweb → fails with `HRESULT 0x80070002 (file not found)`.
  → Mirror scripts (`!execute Times.*`, `SOSRingBuffers.*`, `Sessions.*`) then unusable.
  → Fall back to standard commands (`.ecxr`, `.exr -1`, `kn`, `lmvm`, `dv`).
- v3.0.8 update (C:\Tools\windbgcs.3.0.8): adds "on-the-fly code generation (Local
  environment only)" fallback. When the prebuilt symweb assembly 404s, it no longer
  hard-fails — instead `!execute` triggers a local codegen path and shows a
  "SCRIPTS / HELP (Loaded: A-Z)" selection menu. BUT in non-interactive `cdb -c`
  batch mode it stalls at that menu (no output). Needs INTERACTIVE cdb/WinDbg to pick
  scripts, or the (still-unknown) non-interactive script-load syntax. Prebuilt
  symweb path remains unavailable regardless (server-side, old build).
- v3.0.8 exported commands (from DLL strings): `!dcs_initsymsvr` (prebuilt/Watson),
  `!dcs_initlocal <module>` (LOCAL on-the-fly codegen), `!dcs_printasm`, `!dcs_unloadasm`.
  The A-Z script menu items are WinDbg **DML hyperlinks** (must be CLICKED in the GUI
  to compile+load a script group); they are NOT plain bang-commands, so cdb -c batch
  cannot drive them. `!execute ExternalScripts.Install` is the internal loader but also
  just re-renders the DML menu in batch mode.
  → To use Mirror scripts on an old build: run **WinDbg GUI interactively**, `.load`
    the 3.0.8 ext, `!dcs_initlocal sqlservr`, CLICK a letter group (e.g. "T" for Times),
    then `!execute Times.DumpTime`. For automated/batch analysis keep using standard
    cmds + DX (works headless).

## Per-frame locals: prefer DX over `.frame /c`
- `.frame /c N` renumbers across inline frames ("Reset base frame from N to 0") → skips frames.
- Use DX: `dx -r1 @$curthread.Stack.Frames` to list stable indices, then
  `dx Debugger.Sessions[0].Processes[PID].Threads[TID].Stack.Frames[N].SwitchTo()` + `dv /t /v`.
- For `<value unavailable>` locals in minidumps, search stack: `s -su <lo> L<range> ".mdf"`.

## cdb invocation pattern (non-interactive)
`& $cdb -z <dump> -G -lines -logo <out.txt> -cf <script.cdb>` ; script ends with `q`.
First load can take 1-3 min (symbol download); run as background terminal + await.

## SqlScriptRepl (headless mirror) — build matching (2026-07)
- Local `C:\Tools\WinDbgCs\NetStandard20Refs\{SqlDebugTypes,SqlCsScripts}.dll` is compiled
  against a specific SQL Server build (currently 15.0.4249). Mismatched dump →
  `Could not load type 'SqlDebugTypes.SOS_MemoryObjectRingRecord' from assembly SqlDebugTypes...`
  during script invocation.
- FIX: get the matched pair from build share and pass via `-Scripts`:
  `\\sqlbuilds\Released\SQLServer2019\RTM\Hotfixes\<version>\debug\amd64\{SqlDebugTypes.dll,SqlCsScripts.dll}`
  Keep per-build under `C:\Tools\WinDbgCs\NetStandard20Refs\build_<version>\`
  (side-by-side, do not overwrite the default pair).
  Available SQL2019 hotfix builds in share: 4312.2, 4316.3, 4318.3, 4322.2, 4326.1, 4335.1,
  4338.1, 4345.5, 4355.3, 4365.2, 4375.4, 4384.2, 4385.2, 4392.2, 4405.4, 4415.2, 4420.2, 4430.1.
- Get dump build via: `lmvm sqlservr` (in cdb) → file/product version = SQL Server build.
- REPL resolver quirk (SqlScriptRepl "Discovered N scripts"): only ~11 method names
  are auto-registered. Many `[Script]`-attributed classes in the DLL (Sessions, Schedulers,
  Databases, MemoryClerks, Locks, Connections, SOSActiveTasks, HadronManager, SOSNodes,
  SOSTicks, ExecRequests) return `[WARNING] Script 'X.Y' not found.` even with
  fully-qualified name `SqlCsScripts.Scripts.X.Y`. Root cause not yet identified
  (attribute filter differs from what class-level `[Script]` implies).
- VERIFIED WORKING `-Expr` names on 15.0.4312.2 (CU19 GDR):
  - `SOSRingBuffers.EnumerateExceptionRingRecords` (real data — 1017 rows for stuck-thread dump)
  - `SOSRingBuffers.EnumerateMemoryBrokerRingRecords`
  - `SOSRingBuffers.EnumerateMonitorRingRecords`
  - `SOSRingBuffers.EnumerateSchedulerRingRecords`
  - `SOSRingBuffers.EnumerateMemoryNodeOOMRingRecords`
  - `StackFrames.Enumerate`
  - `ExceptionContext.Enumerate`
  - `Threads.Enumerate` (resolves to `DWScripts.Threads.Enumerate`)
  - `Tasks.Enumerate`
  - `ScriptsHelp.LinqQueries`
- Skill's canned `Times.DumpTime` and `ProcessSummary.Enumerate` do NOT exist in the mirror DLL.
- Helper: `C:\Users\lduan\sqlcsi-archive\reports\<case>\ListScripts` (net10 exe) — uses
  `System.Reflection.Metadata.PEReader` to enumerate `SqlCsScripts.Scripts.*` types without
  loading them (avoids loader errors). Reusable across cases; invocation:
  `dotnet run -c Release -- '<path-to-SqlCsScripts.dll>'` (NO `--nologo` — pwsh eats it).

## Enumerating mirror scripts in WinDbg GUI (WinDbgCsExt path)
- After loading WinDbgCsExt and registering the script assembly, run **`!execute` with
  NO argument** to print the full A-Z script menu (all discoverable classes/methods):
  ```
  .load C:\Tools\WinDbgCs\WinDbgCsExt.dll
  !execute C:\Tools\WinDbgCs\NetStandard20Refs\build_15.0.4312.2\SqlCsScripts.dll   * register (build-matched)
  !execute                                                                          * lists ALL scripts
  ```
- This is the authoritative catalog for the WinDbg GUI path — much larger than
  SqlScriptRepl's ~11-item auto-discovered list (SqlScriptRepl uses a stricter filter
  in `CsDebugScript.Common.ScriptDiscovery.DiscoverRunnableScripts`).
