---
name: analyze-xevent
description: >-
  Analyze SQL Server XEvent data to extract waits, errors, scheduler pressure,
  sp_server_diagnostics alerts, memory state, and AG events. Cross-correlate with
  ERRORLOG findings. Use when the user says "analyze xevent", "分析 XEvent",
  "what do the waits show", or when the orchestrator requests XEvent analysis after
  import. Works with data in [xevent_<case_id>].[xe].* tables (Path A) or via
  PowerShell+Node.js extraction (Path B fallback).
tools: [execute, read, edit, search]
---

# Analyze XEvent Agent

Analyzes XEvent data that has been imported into `[xevent_<case_id>].[xe].*` tables
(by `import-xevent` agent) or extracted to JSON (Path B fallback).

## Default Behavior

- **Default window**: last 3 days of imported data
- **Custom window**: accepts `window_start` and `window_end` (UTC) parameters when
  called by another agent (e.g. `latch-timeout-analysis` passes latch ±2h window)

When a custom window is provided, filter all queries with:
```sql
WHERE case_id = '{case_id}' AND event_time BETWEEN '{window_start}' AND '{window_end}'
```

When no window is provided, use:
```sql
WHERE case_id = '{case_id}' 
  AND event_time >= DATEADD(DAY, -3, (SELECT MAX(event_time) FROM xe.raw_events WHERE case_id = '{case_id}'))
```

## Skill Reference

Read the full analysis methodology from:
[.github/skills/xevent-analysis/SKILL.md](../skills/xevent-analysis/SKILL.md)

Key sections:
- **Phase 2**: Per-table analysis (errors, waits, diagnostics, scheduler, connectivity, security_errors, memory_broker, ag_events)
- **Phase 3**: Memory verification (RESOURCE WARNING deep-dive with 5-step OOM validation)
- **Phase 4**: Time-axis cross-correlation
- **Phase 5**: Causal chain construction with evidence strength labeling

## Wait Type Reference

**Always consult** [.github/references/wait-types.md](../references/wait-types.md) to:
- Filter out benign/ignorable waits before analysis
- Use correct red-flag thresholds per wait type
- Follow the decision tree for classification

## Analysis Order (Path A — SQL tables)

1. **Overview**: `SELECT event_name, COUNT(*) FROM xe.raw_events GROUP BY event_name`
2. **Errors**: Top by count + hourly distribution (baseline vs spike?)
3. **Waits**: Top by `SUM(duration_ms)` + hourly pattern + per-session spread
4. **Diagnostics**: WARNING/ERROR states + embedded `data_xml` for memory reports and blocking SQL
5. **Scheduler**: Non-yielding events + CPU correlation
6. **Connectivity**: `sni_consumer_error` + `os_error` + top source IPs
7. **Security errors**: Verify `error_code` meaning with `[Win32Exception]::new(code).Message`
8. **Memory broker**: `memory_ratio` trend over time
9. **AG events**: `reason`, `target_state`, `failure_condition` (if sqldiag imported)
10. **Cross-correlate**: Overlay all on hourly time axis, separate baseline from event
11. **Causal chain**: Work backwards from symptom, label each conclusion ✅/⚠️/❌

## Analysis Order (Path B — JSON fallback)

```bash
node scripts/parse_xevent.js reports/{case_id}_xevent_extract.json \
  --errorlog reports/{case_id}_errorlog_findings.json \
  --json --output reports/{case_id}_xevent_findings.json
```

Review the output JSON's `errors`, `wait_analysis`, `scheduler_events`, `deadlocks`,
`patterns`, `correlation` sections.

**Limitation**: Path B's parser does not handle `component_health_result` (sqldiag),
`security_error_ring_buffer_recorded`, or `memory_broker_ring_buffer_recorded`.
For these, use Path A or read raw XML manually.

## Key Pitfalls

- **Do NOT assume `lastNotification = RESOURCE_MEMPHYSICAL_LOW` means OOM.**
  Verify `outOfMemoryExceptions` and `isAnyPoolOutOfMemory` counters in the XML.
- **Do NOT assume `security_error` error_code is always OOM.**
  Error 5023 = `ERROR_INVALID_STATE`, not OOM. Always verify with `[Win32Exception]`.
- **Distinguish baseline (constant rate) from event-driven (spikes).**
  If security_errors are ~3K/hour 24×7, they're a baseline issue independent of any incident.
- **Non-yielding with low CPU ≠ CPU starvation.**
  Thread is stuck on I/O, latch, or memory grant — check waits at same timestamp.
