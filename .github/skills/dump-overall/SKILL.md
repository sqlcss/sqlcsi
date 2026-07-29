---
name: dump-overall
description: >-
  Produce the OVERALL / global snapshot of a SQL Server crash dump — a DumpViewer-first
  pass that is independent of what the specific problem is. PRIMARY path runs
  **DumpViewer.exe** up front to emit `dumpviewer_out\Reports\*` and builds the report
  from that data for 第一步 (threads: ThreadDetails/UniqueStacks), 第二步 (tasks:
  Tasks/ActiveTasks) and most of the 附加步骤 (SOS ring buffers). It then SUPPLEMENTS only the
  gaps DumpViewer does not cover — 第三步 per-thread T-SQL via `task.js`/`tsqlstack.js`
  (DScript) plus the ring buffers DumpViewer omits (HADR AR / BlockedProcessReport /
  MemoryBrokerClerk / ProcessSummary via `!execute`). If DumpViewer cannot adapt to the
  build (early SQL 2019 CU / older), it AUTO-FALLS BACK to the full DScript/mirror pipeline
  (`!mex.us` + `!execute Tasks.Enumerate` + the 9 SOS ring-buffer mirrors). Use when the
  user says "dump overall", "整体 dump", "全局 dump 分析", "线程清单", "跑一下整个 dump",
  or as the FIRST pass before any subsystem deep-dive (root-cause interpretation lives in
  the dump-analysis skill).
context: fork
---

# Dump Overall Skill (DumpViewer-style global snapshot)

> ## ⛔ 用途与范围（先读这一段）· PURPOSE & SCOPE — READ FIRST
>
> **本 skill 只做「列举 / 展示」，绝不做任何分析。** 它把一个 SQL Server crash dump 里的
> **线程 / 资源 / 异常 / 语句 / 任务**这五类事实原样枚举、分类、制表，产出一个客观的
> 全局快照，**作为后续分析的素材（material for subsequent analysis）** — 仅此而已。
>
> **分工（DIVISION OF LABOR）:**
> - **dump-overall（本 skill）** = 对整个 dump 的 **线程 / 资源 / 异常 / 语句 / 任务** 做
>   全面展示，产出素材。
> - **dump-analysis skill**（`.github/skills/dump-analysis`）= 基于这些素材去分析 dump 的
>   **原因与根因（cause & root cause）**。原因/根因永远由 dump-analysis 负责，本 skill 不碰。
>
> **明确不做（NEVER）:**
> - ❌ 不判断 dump 是怎么产生的、为什么会 crash / hang。
> - ❌ 不下任何根因结论、不猜测问题、不给「疑似原因」。
> - ❌ 不做子系统深挖（memory / HADR / scheduler / locking / IO …）。
> - ❌ 不写「关键观察」「怀疑」「可能是」这类推断性结论。
>
> **只做（ONLY）:** 遍历每个线程 → 归类 worker/task 状态 → 枚举 bound SOS_Tasks →
> 枚举异常/exception → 解码正在执行的 T-SQL → **把线程、资源、异常、语句、任务五类事实
> 列成表**。判断、原因、根因、深挖一律交给 **dump-analysis** skill。
>
> **产出形式：主报告 + 子报告。** 一个**主报告**汇总五类列举的概览表；每一类的完整明细
> （全部线程栈、全部任务、全部异常、每线程 T-SQL 等）写入**独立的子报告**并从主报告链接过去。
> 主报告只放概览与计数，明细进子报告。

This skill reproduces the **DumpViewer** tool's "run the whole dump, get the global
result" pass — the part that is **independent of what the specific problem is**. It
walks every thread, classifies worker/task state, enumerates bound SOS_Tasks, and
decodes the running T-SQL, producing a multi-section snapshot **（纯列举，不含任何分析/结论）**:

- **第一步：OS 线程形态清单（mex us）** — thread inventory + SQLOS worker-state
  (stack-inferred)（纯计数，不解读）.
- **第二步：`Tasks.Enumerate` dump task 清单** — authoritative bound-task TaskState
  （表 2 状态汇总 + 表 3 按调度器分布）— 权威镜像计数，非 task.js 子集.
- **第三步：执行语句线程统计（process_commands_internal）** — `task.js` sweep +
  `tsqlstack.js` + a runtime-state (blocking-chain) table.
- **第四步：调度器清单（`!execute Schedulers.Enumerate` 优先 / `sys.schedulers.js` fallback）** — SQLOS 全部调度器
  （≈ `sys.dm_os_schedulers`）：runnable/work queue 长度、yield count、当前 worker、preemptive 状态。
  **SQL2022 及以后**先试 `!execute Schedulers.Enumerate`，无输出则回退 `sys.schedulers.js`；**SQL2022 之前**直接用 `sys.schedulers.js`.
- **第五步：内存代理清单（`!execute MemoryBrokers.Enumerate`）** — 每个 memory broker（CACHE/STEAL/RESERVE）
  的 target/future/current 内存、rate、last_notification（≈ `sys.dm_os_memory_brokers`）.
- **第六步：latch 争用页面 + 线程栈联表（`dump_latch_contended_pages.js`）** — 找出发生 latch 争用的
  page（db/file/page + latch class/mode + 等待时长），再把它返回的 **thread ID** 到**第一步**的逐线程栈里反查出完整调用栈.
- **附加步骤：SOS 环形缓冲全量列举（9 条 `!execute`）** — 9 ring-buffer / summary mirrors
  （含 SchedulerMonitor 为第 5 条），每条 top-N + 规则化异常标记（与编号解耦，可在前面任意新增编号步骤而无需重编号）.

---

## 🧭 数据来源架构 · DumpViewer-FIRST（PRIMARY）+ DScript SUPPLEMENT + FALLBACK — READ BEFORE RUNNING

> **一句话：一开始就先跑 `DumpViewer.exe`，用它产出的 `dumpviewer_out\Reports\*` 数据来做报告，
> 然后只补充 DumpViewer 覆盖不到、必须跑 DScript / mirror 的步骤。** DumpViewer 自带
> CsDebugScript/dbgeng 引擎，对 **SQL 2019（较新 CU）/ 2022 / 2025** 的 dump 可直接适配；对
> **SQL 2019 早期 CU 及更早版本**无法适配 → 自动回退到完整 DScript/mirror 管线。

**三种角色（THREE ROLES）：**

- **PRIMARY = DumpViewer**（第零步，先跑）：一次性产出 `dumpviewer_out\Reports\*.html` +
  `*_json.js` 数据文件。用它的数据直接填 **第一步（线程）、第二步（任务）、附加步骤大部分（环形缓冲）**。
- **SUPPLEMENT = DScript / mirror**（补充 DumpViewer 缺的）：
  - **第三步（每线程 T-SQL 解码）永远要跑** —— DumpViewer 的 `ExecRequests` 不解码每个线程正在执行的
    T-SQL 语句文本，必须用 DScript `tsqlstack.js`。
  - **附加步骤缺的 4 条环形缓冲**（HADR AR ×2 / BlockedProcessReport / MemoryBrokerClerk /
    ProcessSummary）——DumpViewer 默认报告集不含，用 `!execute` mirror 单独补（同一批 build 可用）。
- **FALLBACK = 完整 DScript/mirror 管线**（DumpViewer 适配失败时）：`run_dumpviewer.ps1` 退出码为
  `2`（Reports 空 / 缺关键页）时，整个流程回退到本 skill 既有的 **分析第一步（`!mex.us`）/ 第二步
  （`!execute Tasks.Enumerate`）/ 附加步骤（9 条 SOS mirror）**，就当没有 DumpViewer 一样跑。

**DumpViewer 报告 → 本 skill 分节 的映射（PRIMARY 模式下的取数表）：**

| 本 skill 分节 | 覆盖度 | DumpViewer `Reports\` 页面（`*.html` + `*_json.js`） | 缺口 / 备注 |
|---|---|---|---|
| **第一步 OS 线程形态** | ✅ 完全覆盖 | `ThreadDetails.html` (`ThreadDe_ThreadDe_2_json.js`)、`UniqueStacks.html` (`UniqueSt_ThreadUn_4_json.js`)、`Threads.html` (`Threads_Threads_38_json.js`)、`SystemThreads.html` | `ThreadDetails` 已含 `worker_state/worker_last_wait/task_state/call_stack` 的组合联表（= `MiniDumpData.GetThreadDetails`），`UniqueStacks` = `!mex.us` 的按栈聚合等价视图 |
| **第二步 Tasks 清单** | ✅ 完全覆盖 | `Tasks.html` (`Tasks_Tasks_21_json.js`)、`ActiveTasks.html` (`ActiveTa_ActiveTa_32_json.js`)、`WaitingTask.html` (`WaitingT_WaitingT_22_json.js`) | 等价于 `!execute Tasks.Enumerate`（同引擎） |
| **第三步 执行语句线程** | ❌ 不覆盖 | （`ExecRequests.html` 仅列请求，不解码每线程 T-SQL 文本） | **永远跑 DScript** `task.js` + `tsqlstack.js`（第三步全套） |
| **附加步骤 SOS 环形缓冲** | 🟡 部分覆盖 | `SchedRingRecords.html`、`MonitorRingRecords.html`、`OOMRingRecords.html`、`MemBrokerRingRecords.html`、`SchedMonitors.html` | DumpViewer 覆盖 5 类；**缺 4 条**（HADR AR Publish/Signal、BlockedProcessReport、MemoryBrokerClerk、ProcessSummary）→ 用 `!execute` mirror 补 |

> **读取 DumpViewer 数据的方法：** 每个报告表都有一个 JS 数据侧车文件
> `X_..._json.js`（`var var_... = [{ header, multiLineCols, data }];`，是 JS 对象字面量、非严格
> JSON）。用committed helper 把它转成干净 JSON：
> `node .github\skills\dump-overall\scripts\parse_dumpviewer_json.js <sidecar.js> --out out.json`
> （加 `--array` 输出原始行数组）。后续生成器消费这些 JSON 即可。

---

> **Reference implementation:** `SqlTelemetry/Src/Tools/DumpViewer/DumpViewer.cs`
> (namespace `CsDebugScript.DumpViewer`) — this skill expresses the same overall analysis
> as headless cdb / SqlScriptRepl commands.
>
> **Handoff:** 本 skill 产出的五类列举（线程/资源/异常/语句/任务）是 **素材**；基于这些
> 素材去判断 dump 的 **原因与根因（cause & root cause）** 由 **dump-analysis** skill
> （`.github/skills/dump-analysis`）完成。本 skill 故意不决定任何根因 — 它只产出全局快照。

## Symbol Server Path → single-sourced in `reference/setup.md`

> The symbol path (`srv*C:\Symbols*https://symweb.azurefd.net`), the symweb-internal /
> msdl warning, and the sympath-ordering rule are single-sourced in
> [`reference/setup.md`](reference/setup.md) §Symbol Path. Read it there.

## Required Inputs

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `dump_path` | string | Yes | Path to the dump file (`.mdmp`/`.dmp`) |
| `case_id` | string | No | Case identifier for output naming |
| `dumpviewer_path` | string | **PRIMARY — always try first** | Folder holding `DumpViewer.exe`, default `C:\Users\lduan\tools\DumpViewer` (**ASK the user**, this as default). Runs first via `run_dumpviewer.ps1` → `dumpviewer_out\`. Supplies 第一/二步 + most of the 附加步骤. |
| `dscript_path` | string | When running `task.js` / `tsqlstack.js` | Folder holding the DScript `.js` scripts, e.g. `C:\Tools\dscript\sql2019`. **Build-specific** — must match the dump's product major version. Needed for 第三步 (always) and the FALLBACK pipeline. |
| `mex_path` | string | FALLBACK only (`!mex.us` 第一步) | Folder holding `mex.dll`, e.g. `C:\Tools\mex`. Used by `.load {mex_path}\mex.dll` **only when DumpViewer fails** and 第一步 runs via mirror/mex. |
| `wdbgcs` | string | When running `Tasks.Enumerate` (FALLBACK 1.5.5) + the 4 missing rings | Folder holding `WinDbgCsExt.dll` + `NetStandard20Refs\SqlCsScripts.dll` + `NetStandard20Refs\SqlDebugTypes.dll`, e.g. `C:\Tools\WinDbgCs` (**v3.2.7** for SQL 2019, NOT v4.11.0 amd64). The mirror pair must be **build-matched** to the dump (verify `True True`). |

> **`dscript_path` / `mex_path` are machine- and build-specific — ASK the user** for the
> folder if not provided; do NOT hardcode. Pick the `dscript_path` sub-folder matching the
> dump's SQL major version (`...\sql2019\`, `...\SQL2016\`, …). All `!dscript.run` examples
> use `{dscript_path}`; all `.load` examples use `{mex_path}\mex.dll`.

---

## 🔒 执行顺序与交互契约 · Canonical Run Order & Interaction Contract （每次必须逐条执行，不得跳过 / 重排）

> This is the **authoritative sequence** for every dump-overall run — follow it top-to-bottom.
> The detailed mechanics live in the referenced sections below; this table fixes only the
> **order** and the **pause points**. There are up to **FOUR ⏸️ user-input pauses** (P2 fires
> **only in FALLBACK mode** — in PRIMARY/DumpViewer mode the task list comes from DumpViewer
> with no pause). At each ⏸️ you MUST print what the user reviews, then **STOP and WAIT** for
> their answer before continuing. **Never batch past a ⏸️, never silently pick a default,
> never merge two pauses.**

| # | Phase / 章节 | What you do | ⏸️ PAUSE — ask & WAIT |
|---|--------------|-------------|------------------------|
| 1 | **Step 0 Pre-Check** | Collect machine-specific paths, then verify each exists (`True`) | ⏸️ **P1** — ASK `{dump_path}`, `{dumpviewer_path}` (default `C:\Users\lduan\tools\DumpViewer`), `{dscript_path}`, and (FALLBACK) `{mex_path}` / `{wdbgcs}` (candidate defaults are suggestions only — the user's answer wins). Then run the pre-check; required paths must be `True` before proceeding. |
| 2 | **第零步 (PRIMARY) DumpViewer.exe** | `run_dumpviewer.ps1` → `{case}_dump_overall\dumpviewer_out\`. **Auto mode gate:** exit `0`=SUCCESS→**PRIMARY mode**; exit `2`=**FALLBACK mode** (early 2019 CU / older build). | — automated, **no pause** (the mode gate is auto-detected from the exit code) |
| 3 | **Step 1 Session Setup** | Resolve `cdb.exe`, register DScript CLSIDs (HKCU), launch headless session — needed for the 第三步 DScript supplement + the 4 missing rings (PRIMARY) or the full pipeline (FALLBACK) | — automated, **no pause** |
| 4 | **第一步 线程形态** | **PRIMARY:** `parse_threaddetails_states.ps1` on `threaddetails.json`(权威 `worker_state`)→ 表 1;表 2 功能分类读 DumpViewer `*Threads` 侧车;link native `ThreadDetails.html` + `UniqueStacks.html`(no `_us.html`). **If parser exits 2**(ThreadDetails empty)→ FALLBACK. **FALLBACK:** `!mex.us` → classify SQLOS worker-state → `parse_us_states.ps1` + `gen_us_html.ps1` → `{case}_us.html`;表 2 功能分类用 `classify_thread_categories.ps1` 复现. **两模式:只内联命中功能桶的线程完整栈** | — automated, **no pause** |
| 5 | **第二步 Tasks 清单** | **PRIMARY:** parse DumpViewer `Tasks`/`ActiveTasks` sidecars (no pause). **FALLBACK:** run `run_windbgcs_tasks.ps1`; if `!dcs_initsymsvr` 404s, seed the build-matched mirror pair with `acquire_mirrors.ps1` and rerun via `run_windbgcs_direct.ps1`; then generate `{case}_tasks.html` + 表 2/3 fragments. | ⏸️ **P2 (FALLBACK only)** — FIRST print the resolved **(b) 手工 WinDbg block** (`{wdbgcs}`/`{dump_path}` substituted; mirror pair verified `True True`), THEN ask **手工粘结果 vs 自动跑**. manual → wait for pasted output; auto → run **(a) `run_windbgcs_tasks.ps1`**. If auto fails because the SymSvrManifest is missing (404), this is setup fallback, not a new user pause: run `acquire_mirrors.ps1` + `run_windbgcs_direct.ps1` and continue. In PRIMARY mode this row is **skipped**. |
| 6 | **第二步 1.5.6 按调度器分布** | Pivot the SAME 第二步 rows by `SchedulerId` (DumpViewer or FALLBACK source) | — **reuse** step-5 result — NO re-acquisition, **NO second pause** |
| 7 | **第三步 1.7.1–1.7.2 task.js sweep** | **ALWAYS runs** (DumpViewer does not decode per-thread T-SQL). Identify exec mains + parallel children, `gen_task_sweep.ps1` | ⏸️ **P3** — ASK **auto (cdb headless) vs manual (WinDbg `$$><`)**. Both write the SAME `.logopen` file; you parse that file either way. This choice also governs the tsqlstack sweep (1.7.4). |
| 8 | **第三步 1.7.3–1.7.5** | Parse → `task_fields.json`; `tsqlstack.js` per main → `{case}_sql_exec_thread.html`; build the two report tables | — automated (runs per the P3 choice), **no pause** |
| 9 | **第四步 · 调度器清单 (`Schedulers.Enumerate` 优先 / `sys.schedulers.js` fallback)** | SQLOS 调度器清单（≈ `sys.dm_os_schedulers`）。**SQL2022+：** 先 `!execute Schedulers.Enumerate`，无输出→回退 DScript。**SQL2022 之前：** 直接用 `run_dscript_once.ps1 -ScriptPath {dscript_path}\sys.schedulers.js -EndMarker 'END SYS.SCHEDULERS'`。 | — automated (reuse P3 / mirror session), **no pause** |
| 10 | **第五步 · 内存代理清单 (`MemoryBrokers.Enumerate`)** | `!execute MemoryBrokers.Enumerate` when mirror supports it; otherwise run `run_dscript_once.ps1 -ScriptPath {dscript_path}\sys.dm_os_memory_brokers.js -EndMarker 'END MEMORY BROKERS'`. | — automated (reuse mirror / DScript session), **no pause** |
| 11 | **第六步 · latch 争用页面 + 线程栈联表 (`dump_latch_contended_pages.js`)** | Run `run_dscript_once.ps1 -ScriptPath {dscript_path}\dump_latch_contended_pages.js -EndMarker 'END LATCH CONTENDED PAGES'`; then join returned thread IDs back to 第一步 stacks. If it prints `No pages found`, keep that raw evidence and still generate the latch subreport. | — automated (reuse P3 session), **no pause** |
| 12 | **附加步骤 · SOS 环形缓冲** | **PRIMARY:** 5 rings from DumpViewer (`SchedRing`/`MonitorRing`/`OOMRing`/`MemBrokerRing`/`SchedMonitors`) + the **4 missing** via `!execute` (HADR AR ×2 / BlockedProcessReport / MemoryBrokerClerk / ProcessSummary). **FALLBACK:** all 9 via `build_ringbuf_reports.ps1`. | — **reuse** step-5's choice (FALLBACK) or run the 4 supplement `!execute` (PRIMARY), **NO new pause** |
| 13 | **DoD Gate** | Paste + tick the DEFINITION-OF-DONE checklist | — mandatory self-check, **not a pause** |
| 14 | **Report Generation + Completion Gate** | Assemble the fixed artifact set, then run the single canonical entry point `finalize_dump_overall.ps1`. It generates/regenerates MAIN + 9 ring subreports, runs the ledger-gated generator, executes `verify_case_deliverables.ps1 -Stage Completion`, and atomically publishes a SHA-256-bound `overall_completion_receipt.json` only after PASS. | ⏸️ **P4** — ASK **language (English / 中文)** + **format (HTML / Markdown)**, THEN write and validate the report. |
| 15 | **POST-OVERALL first-pass probes + branch-hints report** | **Only after row 14 PASS.** Run the single canonical entry point `run_post_overall_branch_hints.ps1`. It verifies the Gate A receipt/hash, runs `run_first_pass_probes.ps1`, generates the separate report, validates Gate B, and proves the Gate A report hash is unchanged. | — automated, **no pause**; failures are isolated to Gate B evidence and MUST NOT invalidate or rewrite the completed overall gate |

> **Latch dump hard gate:** for latch-timeout or latch/page-contention dumps, the DoD verifier
> must include `-RequireSchedulerInventory -RequireLatchContendedPages`. DumpViewer latch pages
> are optional side evidence and do not replace `sys.schedulers.js` / `Schedulers.Enumerate` or
> `dump_latch_contended_pages.js` output.

### 固化脚本执行清单 · Stabilized script runbook

The table above is the workflow contract; the concrete script chain below is the stable path
validated on SQL2016 latch-timeout and SQL2019 CU20 Stalled Dispatcher dumps. Do not replace
these steps with ad-hoc parsing or one-off HTML generation.

1. **Pre-flight / setup** — initialize `workflow_ledger.json` first with
  `initialize_overall_workflow_ledger.ps1`; run `pre_check.ps1`; run `register_dscript.ps1`; resolve `cdb.exe`,
  `mex.dll`, `WinDbgCsExt.dll`, `{dscript_path}`, `{sym_path}`, and the archive output folder
  under `C:\Users\lduan\sqlcsi-archive\reports\<case>_<brief_words>\`.
2. **DumpViewer primary** — run `run_dumpviewer.ps1`. Exit `0` means consume DumpViewer
  sidecars with `parse_dumpviewer_json.js` / `parse_threaddetails_states.ps1`; exit `2` means
  switch to the fallback path without marking the run failed.
3. **Fallback thread/task inventory** — run `run_mex_us.ps1` -> `parse_us_states.ps1` ->
  `gen_us_html.ps1` -> `shred_mex_us.ps1` -> `classify_thread_categories.ps1` ->
  `gen_thread_categories_html.ps1`. The category page must emit stable `cat-<key>` anchors
  for every bucket, including empty buckets.
4. **Tasks.Enumerate fallback** — run `run_windbgcs_tasks.ps1`. If `!dcs_initsymsvr` returns a
  missing `SqlCsScripts.SymSvrManifest.dll` / 404, run `acquire_mirrors.ps1 -Build <version>
  -Product <SQLServerYYYY> [-CaseDir <case folder>]`, then rerun `Tasks.Enumerate` with
  `run_windbgcs_direct.ps1 -Scripts <...\NetStandard20Refs\build_<version>\SqlCsScripts.dll>`.
  Preserve the failed init log as evidence; the direct-load output becomes authoritative when
  it contains the pipe-table rows. Generate `{case}_tasks.html` with `gen_tasks_full_html.ps1`
  and the overall Table 2/3 fragments with `emit_tasks_tables_html.ps1`.
5. **SQL execution threads** — normally derive exec mains and parallel children from the
  authoritative `Tasks.Enumerate` rows. **Only when `Tasks.Enumerate` is unavailable/null**
  (for example 0 rows from a filtered minidump), fall back to 第一步 `!mex.us` and use the
  skill-defined stack rules to build the sweep input:
  `extract_exec_sweep_threads_from_us.ps1 -UsTxt {case}_us.txt -OutThreads {case}_exec_sweep_threads.txt -OutJson {case}_exec_sweep_threads.json`.
  The fallback extractor marks MAIN threads whose stack matches `sqllang!process_request`,
  `CSQLSource::Execute`, or `sqllang!process_commands/process_commands_internal`, and CHILD
  threads whose stack matches the parallel-worker rule (`sqlmin!SubprocEntrypoint` / CX* exchange
  frames) without a main marker. Use the resulting comma-separated `TID:ROLE` list as
  `-Threads` for `gen_task_sweep.ps1 -Script task.js -Run ...`; parse with
  `parse_task_fields.ps1`. Then run `gen_task_sweep.ps1 -Script tsqlstack.js` over the parsed
  MAIN tids from `task_fields.json`. Retry unfinished threads with `-ShardSize 1` or
  `-RunPerThread`; keep `DSCRIPT_SHARD_TIMEOUT` / COM read-fault blocks as evidence. Parse with
  `parse_tsqlstack.ps1 -Log ... -Out ...`, then build `build_sql_exec_manifest.ps1` ->
  `gen_sql_exec_html.ps1`. A stack-signature HTML/list is diagnostic only; it is not a substitute
  for running `task.js` and `tsqlstack.js` on the selected fallback thread list.
6. **Bounded single DScript supplements** — run `run_dscript_once.ps1` for
  `sys.schedulers.js`, `sys.dm_os_memory_brokers.js`, and `dump_latch_contended_pages.js`, each
  with an explicit `-EndMarker`. Marker reached + cdb stuck at prompt is success; kill only the
  idle prompt and keep the log.
7. **Ring buffers / raw evidence** — run `run_windbgcs_direct.ps1` for build-matched mirror
  expressions when automatic init cannot adapt. Then call the single finalizer
  `finalize_ringbuf_reports.ps1`; it auto-splits combined direct logs into
  `txt_detail\{case}_{expr}.txt`, runs `build_ringbuf_reports.ps1`, regenerates the MAIN report,
  and runs the verifier. The MAIN report must show each expression as a categorized section with
  `top 20` + rule-based anomaly rows; `direct_mirror.html` / raw txt is evidence only, not the
  user-facing result.
8. **Final assembly / Gate A** — run `finalize_dump_overall.ps1` with the manifest, ledger,
  ring `txt_detail` folder, and applicable requirement switches. This is the only canonical
  finalization entry point. It must produce MAIN + subreports, pass Completion, and atomically
  publish `overall_completion_receipt.json`; report existence alone is not completion.
9. **Post-overall branch hints / Gate B (separate, best effort)** — only after step 8 PASS,
  run `run_post_overall_branch_hints.ps1`. It verifies the receipt-bound overall SHA-256 before
  probes and again after report generation. The branch report and probe status are not members
  of the overall completion ledger. A failed/unavailable probe is retained separately and never
  deletes, regenerates, or downgrades `<case>_overall_report.html`.

### Reproducible final command chain（validated on case 2606220030003771）

After Steps 0–12 have produced their fixed artifacts, the following is the required chain for
the same FALLBACK/English report layout. Do not hand-write the ledger, MAIN HTML, receipts, or
branch report:

```powershell
# Run start (before Step 0)
pwsh -File .github\skills\dump-overall\scripts\initialize_overall_workflow_ledger.ps1 `
  -CaseId '{case_id}' -OutDir '{case_dump_overall}'

# After each acquisition phase (example; repeat for each requiredSteps item)
pwsh -File .github\skills\dump-overall\scripts\set_overall_workflow_status.ps1 `
  -Ledger '{case_dump_overall}\workflow_ledger.json' `
  -Group requiredSteps -Name step1_os_threads -Status done

# Build the dump-specific manifest from the fixed FALLBACK artifacts
pwsh -File .github\skills\dump-overall\scripts\build_overall_manifest_from_artifacts.ps1 `
  -CaseId '{case_id}' -Dir '{case_dump_overall}' `
  -DumpName '{dump_name}' -SqlVersion '{sql_version}' `
  -Mode 'FALLBACK' -CaptureTime '{capture_time}'

# Gate A: MAIN + all fixed subreports + Completion PASS + SHA-256 receipt
pwsh -File .github\skills\dump-overall\scripts\finalize_dump_overall.ps1 `
  -CaseId '{case_id}' -OutDir '{case_dump_overall}' `
  -RequireThreadCategories -RequireSqlExec -RequireSchedulerInventory

# Gate B: only after Gate A receipt; isolated probes + branch report + hash check
pwsh -File .github\skills\dump-overall\scripts\run_post_overall_branch_hints.ps1 `
  -CaseId '{case_id}' -OutDir '{case_dump_overall}' -Dump '{dump_path}'
```

For latch/page-contention cases, add `-RequireLatchContendedPages` to Gate A. With unchanged
evidence, repeated Gate A runs must produce the same MAIN SHA-256, and repeated Gate B runs
must produce the same branch-report SHA-256 while recording identical Gate A before/after hashes.

### POST-OVERALL first-pass mirror probes & branch hints（独立报告，纯信号归桶）

⛔ **Ordering hard gate:** do not run this section until the previously defined dump-overall
MAIN report and all fixed subreports have been generated and
`verify_case_deliverables.ps1 -Stage Completion` has printed PASS. Persist that PASS as
`overall_completion_receipt.json`. This post-overall phase is isolated: probe failures must not
change the overall ledger, rewrite the overall report, or turn the completed overall PASS into
a failure.

After that gate, preserve the following general first-pass probes as raw evidence. These probes
are **coverage**, not root-cause analysis. They help the next `dump-analysis` step choose a route
without re-opening broad discovery.

```windbg
!execute Times.Enumerate
!execute TraceFlags.Enumerate
!execute Sessions.Enumerate
!execute Tasks.Enumerate
!execute Workers.Enumerate
!execute Schedulers.Enumerate
!execute MemoryNodes.Enumerate
!execute SOSNodes.Enumerate
!execute SOSRingBuffers.EnumerateExceptionRingRecords
!execute ExceptionContext.CurrentStack
!execute ExceptionContext.Enumerate
!execute ExceptionHandlerStacks.Enumerate
```

Optional probes should be captured when the script is available and the current dump type can
support them. If a probe returns no rows or is unavailable in a minidump, keep that raw result
as evidence instead of substituting another conclusion:

```windbg
!execute MemoryClerks.Enumerate
!execute MemoryObjects.Enumerate
!execute LeakedAllocations.Enumerate
!execute DbccInputBuffers.Enumerate
!execute QueryPlans.Enumerate
!execute QueryExecutionTrees.Enumerate
```

The separate branch report MUST expose **two independent axes**; never collapse them into one
green `signal-present` badge:

1. **Data coverage** — `data-present`, `empty-result`, or `unavailable-with-evidence`.
  This says only whether rows/artifacts were captured. A full Tasks, exception-ring,
  MemoryBroker, or HADR history is ordinary inventory and is not an abnormality by itself.
2. **Routing relevance** — `route-signal`, `context-only`, `no-route-signal`, or
  `unavailable-with-evidence`. A route signal requires a branch-specific predicate (for
  example `SMR_NONYIELD*`, OOM marker, abnormal current HADR role/exception, or a
  Spinlock/Backoff stack). It selects a downstream review path; it still does not prove cause.

Every bucket must include a plain-language `routingReason`. The report must not use root-cause
or probability language.

| Branch bucket | First-pass evidence sources | Downstream route |
|---|---|---|
| Exception / AV / dump reason | `ExceptionContext.CurrentStack`, `ExceptionContext.Enumerate`, `ExceptionHandlerStacks.Enumerate`, exception ring records, current `.ecxr` stack when captured | `dump-analysis` exception / call-stack route |
| Scheduler / non-yield | `Schedulers.Enumerate`, `Workers.Enumerate`, SchedulerMonitor / Scheduler ring records, copied-stack records if available | scheduler / non-yield route |
| Memory / OOM / leak | `MemoryNodes.Enumerate`, `MemoryClerks.Enumerate`, `MemoryObjects.Enumerate`, `LeakedAllocations.Enumerate`, OOM / MemoryBroker ring records | memory / OOM / leak route |
| Query execution | active sessions/tasks, `DbccInputBuffers.Enumerate`, `QueryPlans.Enumerate`, `QueryExecutionTrees.Enumerate`, `task.js`, `tsqlstack.js`, `process_commands` stacks | query execution route |
| Blocking / latch / locking | `Tasks.Enumerate`, `Workers.Enumerate`, `WaitingTask`/blocked-process rings when available, latch-contended-pages output, lock/latch stack groups | locking / latch route |
| HADR / AG | HADR ring buffers, HADR-related stacks or sessions, AG-related errors in exception/ring output | HADR route |
| IO / storage / transaction log | IO-related waits/stacks, `PendingIOs` when available, `WriteFileGather`, `WRITELOG`, log-manager frames, storage/IO ring output | IO / log route |
| SQLPAL / Linux | Linux core/archive shape, SQLPAL modules, `SqlpalDebuggerTool`-generated context | SQLPAL workflow |

**Canonical committed entry point (Gate B):**

```powershell
pwsh -File .github\skills\dump-overall\scripts\run_post_overall_branch_hints.ps1 `
  -Dump '{dump_path}' -OutDir '{case_dump_overall}' -CaseId '{case_id}'
```

The orchestrator calls `run_first_pass_probes.ps1` →
`gen_first_pass_branch_hints_report.ps1` → `verify_first_pass_branch_hints.ps1` internally.
Do not bypass it in normal runs.

The second command always creates a **separate** branch report and JSON sidecar:

- `<case>_first_pass_branch_hints.html`
- `<case>_first_pass_branch_hints.json`
- `<case>_first_pass_probe_status.json`
- `<case>_first_pass_probes.txt` + `first_pass_probe_sections\*.txt`
- `first_pass_branch_completion_receipt.json`（Gate B PASS + Gate A hash unchanged）

These files are post-overall routing artifacts, not required members of the fixed dump-overall
artifact set or its completion ledger.

> ⛔ Boundary: branch hints are only an index over first-pass evidence. They do not say the
> problem “is” memory, HADR, scheduler, etc.; they say which evidence bucket exists and which
> downstream deep-dive should consume it. `dump-overall` still produces facts only.

> ⛔ **Gate discipline (验证过的行为):** In **PRIMARY mode** P2 does not fire — the task list
> comes from DumpViewer. In **FALLBACK mode** P2 is the only gate where you emit a paste-ready
> block **before** asking; running the automated path (a) before emitting (b) and pausing is a
> **violation**. P1/P3/P4 ask a plain choice. If the user chose **manual** at P2 or P3, do NOT
> run the auto path — wait for their pasted result / "done" and read the file they targeted.

---

## Step 0 & Step 1 (setup) → `reference/setup.md`

> **All setup — Symbol Path · Step 0 Pre-Check (tool inventory + install prompts) · Step 1
> Session Setup (cdb resolution + DScript COM registration + Path A/B) · Step 1 fallback
> (mirror-404 build-share load) — is single-sourced in
> [`reference/setup.md`](reference/setup.md).** This file lives INSIDE this skill, so
> `dump-overall` is self-contained whether it runs standalone or is invoked by the
> `dump-analysis` agent. Run it FIRST (respecting the P1 pause gate in the Canonical Run
> Order above), then continue with 分析第零步 below.

> **This skill is DumpViewer-FIRST (PRIMARY).** In setup, the surface that matters here is
> **`DumpViewer.exe`** (`{dumpviewer_path}`, default `C:\Users\lduan\tools\DumpViewer`) for
> 分析第零步 + 第一/二步 + most 附加步骤, plus **DScript `.js`** (`{dscript_path}`) for 第三步.
> The **mex.dll / WinDbgCsExt / SqlScriptRepl** surfaces in setup.md are **FALLBACK-only**
> (used only if DumpViewer can't run and the pass enters FALLBACK mode). Committed helper
> scripts live under `.github/skills/dump-overall/scripts/` (`pre_check.ps1`,
> `run_mex_us.ps1`, `register_dscript.ps1`, `acquire_mirrors.ps1`,
> `run_windbgcs_direct.ps1`, `split_direct_mirror_log.ps1`, `finalize_ringbuf_reports.ps1`,
> `build_sqlscriptrepl.ps1`) — setup.md points at them.

---

## 分析第零步（PRIMARY）：运行 DumpViewer.exe → dumpviewer_out · Run DumpViewer FIRST

> **This runs BEFORE 第一步/第二步/附加步骤.** DumpViewer.exe opens the dump with its own
> CsDebugScript/dbgeng engine and emits a full static-HTML report bundle. We build the report
> **primarily from that data**, then only supplement the gaps. If DumpViewer cannot adapt to
> the build (early SQL 2019 CU / older), we AUTO-FALL BACK to the full DScript/mirror pipeline
> (分析第一步/第二步/附加步骤 below), exactly as if DumpViewer did not exist.

### 0.1 Run the committed driver

⛔ **No ad-hoc DumpViewer invocation.** Run the committed driver — it resolves
`DumpViewer.exe`, runs it against the dump into `{case}_dump_overall\dumpviewer_out\`, verifies
the key report pages exist, and returns the **mode gate** via its exit code:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\run_dumpviewer.ps1 `
  -Dump       '{dump_path}' `
  -OutDir     'C:\Users\lduan\sqlcsi-archive\reports\{case_id}_dump_overall' `
  -DumpViewer '{dumpviewer_path}'    # default C:\Users\lduan\tools\DumpViewer
```

**Mode gate (auto-detected from the exit code):**

| Exit | Mode | Meaning | Next |
|------|------|---------|------|
| `0` | **PRIMARY** | `dumpviewer_out\Reports\` has `ThreadDetails.html` + `UniqueStacks.html` + `Tasks.html` + `Threads.html` | Build 第一/二步 + 5 rings of the 附加步骤 from DumpViewer; run DScript only for 第三步; run `!execute` only for the 4 missing rings. |
| `2` | **FALLBACK** | DumpViewer failed / timed out / key pages missing (early 2019 CU / older build) | Ignore DumpViewer; run the FULL DScript/mirror pipeline (分析第一步 `!mex.us` / 第二步 `Tasks.Enumerate` / 附加步骤 9 mirrors) as written below. |
| `1` | HARD ERROR | `DumpViewer.exe` or the dump not found | Fix the path (go back to P1) and retry. |

### 0.2 (PRIMARY only) Read the DumpViewer report data

Each report table has a JS data sidecar `Reports\X_..._json.js`. Convert the ones we consume to
clean JSON with the committed helper (`--array` keeps rows as raw arrays for the big tables):

```powershell
$dv = 'C:\Users\lduan\sqlcsi-archive\reports\{case_id}_dump_overall\dumpviewer_out\Reports'
# 第一步 (threads)
node .github\skills\dump-overall\scripts\parse_dumpviewer_json.js "$dv\ThreadDe_ThreadDe_2_json.js"  --array --out "$dv\..\threaddetails.json"
node .github\skills\dump-overall\scripts\parse_dumpviewer_json.js "$dv\UniqueSt_ThreadUn_4_json.js"  --array --out "$dv\..\uniquestacks.json"
# 第二步 (tasks)
node .github\skills\dump-overall\scripts\parse_dumpviewer_json.js "$dv\Tasks_Tasks_21_json.js"       --array --out "$dv\..\tasks.json"
node .github\skills\dump-overall\scripts\parse_dumpviewer_json.js "$dv\ActiveTa_ActiveTa_32_json.js" --array --out "$dv\..\activetasks.json"
# 附加步骤 (5 rings DumpViewer covers)
node .github\skills\dump-overall\scripts\parse_dumpviewer_json.js "$dv\SchedRin_SchedRin_28_json.js" --array --out "$dv\..\schedring.json"
node .github\skills\dump-overall\scripts\parse_dumpviewer_json.js "$dv\MonitorR_MonitorR_31_json.js" --array --out "$dv\..\monitorring.json"
node .github\skills\dump-overall\scripts\parse_dumpviewer_json.js "$dv\OOMRingR_OOMRingR_30_json.js" --array --out "$dv\..\oomring.json"
node .github\skills\dump-overall\scripts\parse_dumpviewer_json.js "$dv\MemBroke_MemBroke_29_json.js" --array --out "$dv\..\membrokerring.json"
node .github\skills\dump-overall\scripts\parse_dumpviewer_json.js "$dv\SchedMon_SchedMon_27_json.js" --array --out "$dv\..\schedmonitors.json"
```

> The `*_json.js` sidecar names carry a numeric suffix DumpViewer assigns per run — if a name
> above doesn't resolve, list `Reports\*_json.js` and match by the report prefix
> (`ThreadDe`/`UniqueSt`/`Tasks`/`ActiveTa`/`SchedRin`/`MonitorR`/`OOMRingR`/`MemBroke`/`SchedMon`).

**What each section then does in PRIMARY vs FALLBACK mode:**

- **第一步** — PRIMARY: run `parse_threaddetails_states.ps1` on `threaddetails.json` for the
  authoritative `worker_state` 表 1, and link DumpViewer-native `ThreadDetails.html` +
  `UniqueStacks.html` as the detail pages (skip `!mex.us`, no `_us.html`). 表 2 · 线程功能分类
  reads DumpViewer's `*Threads` sidecars directly. **If that parser
  exits 2** (ThreadDetails empty / `worker_state` blank on every row) → FALLBACK to `!mex.us` →
  `parse_us_states.ps1` + `gen_us_html.ps1` → `_us.html` and link that instead, and derive 表 2
  via `classify_thread_categories.ps1` on the `!mex.us` stacks (1.5.0). FALLBACK
  (whole-dump): run `!mex.us` as written below. **Only threads that hit a functional bucket get
  their full stack inlined** (grouped by category); regular/idle threads are not expanded. Both
  paths are retained.
- **第二步** — PRIMARY: feed `tasks.json` / `activetasks.json` into the tables (skip the P2 gate).
  FALLBACK: run the `!execute Tasks.Enumerate` EMIT-B-THEN-PAUSE gate below.
- **第三步** — ALWAYS run DScript `task.js`/`tsqlstack.js` below (DumpViewer does not decode
  per-thread T-SQL).
- **附加步骤** — PRIMARY: use the 5 ring JSONs above + run `!execute` for the **4 missing** rings
  (HADR AR Publish/Signal, BlockedProcessReport, MemoryBrokerClerk, ProcessSummary). FALLBACK:
  run all 9 via `build_ringbuf_reports.ps1`.

---

## 分析第一步（报告「第一步」）：OS 线程形态清单（mex us） · Thread Inventory & State Statistics

> **PRIMARY (DumpViewer) mode:** source from `threaddetails.json` / `uniquestacks.json`
> (第零步 0.2) and SKIP `!mex.us` — `ThreadDetails` already carries per-thread
> `worker_state`/`worker_last_wait`/`task_state`/`call_stack` (= `MiniDumpData.GetThreadDetails`,
> the engine-authoritative `SOS_Worker.m_state`, better than stack inference), and
> `UniqueStacks` is the by-stack aggregation equivalent to `!mex.us`. Run
> **`parse_threaddetails_states.ps1`** (1.5.3 PRIMARY) for 表 1, and link the DumpViewer-native
> **`dumpviewer_out/Reports/ThreadDetails.html`** (per-thread) + **`UniqueStacks.html`** (per-stack)
> as the 第一步 detail pages. In PRIMARY mode there is **no `_us.html`** (that is a `!mex.us`
> artifact) — do NOT synthesize one.
>
> **⛔ EMPTINESS GATE — PRIMARY → FALLBACK per-section:** `parse_threaddetails_states.ps1` exits
> **2** when `threaddetails.json` has 0 rows OR `worker_state` is blank on *every* row (a build /
> filtered dump DumpViewer could not populate SOS state for). **On exit 2 you MUST fall back to
> the `!mex.us` path** (1.5.1–1.5.4 below): `!mex.us` → `parse_us_states.ps1` +
> `gen_us_html.ps1` → `{case_id}_us.html`, and point the main report's 第一步 detail link at
> `{case_id}_us.html` **instead of** `ThreadDetails.html`. Both paths are first-class and are
> **both retained** — PRIMARY is preferred, `!mex.us` is the guaranteed fallback.
>
> **FALLBACK mode (whole-dump, 第零步 exit 2):** run `!mex.us` as written below from the start.
>
> **Report section:** `第一步：OS 线程形态清单（mex us）`. The FIRST analysis view — works on
> **any** build (mex-based, no Mirrors required) and gives the "shape" of the process: how
> many threads exist and what state they are in. For a *Stalled Dispatcher*, *non-yield*, or
> *hung server* dump this is often decisive on its own.
>
> Three complementary views (the report shows all three) — **纯列举，不含任何推断/结论**:
> 1. **SQLOS worker-state** — stack-inferred, over *all OS threads* (1.5.1–1.5.3).
> 2. **Authoritative TaskState** — `Tasks.Enumerate` over *bound SOS_Tasks* (1.5.5).
> 3. **Per-scheduler distribution** — task counts per scheduler (1.5.6).
>
> ⛔ **只统计状态（IDLE / RUNNABLE / SUSPENDED / RUNNING / SYSTEM-*）的线程数与任务数**，
> 不判断哪个是「根因/症状」、不猜「为什么」、不给「下一步 pivot」。任何推断交给 dump-analysis。

### 1.5.0 表 2 · 线程功能分类（DumpViewer buckets ↔ FALLBACK stack classifier）

第一步除了「表 1 · worker-state 分布」外，还给出「**表 2 · 线程功能分类**」——把 OS 线程按
**功能桶**归类（IOCP / NetworkIO / FileIO / Backup / Checkpoint / LazyWriter / Latch / Exception /
Monitor / Parallel / Busy / NonYield）。一个线程可同时命中多个桶(如并行备份 worker 同时进 Backup
与 Parallel)。**纯客观归类,不含根因**。

- **PRIMARY (DumpViewer):** 直接读 DumpViewer 内建的 `*Threads.html` 侧车
  (`BusyThreads`/`NonYieldThreads`/`LatchThreads`/`InParallelThreads`/`FileIOThreads`/
  `NetworkIOThreads`/`IOCPThreads`/`BackupThreads`/`CheckpointThreads`/`LazyWriterThreads`/
  `MonitorThreads`/`ExceptionThreads`)——每个侧车列 `id, call_stack`。用侧车里的 `id` 列即得每桶
  线程 ID(解析同 0.2 的 `_json.js`,行首 `  [ <id> ,`)。
- **FALLBACK (`!mex.us`):** DumpViewer 的功能桶不存在,改用
  **`classify_thread_categories.ps1`** 在原始调用栈上**复现**同样的分类。输入既可是 DumpViewer
  `threaddetails.json`(用于校验),也可是从 `!mex.us` shred 出的 `{id, stack}` 列表。
  端到端管线(已在 843 验证):
  `shred_mex_us.ps1 -UsTxt {case}_us.txt -Out us_threads_shredded.json` →
  `classify_thread_categories.ps1 -ThreadsJson us_threads_shredded.json -Out cats.json`。
  `shred_mex_us.ps1` 解析每个 `N thread(s) [stats]: <id>[!mex.t <id>] ...` 组头(多线程组会列出全部
  id)+ 缩进帧行(去掉 `(source @ line)` 后缀),每个 id 输出一行 `{id, stack}`;mex 线程号与
  DumpViewer `thread_id` 一致(IOCP 组两边都是 22/46/51)。⚠️ `!mex.us` 对**大组**(如 843 里
  124/31/30 个线程的 IDLE/dispatcher 组)会把 `[stats]` id 列表**截断为前 ~10 个 + `...`**,故
  shred 出 169 行 < 332 线程——**无害**:被截断的都是不命中任何功能桶的空闲/系统栈,每个功能桶线程
  都在 1–6 个线程的小组里(不截断)故全部捕获。
  签名表(在栈全文上做大小写不敏感正则匹配)——已对 dump `2607030030000843` 逐桶反推验证:

  | 桶 | method | 栈签名(正则要点) | 复现度 |
  |----|--------|------------------|--------|
  | IOCP | stack | `SOS_Node::ListenOnIOCompletionPort` | ✅ 与 DumpViewer 完全一致 |
  | NetworkIO | stack | `TDSSNIClient::` `WaitOnWriteAsyncToFinish` `flush_buffer` `CTds*::Send` `SNIWriteAsync/ReadAsync` | ✅ 一致 |
  | Backup | stack | `BackupThread::` `BackupOperation::` `BackupVirtualDeviceSet` `BackupLogMediaWriter` `sqlvdi!` | ✅ 一致 |
  | Checkpoint | stack | `Checkpoint(Helper\|Loop\|RU2\|Worker\|RU)` `RegisterCheckPtWorker` | ✅ 一致 |
  | LazyWriter | stack | `BPool::LazyWriter` `!lazywriter` | ✅ 一致 |
  | Latch | stack | `LatchBase::` `Latch::Acquire` `::AcquireLatch` | ✅ 一致 |
  | Exception | stack | `KiUserExceptionDispatch` `RtlDispatchException` `_CxxThrowException` `RaiseException` `CDmpDump::` `CImageHelper::DoMiniDump` `SQLDumperLibraryInvoke` `sqllang!stackTrace` | ✅ 一致 |
  | Monitor | stack | `SchedulerMonitor::` `ResourceMonitor::` `DeadlockMonitor::` `lockMonitor` `SystemHealthMonitor` `SQLAgentMonitorThread` | ✅ 一致 |
  | Parallel | stack | `CXPort` `CXPacket` `CXTransport` `CXPipe` `CQScanExchange` `SubprocEntrypoint` | ✅ 一致 |
  | FileIO | stack | `FCB::(Async)?(Read\|Write)` `WriteFileGather` `ReadFileScatter` `AsyncDiskWorker` `DiskWorker::` | ⚠️ 部分(DumpViewer 的 FileIO 含 CLR external-access 线程,栈不可纯 IO 复现) |
  | Busy | **state** | `worker_state == WORKER_STATE_RUNNING`;FALLBACK 无 state → 栈顶未停在 work dispatcher 的近似 | ⚠️ state 口径(FALLBACK 为超集近似) |
  | NonYield | **na** | 栈不可复现 → 需 `RING_BUFFER_SCHEDULER_MONITOR` / system_health `non_yield`|`NonYieldingTask` 事件(附加步骤交叉验证) | — |

  用法:`pwsh -File classify_thread_categories.ps1 -ThreadsJson <threads.json> [-Out cats.json]`。
  9 个 stack 桶与 DumpViewer 逐 ID 一致(FALLBACK 从原始 `!mex.us` 文本亦完全一致);`Busy`(state)
  与 `NonYield`(na)是**已知降级项**——尤其 FALLBACK 无 `worker_state` 时 `Busy` 启发式会严重超集
  (843:120/169 vs DumpViewer 8),报告须标注 method,**不得**当作与 PRIMARY 等价。

- **内联规则(两种模式通用):** 第一步**只内联「命中功能桶」的线程**的完整调用栈(按功能分类分组,
  锚点 `id='thr-<桶key>-<tid>'`,表 2 的线程 ID chip 跳转至此);**其余常规/空闲线程不展开**
  (332 线程里通常只有几十个命中桶),保持报告精简。表 1 仍为全量 worker-state 汇总。

- **强制产物 / hard gate:** 生成 `thread_categories.json` 后必须立刻运行
  `gen_thread_categories_html.ps1 -UsTxt {case}_us.txt -Out {case}_thread_categories.html -CaseId {case_id}`。
  主报告的「线程功能分类」摘要表必须链接到 `{case}_thread_categories.html`，并至少包含
  `#cat-iocp` / `#cat-lat` / `#cat-mon` / `#cat-par` 这些功能桶锚点。完成前运行
  `verify_case_deliverables.ps1 -Stage Completion`；只要 `thread_categories.json` 存在，verifier 会
  强制检查明细 HTML、功能桶锚点、`<details>` stack blocks 以及主报告链接。没有这个明细页不得交付。

### 1.5.1 Capture every thread's stack with mex (to a log file)

Load `mex.dll`, then dump all unique stacks to a log. `!mex.us` groups identical stacks and
prints a per-group thread count + a `[stats]` thread-id list.

```text
.load {mex_path}\mex.dll
.logopen reports/{case_id}_us.txt
!mex.us
.logclose
```

> `!mex.us` (unique stacks) is preferred over `~*k` — it collapses hundreds of identical
> idle-worker stacks into one group, so the histogram is readable. The tail prints
> `N stack(s) with M threads displayed (M Total threads)`.

### 1.5.2 Classify each stack group into a SQLOS worker state

The OS thread state alone is not enough — classify by the **SQLOS frames** in each stack.
Heuristics (top-down, first match wins):

| State | Stack signature (SQLOS frames) | Meaning |
|-------|-------------------------------|---------|
| **IDLE** | bottoms out in `WorkDispatcher::DequeueTask` / `WorkDispatcher::WorkerIdleElem::Suspend` | Worker parked, **no task** assigned — waiting for work |
| **RUNNABLE** | has a task (`SOS_Task::Param::Execute` / `SOS_Scheduler::RunTask`) **and** `SOS_Task::OSYieldNoAbort` / `OSYield` | Task voluntarily yielded; on the **runnable queue** awaiting quantum |
| **SUSPENDED** | has a task **and** is in a wait API (`ZwWaitForSingleObject`, `SignalObjectAndWait`, `WaitForSingleObjectEx`) via `SOS_Scheduler::Suspend`/`WaitableBase::Wait`/`EventInternal`/`LockOwner::Sleep`/`SOS_Task::Sleep` | Task **blocked** on a resource (lock, latch, event, IO, sleep) |
| **RUNNING** | has a task **and** is **not** in a wait API | Task executing on CPU (rare in a dump — usually the faulting thread) |
| **SYSTEM-WAIT** | no SQLOS task, in a wait API | System/background thread waiting |
| **SYSTEM-RUNNING** | no SQLOS task, not waiting | System/background thread running |

> ⚠️ State is **stack-inferred** when Mirrors/`SOS_Worker.m_state` are unavailable (old
> builds, minidumps). State it as inferred in the report. If Mirrors load, cross-check
> against `Workers.Enumerate` / `Schedulers.Enumerate`.

### 1.5.3 Parse + summarize with PowerShell

⛔ **No ad-hoc parser.** Run the committed script — it groups `!mex.us` output by unique
stack (`^\d+ threads? \[stats\]`), applies the SQLOS worker-state table above, and emits
both a stdout summary and (optionally) a JSON that `gen_overall_report.ps1` consumes for
第一步 表 1:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\parse_us_states.ps1 `
  -Src     'reports/{case_id}_dump_code_analysis/{case_id}_us.txt' `
  -OutJson 'reports/{case_id}_dump_overall/{case_id}_us_states.json'
```

Sample stdout (validated on case 2606250030005483 — 831 threads / 82 stack groups):

```
State          Stacks Threads  Pct
-----          ------ -------  ---
IDLE                4     669 80.5
SUSPENDED          48     109 13.1
SYSTEM-WAIT         8      23  2.8
RUNNABLE           13      18  2.2
RUNNING             6       7  0.8
SYSTEM-RUNNING      3       5  0.6
```

### 1.5.4 记录（纯列举，不做解读）

> ⛔ **不写任何 Interpretation。** 本小节只把 1.5.3 的聚合结果原样落表 —
> 每个状态（IDLE / RUNNABLE / SUSPENDED / RUNNING / SYSTEM-WAIT / SYSTEM-RUNNING）的
> **stack 组数** 与 **线程数**，外加各组的代表性栈签名。不判断哪个状态「异常」、
> 不猜原因、不给 pivot 方向。

Record this stack-inferred table as the **first sub-view** of the report's 第一步
(`SQLOS Worker 状态分布`). **Do NOT stop at the flat summary counts** — the linked detail page
MUST be a **paginated, per-unique-stack, func-filterable** view. Run the skill-local generator
(⛔ **MANDATORY**, not optional — this is the `_us.html` deliverable):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\gen_us_html.ps1 `
  -Src 'reports/{case_id}_dump_code_analysis/{case_id}_us.txt' `
  -Out 'reports/{case_id}_dump_overall/{case_id}_us.html' `
  -CaseId '{case_id}'
```

It emits **one collapsible `<details>` block per unique call stack** (thread count + state tag +
representative `mod!func` signature) with a **func filter** toolbar (live substring highlight;
non-matching stacks hidden) — this is what makes dozens of unique stacks navigable and is
required so a reader can filter by function. Link `{case_id}_us.html` as the 第一步 detail page.
第一步（mex us OS 线程形态）到此结束 —— 只列举 OS 线程与 SQLOS worker 状态，不含任务级镜像。
Then continue to **分析第二步** for the authoritative task-level view.

---

## 分析第二步（报告「第二步」）：`Tasks.Enumerate` dump task 清单 · Authoritative Task List

> **PRIMARY (DumpViewer) mode:** source the task list from `tasks.json` / `activetasks.json`
> (第零步 0.2) and **SKIP the P2 gate below** — DumpViewer's `Tasks` table is the same
> `Tasks.Enumerate` view (same CsDebugScript engine). Feed those rows straight into 表 2 / 表 3.
> **FALLBACK mode:** run the `!execute Tasks.Enumerate` EMIT-B-THEN-PAUSE gate exactly as
> written below. The pivot (1.5.6) reuses whichever source was used.
>
> **Report section:** `第二步：Tasks.Enumerate dump task 清单` — 权威 bound-task TaskState
> （表 2 状态汇总 + 表 3 按调度器分布）. 这是 dump 里「服务器到底在干什么」的权威计数，
> 不是 task.js sweep 的子集。**纯列举，不解读。** 每个 case / 每个 dump 都必须产出本步。

#### 1.5.5-P · PRIMARY 取数（DumpViewer Tasks 侧栏 → 复用 FALLBACK 生成器）

DumpViewer 的 `Tasks` 侧栏与 `!execute Tasks.Enumerate` 是**同一引擎（CsDebugScript）**的
同一视图，含 `nullptr` 占位行（未绑定/已回收 worker，`task` 为真实 `0x` 地址、其余列为
`nullptr`）。为**不重复实现**统计逻辑，PRIMARY 用一个薄适配器把 `tasks.json` 转成
`gen_tasks_full_html.ps1` 接受的管道分隔格式，再跑与 FALLBACK **完全相同**的子报告生成器 +
表 2/3 片段发射器（与第一步 `shred_mex_us.ps1` → `classify_thread_categories.ps1` 同构）：

```powershell
$sk = '.github\skills\dump-overall\scripts'
$ov = 'reports\{case_id}_dump_overall'
# 1) DumpViewer tasks.json（{rows:[...]} 或裸数组均可）→ pipe 格式 <case>_tasks_enumerate.txt
pwsh -NoProfile -File "$sk\tasks_json_to_enumerate.ps1" `
     -TasksJson "$ov\parsed\tasks.json" -Out "$ov\{case_id}_tasks_enumerate.txt"
# 2) 与 FALLBACK 同一生成器 → 子报告 + <case>_tasks_stats.json 侧车
pwsh -NoProfile -File "$sk\gen_tasks_full_html.ps1" `
     -Src "$ov\{case_id}_tasks_enumerate.txt" -Out "$ov\{case_id}_tasks.html" `
     -CaseId '{case_id}' -Subtitle '{dump}.mdmp · 数据来源：DumpViewer Tasks 侧栏（等价 !execute Tasks.Enumerate）'
# 3) 表 2/表 3 片段（喂给 overall manifest 的 raw 块）——PRIMARY 传 DumpViewer 出处措辞
$hdr  = 'DumpViewer Tasks 侧栏（等价 <span class="mono">!execute Tasks.Enumerate</span>）'
$note = '数据源：<b>DumpViewer Tasks 侧栏</b>（<span class="mono">MiniDumpData</span> 任务枚举，等价 <span class="mono">!execute Tasks.Enumerate</span> 权威口径，非 <span class="mono">task.js</span> 过滤子集）。'
pwsh -NoProfile -File "$sk\emit_tasks_tables_html.ps1" `
     -Stats "$ov\{case_id}_tasks_stats.json" `
     -Out2 "$ov\parsed\{case_id}_tbl2_state_summary.html" `
     -Out3 "$ov\parsed\{case_id}_tbl3_scheduler_pivot.html" `
     -TasksLinkHref '{case_id}_tasks.html' -SourceHeaderHtml $hdr -SourceNoteHtml $note
```

> - `tasks_json_to_enumerate.ps1` 只做**形态适配**（列名 `task/scheduler_id/worker/thread/task_state/task_function` → 6 字段管道行，`task` 归一化为小写 `0x…` 以匹配生成器行正则），不重算任何统计。
> - `emit_tasks_tables_html.ps1` 的 `-SourceHeaderHtml` / `-SourceNoteHtml` **默认值 = FALLBACK 措辞**（`!execute Tasks.Enumerate` / WinDbgCs·SqlScriptRepl），所以 FALLBACK 调用**字节不变**；仅 PRIMARY 传上面的 DumpViewer 措辞。
> - **自检**：`gen_tasks_full_html.ps1` 打印 `N rows, M bound tasks; nullptr K`，其中 `N=表2/3 全量` `M=表2 分母=表3 合计` `K=N−M`；overall manifest 的第二步 note 复用同一 `<case>_tasks_stats.json`（`totalRows`/`totalBound`/`nullptrRows`），三处数字必须一致。
> - 验证过的样例（case 2607030030000843，SQL 2022）：`141 rows, 110 bound, nullptr 31`；SUSPENDED 77 / RUNNABLE 10 / RUNNING 20 / DONE 3；可见调度器 0–31 + 隐藏/系统 id≥1048576。

### 1.5.5 任务级权威状态 — `Tasks.Enumerate`（报告「任务级状态统计」）

The `!mex.us` view above counts **OS threads** with state *inferred from the stack top* (it
includes the hundreds of idle worker-pool threads). For the authoritative "what is the
server actually doing" answer, enumerate **bound SOS_Tasks** and read the engine's own
`TaskState` field. This is a **mirror / WinDbgCs** command.

> ⛔ **`Tasks.Enumerate` runs on the Mirrors / WinDbgCs engine (CsDebugScript) — three hosts:**
> - **`cdb.exe` + `!dcs_initsymsvr`** (RECOMMENDED for SQL 2019 / 2022 / 2025) — the
>   automated/**headless** host driven by `scripts\run_windbgcs_tasks.ps1`. cdb and
>   WinDbg both speak DbgEng, so the same `.load WinDbgCsExt.dll ; !dcs_initsymsvr ; ... ;
>   !execute Tasks.Enumerate` block works headless via `-cf`. This bypasses in-process
>   Roslyn CodeGen, which is what makes it succeed on SQL 2022 / 2025 dumps.
> - **`SqlScriptRepl.exe`** — legacy automated host driven by `scripts\run_sqlscriptrepl.ps1`.
>   Loads a pre-built `SqlDebugTypes.dll` from `NetStandard20Refs\<product>\`. Prefer for
>   SQL 2019 dumps with WinDbgCsExt v3.2.7 + a pre-seeded local bundle. On filtered
>   minidumps it can hit `Tried to access memory address (…) not found in the process`
>   (uncaptured SEList pages) — that's a data-completeness limit, not a host failure.
> - **WinDbg GUI** — `.load WinDbgCsExt.dll ; !dcs_initsymsvr ; ... ; !execute Tasks.Enumerate`
>   run interactively. This is the **manual** host of the SAME engine; the register step
>   is session-scoped — **re-run after every WinDbg restart** or you get `No results to
>   process`. The `!execute <path>\SqlCsScripts.dll` register form is DEPRECATED — it
>   triggers CodeGen which fails on many SQL 2022 / 2025 dumps.
>
> **⛔ EMIT-B-THEN-PAUSE GATE — do NOT auto-run first.** At 1.5.5 you MUST, in this order:
> 1. **First print the (b) 手工跑 WinDbg block** (below) into the session, with every
>    placeholder (`{wdbgcs}`, `{dump_path}`) resolved to a real path — never a `<path>` stub.
>    Complete + verify the mirror-acquisition (Step 1 fallback, `True True`) BEFORE printing.
> 2. **STOP and ASK the user**: 手工执行并把 `Tasks.Enumerate` 结果粘贴回来 (manual) —— 还是
>    让我自动跑 (auto)?  **Do NOT proceed until the user answers.** Never silently pick.
> 3. **If the user chooses manual** → wait for them to paste the output and use that as the
>    result. Do **NOT** run (a).
> 4. **If the user chooses auto** → now run **(a) SqlScriptRepl** and read the captured output.
>
> Printing the paste-ready (b) block is **mandatory in every case** — it is the artifact the
> user reviews before deciding. Auto-running (a) before emitting (b) and pausing is a
> **violation** of this gate.

**(a) 自动跑 — via cdb.exe + `!dcs_initsymsvr`** (RECOMMENDED for SQL 2019 / 2022 / 2025):

> Use the skill-local headless driver `scripts\run_windbgcs_tasks.ps1`. It writes a UTF-8
> no-BOM cdb `-cf` batch containing the exact `!dcs_initsymsvr` sequence from (b) below,
> runs cdb against the dump, and captures both metadata (`vertarget`, `lmvm sqlservr`) and
> the `Tasks.Enumerate` output to `<case>_tasks_output.txt`. It bypasses in-process Roslyn
> CodeGen (which fails on many SQL 2022 / 2025 dumps) — `!dcs_initsymsvr` pulls the
> pre-built `SqlCsScripts` + `SqlDebugTypes` assemblies from the sym server via
> `SymFindFileInPathW`. Exit code 0 iff the `TaskOutput:` marker is present in the log.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\run_windbgcs_tasks.ps1 `
  -Dump   '{dump_path}' `
  -OutDir 'reports/{case_id}_dump_code_analysis' `
  -CaseId '{case_id}' `
  -Wdbgcs '{wdbgcs}'
```

**(a-fallback) SqlScriptRepl.exe** — legacy path, prefer for **SQL 2019** dumps where
`WinDbgCsExt v3.2.7` + a pre-seeded `NetStandard20Refs\<product>\` bundle is available.
Same mirror-acquisition prerequisite as (b) — seed `{wdbgcs}\NetStandard20Refs` first
(Step 1 fallback). `-Expr` accepts multiple expressions in ONE session (batch 1.5.5's
`Tasks.Enumerate` with the 附加步骤 ring buffers' `SOSRingBuffers.EnumerateSchedulerMonitorRecords` to save
the slow DiscoverScripts init). Both blocks land in the same captured log; the parsers
locate their own block by expression name. On **filtered minidumps** it may hit
`Tried to access memory address (…) not found in the process` — that's an uncaptured-page
data limit, not a host failure.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\run_sqlscriptrepl.ps1 `
  -Dump    '{dump_path}' `
  -Expr    'Tasks.Enumerate','SOSRingBuffers.EnumerateSchedulerMonitorRecords' `
  -OutDir  'reports/{case_id}_dump_code_analysis' `
  -Scripts '{wdbgcs}\NetStandard20Refs\SqlCsScripts.dll'
```

**(b) 手工跑 — you MUST print this WinDbg block into your reply** so the user can run it and
paste the result. Resolve every placeholder (`{wdbgcs}`, `{dump_path}`) before printing —
never leave a `<path>` stub. Complete the mirror-acquisition (Step 1 fallback: symweb
auto-download first, `\\sqlbuilds` copy only on 404, then seed `NetStandard20Refs`) **before**
emitting the block, and verify the pair is present (`True True`):

> **SQL 2022 / 2025 note** — use `!dcs_initsymsvr`, NOT `!execute <path>\SqlCsScripts.dll`.
> The `!execute <path>` form triggers in-process Roslyn CodeGen which fails on many SQL
> 2022/2025 dumps with `Codegen failed with exception`. `!dcs_initsymsvr` pulls all
> CsScripts assemblies from the sym server and bypasses CodeGen. See Path B preflight above.

```windbg
* open dump:  windbgx -z {dump_path}
.sympath+ srv*C:\Symbols*https://symweb.azurefd.net
.load {wdbgcs}\WinDbgCsExt.dll                              * version-compatible build (C:\Tools\WinDbgCs = v3.2.7)
!dcs_initsymsvr ;                                           * downloads all CsScripts assemblies from sym server (bypasses CodeGen)
.reload /f sqlos.dll ;
.reload /f sqldk.dll ;
.reload /f sqlmin.dll ;
.reload /f sqllang.dll ;
.reload /f qds.dll ;
.reload /f sqlTsEs.dll ;
.reload /f svl.dll ;
.reload /f sbs.dll ;                                        * harmless if not loaded in this dump
.reload /f sqlvdi.dll ;
.reload /f sqlservr.exe ;
.reload /f hkengine.dll ;
.reload /f hkruntime.dll ;
.reload /f hkcompile.dll ;
.reload /f kernel32.dll ;
.reload /f ntdll.dll ;
.reload /f kernelbase.dll ;
!execute ;                                                  * lists installed scripts — verifies extension is live
!execute ExternalScripts.Install ;                          * register SqlCsScripts helpers
.ecxr ;                                                     * exception context record (dump trigger)
kc ;                                                        * clean call stack of the faulting thread
!execute Tasks.Enumerate                                    * authoritative task-level state
```

> **⛔ DELIVERY GATE:** the paste-ready (b) WinDbg block (real paths substituted) MUST be
> emitted into your reply **first**, then you **pause and ask** — that block is what the user
> reviews to decide manual vs auto. Only **after** the user picks **auto** do you run (a)
> SqlScriptRepl and show its captured output; if they pick **manual**, you wait for their
> pasted result and do NOT run (a). Running the automated path without first emitting the
> ```windbg block and pausing for the user's choice makes the step **incomplete**.

- One row per bound-worker task: `Task | SchedulerId | Worker | Thread | TaskState |
  TaskFunction`. Aggregate by `TaskState` → **SUSPENDED / RUNNABLE / RUNNING / DONE** —
  仅计数，不解读。
- ⛔ 不标注「culprit」、不判断 RUNNABLE 积压是否代表 CPU 压力 —— 只列出每种 TaskState 的数量。
- **Save the full task list to a linked detail page `{case}_tasks.html`** — do NOT hand-roll HTML.
  Run the committed generator against the raw `Tasks.Enumerate` capture (WinDbgCs / SqlScriptRepl):

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\gen_tasks_full_html.ps1 `
    -Src    'reports/{case_id}_dump_code_analysis/{case_id}_tasks_enumerate.txt' `
    -Out    'reports/{case_id}_dump_overall/{case_id}_tasks.html' `
    -CaseId '{case_id}'
  ```

  The script parses `^0x[hex]+ |` rows only (ignores symbol-load noise / help table / exception
  tail) and produces the canonical subreport shape: meta cards → 读法说明 note → **表 2**
  (state summary with 合计) → **表 3** (SchedulerId pivot with 隐藏/系统 aggregate + 合计) →
  值得注意的 RUNNING / RUNNABLE 行 → 全量任务清单 (SchedulerId 升序) → 过滤 minidump 采集局限
  note. **The "按 task_function 聚合" section is INTENTIONALLY OMITTED** — 表 3 + 值得注意的行
  已足以呈现分布模式，不需要再按 function 二次聚合。Row count MUST equal 表 2 任务数 = the
  `Tasks.Enumerate` bound-task row count.

- **Sidecar for overall-report reuse:** the generator also writes
  `{case_id}_tasks_stats.json` next to the HTML. This JSON contains `stateSummary`,
  `schedulerPivot`, and `notable` — the overall-report manifest builder MUST feed it to
  `emit_tasks_tables_html.ps1` so 表 2 / 表 3 in `<case>_overall_report.html` are byte-for-byte
  consistent with the subreport (no hand-rolled counts / no drift):

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\emit_tasks_tables_html.ps1 `
    -Stats         'reports/{case_id}_dump_overall/{case_id}_tasks_stats.json' `
    -Out2          'reports/{case_id}_dump_overall/{case_id}_tbl2_state_summary.html' `
    -Out3          'reports/{case_id}_dump_overall/{case_id}_tbl3_scheduler_pivot.html' `
    -TasksLinkHref '{case_id}_tasks.html'
  ```

  Embed each fragment in the overall-report manifest as a `{ "type":"raw", "html":"..." }`
  block (one single note under 表 2 — do NOT duplicate the data-source note).

> Complements — does not replace — 1.5.3: **1.5.3 = OS-thread shape** (incl. the idle pool,
> stack-inferred); **1.5.5 = logical work** (bound tasks, authoritative TaskState). When
> mirrors are unavailable, recover TaskState via the **dump-analysis** skill's native-walking
> Method 1 (worker/task locals).

### 1.5.6 按调度器分布（报告「按调度器分布」）

Pivot the same `Tasks.Enumerate` rows by `SchedulerId` (0..N) with SUSP / RUNNABLE / RUNNING
counts per scheduler — **纯计数表，不做定位/推断**. ⛔ **Reuse the 1.5.5 `Tasks.Enumerate`
result — do NOT re-acquire the mirror and do NOT pause/ask again.** Whether 1.5.5 ran **auto**
(the `run_sqlscriptrepl.ps1` log) or **manual** (the user-pasted output), this pivot is computed
from that SAME output — **no new WinDbg block is emitted here** (matches the validated flow).

> **Reference expression** (for understanding only — do NOT execute; the pivot is derived by
> grouping the already-captured 1.5.5 rows in PowerShell/JS while assembling the report):
>
> ```windbg
> !evaluate (execute Tasks.Enumerate).GroupBy(t => t.SchedulerId, q => q).Select(q => new {q.Key, q.Count()})
> ```

- 每个 `SchedulerId` 一行，列出该调度器上 SUSP / RUNNABLE / RUNNING 的任务数。
- ⛔ 不标「根因/症状」调度器、不判断哪个调度器「异常」—— 只列数字。
- Exclude hidden/system schedulers (id ≥ 1048576) from the user-work counts.

> 第二步到此结束（两张列举表：任务级 TaskState 汇总 + 按调度器分布）。
> **没有「关键观察」「下一步」环节** —— 本 skill 只列举，不下结论。直接进入 **第三步**（执行语句线程统计）。

---

## 分析第三步（报告「第三步」）：执行语句线程统计（process_commands_internal） · Exec-Statement Thread Stats

> **Report section:** `第三步：执行语句线程统计（process_commands_internal）` — task.js sweep + tsqlstack + 运行时状态表.

**When to run**: right after 第二步, enumerate every thread running actual T-SQL
(`sqllang!process_request` → `CSQLSource::Execute` / `process_commands`) and list its state
+ blocker links **as raw facts**. Three deliverables: (a) a per-main summary table, (b) a
runtime-state table (the blocking chain, at-a-glance), and (c) a `sql_exec_thread.html`
detail page with the decoded T-SQL per thread.

> ⛔ **只列举，不解读。** 「who is blocked by whom」是把 task.js 输出的 BLOCKERS 字段
> 原样制表，**不是**判断谁是 root cause。不写「疑似 Stalled Dispatcher」等结论。

### 1.7.1 Identify the exec-statement main threads

From the 第一步 `_us.txt` (or `~* kn`), pick the threads whose stack contains
`process_request` → `CSQLSource::Execute` — these are the batch/RPC **main** threads.
Parallel-query **child** threads (`sqlmin!SubprocEntrypoint`) belong to a main and are
grouped later by shared SPID.

### 1.7.2 Sweep task.js over every exec + child thread → `<case>_task_all.txt`

`task.js` targets the **current** thread, so sweep each TID into ONE log with a parse marker
per block (see «DScript operational rules» below for the clean-session requirements — no
WinDbgCsExt, wait for the `===..._DONE===` / `===TASK_<tid>===` marker).

**(A) Generate the sweep command file** — use the **skill-local generator**
`scripts\gen_task_sweep.ps1`. It emits one `~<TID>s`+`.echo ===TASK_<tid> <ROLE>===`+
`!dscript.run` line per exec main AND per parallel child, owns its own `.logopen`/`.logclose`,
ends with `q`, and writes **UTF-8-no-BOM**. Pass the threads as **ONE comma-separated string**;
each entry is `TID` or `TID:ROLE` (ROLE default `MAIN`; children `CHILD-A`…).

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\gen_task_sweep.ps1 `
  -Threads '<TID1>:MAIN,<TID2>:CHILD-A,<TID3>:CHILD-B' `
  -DscriptPath '{dscript_path}' `
  -LogFile 'reports/{case_id}_dump_code_analysis/{case_id}_task_all.txt' `
  -OutWds  'reports/{case_id}_dump_code_analysis/{case_id}_task_all.wds'
```

> It generates exactly this layout (markers match §1.7.3's `^===TASK_(\d+)\s+(MAIN|CHILD[^=]*)===`):
>
> ```text
> .logopen reports/{case_id}_dump_code_analysis/{case_id}_task_all.txt
> ~<TID1> s ; .echo ===TASK_<TID1> MAIN=== ; !dscript.run {dscript_path}\task.js
> ~<TID2> s ; .echo ===TASK_<TID2> CHILD-A=== ; !dscript.run {dscript_path}\task.js
> .echo ##### END TASK.JS SWEEP #####
> .logclose
> q
> ```

> `{dscript_path}` = the user-provided DScript scripts folder. **Ask the user** if not supplied.

> ⏸️ **After generating the file, ASK the user how to run it — auto or manual:**
> - **auto** → *you* run it headless with **cdb** (recipe (B)) and read the log; **OR**
> - **manual** → give the user the one-line `$><` command (recipe (C)); they run it in WinDbg,
>   tell you "done", and **you read the `.logopen` file they targeted**.
>
> Both surfaces write the SAME `.logopen` file — downstream parsing is identical. (Unlike
> 1.5.5 `Tasks.Enumerate`, DScript **does** run under cdb, so here auto = cdb.)

**(B) auto = run it headless with cdb — the PROVEN recipe (symbols WARM ⇒ ~1–2 s/task):**
Add `-Run -Dump '{dump_path}'` to the **same generator** — it generates the `.wds` then runs
cdb headless with the proven invocation (`-y` symbols, `$$><` BLOCK mode), auto-detects the
Store WinDbg `cdb.exe`, and reports the task-block count vs expected:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\gen_task_sweep.ps1 `
  -Threads '<TID1>:MAIN,<TID2>:CHILD-A,<TID3>:CHILD-B' `
  -DscriptPath '{dscript_path}' `
  -LogFile 'reports/{case_id}_dump_code_analysis/{case_id}_task_all.txt' `
  -OutWds  'reports/{case_id}_dump_code_analysis/{case_id}_task_all.wds' `
  -Run -Dump '{dump_path}'
```

**Canonical bounded run for large main+child sweeps (recommended):** use the same script with
`-ShardSize` / `-ShardTimeoutSec`. This is the stable path for cases with many parallel child
threads. It writes one shard `.wds` per batch, polls each shard's `.logopen` file for
`##### END TASK.JS SHARD <n> #####`, kills cdb if it is merely sitting at the prompt after the
marker, and merges all shard logs into `{case_id}_task_all.txt`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\gen_task_sweep.ps1 `
  -Threads '<main1>:MAIN,<child1>:CHILD,<child2>:CHILD,...' `
  -DscriptPath '{dscript_path}' `
  -LogFile 'reports/{case_id}_dump_code_analysis/{case_id}_task_all.txt' `
  -OutWds  'reports/{case_id}_dump_code_analysis/{case_id}_task_all.wds' `
  -Script task.js `
  -Run -ShardSize 10 -ShardTimeoutSec 300 `
  -Dump '{dump_path}' -SymPath '{sym_path}' -Cdb '{cdb_path}'
```

> **Why this exists:** cdb/DScript often completes the script and reaches the shard end marker
> but then stays at the debugger prompt instead of exiting. Older raw `& cdb ...` calls look
> like a hang. The bounded shard mode treats the end marker as success, kills only the prompt,
> and continues. If a shard never reaches the marker, it appends `DSCRIPT_SHARD_TIMEOUT` evidence
> and continues with later shards. Do not replace this with an unbounded one-shot cdb call.

> Under the hood it runs the proven line (register DScript COM first via
> `scripts\register_dscript.ps1` if `!dscript.run` errors `not registered as a COM server`):
> ```powershell
> & <cdb> -y 'srv*C:\Symbols*https://symweb.azurefd.net' -z '{dump_path}' -c "`$`$><$wds" *> '<wds>.console.txt'
> ```

Then verify by marker count: `(Select-String task_all.txt -Pattern '(?m)^===TASK_').Count`
== expected N, and `END TASK.JS SWEEP` present.

> ⛔ **cdb `-c` command-line parsing traps — get these wrong and cdb "hangs" (idle at the
> prompt, CPU 0) or errors `Win32 0n2 file not found`. These caused every prior sweep "hang"
> — NOT symbols, NOT DScript:**
> 1. **Symbols via `-y`, NEVER `.sympath` inside `-c`.** A `.sympath srv*...; cmds; q` string
>    makes `.sympath` swallow the whole rest of the line (incl. `q`) as the path.
> 2. **`q` goes INSIDE the file as the last line — never after the file ref in `-c`.**
>    `-c "$><file; q"` makes `$><` read the filename to end-of-line → *file not found*.
> 3. **Use `$$><` (block) not `$><` when the file has `$$` comment lines.** PowerShell
>    double-quote escaping: `$$><` → `` "`$`$><$wds" ``.

**(C) manual = the user runs it, then you read the log.** Give the user a paste-ready block
with the `.logopen`/`.logclose` path resolved. They run it in the WinDbg GUI, tell you
**"done"**, and **you then read the exact `.logopen` file they targeted** and parse it (§1.7.3).
**Resolve every placeholder** (`{dump_path}`, `{dscript_path}`, real TIDs, the log path):

```windbg
* open dump:  windbgx -z {dump_path}
.sympath srv*C:\Symbols*https://symweb.azurefd.net
.reload /f
.logopen C:\...\<case>_task_all.txt
~<TID1> s ; .echo ===TASK_<TID1> MAIN===    ; !dscript.run {dscript_path}\task.js
~<TID2> s ; .echo ===TASK_<TID2> CHILD-A=== ; !dscript.run {dscript_path}\task.js
* ... one line per exec main AND per parallel child ...
.logclose
```

> In the GUI do **NOT** append `q` (keep the session open) and do **NOT** `.load WinDbgCsExt`
> (poisons DScript). If dscript errors `not registered as a COM server`, run
> `register_dscript.ps1` first.

Each block carries the fields the table needs: `SOS_Task : … (SPID:N, …, ~<tid>s, Sch<n>:…)`,
`Task state`, `Worker state`, `Elapsed time : N ms`, `CPU time : N ms`, `Task function`,
`Wait type description` (**absent ⇒ RUNNING/on-CPU**), and the `------ BLOCKERS -----------`
section.

### 1.7.3 Parse the sweep → `task_fields.json`

Split on `^===TASK_(\d+)\s+(MAIN|CHILD[^=]*)===`; for each block extract the fields
**anchored at column 0** (`^SOS_Task`, `^Task state`, `^Worker state`, `^Elapsed`, `^CPU time`,
`^Task function`, `^Wait type description`). **BLOCKERS parse rule:** the task's own fields are
at column 0, the blocker's duplicated fields are prefixed with `  ---->  ` — take the blocker
reason from `BLOCKER_0[^:]*:\s*(.+)` and the blocker SPID/tid from the first
`---->\s*SOS_Task … \(SPID:(\d+),.*~(\d+)s`. Group CHILD blocks under the MAIN with the **same
SPID**; emit `{ main, childCount, children[] }` per main.

> ✅ **Use the skill-local parser — do NOT hand-roll it:**
> ```powershell
> powershell -NoProfile -ExecutionPolicy Bypass `
>   -File .github\skills\dump-overall\scripts\parse_task_fields.ps1 `
>   -CaseId '{case_id}' `
>   -Dir 'reports/{case_id}_dump_code_analysis' `
>   -TaskAll 'reports/{case_id}_dump_code_analysis/{case_id}_task_all.txt'
> ```
> It writes `task_fields.json` = one `{ main, childCount, children[] }` object per exec main.
> `childCount` feeds the 子线程数 column (1.7.5) and the `主 · N 子` / `↳ tid` runtime rows.

> **Completion gate:** `{case_id}_task_all.txt` must contain one `===TASK_...===` block per
> selected main/child thread and `##### END TASK.JS SWEEP #####`. A partial main-only sweep is
> incomplete.

> ⚠️ Anchor `^Elapsed time` (NOT `Quantum elapsed time`) and always anchor own-fields at `^`.
> ⚠️ **PowerShell trap:** never name a helper `H` (or any single letter matching a built-in
> alias) — alias > function resolution shadows it. Use `Enc`, `FmtMs`, etc.

### 1.7.4 Decode the T-SQL per main → `sql_exec_thread.html` (`tsqlstack.js`)

For **EVERY** exec main (⛔ not a sample — all N of them) run `tsqlstack.js`. Drive it with the
same sweep generator, `-Script tsqlstack.js`, passing **only the MAIN tids**:

```powershell
powershell -File .github\skills\dump-overall\scripts\gen_task_sweep.ps1 `
  -Threads '<main1>:MAIN,<main2>:MAIN,...' -Script tsqlstack.js `
  -DscriptPath '{dscript_path}' -Run -Dump '{dump_path}' `
  -LogFile 'reports/{case_id}_dump_code_analysis/{case_id}_tsqlstack.txt' `
  -OutWds  'reports/{case_id}_dump_code_analysis/{case_id}_tsqlstack.wds'
```

**Canonical bounded `tsqlstack.js` run:** start with modest shards; if a shard times out, rerun
the unfinished mains with `-ShardSize 1` so one bad minidump read does not hide later mains.
Keep every timeout block as evidence.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\gen_task_sweep.ps1 `
  -Threads '<main1>:MAIN,<main2>:MAIN,...' `
  -DscriptPath '{dscript_path}' `
  -LogFile 'reports/{case_id}_dump_code_analysis/{case_id}_tsqlstack.txt' `
  -OutWds  'reports/{case_id}_dump_code_analysis/{case_id}_tsqlstack.wds' `
  -Script tsqlstack.js `
  -Run -ShardSize 4 -ShardTimeoutSec 420 `
  -Dump '{dump_path}' -SymPath '{sym_path}' -Cdb '{cdb_path}'
```

If a shard stalls before its end marker, preserve the completed shard log, then rerun the
remaining tids one per shard:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\gen_task_sweep.ps1 `
  -Threads '<remaining_main>:MAIN,...' `
  -DscriptPath '{dscript_path}' `
  -LogFile 'reports/{case_id}_dump_code_analysis/{case_id}_tsqlstack_rest.txt' `
  -OutWds  'reports/{case_id}_dump_code_analysis/{case_id}_tsqlstack_rest.wds' `
  -Script tsqlstack.js `
  -Run -ShardSize 1 -ShardTimeoutSec 120 `
  -Dump '{dump_path}' -SymPath '{sym_path}' -Cdb '{cdb_path}'
```

`tsqlstack.js` is slow (~5 min headless per batch — wait for the `===..._DONE===` / `ALL_DONE`
marker; tail param bytes may be missing on a minidump = `[PARTIAL]`). Emit a detail page with,
**per main thread**, the full call stack + decoded `Input string:` statement text, and link it
under the report's 第二步. ⛔ **A `sql_exec_thread.html` that decodes only one main when there
are N mains is INCOMPLETE** — every main needs its own decoded statement (or an explicit
`[PARTIAL]` / minidump-read-fault note).

> **⛔ tsqlstack COM-error contract — DO NOT collapse the block.**
> Many threads abort mid-run with `COM Error Executing Script: 0x80020101` followed by
> `Cannot read from virtual address [0x…]` (this is `tsqlstack.js:862` dereferencing a
> `Parameter N` / `Local N` string blob that filtered minidumps drop). The lines dscript
> printed **before** the COM error — `Nest Level:`, `Procedure name:`, `CSQLObject:`,
> `CCompPlan:`, `CMsqlExecContext:`, `Executing statement: 0n<N>`, `CExecuteStatement: <addr>
> ( <CXStmt…> )`, `CStatement: <addr> ( <CStmt…> )`, plus any successfully captured
> `Parameter`/`Local` values — are authoritative call-site metadata and **MUST** be preserved
> in the manifest's `tsqlstack` field. **Never replace them with a "语句文本未捕获" /
> "statement text unavailable" placeholder** — that discards the procedure name and the
> statement class, which are usually enough to identify the workload (e.g. `sp_cdc_scan` +
> `CStmtWait`, or `sp_readrequest` + `CStmtRecvMsg` with `@receive_timeout = [600000]`).
> Run `parse_tsqlstack.ps1` on the sweep log — it splits per-thread, extracts the header
> fields, records the COM code + failing VA, and writes `rawBefore` (the header block minus
> the COM-error tail, safe to embed as `<pre>`) alongside `rawAll` (the full block) into
> `tsqlstack_fields.json`. Then populate the manifest's `tsqlstack` field from `rawBefore`
> and, when `comError != null`, append a one-line footnote like
> `— tsqlstack aborted at Parameter N (COM 0x80020101 @ VA 0x…) — filtered minidump.`

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .github\skills\dump-overall\scripts\parse_tsqlstack.ps1 `
  -Log 'reports/{case_id}_dump_code_analysis/{case_id}_tsqlstack.txt' `
  -Out 'reports/{case_id}_dump_code_analysis/{case_id}_tsqlstack.json'
```

> **Completion gate:** `{case_id}_tsqlstack.json` must contain one entry per exec main. OK,
> COM partial, and `DSCRIPT_SHARD_TIMEOUT` are all valid evidence states; a missing block is not.

#### 1.7.4b Extract the parallel-child call stacks (InParallelThreads sidecar)

Child workers (`sqlmin!SubprocEntrypoint`) carry **no** top-level T-SQL, so `tsqlstack.js`
skips them — but 第三步 must still list **every** child WITH its full call stack. Do **not**
re-sweep cdb for these: DumpViewer already bucketed the parallel threads and dumped their
stacks. Take them from the **InParallelThreads** sidecar (PRIMARY path — no extra cdb run):

```powershell
# {dv} = {case_id}_dump_overall\dumpviewer_out\Reports
node .github\skills\dump-overall\scripts\parse_dumpviewer_json.js `
  '{dv}\InParall_Parallel_*_json.js' --array `
  --out 'reports/{case_id}_dump_overall/inparallel.json'
```

`inparallel.json` = rows of `{ id, call_stack }`. The `id` is the mex / task.js thread number,
so join it directly to the `children[]` tids from `task_fields.json` (1.7.3). Every child tid
with `childCount > 0` **must** resolve to a `call_stack` here; if a child is missing from the
sidecar (rare — e.g. DumpViewer bucketed it elsewhere), fall back to a one-line
`~<tid>s ; kn` cdb sweep for just that tid. Feed each stack into the section-2 `<details>`
(see the layout note below). ⛔ Stacks in the tool-preview may show `[truncated]` at 2000
chars — that is a display limit only; the JSON file holds the **full** stack (verify it ends
at `ntdll!RtlUserThreadStart`).

**Assemble `{case}_sql_exec_thread.html` via the committed generator** — do NOT hand-roll HTML.
Build a manifest JSON with one entry per main (and its parallel children) — status tag, meta
line, `tsqlstack` output (raw text, will be HTML-escaped + wrapped in `<pre>`), and the call
stack — then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\build_sql_exec_manifest.ps1 `
  -CaseId '{case_id}' `
  -Dir 'reports/{case_id}_dump_code_analysis' `
  -TaskFields 'reports/{case_id}_dump_code_analysis/task_fields.json' `
  -TsqlStackJson 'reports/{case_id}_dump_code_analysis/{case_id}_tsqlstack.json' `
  -ThreadsJson 'reports/{case_id}_dump_code_analysis/threads_from_us.json' `
  -Out 'reports/{case_id}_dump_code_analysis/{case_id}_sql_exec_manifest.json' `
  -BackLink '{case_id}_overall_report.html'

powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\gen_sql_exec_html.ps1 `
  -Manifest 'reports/{case_id}_dump_code_analysis/{case_id}_sql_exec_manifest.json' `
  -Out      'reports/{case_id}_dump_code_analysis/{case_id}_sql_exec_thread.html'
```

Manifest schema (cards / verdict / sections[] / threads[] with `tid`, `cardCls`, `statusTag`,
`statusText`, `exception`, `meta`, `tsqlstack`, `stack`, `extraHtml`) is documented in the
script header.

> **⛔ 子报告固定三段布局（列出**全部**执行语句线程 — 主线程 + 并行子线程都要在）：** the
> generator renders `sections[]` in order, each with an `h2`, its `threads[]` cards, and an
> optional section-level `extraHtml`. Use the canonical three sections so `sql_exec_thread.html`
> shows **every** exec thread (main *and* parallel child) — never just the mains:
>
> 1. **`一、执行语句主线程（N · 含 process_commands_internal）`** — one `.tcard` per exec main
>    (its `tsqlstack` decoded statement + call stack). `threads[]` populated.
> 2. **`二、并行子线程（M）`** — the parallel-query / parallel-backup children
>    (`sqlmin!SubprocEntrypoint`, no `process_request`). Emit via the section's `extraHtml`
>    (leave `threads[]` empty) as **one summary `<table>`** — columns `线程 | SPID | 父主线程 |
>    父语句 | Task 状态 | Worker 状态 | Scheduler | EC | Wait type | Elapsed` — **followed by
>    one `<details>` per child carrying its FULL call stack** (`▶ 子线程 <tid>（SPID N · 父 P）
>    调用栈`). List **every** child, not a sample. Source the child call stacks from the
>    DumpViewer **InParallelThreads** sidecar (`InParall_Parallel_*_json.js`, cols `id` +
>    `call_stack`) — parse with `parse_dumpviewer_json.js --array`; the `id` matches the mex /
>    task.js thread number. Children carry no top-level T-SQL — the statement belongs to the
>    父主线程. **纯客观列举，不做根因判定。**
> 3. **`三、主线程 / 子线程运行时状态明细（N+M 线程）`** — the runtime-state `<table class="rt">`
>    (1.7.5) covering **all** threads; children render as `↳ tid` indented under their parent.
>
> ⛔ **A subreport with only section 1 is INCOMPLETE** — if `task_fields.json` reports any
> `childCount > 0`, sections 2 and 3 MUST list those children (source them from the
> `===TASK_<tid> CHILD===` blocks in `{case}_task_all.txt`). Reference layout:
> `2606250030005483_dump_overall\2606250030005483_sql_exec_thread.html`.

> **Completion gate:** `{case_id}_sql_exec_thread.html` must contain all three section labels:
> `执行语句主线程`, `并行子线程`, and `主线程 / 子线程运行时状态明细`, and the main overall report must
> link to it.

### 1.7.5 Build the two report tables

- **Per-main summary table** — columns `线程 | SPID | 异常路径 | CompPlan | 子线程数 |
  tsqlstack 结果`. `子线程数` = `childCount` from 1.7.3 (parallel mains > 0, serial = 0).
- **Runtime-state table (all N threads)** — reads `task_fields.json` and injects a
  `<table class="rt">` (columns `线程 | SPID | 角色 | Task 状态 | Worker 状态 | Wait type |
  Elapsed | CPU | Task function | Blocking`). Mains show `主 · N 子`; children render as
  `↳ tid` under their parent. The **Blocking** column is the payoff: it makes "many mains
  blocked by one culprit" obvious — e.g. 10 mains all `SPID 1346 (~144s) · SEARCH_OR scheduler
  yield` while the culprit thread itself is `RUNNING`, no wait, monopolizing its scheduler =
  textbook **Stalled Dispatcher**.

> Generator scripts are Chinese-in-HTML → build the fragment in a `.ps1` and write with
> `[System.IO.File]::WriteAllText(path, html, (New-Object System.Text.UTF8Encoding($false)))`
> — never PowerShell here-strings (corrupt Chinese to `?`).

---

## 第四步 · 调度器清单（报告「第四步」）· Scheduler Inventory（`Schedulers.Enumerate` 优先 / `sys.schedulers.js` fallback）

> **第四步 = 调度器清单。** 在第三步之后、第五步（内存代理清单）与 SOS 环形缓冲附加步骤之前执行；
> 两种采集方式都能与前面的会话顺带产出，无需另开会话。

一次性列举 SQLOS 全部调度器（≈ `sys.dm_os_schedulers` 的 dump 等价视图）——每个
scheduler 的 `runnable/work queue` 长度、`yield count`、当前 worker、preemptive 状态等。这是
**Stalled Dispatcher / 调度器不让出（non-yield）** 场景的关键旁证（哪个 scheduler 队列堆积、哪个
worker 独占 scheduler），但本 skill **只客观列举，不下根因结论**（因果解读永远交给 dump-analysis）。

### 🔀 采集方式二选一（按 dump 的产品主版本决定顺序）

有 **两种**方式产出调度器清单——`!execute Schedulers.Enumerate`（mirror）或 `sys.schedulers.js`（DScript）：

- **SQL2022 及以后的 dump：** **先尝试** `!execute Schedulers.Enumerate`（与第五步 / SOS 环形缓冲附加步骤
  用**同一个** mirror 会话，`!dcs_initsymsvr` 初始化后即可）。**若无输出**（mirror 不适配该 build），
  **再 fallback 到** `sys.schedulers.js`（DScript）。
- **SQL2022 之前的 dump：** **直接使用** `sys.schedulers.js`（DScript），不必先试 mirror。

```windbg
:: SQL2022+ 优先尝试（mirror，同第五步会话）
!execute Schedulers.Enumerate

:: 无输出时 fallback（DScript，同第三步会话）；SQL2022 之前直接用这一条
!dscript.run C:\Tools\dscript\sql2022\scripts\scripts\sys.schedulers.js
```

For SQL2022-before dumps (or mirror fallback), run the DScript path with the bounded single-script
runner. Do not run a naked `& cdb ...` command, because cdb may execute the script and then sit at
the prompt forever.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\run_dscript_once.ps1 `
  -ScriptPath '{dscript_path}\sys.schedulers.js' `
  -LogFile 'reports/{case_id}_dump_code_analysis/{case_id}_sys.schedulers.txt' `
  -OutWds  'reports/{case_id}_dump_code_analysis/{case_id}_sys.schedulers.wds' `
  -Dump '{dump_path}' -SymPath '{sym_path}' -Cdb '{cdb_path}' `
  -EndMarker 'END SYS.SCHEDULERS' -TimeoutSec 300
```

> ⚠️ **mirror / DScript 路径都按 dump 的 build 选择。** `!execute Schedulers.Enumerate` 的 mirror 对必须与
> dump 的 build 匹配（`True True`）；fallback 的 `sql2022` 是**版本专属**目录——必须与 dump 的产品主版本
> 匹配（2019/2022/2025 各自的 `sys.schedulers.js`），否则符号偏移不对。DScript 与第三步 `task.js`/`tsqlstack.js`
> 用**同一个** `{dscript_path}`（见 Required Inputs），可在第三步那次 cdb / WinDbg 会话里顺带执行；
> `!execute` 则与第五步 / SOS 环形缓冲附加步骤同一 mirror 会话——两种方式都无需另开会话。

原始输出留档到 `txt_detail\`（与 SOS 环形缓冲附加步骤同规范，供后续 agent 复用）——按实际采集方式命名：

```
:: SQL2022+ 走 mirror 命中时
{case}_dump_overall\txt_detail\{case}_Schedulers.Enumerate.txt
:: fallback 到 DScript（或 SQL2022 之前）时
{case}_dump_overall\txt_detail\{case}_sys.schedulers.txt
```

> **Completion gate:** the scheduler inventory raw file must be non-empty. For the DScript path,
> `{case_id}_sys.schedulers.txt` must contain `END SYS.SCHEDULERS`. After running
> `inject_dscript_inventory_sections.ps1`, the MAIN report must include a parsed
> `Scheduler detail` table with the row-level `sys.schedulers.js` result, not only a
> summary count or raw txt link.

> 采集方式：`!execute Schedulers.Enumerate`（SqlScriptRepl / mirror）**或** `sys.schedulers.js`
> （cdb `-c "$$><file; q"` / SqlScriptRepl `!dscript.run`）。两者列的语义等价（≈ `sys.dm_os_schedulers`）。
> **纯列举，绝不做根因分析**——「哪个 scheduler 卡住、为什么」交给 dump-analysis skill。

---

## 第五步 · 内存代理清单（报告「第五步」）· Memory Broker Inventory（`!execute MemoryBrokers.Enumerate`）

> **第五步 = 内存代理清单。** 从 SOS 环形缓冲附加步骤里独立出来单列 —— 环形缓冲给的是内存代理的
> **历史通知记录**（`EnumerateMemoryBrokerRingRecords` / `EnumerateMemoryBrokerClerkRingRecords`，仍留在
> 附加步骤里），本步给的是 dump 时刻**每个 broker 的当前状态快照**（≈ `sys.dm_os_memory_brokers`）。

用 mirror 一次性列举内存代理（`MEMORYBROKER_FOR_CACHE` / `_STEAL` / `_RESERVE`）—— 每个 broker 的
`target / future / current` 内存、`rate`、`last_notification`（`GROW`/`SHRINK`/`STABLE`）、
`shrink/grow` 计数等。这是**内存压力 / OOM / 缓存被迫收缩**场景的关键旁证（哪个 broker 在收缩、
目标与当前差多少），但本 skill **只客观列举，不下根因结论**（因果解读永远交给 dump-analysis）。

```windbg
!execute MemoryBrokers.Enumerate
```

> ⚠️ 与 SOS 环形缓冲附加步骤的 `!execute` 用**同一个** mirror 会话（`!dcs_initsymsvr` 初始化后即可），
> 无需另开会话；mirror 对必须与 dump 的 build 匹配（`True True`）。

原始输出留档到 `txt_detail\`（与 SOS 环形缓冲附加步骤同规范，供后续 agent 复用）：

```
{case}_dump_overall\txt_detail\{case}_MemoryBrokers.Enumerate.txt
```

> 采集方式同 1.5.5 / SOS 环形缓冲附加步骤（cdb `-c "$$><file; q"` 或 SqlScriptRepl）。**纯列举，
> 绝不做根因分析**——「哪个 broker 在收缩、为什么内存不够」交给 dump-analysis skill。

---

## 第六步 · latch 争用页面 + 线程栈联表（报告「第六步」）· Latch-Contended Pages ⋈ Thread Stacks（`dump_latch_contended_pages.js`）

> **第六步 = latch 争用页面清单 + 争用线程调用栈联表。** 在第五步之后执行。与第三步 `task.js` /
> 第四步 `sys.schedulers.js` 用**同一个** cdb / WinDbg 会话即可顺带产出，无需另开会话。

分两小节：**（6.1）** 用 DScript 一次性列举 dump 时刻**正在发生 latch 争用的页面**——每条给出
`db_id / file_id / page_id`、latch class、当前持有 mode（`SH`/`EX`/`UP`/…）、等待者数量、以及**争用该页的
thread ID 列表**；**（6.2）** 把 6.1 返回的每个 **thread ID** 拿去**第一步**的逐线程调用栈里**反查**，
把它们的**完整调用栈**列出来（第一步已按线程留存 `call_stack`）。这是 **latch timeout / `PAGELATCH_*`
/ `BUF latch` 争用**场景的关键旁证（哪一页在争、谁持有、谁在等、各自栈在哪），但本 skill **只客观列举
+ 联表，不下根因结论**（因果解读永远交给 dump-analysis / latch-timeout-analysis skill）。

### 6.1 列举 latch 争用页面（DScript）

```windbg
!dscript.run C:\Tools\dscript\sql2022\scripts\scripts\dump_latch_contended_pages.js
```

> ⚠️ **路径按 dump 的 build 选择。** 上面的 `sql2022` 是**版本专属**目录——必须与 dump 的产品主版本
> 匹配（2019/2022/2025 各自的 `dump_latch_contended_pages.js`），否则符号偏移不对。与第三步
> `task.js` / 第四步 `sys.schedulers.js` 用**同一个** `{dscript_path}`（见 Required Inputs），可在同一次
> cdb / WinDbg 会话里顺带执行，无需另开会话。

> ⚠️ **脚本帧匹配需放宽到 `BUF::Acquire*Latch*`，否则漏 PAGEIOLATCH。** 厂商自带的
> `dump_latch_contended_pages.js` **只精确匹配帧名 `BUF::AcquireLatch`**，于是 PAGEIOLATCH 路径的等待者
> （帧 `BUF::AcquireIOLatch`，栈形如 `BPool::FlushBuf → WriteMultiple → PageReadyToWrite →
> BUF::AcquireIOLatch → LatchBase::Suspend → …DumpOnTimeoutIfNeeded`）会被漏掉，脚本假阴性输出
> `No pages found.`。把帧匹配从 `name == "BUF::AcquireLatch"` 放宽为
> `name.indexOf("BUF::Acquire")==0 && name.indexOf("Latch")!=-1`（覆盖 `BUF::AcquireLatch` /
> `BUF::AcquireIOLatch` / `BUF::AcquireLatchInternal`——都是 `BUF` 方法，`this` 均为 `BUF*`，
> `bpageno.m_file:m_id` 提取逻辑不变）。已在 `sql2022` / `sql2025` 两份副本改好；`SQL2016/2017/2019`
> 是另一套实现，不套用此改法。
>
> ⚠️ **解析陷阱：cdb 的 `Processing X of Y` 进度行用裸 `\r`（回车覆盖）分隔，不是 `\r\n`。**
> 汇总解析若用 `split(/\r?\n/)` 会把所有进度行挤成一行、只取到第一个 `Found 0`；须用
> `split(/\r\n|\r|\n/)` 才能拿到末行 `Processing N of N - Found M threads (K pages)`。

原始输出留档到 `txt_detail\`（与第四/五步、SOS 环形缓冲附加步骤同规范，供后续 agent 复用）：

```
{case}_dump_overall\txt_detail\{case}_dump_latch_contended_pages.txt
```

### 6.2 用 thread ID 反查第一步的调用栈（联表）

6.1 每条争用记录带一组 **thread ID**（持有者 + 等待者）。**逐个** thread ID 到**第一步**的逐线程数据里
反查其**完整调用栈**——两种模式取数一致（第一步已保留每线程 `call_stack`）：

- **PRIMARY (DumpViewer):** 从 `threaddetails.json`（第零步 0.2 解析出的 `MiniDumpData.GetThreadDetails`）
  按 `thread_id` 直接 join 出该线程的 `call_stack`；第一步报告里命中功能桶（含 `Latch` 桶）的线程已带
  锚点 `id='thr-<桶key>-<tid>'`，第六步表格的 thread ID chip **直接跳转**到第一步已内联的该线程完整栈。
- **FALLBACK (`!mex.us`):** 从第一步 shred 出的 `{id, stack}` 列表（`shred_mex_us.ps1` 产物
  `us_threads_shredded.json`）按 `id` 反查 `stack`。若某 thread ID 落在 `!mex.us` 的**大组截断**里
  （见 1.5.0 的截断说明），则回到 `{case}_us.txt` 里按该 id 单独 grep 其栈补齐。

> ⛔ **纯列举 + 联表，绝不做根因分析。** 本步只客观列出「哪些页在 latch 争用、每页有哪些 thread」，
> **不判断**哪个是持有者/受害者、不猜「为什么会争这一页」、不给 pivot 方向。
> 「latch 争用因果」交给 **latch-timeout-analysis / dump-analysis** skill。

> ⛔ **第六步只列争用结果 + 链接回第一步，不重复打印线程栈。** 第一步已把命中功能分类（含 `Latch`
> 桶）的线程**完整调用栈内联**并带锚点，第六步表格的 thread ID chip **只做跳转/交叉引用**，**不再在
> 第六步段内重复渲染整段 `kn` 栈**（避免与第一步重复、报告膨胀）。若某 thread ID 未落在第一步已内联的
> 功能桶里，才补一个指回第一步逐线程明细页的链接。

> **报告呈现：** 第六步表格每行一条争用页记录（`db/file/page` + latch class + mode + 等待者数），
> 该页的 thread ID 以 chip 列出；每个 chip **链接**到第一步对应线程的完整栈锚点（PRIMARY）或内联/补齐
> 的栈块（FALLBACK）——**链接而非重印**。保持与第四/五步一致的「纯客观列举」风格。

> **Completion gate:** for latch-timeout dumps, `{case_id}_dump_latch_contended_pages.txt`
> must exist, be non-empty, and contain `END LATCH CONTENDED PAGES`. `No pages found` is
> acceptable only as raw evidence emitted by this script; missing script output is not acceptable.
> After scheduler and latch-contended-pages DScript outputs are generated, the standard
> `finalize_ringbuf_reports.ps1` automatically runs `inject_dscript_inventory_sections.ps1`
> so the MAIN overall report includes the 第四步 and 第六步 sections. The 第四步 section must
> include parsed scheduler detail rows, and the 第六步 section must include the parsed `Page | Count | Threads`
> detail rows from `{case_id}_dump_latch_contended_pages.txt` (for example,
> `1:9 | 4 | ~217, ~226, ~256, ~394`), not just a raw txt link. The verifier checks both
> the raw files and the MAIN report links/sections/detail rows.

---

## SchedulerMonitor 环形缓冲 —— 已并入附加步骤（第 5 条），不再单独成段

> ⛔ **旧「1.8 SchedulerMonitor 独立段」已删除。** SchedulerMonitor 环形缓冲
> （`SOSRingBuffers.EnumerateSchedulerMonitorRecords`）现在**只作为下面附加步骤「SOS 环形缓冲（9 条）」
> 的第 5 条**产出 —— 完整分页子报告 `{case}_sub_...SchedulerMonitorRecords.html` + MAIN 报告的
> top-N / 规则化异常，全部由附加步骤的 `build_ringbuf_reports.ps1` 统一生成。旧的「±20 min 切片」
> snippet 段与独立的 `{case}_scheduler_monitor.html` / `_snippet.html` 产物一并取消，以避免与第 5 条重复。
> 事件类型语义解读（`SMR_STUCK_DISPATCHER_*` / `SMR_NONYIELD_*` 是因是果）永远交给 **dump-analysis** skill。

---

## 附加步骤 · SOS 环形缓冲 / 摘要全量列举（9 条 `!execute`）· All Ring Buffers（列举 + 规则化异常判定）

> **为什么是「附加步骤」而不是编号步骤：** 本步与第一/二/三/四/五/六步的顺序无关，可在前面任意新增编号步骤
> 而无需重编号（正因如此，第四步=调度器、第五步=内存代理、第六步=latch 争用页都排在它前面）。放在最后只是逻辑上收尾。

> **PRIMARY (DumpViewer) mode:** DumpViewer already covers **5 of the 9** rings — take
> `#7 SchedulerRing` ← `schedring.json`, `#5 SchedulerMonitor` ← `monitorring.json` /
> `schedmonitors.json`, `#2 MemoryBroker` ← `membrokerring.json`, and the OOM ring ←
> `oomring.json` (第零步 0.2). Then run `!execute` for **ONLY the 4 rings DumpViewer omits**:
> `#8 HadrArPubishEvents`, `#9 HadrArSignalState`, `#3 BlockedProcessReport`,
> `#4 MemoryBrokerClerk` (and `#1 ProcessSummary` if not already present). **FALLBACK mode:**
> run all 9 via `build_ringbuf_reports.ps1` as written below.

Enumerate the **9** SOS ring-buffer / summary mirror expressions in one pass and fold them
into the MAIN report as an **附加步骤** section. **SchedulerMonitor 环形缓冲就是这九条里的第 5 条**
（`SOSRingBuffers.EnumerateSchedulerMonitorRecords`）—— 不再单独成段（旧「1.8 SchedulerMonitor
±20 min 切片」独立段已删除，避免与本步第 5 条重复）. **纯列举 + 规则化异常标记，绝不做根因分析**（根因永远交给 dump-analysis）.

### The 9 expressions (fixed order)

| # | `!execute` expression | 类别直方图列 (`catCol`) |
|---|-----------------------|-------------------------|
| 1 | `ProcessSummary.Enumerate` | —（无分类列）|
| 2 | `SOSRingBuffers.EnumerateMemoryBrokerRingRecords` | `m_type` |
| 3 | `SOSRingBuffers.EnumerateBlockedProcessReportRingBufferRecords` | — |
| 4 | `SOSRingBuffers.EnumerateMemoryBrokerClerkRingRecords` | `m_clerk` |
| 5 | `SOSRingBuffers.EnumerateSchedulerMonitorRecords` | `m_event` |
| 6 | `SOSRingBuffers.EnumerateExceptionRingRecords` | `m_error` |
| 7 | `SOSRingBuffers.EnumerateSchedulerRingRecords` | —（`m_scheduler_action` 可选）|
| 8 | `SOSRingBuffers.EnumerateHadrArPubishEventsRecords` | `m_current_ar_role` |
| 9 | `SOSRingBuffers.EnumerateHadrArSignalStateRecords` | `m_signal_type` |

### `txt_detail\` capture convention （原始 txt 留档给后续 agent）

Capture each expression via the **same acquisition path as 1.5.5** (cdb + `!dcs_initsymsvr`,
or SqlScriptRepl — batch all 9 `-Expr` into one session to amortise the slow DiscoverScripts
init), and save each raw pipe-table output to:

```
{case}_dump_overall\txt_detail\{case}_{expression}.txt
```

e.g. `txt_detail\2607030030000843_SOSRingBuffers.EnumerateExceptionRingRecords.txt`. The
`txt_detail\` folder is the **committed留档位置** — the builder reads from it and later
agents (dump-analysis 第三步/附加步骤) can re-parse the same raw captures. Also keep the five
carry-forward captures here for downstream reuse: `{case}_us.txt`, `{case}_tasks_output.txt`,
`repl_stdout_<ts>.txt`, `{case}_task_all.txt`, `{case}_tsqlstack.txt`.

When the acquisition path is `run_windbgcs_direct.ps1`, its output is one combined log with
`== MARKER_<expr> ==` fences. **Do not link that combined log, or a `direct_mirror.html` wrapper
around it, as the ring-buffer result.** Run the committed finalizer; it performs split → build →
inject scheduler/latch DScript sections → verify in one call:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\finalize_ringbuf_reports.ps1 `
  -Dir    'reports/{case_id}_dump_overall' `
  -CaseId '{case_id}' `
  -TopN   20 `
  -RequireThreadCategories `
  -RequireSqlExec `
  -RequireSchedulerInventory `
  -RequireLatchContendedPages
```

For non-latch dump routines, omit `-RequireLatchContendedPages`. For latch-timeout or
latch/page-contention dumps, keep both scheduler and latch-page switches enabled. When both
`{case_id}_sys.schedulers.txt` and `{case_id}_dump_latch_contended_pages.txt` exist, the
finalizer automatically calls `inject_dscript_inventory_sections.ps1` before verification, so
the MAIN report contains the parsed scheduler detail table and `Page | Count | Threads` rows.

The raw direct log may still be linked as evidence, but the MAIN report's 附加步骤 must be the
parsed/classified view: category histogram, dump-before top 20 rows, rule-based anomaly rows,
and one paginated sub-report per expression. `split_direct_mirror_log.ps1` and
`build_ringbuf_reports.ps1` remain available for debugging, but normal runs use the finalizer.

### Build the 附加步骤 section (committed script)

⛔ **No ad-hoc parser / HTML.** Run the committed builder. It parses the 9 `txt_detail\`
captures, writes one paginated sub-report per expression (`{case}_sub_<expr>.html`), then
**injects** an 附加步骤 section into `{case}_overall_manifest.json` and **regenerates**
`{case}_overall_report.html` via `gen_overall_report.ps1`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\build_ringbuf_reports.ps1 `
  -Dir    'reports/{case_id}_dump_overall' `
  -CaseId '{case_id}' `
  -TopN   20            # default 20 — 主报告每条只展示 top-N 最新 + top-N 异常
```

> **Must run with `pwsh` (PS7), not `powershell` (5.1)** — the script embeds Chinese literals
> as no-BOM UTF-8; PS 5.1 corrupts them to mojibake and fails parsing. `-TxtDir` defaults to
> `{Dir}\txt_detail`, `-Manifest` to `{Dir}\{CaseId}_overall_manifest.json`, `-Generator` to
> the sibling `gen_overall_report.ps1` (`$PSScriptRoot`). It is **idempotent** — re-running
> removes any prior `附加步骤 · SOS 环形缓冲*` section before re-inserting, and inserts the
> section immediately **before** the DoD section, adding a `环形缓冲命令 = 9 条 · 见附加步骤` card.

> ⛔ **Direct mirror completion gate:** if `run_windbgcs_direct.ps1` produced any ring-buffer
> rows, `finalize_ringbuf_reports.ps1` must finish successfully. A report that only links
> `direct_mirror.html` / raw txt is incomplete even if the direct mirror command itself succeeded.

For **each** of the 9 sections the MAIN report shows:

- **① dump 前 top {TopN} 最新记录**（`position` 降序 = 最新在前）
- **② 值得注意的记录（规则化异常判定）** — the actual flagged records (not just a count),
  labeled with the rule; **命中 0 时显式绿色标注**「无符合规则的异常记录」
- 顶部**类别直方图**（`catCol`）
- 若最新记录的 `m_time_stamp` 距 dump ≥ 1 天 → **陈旧标注**「⚠ 最新记录距 dump 约 N 天 —— 该环形缓冲长期未更新，下表并非 dump 前近期活动」（防止把 60+ 天前的旧记录误读成 dump 前活动）。

### Anomaly rules (`Get-Anomalies`) — 规则化、可按案例调整

Rules live in `build_ringbuf_reports.ps1 → Get-Anomalies()`; they are **heuristics meant to
be tuned per case**, and every rule's text is printed in the report next to its table.

| Expression | 异常判定规则 |
|------------|-------------|
| MemoryBrokerRing | `m_last_notification` 含 `SHRINK`（内存收缩压力）|
| MemoryBrokerClerk | `m_internal_freed_pages` > 0 **或** `m_periodic_freed_pages` > 0（clerk 被要求释放内存）|
| SchedulerMonitor | `m_event` ≠ `SMR_SYSTEM_HEALTH`（STUCK_DISPATCHER / NONYIELD / DEADLOCK）**或** `m_process_utilization` > 90（high CPU）**或** `m_working_set_delta` < `-104857600` 字节（释放物理内存 > 100 MB）|
| ExceptionRing | `m_severity` ≥ 19（高危）**或** 主导洪泛错误码 top-1 的最新样本（≤ 15 条）|
| SchedulerRing | `m_return_code` ≠ 0（非成功返回码）|
| HadrArPubishEvents | `m_has_exception` = True **或** `m_current_ar_role` ∉ {`PRIMARY_NORMAL`, `SECONDARY_NORMAL`}（RESOLVING / PENDING 角色迁移）|
| HadrArSignalState | 少数派 `m_signal_type`（≠ 主导信号类型）|
| ProcessSummary / BlockedProcessReport | （无规则，仅列举）|

> 数值解析 `NumOf()` 用 `^\s*(-?\d+)` 从 `13706324(0xd12454)` / `-29356032(0xfff...)` /
> `14(0xe)` 取前导整数（支持负数）；陈旧天数 `AgeDays()` 从 `Age: 66.01:47:22.16` 取 `66`
> 天（`Age: 00:09:32` = 0 天）。**只列举 + 规则化标记，不下根因结论。**

---

## DScript operational rules (⛔ read before running `task.js` / `tsqlstack.js`)

`task.js` / `tsqlstack.js` run **purely through the DScript extension against private
symbols** — they do **NOT** use the WinDbgCs / Mirrors mechanism. Hard-won rules:

1. **Prepare once (per-user, no admin):** register the 4 DScript CLSIDs in HKCU —
   ```powershell
   pwsh -NoProfile -File .github\skills\dump-overall\scripts\register_dscript.ps1
   ```
   Else `!dscript.run` fails: `not registered as a COM server ... 0x80070005`. **WinDbg
   auto-updates break it** (package path changes) → just **re-run the script**.

2. **NEVER `.load WinDbgCsExt.dll` and NEVER run `!dcs_initsymsvr` in the SAME session as
   `!dscript.run`.** Mirrors init (1.5.5) and DScript are two separate surfaces — do not mix.
   WinDbgCsExt pulls its own managed engine + `msdia140.dll`, which poisons DScript's COM /
   DIA activation → the next `!dscript.run` fails with `0x800A0030 [Error in loading DLL]`.
   If you already ran `.load WinDbgCsExt` / `!dcs_init*`, **quit and start a fresh cdb**.

3. **Clean run procedure:**
   ```text
   cdb -z <dump>.mdmp -y srv*C:\Symbols*https://symweb.azurefd.net -lines
   ~<TID> s                                * dscript targets the CURRENT thread — switch first
   !dscript.run {dscript_path}\task.js ; .echo ===TASK_<TID>_DONE===
   ```
   `!dscript.run` auto-loads DScript (`--- Loading DScript`). No other setup beyond the
   one-time HKCU registration. `{dscript_path}` is user-provided and build-specific — **ASK
   the user**; do NOT hardcode.

4. **Always append `.echo ===..._DONE===` and WAIT for it — do NOT kill early.** With warm
   symbols, `task.js` runs ~1–2 s/thread; `tsqlstack.js` takes **≥ 5 min** (the line
   `Input string:(` is in-progress, NOT a hang). Idle-detection can return in ~1 min while
   the script is still running — poll for the `===..._DONE===` marker before reading results.

5. **Minidump read faults are a dump limitation, not an error.** `tsqlstack.js` may end with
   `0x8007001E (ERROR_READ_FAULT)` / `Cannot read from virtual address` / `<CORRUPTED>`. If the
   `Input string:` text is fully captured, use it and ignore the tail error; if the fault hits
   mid-string, record `[PARTIAL]` — a `.dump /ma` full dump is the only way to get the rest.

6. **`task.js` is the fast, high-value first choice** — SPID, scheduler, Worker state, wait
   type, and the **BLOCKERS chain** in seconds. Run `tsqlstack.js` (slow) only when you need
   the actual T-SQL statement text + parameters.

---

## Output — the Overall Snapshot report

### Hard workflow ledger + completion verifier

⛔ **Final report generation is not the completion gate.** The workflow must maintain a
`workflow_ledger.json` from the beginning of the run and must pass the committed completion
verifier before the agent may say the task is complete. This prevents both failure modes:

- an incomplete `<case>_overall_report.html` generated from a partial manifest;
- no `<case>_overall_report.html` generated at all.

The ledger has two top-level groups:

```json
{
  "requiredSteps": {
    "P3_dscript_exec": {
      "required": true,
      "status": "missing",
      "artifacts": ["<case>_task_all.txt", "task_fields.json", "<case>_sql_exec_thread.html"]
    }
  },
  "requiredDeliverables": {
    "overall_html": {
      "required": true,
      "stage": "Completion",
      "status": "missing",
      "path": "<case>_overall_report.html"
    }
  }
}
```

Never hand-author this ledger on a normal run. Initialize it before Step 0 and atomically
transition each item after its artifacts are present:

```powershell
pwsh -File .github\skills\dump-overall\scripts\initialize_overall_workflow_ledger.ps1 `
  -CaseId '{case_id}' -OutDir '{case_dump_overall}'

pwsh -File .github\skills\dump-overall\scripts\set_overall_workflow_status.ps1 `
  -Ledger '{case_dump_overall}\workflow_ledger.json' `
  -Group requiredSteps -Name step1_os_threads -Status done
```

Use `unavailable-with-evidence` only with `-Evidence <non-empty raw log paths>`. Deliverable
items remain `missing` until their files are generated; transition them to `done` before Gate A.

Allowed terminal statuses are only `done`, `unavailable-with-evidence`, and
`skipped-by-user`. `missing`, `not_run`, `blocked`, or `failed` blocks final completion.
`unavailable-with-evidence` is valid only when the ledger item also lists non-empty raw
failure logs in `evidence[]`.

Before writing the main report, pass the ledger to the generator so required pre-report steps
cannot be silently omitted:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\gen_overall_report.ps1 `
  -Manifest 'reports/{case_id}_dump_overall/{case_id}_manifest.json' `
  -Out      'reports/{case_id}_dump_overall/{case_id}_overall_report.html' `
  -Ledger   'reports/{case_id}_dump_overall/workflow_ledger.json'
```

For normal runs, do not invoke the generator and verifier piecemeal. After the manifest,
ledger, and nine split ring captures exist, use the canonical Gate A finalizer:

```powershell
pwsh -File .github\skills\dump-overall\scripts\finalize_dump_overall.ps1 `
  -CaseId '{case_id}' -OutDir '{case_dump_overall}' `
  -Manifest '{case_dump_overall}\{case_id}_overall_manifest.json' `
  -Ledger '{case_dump_overall}\workflow_ledger.json' `
  -RequireThreadCategories -RequireSqlExec -RequireSchedulerInventory
```

Add `-RequireLatchContendedPages` for latch/page-contention cases. The finalizer publishes
`overall_completion_receipt.json` only after Completion PASS; the receipt binds the overall,
manifest, and ledger by SHA-256.

Before final response / `task_complete`, run the completion verifier. If it fails, the run is
incomplete and the final response must list the missing deliverables instead of claiming
completion:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\verify_case_deliverables.ps1 `
  -CaseId '{case_id}' `
  -OutDir 'reports/{case_id}_dump_overall' `
  -Ledger 'reports/{case_id}_dump_overall/workflow_ledger.json' `
  -Stage Completion
```

The overall pass produces a report (HTML or Markdown per user preference) with:

| Section | Source | Delivers |
|---------|--------|----------|
| *(header meta cards)* | Step 0–1 setup | dump metadata: bugcheck, build, PID, MemoryLoad, uptime, capture time |
| **第一步：OS 线程形态清单（mex us）** | 分析第一步 | SQLOS worker-state (stack-inferred)（纯列举）+ **`{case}_us.html`：按唯一栈折叠分页 + func filter 的线程清单** |
| **第二步：`Tasks.Enumerate` dump task 清单** | 分析第二步 | 权威 `Tasks.Enumerate` TaskState（**表 2** 状态汇总）+ **表 3** 按调度器分布 + **`{case}_tasks.html`：全量任务清单** |
| **第三步：执行语句线程统计（process_commands_internal）** | 分析第三步 | per-main summary（含 **子线程数**）+ runtime-state (blocking-chain) table（主 `主·N子`、子 `↳ tid`）+ **`sql_exec_thread.html`：每个 main 都有 tsqlstack 解出的语句** |
| **附加步骤：SOS 环形缓冲全量列举（9 条，含 SchedulerMonitor）** | 附加步骤 build_ringbuf_reports | 9 条 `!execute` 环形缓冲/摘要（**SchedulerMonitor 为第 5 条**），每条 **① dump 前 top-N 最新记录 + ② 规则化异常记录**（命中 0 显式标注）+ 类别直方图 + 陈旧标注 + **`{case}_sub_<expr>.html`：每条完整分页子报告** |

### 固化的报告产物集与结构 · Fixed artifact set & structure （每次都必须产出这一套）

⛔ **This exact file set and per-file structure is FIXED — reproduce it every run** (validated on
case 2606250030005483). All files live under
`C:\Users\lduan\sqlcsi-archive\reports\<case_id>_dump_overall\`, are **no-BOM UTF-8**, and use
the **Catppuccin Mocha** dark theme. The MAIN report links to every sub-report.

| File | Role | Required structure |
|------|------|--------------------|
| `<case>_overall_report.html` | **MAIN** report (概览) | ① header meta cards（build / PID / bugcheck / MemoryLoad / uptime / capture time）; ② **第一步 · OS 线程形态清单（mex us）**: SQLOS worker-state（stack-inferred）enumeration table + the **主线程表** with a **子线程** column rendering `主 · N 子` and indented `↳ tid` child rows, linking to `_us.html`; ③ **第二步 · `Tasks.Enumerate` dump task 清单**: `Tasks.Enumerate` TaskState（权威，**表 2**：TaskState / 数量 / 占比 + 合计）+ 按调度器分布（**表 3**：调度器 / 总数 / SUSPENDED / RUNNABLE / RUNNING / DONE，含「隐藏/系统 (id≥1048576)」聚合行 + 合计）, linking to `_tasks.html`; ④ **第三步 · 执行语句线程（process_commands_internal）**: per-main summary（含 **子线程数**）+ runtime-state blocking-chain table（`主·N子` / `↳ tid`）linking to `_sql_exec_thread.html`; ⑤ **附加步骤 · SOS 环形缓冲（9 条）** injected by `build_ringbuf_reports.ps1`（含 SchedulerMonitor 第 5 条）; ⑥ links to `_exception.html`; notes: us-note「分页折叠 + 函数名过滤」、T-SQL note「下表仅列摘要」. 表 2 / 表 3 的 HTML fragments 由 `emit_tasks_tables_html.ps1` 从 `_tasks_stats.json` sidecar 生成后作为 `raw` block 嵌入 manifest —— 数字与子报告完全一致。**纯列举，无关键观察/根因**. |
| `<case>_us.html` | 第一步 detail | one collapsible `<details>` **per unique stack**（thread count + state tag + `mod!func` signature）+ a **func-filter** toolbar（live substring highlight, non-match hidden）. Built by `scripts\gen_us_html.ps1`. |
| `<case>_tasks.html` | 第二步 detail | Full `Tasks.Enumerate` subreport, produced by `scripts\gen_tasks_full_html.ps1`. Canonical shape: **meta cards**（总行数 / 有效任务 / SUSPENDED / RUNNABLE / RUNNING / DONE）→ 读法说明 → **表 2** 状态汇总（含 合计）→ **表 3** 按调度器分布（含 隐藏/系统 聚合 + 合计）→ 值得注意的 RUNNING / RUNNABLE 行 → 全量任务清单（按 SchedulerId 升序）→ 过滤 minidump 采集局限 note. Row count of 全量清单 **== 原始 `Tasks.Enumerate` 行数**；表 2 分母 **== 表 2 合计 == 表 3 合计 == bound-task 数** (nullptr 占位行不计入). **`按 task_function 聚合` 章节被主动移除**（表 3 + 值得注意的行已足以呈现分布）. Also writes `<case>_tasks_stats.json` sidecar for overall-report reuse. |
| `<case>_sql_exec_thread.html` | 第三步 detail | **per exec main**（all N, not a sample）the full call stack + decoded `Input string:` T-SQL from `tsqlstack.js`; missing tail = `[PARTIAL]` / read-fault note. |
| `<case>_exception.html` | 异常 detail | enumeration of the exception record / faulting thread（raw facts only — no cause）. Built by `scripts\gen_exception_html.ps1` from a manifest JSON — see snippet below. |
| `<case>_sub_<expr>.html` ×9 | 附加步骤 detail | one paginated sub-report per ring-buffer expression（total records / columns / RecordType cards → 类别直方图 → 陈旧标注 → ② 值得注意的记录 → 全量分页明细 pageSize=100）. Built by `scripts\build_ringbuf_reports.ps1` from `txt_detail\{case}_{expr}.txt`. Row count == `!execute <expr>` 输出行数. The same script injects the **附加步骤** section (top-N + 异常 per expression) into the MAIN report. |
| `overall_completion_receipt.json` | **Gate A receipt** | Published atomically by `finalize_dump_overall.ps1` only after Completion PASS. Records overall/manifest/ledger SHA-256 and is the mandatory prerequisite for post-overall probes. |

**`{case}_exception.html`** — emit it with the committed generator (never hand-roll HTML). The
manifest lists the exception record cards, faulting-thread meta, the raw `.exr` / `!analyze -v`
text (HTML-escaped + wrapped in `<pre>`), and the call stack:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\gen_exception_html.ps1 `
  -Manifest 'reports/{case_id}_dump_overall/{case_id}_exception_manifest.json' `
  -Out      'reports/{case_id}_dump_overall/{case_id}_exception.html'
```

Manifest schema (cards / stats / sections[] with `title`, `pre`, `html`, `note`) is documented
in the script header. 纯列举 — 无 root-cause 判断。

> **Report assembly is script-driven** — no ad-hoc HTML in a `.ps1` at runtime. The MAIN
> `<case>_overall_report.html` is produced by the committed generator, with the workflow
> ledger passed as a hard pre-report gate:
>
> ```powershell
> powershell -NoProfile -ExecutionPolicy Bypass -File .github\skills\dump-overall\scripts\gen_overall_report.ps1 `
>   -Manifest 'reports/{case_id}_dump_overall/{case_id}_manifest.json' `
>   -Out      'reports/{case_id}_dump_overall/{case_id}_overall_report.html' `
>   -Ledger   'reports/{case_id}_dump_overall/workflow_ledger.json'
> ```
>
> The generator owns the fixed CSS (**Catppuccin Mocha**) + the section skeleton (header meta
> cards → 第一步 tables + links → 第二步 tables + links). The **manifest** carries all
> dump-specific content — header cards, table columns/rows, notes, links to the sub-reports.
> Cells are either `"text"` (auto HTML-escaped) or `{"html":"..."}` / `{"text":"...","class":"num mono"}`.
> Full schema is documented in the script header.
>
> On-disk output is guaranteed no-BOM UTF-8 via `[System.IO.File]::WriteAllText(path, html,
> (New-Object System.Text.UTF8Encoding($false)))`. **Never** use PowerShell here-strings for
> Chinese HTML (they corrupt to `?`). The `<case>_sql_exec.html` stub is optional/deletable —
> it is **NOT** part of the required set.

> ⛔ **DEFINITION-OF-DONE GATE — paste this checklist and tick every box BEFORE writing the
> report. Any unchecked / numeric-mismatch box ⇒ the overall pass is INCOMPLETE, go back:**
> - [ ] **Workflow ledger initialized at run start** with all required steps and deliverables
>       defaulting to `missing`; no final response / `task_complete` is allowed until
>       `verify_case_deliverables.ps1 -Stage Completion` prints PASS.
> - [ ] **Final deliverables are verified by script**, not by visual inspection: at minimum
>       `<case>_overall_report.html` exists and is non-empty, and every required ledger
>       artifact is `done`, `unavailable-with-evidence`, or `skipped-by-user`.
> - [ ] **第零步 DumpViewer** ran first via `run_dumpviewer.ps1`; the resolved **mode** is recorded
>       (exit `0`=PRIMARY / exit `2`=FALLBACK). PRIMARY: `dumpviewer_out\Reports\` populated and the
>       consumed sidecars converted via `parse_dumpviewer_json.js`. FALLBACK: full DScript/mirror path used.
> - [ ] **表2 任务数** = task list row count（权威），**NOT** the task.js sweep subset. PRIMARY source =
>       DumpViewer `tasks.json`; FALLBACK source = `!execute Tasks.Enumerate`. Self-check:
>       `表2 total == (task list rows)`; if it equals the sweep count → WRONG source.
> - [ ] **第一步 detail page** linked correctly by mode: **PRIMARY** → DumpViewer-native
>       `dumpviewer_out/Reports/ThreadDetails.html`(per-thread)+ `UniqueStacks.html`(per-stack),
>       and 表 1 from `parse_threaddetails_states.ps1`(权威 `worker_state`), **no `_us.html`**.
>       **FALLBACK**(parser exit 2 / whole-dump)→ **`{case}_us.html`** exists, has **one
>       `<details>` per unique stack**(count == 唯一栈数)**and** a working **func filter** toolbar
>       (from `!mex.us`). A flat summary table alone = FAIL.
> - [ ] **task.js sweep** (ALWAYS, both modes) covered **every** exec main **AND** each main's parallel
>       children (`gen_task_sweep.ps1` thread list = all mains + all children). Marker count == expected.
> - [ ] **Per-main summary table** row count **== number of exec mains** (no main omitted), and
>       每行都有 **子线程数**（`childCount`）与 **tsqlstack 结果**。
> - [ ] **Runtime-state table** shows each main as `主 · N 子` with its children as `↳ tid`
>       indented rows (from `task_fields.json`).
> - [ ] **`sql_exec_thread.html`** decoded T-SQL for **每一个** main（缺的标 `[PARTIAL]`/read-fault），
>       not just one sampled thread.
> - [ ] **附加步骤 · 9 条环形缓冲** complete：MAIN 报告含 9 个 section，每条都有 **① top-N 最新 + ② 规则化
>       异常（命中 0 显式绿色标注）**. PRIMARY: 5 rings from DumpViewer JSON + the **4 missing** via `!execute`
>       (HADR AR ×2 / BlockedProcessReport / MemoryBrokerClerk / ProcessSummary). FALLBACK: all 9 via
>       `build_ringbuf_reports.ps1`. 每条子报告全量行数 == 源（DumpViewer / `!execute`）输出行数；`txt_detail\` 留档。

- **Report language/format:** before generating, **ASK the user** for preferred language
  (English or 中文) and format (HTML or Markdown) — do not assume.
- **Report location:** save under the archive report root
  `C:\Users\lduan\sqlcsi-archive\reports\<case_id>_<brief_words>\` (never into the git repo).
- HTML uses the Catppuccin Mocha dark theme (see repo `copilot-instructions.md`).

> **Handoff to dump-analysis:** this snapshot is **pure enumeration** — it ends once the
> thread / task / scheduler / T-SQL lists are tabulated, with **no 关键观察 / 下一步 / 根因**.
> For any interpretation — subsystem deep-dive and root-cause compilation,
> memory / HADR / scheduler / locking / IO / connectivity — switch to the **dump-analysis**
> skill, which also holds the native dump-walking (Part 2), DScript deep reference (Part 3),
> and the cdb/LINQ command reference.
