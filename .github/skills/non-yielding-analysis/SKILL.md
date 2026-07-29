---
name: non-yielding-analysis
description: >-
  Analyze SQL Server non-yielding scheduler, non-yielding IOCP, non-yielding
  resource monitor, and stalled dispatcher incidents from ERRORLOG and XEvent
  (.xel) data. Extracts Errors 17883/17884/17887/17888, scheduler ID, OS TID,
  worker, CPU/idle/interval samples, and correlates scheduler_monitor,
  sp_server_diagnostics, waits, I/O, memory, and worker pressure. Use when the
  user says "non-yielding scheduler", "non-yielding IOCP", "stalled dispatcher",
  "17883", "17884", "17887", "17888", "分析 non-yielding", or provides logs/XEL
  generated around a non-yield incident.
context: fork
---

# SQL Server Non-Yielding Analysis

## Scope and Ownership

This skill owns the **ERRORLOG + XEvent** investigation of:

- non-yielding scheduler;
- non-yielding IOCP;
- non-yielding resource monitor;
- stalled/stuck dispatcher;
- Errors 17883, 17884, 17887, and 17888;
- repeated `appears to be non-yielding on Scheduler N` progress samples.

Input-type boundaries are strict:

| Input | Owner |
|---|---|
| ERRORLOG + `*.xel` | this skill / `non-yielding-analysis` agent |
| `.mdmp` / `.dmp` | delegate to `dump-analysis` |
| WPR `.etl` | delegate to `wpr-trace-analysis` |

This skill does not run DumpViewer, cdb, WinDbg, or DScript. If a matching dump is
available, it builds an explicit handoff and delegates to `dump-analysis`, which must
run dump-overall before the native non-yield route.

## Invocation Architecture

Two independent entry paths are supported:

| Path | Entry point | Initial state | Gate ownership |
|---|---|---|---|
| **Path 1** | `non-yielding-analysis` | ERRORLOG/XEL; Gate A/B/C normally absent | This skill completes the log report, then `dump-analysis` generates Gate A → B → C if a dump is matched |
| **Path 2** | `dump-analysis` directly | Dump only; no upstream log report required | `dump-analysis` generates Gate A → B → C |

In Path 1, the PASS log-analysis receipt is the only upstream prerequisite for dump detection.
Gate A/B/C must not be required, discovered, or synthesized before invoking `dump-analysis`.
They belong to the downstream dump pipeline.

## Report Policy

Before generating a report, ask for:

1. language: English or 中文;
2. format: HTML or Markdown.

Skip the question only if the parent/user already supplied both. Save reports under:

`C:\Users\lduan\sqlcsi-archive\reports\<case_id>_non_yielding_<brief>`

HTML uses the repository Catppuccin Mocha theme.

## Analysis Modes

| Mode | Inputs | Result |
|---|---|---|
| Basic complete | ERRORLOG + XEL | correlated log/XEvent root-cause assessment |
| Basic partial | ERRORLOG, no usable XEL | ERRORLOG incident identity and CPU-shape assessment with explicit XEvent limitation |
| Downstream dump analysis | PASS log-analysis receipt + matching `.mdmp` | separate full dump pipeline that creates Gate A/B/C and its own report |

Always complete and lock the Basic log-analysis report first. Dump detection is forbidden
before `non_yield_log_analysis_completion_receipt.json` is PASS. The later dump workflow is
fail-open and separate: it must not modify, suppress, or invalidate the log report.

---

# BASIC ANALYSIS

## B0. Inventory and Start XEL Import

Inventory `{case_dir}` for:

- `ERRORLOG`, `ERRORLOG.1`, ...;
- `system_health*.xel`, `*SQLDIAG*.xel`;
- optional customer-provided stacks.

Do **not** scan or select `SQLDump*` in this phase. Dump discovery begins only after the
independent log-analysis report receipt is PASS.

If XEL files exist, start/continue `import-xevent` immediately with the `non-yield` profile,
then parse ERRORLOG while
import proceeds. Do not parse XEL binary directly with text tools.

The deterministic profile command is:

```powershell
sqlcmd -S localhost -E -v `
  case_id="{case_id}" xel_path="{case_dir}\system_health_0_*.xel" days="30" `
  -i .github\skills\non-yielding-analysis\scripts\import_xel_non_yield.sql
```

It retains all raw XML but shreds only errors, waits, diagnostics, scheduler, deadlocks, and
memory broker; connectivity/security materialization is intentionally skipped.

Use existing components rather than copying them:

- general ERRORLOG context: `errorlog-analysis`;
- XEL import: `import-xevent`;
- XEvent interpretation: `analyze-xevent`;
- specialized non-yield ERRORLOG extraction: bundled script below.

## B1. Parse Non-Yield ERRORLOG Records

Run the streaming parser, oldest ERRORLOG first:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File `
  .github\skills\non-yielding-analysis\scripts\parse_non_yield_errorlog.ps1 `
  -CaseId '{case_id}' `
  -ErrorLog '{case_dir}\ERRORLOG.4','{case_dir}\ERRORLOG.3','{case_dir}\ERRORLOG.2','{case_dir}\ERRORLOG.1','{case_dir}\ERRORLOG' `
  -OutJson '{report_dir}\{case_id}_non_yield_errorlog.json'
```

Optional bounds use source-server local time:

```powershell
  -From '2026-06-17 13:00:00' -To '2026-06-17 18:00:00'
```

The parser handles UTF-16LE (with or without BOM), UTF-16BE, and UTF-8. It emits:

- incidents grouped by OS TID + worker + scheduler;
- repeated progress samples;
- estimated incident start;
- process utilization, system idle, and offender CPU ratio;
- trigger headers and Errors 17883/17884/17887/17888;
- nearby dump references;
- local analysis windows, but no guessed UTC conversion.

### Primary ERRORLOG signatures

Trigger header:

```text
* Non-yielding Scheduler
* Non-yielding IOCP
* Non-yielding Resource Monitor
* Stalled Dispatcher
```

Progress sample:

```text
Process 0:0:0 (0x3a8c) Worker 0x000003DB2803C160 appears to be
non-yielding on Scheduler 42. Thread creation time: ...
Approx Thread CPU Used: kernel 890 ms, user 1750 ms.
Process Utilization 39%. System Idle 56%. Interval: 70841 ms.
```

Also search standard/localized error lines for 17883, 17884, 17887, and 17888.
Text signatures are primary because not every build logs an explicit 1788x line.

## B2. Build Incident Identity and Timeline

For every incident, retain these namespaces separately:

| Field | Meaning |
|---|---|
| incident type | scheduler / IOCP / resource monitor / stalled dispatcher |
| source SPID | ERRORLOG source column or stack-header SPID; not automatically the offender session |
| scheduler ID | affected SQLOS scheduler |
| OS TID | hexadecimal Windows thread ID in parentheses |
| worker | SQLOS worker pointer |
| thread creation time | lifetime discriminator for TID reuse |
| interval | elapsed detection interval reported by SchedulerMonitor |
| kernel/user CPU | cumulative offender CPU sample |
| process utilization | SQL Server process CPU percentage |
| system idle | host idle percentage |

### Do not overcount repeated samples

Multiple lines for the same OS TID + worker + scheduler with increasing `Interval` are
**one incident**, not multiple non-yield incidents. Start a new incident only when:

- identity changes;
- sample gap exceeds 15 minutes; or
- `Interval` resets/decreases.

### Estimate the start

`estimated_start = first_sample_timestamp - first_sample.interval_ms`

This is an estimate of when the monitor interval began. Keep the stack-dump trigger time,
first sample, and estimated start as separate values.

### CPU-shape calculation

For multiple samples:

`worker_cpu_ratio = 100 × Δ(kernel_ms + user_ms) / Δ(interval_ms)`

For one sample, use cumulative CPU divided by interval.

| Worker CPU ratio | Classification | Safe interpretation |
|---|---|---|
| `<= 20%` | wait-dominated | not a pure CPU tight loop; exact wait still unproven |
| `20–70%` | mixed | both CPU work and off-CPU delay may participate |
| `>= 70%` | CPU-active | runaway CPU/spin/non-yield code path plausible |

Do not substitute SQL process utilization for offender CPU ratio. A process can be at 30%
while one worker is CPU-active, or at 90% while the offender is sleeping.

### Important evidence boundaries

- Low offender CPU does not identify I/O, latch, lock, or memory by itself.
- A stack-dump header SPID may be dumper/request context, not the offending SQL SPID.
- No later sample is not proof of recovery.
- `appears to have yielded`/recovery text is stronger than simple silence.
- ERRORLOG identifies detection and persistence, not the blocked function/resource.

## B3. Select the Correlation Window and Align Time Zones

Default per-incident window:

- local start: `estimated_start - 2 hours`;
- local end: `last_sample + 2 hours`.

ERRORLOG is source-server local time. XEL `@timestamp` is UTC. Never compare them raw.
Determine offset using, in order:

1. explicit source timezone / `SYSDATETIMEOFFSET()` captured with the case;
2. one event visible in both ERRORLOG and XEL;
3. server configuration metadata.

Record the source of the offset. If unknown, do not guess: report separate local/UTC
windows and mark cross-correlation timing as limited.

## B4. Analyze XEvent in the Incident Window

After import completes, invoke `analyze-xevent` with:

- `case_id`;
- UTC `window_start` / `window_end`;
- incident scheduler ID and ERRORLOG timestamp as correlation keys.

If the `analyze-xevent` subagent is unavailable but Path A import succeeded, run the bundled
deterministic fallback for the same methodology surfaces:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File `
  .github\skills\non-yielding-analysis\scripts\analyze_imported_non_yield_xevent.ps1 `
  -CaseId '{case_id}' `
  -ImmediateStartUtc '{dump_time_utc_minus_2h}' `
  -ImmediateEndUtc '{dump_time_utc_plus_2h}' `
  -PersistenceStartUtc '{estimated_start_utc}' `
  -PersistenceEndUtc '{last_sample_utc_plus_2h}' `
  -OutJson '{report_dir}\{case_id}_xevent_findings.json'
```

Record whether primary `analyze-xevent` or this fallback produced the findings. Do not run
both and silently choose the preferred result.

Path B fallback is allowed when SQL import is unavailable:

```powershell
node scripts/parse_xevent.js '{report_dir}\{case_id}_xevent_extract.json' `
  --errorlog '{report_dir}\{case_id}_errorlog_findings.json' `
  --json --output '{report_dir}\{case_id}_xevent_findings.json'
```

### Mandatory XEvent surfaces

#### 1. Scheduler monitor

```sql
SELECT event_name, event_time, sql_cpu_pct, system_idle_pct,
       scheduler_id, nonyielding_count
FROM xe.scheduler
WHERE case_id = '{case_id}'
  AND event_time BETWEEN '{utc_start}' AND '{utc_end}'
  AND (event_name LIKE '%non_yielding%'
       OR event_name LIKE '%deadlock%'
       OR nonyielding_count > 0
       OR sql_cpu_pct > 75)
ORDER BY event_time;
```

Use `xe.raw_events.event_data` when shredded columns are null or the exact event payload is
needed. Preserve the event name: scheduler, IOCP, deadlock/stalled dispatcher are not
interchangeable.

#### 2. sp_server_diagnostics

Query WARNING/ERROR and adjacent CLEAN samples for:

- `SYSTEM`: `nonYieldingTasksReported`, spinlock backoffs, page faults, SQL/system CPU;
- `QUERY_PROCESSING`: max/created/idle workers, pending tasks, deadlocked schedulers,
  top waits, and `<blockingTasks>` SQL;
- `RESOURCE`: committed/target memory, OOM counters, pool state;
- `IO_SUBSYSTEM`: long I/Os and I/O latch timeouts.

```sql
SELECT event_time, component, state_desc, data_xml
FROM xe.diagnostics
WHERE case_id = '{case_id}'
  AND event_time BETWEEN '{utc_start}' AND '{utc_end}'
ORDER BY event_time, component;
```

#### 3. Waits

Compare the narrow incident window (`±5 minutes`) with the broader `±2 hours` baseline:

```sql
SELECT wait_type, COUNT(*) AS cnt, SUM(duration_ms) AS total_ms,
       SUM(signal_duration_ms) AS signal_ms, MAX(duration_ms) AS max_ms
FROM xe.waits
WHERE case_id = '{case_id}'
  AND event_time BETWEEN '{utc_narrow_start}' AND '{utc_narrow_end}'
GROUP BY wait_type ORDER BY total_ms DESC;
```

Prioritize evidence for:

| Evidence | Possible mechanism |
|---|---|
| high signal time, `SOS_SCHEDULER_YIELD` | CPU scheduling pressure |
| `THREADPOOL`, pending tasks, low idleWorkers | worker exhaustion |
| `PAGEIOLATCH_*`, long I/O | data-file I/O stall |
| `WRITELOG` | transaction-log flush stall |
| `LATCH_*` | non-buffer latch contention |
| `LCK_M_*` | lock blocking |
| `RESOURCE_SEMAPHORE` | query memory grant |
| `PREEMPTIVE_*` | external/OS call |
| spinlock backoff increase | spin contention; lock identity still needs stack/dump |

XEvent wait sessions are thresholded and incomplete. Absence of a wait is not proof that
it did not occur.

#### 4. Errors and co-occurring events

Query `xe.errors`, deadlocks, connectivity, memory broker, and HADR only when they overlap
the incident. Separate baseline noise from a timestamp-local spike.

## B5. Classify the Incident

Use an evidence matrix; do not force a single cause when data is incomplete.

| Classification | Required supporting evidence |
|---|---|
| CPU-active non-yield | high offender CPU ratio; preferably high SQL CPU/low idle, signal waits, or CPU-active stack |
| host CPU starvation | high process/system CPU, low idle, scheduler pressure across multiple schedulers; offender may have low CPU because it cannot run |
| wait-dominated stuck worker | low offender CPU ratio plus matching I/O/latch/lock/memory/preemptive evidence |
| worker exhaustion | THREADPOOL, high pendingTasks, workersCreated near maxWorkers, low idleWorkers |
| spinlock persistence | repeated non-yield plus spin/backoff stack or counters; exact spinlock/owner requires dump or supplied stack |
| IOCP/resource monitor stall | matching event type plus I/O/resource diagnostics; do not relabel as scheduler incident |
| systemic scheduler failure | multiple schedulers/non-yield events clustered in <5 minutes, often with deadlocked scheduler evidence |
| unresolved | detection is proven but blocking function/resource is not |

### Confidence labels

- **High**: same mechanism independently shown by ERRORLOG and XEvent/dump stack.
- **Medium**: strong timing and resource correlation, but no stack/resource identity.
- **Low**: only non-yield detection is available.

## B6. Log-Analysis Workflow Ledger

Create `{report_dir}\workflow_ledger.json`:

```json
{
  "caseId": "{case_id}",
  "requiredSteps": {
    "errorlog_non_yield_context": { "status": "done", "evidence": ["{case_id}_non_yield_errorlog.json"] },
    "xevent_import": { "status": "done", "evidence": ["{case_id}_xevent_import.txt"] },
    "xevent_environment_context": { "status": "done", "evidence": ["{case_id}_xevent_findings.json"] },
    "synthesized_log_conclusion": { "status": "done", "evidence": ["{case_id}_non_yield_log_analysis_en.html"] }
  }
}
```

If no XEL exists, use `status: unavailable-with-evidence` and retain a file describing the
missing input. The report is Basic partial; do not claim XEvent correlation.

## B7. Generate the Independent Log-Analysis Report

Generate this report **before detecting or selecting any dump**. For English HTML, use:

`{case_id}_non_yield_log_analysis_en.html`

It contains only ERRORLOG/XEvent conclusions and must stand on its own. Required sections:

1. executive verdict and confidence;
2. source-server local incident time and UTC-aligned XEvent window;
3. ERRORLOG trigger/progress samples and offender CPU ratio;
4. `import-xevent` completion/distribution evidence;
5. `analyze-xevent` scheduler monitor, diagnostics, waits, memory, I/O, and worker context;
6. system-pressure participation verdict;
7. cross-source timeline and evidence mapping;
8. limitations and actions.

Do not embed dump conclusions or wait for dump-analysis. A later case index may link both
independent reports, but this log report remains immutable.

## B8. Verify and Lock the Log Report

First run the report verifier, then publish the hard sequencing receipt:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File `
  .github\skills\non-yielding-analysis\scripts\finalize_non_yield_log_analysis.ps1 `
  -CaseId '{case_id}' -ReportDir '{report_dir}' `
  -ReportPath '{case_id}_non_yield_log_analysis_en.html' `
  -Ledger '{report_dir}\workflow_ledger.json' `
  -ErrorLogFindings '{report_dir}\{case_id}_non_yield_errorlog.json' `
  -XEventFindings '{report_dir}\{case_id}_xevent_findings.json' `
  -XEventImportEvidence '{report_dir}\{case_id}_xevent_import.txt' `
  -AdditionalEvidence '{report_dir}\{case_id}_errorlog_findings.json'
```

This writes `non_yield_log_analysis_completion_receipt.json` with SHA-256 hashes for the
report, ledger, ERRORLOG findings, XEvent findings, and import evidence. No dump detection or
delegation is allowed unless this receipt exists with `status=PASS`.

### Log Gate completion boundary

`status=PASS` means the log-analysis report is fully complete and publishable. Immediately
open/link/return it to the user; do not wait for dump detection, dump-overall, Gate A/B/C, or
the dump final report. The receipt must encode:

- `completionBoundary = Log Gate`;
- `logAnalysisComplete = true`;
- `reportPublicationAllowed = true`;
- `downstreamDumpRequiredForLogCompletion = false`.
- `receiptIsImmutableAfterPublication = true`.

If the task requested log analysis only, completion is allowed here. The section below is a
separate post-log continuation. Its absence, duration, or failure does not alter Log Gate PASS
or the immutable report hash.

Executable invariants:

- `finalize_non_yield_log_analysis.ps1` has no case/dump-selection input and cannot start
  dump detection;
- `detect_non_yield_dump.ps1` refuses to run unless all Log Gate completion/publication/
  immutability fields are valid;
- detector success or failure must preserve both the report and receipt SHA-256;
- Post-Log state is written only to separate detection/binding/dump receipts, never back into
  the Log Gate receipt.

---

# POST-REPORT DUMP DETECTION AND DELEGATION

## D1. Detect and Match Dumps Only After Log PASS

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File `
  .github\skills\non-yielding-analysis\scripts\detect_non_yield_dump.ps1 `
  -CaseId '{case_id}' -CaseDir '{case_dir}' -ReportDir '{report_dir}' `
  -LogCompletionReceipt '{report_dir}\non_yield_log_analysis_completion_receipt.json' `
  -ErrorLogFindings '{report_dir}\{case_id}_non_yield_errorlog.json'
```

The detector validates receipt and artifact hashes before scanning. It uses the explicit
ERRORLOG `SQLDumpNNNN` reference when available. Otherwise it correlates:

- stack-dump trigger timestamp;
- `SQLDumpNNNN.txt` header timestamp/type;
- dump metadata timestamp;
- incident type.

It emits `{case_id}_non_yield_dump_detection.json`. Only `status=matched` may be delegated.
`ambiguous`, `text-only`, and `not-found` require manual resolution or stop dump processing.
Do not choose a dump solely because it is newest.

## D2. File-Based Handoff

Write `{case_id}_non_yield_dump_handoff.json` containing:

```json
{
  "case_id": "{case_id}",
  "case_dir": "{case_dir}",
  "dump_path": "{matched_mdmp}",
  "log_report": "{report_dir}\\{case_id}_non_yield_log_analysis_en.html",
  "log_completion_receipt": "{report_dir}\\non_yield_log_analysis_completion_receipt.json",
  "log_completion_receipt_sha256": "{sha256}",
  "trigger": "non-yielding scheduler",
  "incident_type": "scheduler",
  "estimated_start_local": "{timestamp}",
  "window_start_utc": "{timestamp}",
  "window_end_utc": "{timestamp}",
  "scheduler_id": 42,
  "os_tid": "0x3a8c",
  "worker": "0x...",
  "worker_cpu_ratio_pct": 3.7,
  "process_utilization_pct": 39,
  "system_idle_pct": 56,
  "errorlog_evidence": "{case_id}_non_yield_errorlog.json",
  "xevent_evidence": "{case_id}_xevent_findings.json"
}
```

## D3. Delegate to dump-analysis

Invoke `dump-analysis` with the handoff. Require:

1. no pre-existing Gate A/B/C artifact; absence is the normal fresh-run state;
2. generate dump-overall (Gate A) and pass its verifier first;
3. generate Gate B branch hints after Gate A PASS;
4. initialize/execute Gate C Scheduler/non-yield route after Gate B PASS;
5. `.github/skills/dump-analysis/reference/non_yielding.md` methodology;
6. `pTrack` identity/timing;
7. dump-time current stack;
8. first-detected copied stack from `g_copiedStackInfo.threadContext` or explicit
   unavailable evidence;
9. task/SPID/SQL correlation where recoverable;
10. minidump limitations;
11. final dump report and completion receipt.

The dump workflow owns cdb and all dump report generation. This skill only consumes the
returned report paths and structured findings. The log report and log receipt are read-only
prerequisites and must not be regenerated by `dump-analysis`.

If delegation fails, preserve the PASS log report/receipt and write separate dump failure
evidence. Do not invalidate or rewrite the ERRORLOG/XEvent report.

If the `dump-analysis` agent name is unavailable but the **identical matched dump** already
has a complete PASS dump-analysis directory, use the audited reuse fallback rather than
pretending an agent ran:

```powershell
pwsh -File .github\skills\non-yielding-analysis\scripts\bind_log_report_to_existing_dump_analysis.ps1 `
  -DetectionJson '{report_dir}\{case_id}_non_yield_dump_detection.json' `
  -DumpAnalysisDir '{existing_dump_analysis_dir}'
```

It validates dump identity and all existing Gate A/B/C/final hashes, injects the immutable
upstream log-report link, reruns the canonical dump finalizer, and writes
`non_yield_log_to_dump_binding_receipt.json`. Reuse is forbidden if any identity/hash check
fails.

---

# LOG-ANALYSIS REPORT CONTRACT

The synthesized report must contain:

1. **Executive verdict** — incident type, affected scheduler/thread/worker, classification,
   confidence, and what remains unresolved.
2. **ERRORLOG evidence** — trigger, 1788x errors, timeline, repeated samples, CPU-shape math,
   process utilization/system idle, dump mapping.
3. **XEvent evidence** — scheduler monitor, diagnostics, waits, errors, memory, I/O, worker
   pressure, and explicit system-pressure verdict.
4. **Cross-source timeline** — local and UTC values plus timezone evidence.
5. **Mechanism assessment** — CPU-active, host-starved, wait-dominated, worker exhausted,
   spinlock, IOCP/resource monitor, systemic, or unresolved.
6. **Evidence mapping** — every major claim mapped to ERRORLOG/XEvent/dump evidence and
   limitation.
7. **Actions** — evidence-specific containment and recurrence collection; do not recommend a
   CU/trace flag without attributable documentation.

Run the verifier:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File `
  .github\skills\non-yielding-analysis\scripts\verify_non_yield_report.ps1 `
  -CaseId '{case_id}' -ReportDir '{report_dir}' `
  -ReportPath '{case_id}_non_yield_log_analysis_{lang}.html' `
  -Ledger '{report_dir}\workflow_ledger.json' `
  -RequireXEventEvidence
```

## Report Summary Template

```markdown
## Non-Yielding Root Cause — Case {case_id}

### Incident identity
- Type: {scheduler | IOCP | resource monitor | stalled dispatcher}
- Estimated start: {local} / {UTC}
- Scheduler / OS TID / Worker: {id} / {tid} / {worker}
- Samples / max interval: {count} / {ms}

### CPU shape
- Offender CPU ratio: {ratio}% — {wait-dominated | mixed | cpu-active}
- SQL process utilization: {range}%
- System idle: {range}%

### XEvent correlation
- Scheduler events: {summary}
- Diagnostics: {SYSTEM / QUERY_PROCESSING / RESOURCE / IO}
- Incident-window waits: {summary}
- Systemic pressure participated: {yes/no/unresolved}

### Conclusion
- Most likely mechanism: {mechanism}
- Confidence: {High/Medium/Low}
- Proven: {facts}
- Unresolved: {gaps}
```

## References

- General ERRORLOG workflow: [errorlog-analysis](../errorlog-analysis/SKILL.md)
- XEvent workflow and schemas: [xevent-analysis](../xevent-analysis/SKILL.md)
- Dump-native methodology: [dump-analysis non-yield reference](../dump-analysis/reference/non_yielding.md)
- Wait classification: [.github/references/wait-types.md](../../references/wait-types.md)
