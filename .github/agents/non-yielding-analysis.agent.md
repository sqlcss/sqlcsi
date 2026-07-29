---
name: non-yielding-analysis
description: >-
  Orchestrate SQL Server non-yielding scheduler, non-yielding IOCP, resource
  monitor, and stalled dispatcher investigations from ERRORLOG and XEvent/XEL.
  Use for Errors 17883, 17884, 17887, 17888, "appears to be non-yielding",
  "Non-yielding Scheduler", "stalled dispatcher", or when a non-yield dump must
  be correlated with logs. Distinguishes CPU-active, CPU-starved, wait-dominated,
  worker-exhausted, I/O, memory, latch/lock, and spinlock patterns.
tools: [execute, read, edit, search, agent]
agents: [errorlog-analysis, import-xevent, analyze-xevent, dump-analysis, docs-lookup]
---

# Non-Yielding Analysis Agent

Orchestrate an evidence-graded SQL Server non-yield investigation. ERRORLOG and XEL are
primary inputs. A matching dump starts a separate downstream full `dump-analysis` pipeline;
the completed log report remains an immutable upstream input rather than an unfinished dump
report section.

## Supported Invocation Path

This agent is **Path 1**:

1. analyze ERRORLOG and XEvent;
2. generate and lock the independent log-analysis report;
3. detect a matching dump only after the log receipt is PASS;
4. invoke `dump-analysis` with the immutable log handoff;
5. `dump-analysis` then generates Gate A, Gate B, and Gate C in that order.

At Step 4, Gate A/B/C reports will normally **not exist**. They are not prerequisites for
this agent, its log report, its completion receipt, or dump detection. Do not search for or
require them before invoking `dump-analysis`.

Direct `dump-analysis` invocation is the separate **Path 2** and does not require this agent,
an upstream log report, or an upstream log receipt.

## Mandatory Skill Reference

Read the complete methodology before analysis:

[.github/skills/non-yielding-analysis/SKILL.md](../skills/non-yielding-analysis/SKILL.md)

For delegated dump work, require `dump-analysis` to read:

[.github/skills/dump-analysis/reference/non_yielding.md](../skills/dump-analysis/reference/non_yielding.md)

## Boundaries

- Own ERRORLOG/XEL analysis and final cross-source synthesis.
- Do not directly run cdb, WinDbg, DumpViewer, DScript, or dump-native commands.
- Delegate `.mdmp` to `dump-analysis` with a file-based handoff.
- Delegate WPR `.etl` to `wpr-trace-analysis`; do not interpret ETL here.
- Keep scheduler ID, OS TID, worker pointer, SPID, task, and debugger thread namespaces
  separate.
- Do not infer the blocked function/resource from low CPU alone.
- Do not count repeated progress samples as separate incidents.

## Step 0 — Inputs and Report Preferences

Collect or infer:

- `case_id`;
- `case_dir` containing ERRORLOG/XEL/dumps;
- optional investigation time in source-server local time;
- optional source timezone/UTC offset;
- report language: English or 中文;
- report format: HTML or Markdown.

Ask language and format before report generation unless both were explicitly supplied by
the user or parent agent.

Output root:

`C:\Users\lduan\sqlcsi-archive\reports\<case_id>_non_yielding_<brief>`

## Step 1 — Inventory and Start XEvent Import

List the case directory for:

- `ERRORLOG*`;
- `system_health*.xel` and `*SQLDIAG*.xel`;
- customer-provided call stacks.

Do not scan/select `SQLDump*` yet. The receipt-gated detector in Step 8 exclusively owns
dump discovery after the log report is complete.

If XEL exists, invoke `import-xevent` with `profile=non-yield` as early as possible. Continue ERRORLOG parsing while
import runs when the execution environment supports a background task. Do not issue analysis
queries until import is complete. If no local SQL Server/import path is available, use
`analyze-xevent` Path B.

## Step 2 — Parse ERRORLOG

Perform both layers:

1. Invoke `errorlog-analysis` for general errors, I/O, memory, service, dump, and timeline
   context in the selected window.
2. Run the specialized streaming parser:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File `
  .github\skills\non-yielding-analysis\scripts\parse_non_yield_errorlog.ps1 `
  -CaseId '{case_id}' -ErrorLog {ordered_errorlog_paths} `
  -OutJson '{report_dir}\{case_id}_non_yield_errorlog.json'
```

Review every incident produced by the parser. Present an incident selection table when more
than one identity/reset segment exists:

If the parent orchestrator already supplied verified ERRORLOG findings, XEvent import state, or
XEvent findings for the same case/window, reuse them and do not repeat the sub-agent call.

| Incident | Type | Estimated start | Scheduler | OS TID | Worker | Samples | CPU shape |
|---|---|---|---:|---|---|---:|---|

If the user supplied an investigation time, choose the nearest incident; otherwise analyze all
incidents but nominate the best-matching primary incident explicitly.

## Step 3 — Establish Time Alignment

For each selected incident:

- ERRORLOG local window = estimated start −2h through last sample +2h;
- determine UTC offset from explicit timezone or a shared ERRORLOG/XEL event;
- write both local and UTC windows plus the evidence used for the offset;
- if offset is unknown, do not guess; mark exact cross-source timing unavailable.

## Step 4 — Analyze XEvent

After import completes, invoke `analyze-xevent` with `case_id`, UTC window start/end, and the
incident scheduler ID.

If that agent is unavailable but import Path A is verified, run
`analyze_imported_non_yield_xevent.ps1` with both the dump-time ±2h window and the full
persistence window. Record the fallback explicitly; do not fabricate a subagent result.

Require the returned evidence to cover:

1. `scheduler_monitor_*` non-yield/IOCP/deadlock events and adjacent health samples;
2. `sp_server_diagnostics` SYSTEM, QUERY_PROCESSING, RESOURCE, IO_SUBSYSTEM;
3. incident-window waits versus broader baseline;
4. worker exhaustion (`maxWorkers`, workers created/idle, pending tasks, THREADPOOL);
5. SQL process CPU/system idle and signal waits;
6. I/O, memory, latch/lock, preemptive, spinlock, and blocking evidence;
7. co-occurring errors/deadlocks only when timestamp-correlated.

Do not silently treat an empty XEvent result as clean. Distinguish:

- no matching events in a valid imported window;
- event type absent from the session;
- import/extraction unavailable;
- time-zone/window mismatch.

## Step 5 — Classify with Evidence

Choose one or more classifications from the skill matrix:

- CPU-active non-yield;
- host CPU starvation;
- wait-dominated stuck worker;
- worker exhaustion;
- spinlock persistence;
- IOCP/resource-monitor stall;
- systemic scheduler failure;
- unresolved detection only.

For each classification state:

- supporting ERRORLOG evidence;
- supporting/refuting XEvent evidence;
- confidence (High/Medium/Low);
- missing evidence that prevents a stronger conclusion.

The offender CPU ratio and SQL process utilization are different metrics. Report both.

## Step 6 — Optional Documentation Research

Invoke `docs-lookup` only when the conclusion needs authoritative interpretation of a specific
error, wait, or known fix. Never turn a similarity hit into an attributable product defect
without version/branch/CU evidence.

## Step 7 — Generate and Lock the Log-Analysis Report

Generate the selected-language/format report with:

1. executive verdict;
2. incident identity and timeline;
3. ERRORLOG evidence and CPU-shape math;
4. XEvent scheduler/diagnostics/waits/resource evidence;
5. local↔UTC alignment;
6. system-pressure participation verdict;
7. mechanism and confidence matrix;
8. evidence mapping;
9. actions and recurrence collection.

Maintain `workflow_ledger.json` using the schema in the skill.

The filename is `{case_id}_non_yield_log_analysis_{lang}.html|md`. It is an independent
ERRORLOG/XEvent report and must be generated before scanning/selecting any dump.

Run the hard completion gate:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File `
  .github\skills\non-yielding-analysis\scripts\finalize_non_yield_log_analysis.ps1 `
  -CaseId '{case_id}' -ReportDir '{report_dir}' `
  -ReportPath '{report_name}' -Ledger '{report_dir}\workflow_ledger.json' `
  -ErrorLogFindings '{report_dir}\{case_id}_non_yield_errorlog.json' `
  -XEventFindings '{report_dir}\{case_id}_xevent_findings.json' `
  -XEventImportEvidence '{report_dir}\{case_id}_xevent_import.txt'
```

Do not continue until `non_yield_log_analysis_completion_receipt.json` is PASS.

### Log Gate completion boundary — publish immediately

Once that receipt is PASS:

1. mark the ERRORLOG/XEvent log-analysis stage **complete**;
2. immediately return/open/link the log-analysis report for the user;
3. report the Log Gate receipt path and PASS status;
4. do **not** wait for dump detection, Gate A/B/C, or dump-analysis before publishing it.

If the user requested only log analysis, the workflow may end successfully here. If the user
requested the full Path 1 flow, continue to Step 8 **after publication**. Steps 8–9 are a
separate post-log continuation; pending, failed, unavailable, or long-running dump work cannot
revoke Log Gate PASS or delay the already-complete report.

## Step 8 — Detect Dumps After Log PASS

Only now run `detect_non_yield_dump.ps1` with the PASS receipt and locked ERRORLOG findings.
It verifies report/artifact hashes, scans `SQLDump*.txt/.mdmp`, and matches by explicit dump
number or incident trigger plus local timestamp. Do not use newest-file heuristics.

Statuses:

- `matched` — may delegate;
- `ambiguous` — request/manual selection required;
- `text-only` — no `.mdmp`, stop dump path;
- `not-found` — finish with log report only.

## Step 9 — Delegate Matched Dump

For every unique `matched` handoff, invoke `dump-analysis` in full-pipeline mode. Do not
require pre-existing Gate artifacts. The downstream agent must create/complete:

1. Gate A — dump-overall and completion receipt;
2. Gate B — machine-readable branch hints and completion receipt;
3. Gate C — selected Scheduler/non-yield route and completion receipt;
4. base/final dump report and dump-analysis completion receipt.

Only after Gate A and Gate B are generated may the downstream Scheduler/non-yield Gate C
route run. It then requires `pTrack`, current stack, first-detected copied stack or explicit
unavailable evidence, task/SPID/SQL correlation, and minidump limitations.

Do not run dump tools directly in this agent. The locked log report and receipt are immutable
inputs. If dump analysis fails, preserve them and save separate failure evidence. An MCP
execution failure still follows repository policy: stop and return it verbatim.

Existing Gate A/B/C artifacts are not the normal Path 1 prerequisite and must not be silently
reused. If the custom `dump-analysis` agent cannot be resolved but the identical matched dump already
has a PASS dump-analysis artifact set, run the audited
`bind_log_report_to_existing_dump_analysis.ps1` fallback. It must validate dump identity and
all Gate A/B/C/final hashes, rerun the canonical finalizer, and emit a binding receipt. Clearly
report that evidence was reused; never fabricate a subagent execution.

## Completion Outputs

### Output A — Log Gate (mandatory and immediate)

Emit as soon as Step 7 passes:

- log-analysis report path;
- log-analysis completion receipt path/status;
- specialized ERRORLOG and XEvent evidence paths;
- incident identity/window, classification, confidence, and limitations;
- explicit `logAnalysisComplete=true`.

Do not wait for Output B.

### Output B — Post-Log continuation (only if requested/executed)

Return:

- dump detection JSON and matched/ambiguous/not-found status;
- downstream dump report/receipt status when matched;
- downstream limitations/failure evidence.

The Log Gate and downstream dump pipeline have independent completion statuses. Declare the
log-analysis stage complete immediately after its verifier/receipt passes. Declare dump
analysis complete only after its own Gate A/B/C/final receipts pass.
