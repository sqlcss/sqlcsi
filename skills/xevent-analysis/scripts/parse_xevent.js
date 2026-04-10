#!/usr/bin/env node
// =============================================================================
// SQL-CSI: XEvent Parser
// Parses XEvent JSON (output from extract_xel.ps1) into structured analysis.
// Classifies events: errors, waits, scheduler, memory, deadlocks, connectivity.
//
// Usage:
//   node parse_xevent.js <events.json> [--days N] [--json] [--output <file>]
//   node parse_xevent.js events.json --days 3 --json --output findings.json
//   node parse_xevent.js events.json --errorlog errorlog_findings.json
// =============================================================================

const fs = require('fs');
const path = require('path');

// =============================================================================
// Subsystem Classification (shared with parse_errorlog.js)
// =============================================================================

const SUBSYSTEM_MAP = [
  [1, 100, 'GENERAL'], [101, 299, 'METADATA'], [301, 499, 'DATATYPE'],
  [501, 599, 'DBCC'], [601, 699, 'STORAGE_PAGE'], [701, 899, 'MEMORY'],
  [901, 999, 'RESOURCE'], [1001, 1099, 'ENGINE'], [1101, 1299, 'LOCKING'],
  [1401, 1499, 'MIRRORING'], [1501, 1599, 'REPLICATION'], [2001, 2399, 'CHECKDB'],
  [2501, 2599, 'TABLE_INDEX'], [3001, 3999, 'BACKUP'], [4001, 4999, 'PARSER'],
  [5001, 5499, 'DDL'], [5501, 5999, 'DBCC'], [7001, 7999, 'LINKEDSERVER'],
  [8001, 8099, 'NETWORK'], [8101, 8199, 'OPTIMIZER'], [8601, 8699, 'QUERYPROC'],
  [9001, 9100, 'LOG'], [9501, 9999, 'FULLTEXT'], [10001, 10999, 'SERVER'],
  [14001, 14999, 'SECURITY'], [15001, 15999, 'CATALOG'], [17001, 17999, 'SERVICE'],
  [18001, 18449, 'LOGIN'], [18450, 18499, 'LOGIN_AUDIT'],
  [19001, 19399, 'HADR_ERROR1'], [19400, 19499, 'HADR_ERROR2'],
  [19500, 19599, 'HADR_ERROR3'], [21001, 21999, 'REPL_AGENT'],
  [22001, 22999, 'SSIS'], [25001, 25999, 'SPATIAL'], [33001, 33999, 'FILETABLE'],
  [35001, 35999, 'HADR_ADDITIONAL'], [41001, 41399, 'HEKATON'],
  [41401, 41499, 'HEKATON_XTP'],
];

function getSubsystem(errorNumber) {
  for (const [lo, hi, name] of SUBSYSTEM_MAP) {
    if (errorNumber >= lo && errorNumber <= hi) return name;
  }
  return 'UNKNOWN';
}

function getSeverityClass(sev) {
  if (sev >= 20) return 'FATAL';
  if (sev >= 17) return 'RESOURCE';
  if (sev === 16) return 'USER_ERROR';
  if (sev >= 11) return 'WARNING';
  return 'INFO';
}

const BENIGN_ERRORS = new Set([
  17054, 5701, 5703, 8153, 15457, 17830, 4014, 35262, 33204,
]);

// =============================================================================
// Wait Type Classification
// =============================================================================

const WAIT_CATEGORIES = {
  CPU: ['SOS_SCHEDULER_YIELD', 'THREADPOOL', 'SOS_WORK_DISPATCHER'],
  IO: ['PAGEIOLATCH_SH', 'PAGEIOLATCH_EX', 'PAGEIOLATCH_UP', 'PAGEIOLATCH_DT',
       'PAGEIOLATCH_NL', 'PAGEIOLATCH_KP', 'WRITELOG', 'IO_COMPLETION',
       'ASYNC_IO_COMPLETION', 'WRITE_COMPLETION'],
  LOCKING: ['LCK_M_S', 'LCK_M_X', 'LCK_M_U', 'LCK_M_IS', 'LCK_M_IX',
            'LCK_M_SIX', 'LCK_M_SIU', 'LCK_M_UIX', 'LCK_M_SCH_S',
            'LCK_M_SCH_M', 'LCK_M_BU', 'LCK_M_RS_S', 'LCK_M_RS_U',
            'LCK_M_RIn_NL', 'LCK_M_RIn_S', 'LCK_M_RIn_U', 'LCK_M_RIn_X'],
  LATCH: ['PAGELATCH_SH', 'PAGELATCH_EX', 'PAGELATCH_UP', 'PAGELATCH_DT',
          'PAGELATCH_NL', 'PAGELATCH_KP', 'LATCH_SH', 'LATCH_EX', 'LATCH_UP',
          'LATCH_DT', 'LATCH_NL', 'LATCH_KP'],
  NETWORK: ['ASYNC_NETWORK_IO', 'NET_WAITFOR_PACKET'],
  MEMORY: ['RESOURCE_SEMAPHORE', 'CMEMTHREAD', 'RESOURCE_SEMAPHORE_QUERY_COMPILE',
           'RESOURCE_SEMAPHORE_SMALL_QUERY'],
  HADR: ['HADR_LOGCAPTURE_SYNC', 'HADR_LOGCAPTURE_WAIT', 'HADR_SYNC_COMMIT',
         'HADR_TRANSPORT_SESSION', 'HADR_WORK_QUEUE', 'HADR_TIMER_TASK',
         'HADR_CLUSAPI_CALL', 'HADR_NOTIFICATION_DEQUEUE',
         'PWAIT_HADR_ACTION_COMPLETED', 'PWAIT_HADR_CHANGE_NOTIFIER_TERMINATION_SYNC',
         'PWAIT_HADR_CLUSTER_INTEGRATION', 'PWAIT_HADR_OFFLINE_COMPLETED',
         'PWAIT_HADR_ONLINE_COMPLETED', 'PWAIT_HADR_SERVER_READY_CONNECTIONS'],
  BACKUP: ['BACKUPBUFFER', 'BACKUPIO', 'BACKUPTHREAD'],
  PREEMPTIVE: [], // matched by prefix
  CLR: ['CLR_AUTO_EVENT', 'CLR_CRST', 'CLR_JOIN', 'CLR_MANUAL_EVENT',
        'CLR_MEMORY_SPY', 'CLR_MONITOR', 'CLR_RWLOCK_READER', 'CLR_RWLOCK_WRITER',
        'CLR_SEMAPHORE', 'CLR_TASK_START', 'SQLCLR_APPDOMAIN', 'SQLCLR_ASSEMBLY',
        'SQLCLR_DEADLOCK_DETECTION', 'SQLCLR_QUANTUM_PUNISHMENT'],
};

function getWaitCategory(waitType) {
  if (!waitType) return 'OTHER';
  const wt = String(waitType);
  // Prefix matches
  if (wt.startsWith('PREEMPTIVE_OS_')) return 'PREEMPTIVE';
  if (wt.startsWith('LCK_M_')) return 'LOCKING';
  if (wt.startsWith('PAGEIOLATCH_')) return 'IO';
  if (wt.startsWith('PAGELATCH_')) return 'LATCH';
  if (wt.startsWith('LATCH_')) return 'LATCH';
  if (wt.startsWith('HADR_')) return 'HADR';
  if (wt.startsWith('PWAIT_HADR_')) return 'HADR';
  if (wt.startsWith('BACKUP')) return 'BACKUP';
  if (wt.startsWith('CLR_') || wt.startsWith('SQLCLR_')) return 'CLR';

  // Exact matches
  for (const [cat, types] of Object.entries(WAIT_CATEGORIES)) {
    if (types.includes(wt)) return cat;
  }
  return 'OTHER';
}

// =============================================================================
// Event Classification
// =============================================================================

const ERROR_EVENTS = new Set([
  'error_reported',
  'errorlog_written',
]);

const WAIT_EVENTS = new Set([
  'wait_info',
  'wait_info_external',
]);

const SCHEDULER_EVENTS = new Set([
  'scheduler_monitor_non_yielding_ring_buffer_recorded',
  'scheduler_monitor_system_health_ring_buffer_recorded',
  'scheduler_monitor_deadlock_ring_buffer_recorded',
  'scheduler_monitor_non_yielding_iocp_ring_buffer_recorded',
]);

const MEMORY_EVENTS = new Set([
  'memory_broker_ring_buffer_recorded',
  'sp_server_diagnostics_component_result',
]);

const DEADLOCK_EVENTS = new Set([
  'xml_deadlock_report',
]);

const CONNECTIVITY_EVENTS = new Set([
  'connectivity_ring_buffer_recorded',
  'login_failed',
  'login',
]);

// =============================================================================
// Main Analysis
// =============================================================================

// Simple XML attribute parser (no dependency needed)
function parseXmlAttrs(xml) {
  const result = {};
  const attrRe = /(\w+)="([^"]*)"/g;
  let m;
  while ((m = attrRe.exec(xml)) !== null) {
    const val = m[2];
    result[m[1]] = /^\d+$/.test(val) ? parseInt(val, 10) : val;
  }
  return result;
}

// Parse <entry description="..." value="..."/> pairs from resource XML
function parseXmlEntries(xml) {
  const result = {};
  const re = /<entry\s+description="([^"]*)"\s+value="([^"]*)"\s*\/>/g;
  let m;
  while ((m = re.exec(xml)) !== null) {
    result[m[1]] = /^\d+$/.test(m[2]) ? parseInt(m[2], 10) : m[2];
  }
  return result;
}

// Parse <wait .../> elements from query_processing XML
function parseWaitElements(xml) {
  const waits = [];
  const re = /<wait\s+([^/]*)\/?>/g;
  let m;
  while ((m = re.exec(xml)) !== null) {
    waits.push(parseXmlAttrs(m[1]));
  }
  return waits;
}

// Analyze sp_server_diagnostics data XML per component
function parseDiagnosticsData(component, dataXml) {
  if (!dataXml) return null;
  const xml = String(dataXml);

  if (component === 'SYSTEM') {
    return parseXmlAttrs(xml);
  }
  if (component === 'RESOURCE') {
    const top = parseXmlAttrs(xml);
    // Parse memory entries
    const entries = parseXmlEntries(xml);
    return { ...top, memory: entries };
  }
  if (component === 'QUERY_PROCESSING') {
    const top = parseXmlAttrs(xml);
    // Parse top waits
    const preemptive = [];
    const nonPreemptive = [];
    // nonPreemptive byCount
    const npSection = xml.match(/<nonPreemptive><byCount>([\s\S]*?)<\/byCount>/);
    if (npSection) nonPreemptive.push(...parseWaitElements(npSection[1]));
    // preemptive byCount
    const pSection = xml.match(/<preemptive><byCount>([\s\S]*?)<\/byCount>/);
    if (pSection) preemptive.push(...parseWaitElements(pSection[1]));
    return { ...top, topWaits: { nonPreemptive, preemptive } };
  }
  if (component === 'IO_SUBSYSTEM') {
    return parseXmlAttrs(xml);
  }
  return { raw: xml.substring(0, 500) };
}

function analyzeXEvents(data, options) {
  const events = data.events || [];
  const { days, errorlogPath } = options;

  // Time filter
  let filtered = events;
  if (days && events.length > 0) {
    const latest = new Date(events[events.length - 1].timestamp);
    const cutoff = new Date(latest.getTime() - days * 86400000);
    filtered = events.filter(e => new Date(e.timestamp) >= cutoff);
    process.stderr.write(`Time filter: last ${days} days → ${filtered.length}/${events.length} events\n`);
  }

  // =====================================================================
  // 1. sp_server_diagnostics: only WARNING / ERROR state
  // =====================================================================
  const diagAll = filtered.filter(e => e.name === 'sp_server_diagnostics_component_result');
  const diagAlerts = []; // WARNING or ERROR
  const diagStateCounts = {};

  for (const evt of diagAll) {
    const f = evt.fields || {};
    const comp = f.component || 'UNKNOWN';
    const state = String(f.state || 'CLEAN').toUpperCase();
    const key = `${comp}_${state}`;
    diagStateCounts[key] = (diagStateCounts[key] || 0) + 1;

    if (state === 'WARNING' || state === 'ERROR') {
      const parsed = parseDiagnosticsData(comp, f.data);
      diagAlerts.push({
        timestamp: evt.timestamp,
        component: comp,
        state,
        data: parsed,
      });
    }
  }

  // =====================================================================
  // 2. scheduler_monitor: memory_utilization < 80 OR process_utilization > 75
  // =====================================================================
  const schedAll = filtered.filter(e =>
    e.name === 'scheduler_monitor_system_health_ring_buffer_recorded');
  const schedAlerts = [];
  let schedTotal = schedAll.length;

  for (const evt of schedAll) {
    const f = evt.fields || {};
    const memUtil = f.memory_utilization;
    const cpuUtil = f.process_utilization;
    const sysIdle = f.system_idle;

    const lowMem = (memUtil !== undefined && memUtil < 80);
    const highCpu = (cpuUtil !== undefined && cpuUtil > 75);

    if (lowMem || highCpu) {
      const reasons = [];
      if (lowMem) reasons.push(`memory_utilization=${memUtil}%`);
      if (highCpu) reasons.push(`process_utilization=${cpuUtil}%`);
      schedAlerts.push({
        timestamp: evt.timestamp,
        memory_utilization: memUtil,
        process_utilization: cpuUtil,
        system_idle: sysIdle,
        kernel_mode_time: f.kernel_mode_time,
        user_mode_time: f.user_mode_time,
        page_faults: f.page_faults,
        reasons,
      });
    }
  }

  // Also check for non-yielding scheduler events
  const nonYielding = filtered.filter(e =>
    e.name.includes('non_yielding')).map(evt => ({
    timestamp: evt.timestamp,
    event_name: evt.name,
    ...evt.fields,
  }));

  // =====================================================================
  // 3. error_reported: all errors (complement to errorlog)
  // =====================================================================
  const errors = [];
  for (const evt of filtered) {
    if (evt.name !== 'error_reported' && evt.name !== 'errorlog_written') continue;
    const f = evt.fields || {};
    const errNum = f.error_number || f.error || 0;
    const sev = f.severity || 0;
    if (!errNum) continue;
    errors.push({
      timestamp: evt.timestamp,
      error_number: errNum,
      severity: sev,
      state: f.state || 0,
      message: f.message || f.user_message || '',
    });
  }

  // Error summary
  const errorMap = new Map();
  for (const e of errors) {
    const key = `${e.error_number}_${e.severity}_${e.state}`;
    if (!errorMap.has(key)) {
      errorMap.set(key, {
        error_number: e.error_number, severity: e.severity, state: e.state,
        subsystem: getSubsystem(e.error_number),
        severity_class: getSeverityClass(e.severity),
        is_benign: BENIGN_ERRORS.has(e.error_number),
        count: 0, first_seen: e.timestamp, last_seen: e.timestamp,
        message_sample: e.message,
      });
    }
    const entry = errorMap.get(key);
    entry.count++;
    entry.last_seen = e.timestamp;
  }
  const errorSummary = [...errorMap.values()].sort((a, b) => {
    if (a.severity !== b.severity) return b.severity - a.severity;
    return b.count - a.count;
  });

  // =====================================================================
  // 4. wait_info / wait_info_external: ALL events (no filtering)
  // =====================================================================
  const waits = [];
  for (const evt of filtered) {
    if (evt.name !== 'wait_info' && evt.name !== 'wait_info_external') continue;
    const f = evt.fields || {};
    waits.push({
      timestamp: evt.timestamp,
      wait_type: String(f.wait_type || ''),
      duration_ms: f.duration || 0,
      signal_ms: f.signal_duration || 0,
      wait_resource: f.wait_resource || '',
      opcode: f.opcode || '',
    });
  }

  // Wait summary
  const waitMap = new Map();
  for (const w of waits) {
    const wt = w.wait_type;
    if (!waitMap.has(wt)) {
      waitMap.set(wt, { wait_type: wt, category: getWaitCategory(wt),
        total_duration_ms: 0, total_signal_ms: 0, count: 0,
        max_duration_ms: 0, first_seen: w.timestamp, last_seen: w.timestamp });
    }
    const entry = waitMap.get(wt);
    entry.total_duration_ms += w.duration_ms;
    entry.total_signal_ms += w.signal_ms;
    entry.count++;
    if (w.duration_ms > entry.max_duration_ms) entry.max_duration_ms = w.duration_ms;
    entry.last_seen = w.timestamp;
  }
  const waitSummary = [...waitMap.values()]
    .sort((a, b) => b.total_duration_ms - a.total_duration_ms)
    .map(w => ({ ...w, avg_ms: Math.round(w.total_duration_ms / w.count) }));

  const waitCategories = {};
  for (const w of waitMap.values()) {
    waitCategories[w.category] = (waitCategories[w.category] || 0) + w.total_duration_ms;
  }

  // =====================================================================
  // 5. Other notable events (deadlocks, connectivity)
  // =====================================================================
  const deadlocks = filtered
    .filter(e => e.name === 'xml_deadlock_report')
    .map(e => ({ timestamp: e.timestamp, xml: e.fields.xml_report || e.fields.data || '' }));

  const connectivity = filtered
    .filter(e => e.name === 'connectivity_ring_buffer_recorded')
    .map(e => ({ timestamp: e.timestamp, ...e.fields }));

  // =====================================================================
  // Timeline: only anomalous events
  // =====================================================================
  const timeline = [];

  for (const e of errors) {
    timeline.push({ timestamp: e.timestamp, icon: '[ERROR]',
      description: `Error ${e.error_number} (Sev ${e.severity}) — ${getSubsystem(e.error_number)}` });
  }
  for (const a of diagAlerts) {
    let detail = a.component;
    if (a.component === 'IO_SUBSYSTEM' && a.data) {
      detail += ` ioLatchTimeouts=${a.data.ioLatchTimeouts || 0} longIos=${a.data.intervalLongIos || 0}`;
    }
    if (a.component === 'SYSTEM' && a.data) {
      detail += ` nonYielding=${a.data.nonYieldingTasksReported || 0} pageFaults=${a.data.pageFaults || 0}`;
    }
    timeline.push({ timestamp: a.timestamp, icon: `[DIAG:${a.state}]`, description: detail });
  }
  for (const s of schedAlerts) {
    timeline.push({ timestamp: s.timestamp, icon: '[SCHED]',
      description: `CPU=${s.process_utilization}% Mem=${s.memory_utilization}% Idle=${s.system_idle}%` });
  }
  for (const s of nonYielding) {
    timeline.push({ timestamp: s.timestamp, icon: '[NON_YIELD]', description: s.event_name });
  }
  for (const w of waits) {
    timeline.push({ timestamp: w.timestamp, icon: '[WAIT]',
      description: `${w.wait_type} ${Math.round(w.duration_ms / 1000)}s` });
  }
  for (const d of deadlocks) {
    timeline.push({ timestamp: d.timestamp, icon: '[DEADLOCK]', description: 'Deadlock detected' });
  }

  timeline.sort((a, b) => a.timestamp.localeCompare(b.timestamp));

  // =====================================================================
  // Patterns
  // =====================================================================
  const patterns = [];

  for (const e of errorSummary) {
    if (e.count >= 5 && !e.is_benign) {
      patterns.push({ type: 'REPEATING_ERROR', error_number: e.error_number,
        count: e.count, first_seen: e.first_seen, last_seen: e.last_seen });
    }
  }
  for (const w of waitSummary) {
    if (w.total_duration_ms > 60000) {
      patterns.push({ type: 'HEAVY_WAIT', wait_type: w.wait_type, category: w.category,
        total_duration_ms: w.total_duration_ms, count: w.count });
    }
  }
  if (nonYielding.length > 0) {
    patterns.push({ type: 'NON_YIELDING_SCHEDULER', count: nonYielding.length,
      timestamps: nonYielding.map(s => s.timestamp) });
  }
  if (deadlocks.length > 0) {
    patterns.push({ type: 'DEADLOCKS_DETECTED', count: deadlocks.length,
      timestamps: deadlocks.map(d => d.timestamp) });
  }
  if (diagAlerts.length > 0) {
    const byComp = {};
    for (const a of diagAlerts) {
      if (!byComp[a.component]) byComp[a.component] = { WARNING: 0, ERROR: 0 };
      byComp[a.component][a.state]++;
    }
    patterns.push({ type: 'DIAGNOSTICS_ALERTS', total: diagAlerts.length, by_component: byComp });
  }
  if (schedAlerts.length > 0) {
    const cpuAlerts = schedAlerts.filter(s => s.process_utilization > 75).length;
    const memAlerts = schedAlerts.filter(s => s.memory_utilization < 80).length;
    patterns.push({ type: 'RESOURCE_PRESSURE', total: schedAlerts.length,
      high_cpu_count: cpuAlerts, low_memory_count: memAlerts });
  }

  // =====================================================================
  // Code search targets
  // =====================================================================
  const codeSearchTargets = errorSummary
    .filter(e => !e.is_benign)
    .map(e => {
      const reasons = [];
      if (e.severity >= 20) reasons.push('fatal severity');
      if (e.severity >= 16 && e.count >= 5) reasons.push(`severity ${e.severity} with ${e.count} occurrences`);
      else if (e.severity >= 16) reasons.push(`severity ${e.severity}`);
      let priority = 'LOW';
      if (e.severity >= 20) priority = 'HIGH';
      else if (e.severity >= 16 && e.count >= 5) priority = 'HIGH';
      else if (e.severity >= 16) priority = 'MEDIUM';
      return { ...e, priority, priority_reasons: reasons };
    })
    .filter(e => e.priority !== 'LOW')
    .sort((a, b) => {
      const pOrder = { HIGH: 0, MEDIUM: 1, LOW: 2 };
      return (pOrder[a.priority] - pOrder[b.priority]) || (b.count - a.count);
    });

  // =====================================================================
  // ERRORLOG correlation
  // =====================================================================
  let correlation = null;
  if (errorlogPath) {
    try {
      let elText = fs.readFileSync(errorlogPath, 'utf8');
      if (elText.charCodeAt(0) === 0xFEFF) elText = elText.slice(1);
      const elData = JSON.parse(elText);
      const elErrors = (elData.errors || []).map(e => e.error_number);
      const xeErrors = errorSummary.map(e => e.error_number);
      correlation = {
        errorlog_source: errorlogPath,
        errors_in_both: [...new Set(xeErrors.filter(e => elErrors.includes(e)))],
        xevent_only_errors: [...new Set(xeErrors.filter(e => !elErrors.includes(e)))],
        errorlog_only_errors: [...new Set(elErrors.filter(e => !xeErrors.includes(e)))],
      };
    } catch (err) {
      process.stderr.write(`Warning: could not load errorlog findings: ${err.message}\n`);
    }
  }

  // =====================================================================
  // Build output
  // =====================================================================
  const timestamps = filtered.map(e => e.timestamp).sort();
  const eventNames = new Set(filtered.map(e => e.name));
  let source = 'custom_session';
  if (eventNames.has('scheduler_monitor_system_health_ring_buffer_recorded') ||
      (data.source_files || []).some(f => f.includes('system_health'))) {
    source = 'system_health';
  }

  // Event type counts
  const eventTypeCounts = {};
  for (const e of filtered) {
    eventTypeCounts[e.name] = (eventTypeCounts[e.name] || 0) + 1;
  }

  return {
    analysis_type: 'sql-csi-xevent',
    analysis_date: new Date().toISOString(),
    source,
    source_files: data.source_files || [],
    total_events_analyzed: filtered.length,
    focus_period: days ? `Last ${days} days` : 'All events',
    time_range: { first: timestamps[0] || 'unknown', last: timestamps[timestamps.length - 1] || 'unknown' },
    event_type_counts: eventTypeCounts,

    // Section 1: Diagnostics alerts (WARNING/ERROR only)
    diagnostics: {
      total_records: diagAll.length,
      state_distribution: diagStateCounts,
      alerts: diagAlerts,
    },

    // Section 2: Scheduler resource pressure
    scheduler: {
      total_records: schedTotal,
      alerts: schedAlerts,
      non_yielding: nonYielding,
    },

    // Section 3: Errors (complement to errorlog)
    error_summary: {
      total_unique: errorSummary.length,
      total_occurrences: errors.length,
      fatal_count: errors.filter(e => e.severity >= 20).length,
    },
    errors: errorSummary,

    // Section 4: All waits
    wait_analysis: {
      total_wait_events: waits.length,
      all_waits: waits,
      wait_summary: waitSummary,
      wait_categories: waitCategories,
    },

    // Section 5: Other
    deadlocks: { count: deadlocks.length, events: deadlocks.slice(0, 20) },
    connectivity: { count: connectivity.length },

    patterns,
    timeline: timeline.slice(0, 500),
    code_search_targets: codeSearchTargets,
    correlation,
  };
}

// =============================================================================
// Console Output
// =============================================================================

function formatConsole(result) {
  const lines = [];
  lines.push('');
  lines.push('═══════════════════════════════════════════════════════');
  lines.push('  SQL-CSI XEvent Analysis (system_health)');
  lines.push('═══════════════════════════════════════════════════════');
  lines.push(`Source: ${result.source} (${result.source_files.join(', ')})`);
  lines.push(`Period: ${result.focus_period}`);
  lines.push(`Time:   ${result.time_range.first} → ${result.time_range.last}`);
  lines.push(`Events: ${result.total_events_analyzed}`);
  lines.push('');

  // Event type counts
  lines.push('── Event Types ──────────────────────────────────────');
  const typeCounts = Object.entries(result.event_type_counts || {})
    .sort((a, b) => b[1] - a[1]);
  for (const [name, count] of typeCounts) {
    lines.push(`  ${String(count).padStart(8)}  ${name}`);
  }
  lines.push('');

  // ── Section 1: sp_server_diagnostics alerts ──
  const diag = result.diagnostics || {};
  lines.push('══ 1. sp_server_diagnostics (WARNING/ERROR only) ════');
  lines.push(`  Total records: ${diag.total_records || 0}`);
  if (diag.state_distribution) {
    lines.push('  State distribution:');
    for (const [k, v] of Object.entries(diag.state_distribution).sort()) {
      lines.push(`    ${k.padEnd(30)} ${v}`);
    }
  }
  if ((diag.alerts || []).length === 0) {
    lines.push('  ✓ No WARNING/ERROR states detected — all components CLEAN');
  } else {
    lines.push(`  ⚠ ${diag.alerts.length} alert(s):`);
    for (const a of diag.alerts) {
      lines.push(`  ${a.timestamp}  [${a.state}] ${a.component}`);
      if (a.data) {
        const d = a.data;
        if (a.component === 'IO_SUBSYSTEM') {
          lines.push(`    ioLatchTimeouts=${d.ioLatchTimeouts} intervalLongIos=${d.intervalLongIos} totalLongIos=${d.totalLongIos}`);
        } else if (a.component === 'SYSTEM') {
          lines.push(`    nonYielding=${d.nonYieldingTasksReported} spinlockBackoffs=${d.spinlockBackoffs} pageFaults=${d.pageFaults} sqlCpu=${d.sqlCpuUtilization}% sysCpu=${d.systemCpuUtilization}%`);
        } else if (a.component === 'RESOURCE') {
          lines.push(`    OOM_exceptions=${d.outOfMemoryExceptions} poolOOM=${d.isAnyPoolOutOfMemory} notification=${d.lastNotification}`);
          if (d.memory) {
            const m = d.memory;
            if (m['Available Physical Memory']) lines.push(`    AvailPhysMem=${Math.round((m['Available Physical Memory']||0)/1073741824)}GB`);
          }
        } else if (a.component === 'QUERY_PROCESSING') {
          lines.push(`    maxWorkers=${d.maxWorkers} pending=${d.pendingTasks} deadlockedSchedulers=${d.hasDeadlockedSchedulersOccurred}`);
        }
      }
    }
  }
  lines.push('');

  // ── Section 2: scheduler_monitor alerts ──
  const sched = result.scheduler || {};
  lines.push('══ 2. scheduler_monitor (CPU>75% or Mem<80%) ════════');
  lines.push(`  Total records: ${sched.total_records || 0}`);
  if ((sched.alerts || []).length === 0) {
    lines.push('  ✓ No resource pressure detected — CPU and memory within normal range');
  } else {
    lines.push(`  ⚠ ${sched.alerts.length} alert(s):`);
    for (const s of sched.alerts.slice(0, 30)) {
      lines.push(`  ${s.timestamp}  CPU=${s.process_utilization}% Mem=${s.memory_utilization}% Idle=${s.system_idle}%  [${s.reasons.join(', ')}]`);
    }
    if (sched.alerts.length > 30) lines.push(`  ... and ${sched.alerts.length - 30} more`);
  }
  if ((sched.non_yielding || []).length > 0) {
    lines.push(`  ⚠ Non-yielding scheduler events: ${sched.non_yielding.length}`);
    for (const n of sched.non_yielding.slice(0, 10)) {
      lines.push(`    ${n.timestamp} ${n.event_name}`);
    }
  }
  lines.push('');

  // ── Section 3: error_reported ──
  lines.push('══ 3. error_reported (errorlog complement) ══════════');
  if (result.errors.length === 0) {
    lines.push('  No errors captured by XEvent');
  } else {
    lines.push(`  Unique: ${result.error_summary.total_unique}, Occurrences: ${result.error_summary.total_occurrences}, Fatal(sev>=20): ${result.error_summary.fatal_count}`);
    for (const e of result.errors) {
      const benign = e.is_benign ? ' [benign]' : '';
      lines.push(`  Error ${e.error_number} | Sev ${e.severity} | ${e.count}x | ${e.subsystem}${benign}`);
      if (e.message_sample) lines.push(`    ${e.message_sample.substring(0, 150)}`);
    }
  }
  lines.push('');

  // ── Section 4: wait_info (all) ──
  lines.push('══ 4. wait_info (all events) ═════════════════════════');
  const wa = result.wait_analysis || {};
  if ((wa.all_waits || []).length === 0) {
    lines.push('  No wait events captured (threshold not reached)');
  } else {
    lines.push(`  Total events: ${wa.total_wait_events}`);
    lines.push('');
    // Show every individual wait event
    for (const w of wa.all_waits) {
      const durSec = Math.round(w.duration_ms / 1000);
      const cat = getWaitCategory(w.wait_type);
      lines.push(`  ${w.timestamp}  ${w.wait_type.padEnd(30)} ${String(durSec + 's').padStart(8)}  ${cat}`);
    }
    lines.push('');
    // Summary
    if (wa.wait_summary && wa.wait_summary.length > 0) {
      lines.push('  Summary by type:');
      lines.push('  Wait Type                          Total(ms)   Count   Avg(ms)  Max(ms)  Category');
      lines.push('  ─────────────────────────────────  ──────────  ──────  ───────  ───────  ────────');
      for (const w of wa.wait_summary) {
        lines.push(`  ${w.wait_type.padEnd(35)}  ${String(w.total_duration_ms).padStart(10)}  ${String(w.count).padStart(6)}  ${String(w.avg_ms).padStart(7)}  ${String(w.max_duration_ms).padStart(7)}  ${w.category}`);
      }
    }
  }
  lines.push('');

  // ── Patterns ──
  if (result.patterns.length > 0) {
    lines.push('══ Patterns ════════════════════════════════════════');
    for (const p of result.patterns) {
      if (p.type === 'HEAVY_WAIT') {
        lines.push(`  [HEAVY_WAIT] ${p.wait_type} (${p.category}): ${Math.round(p.total_duration_ms/1000)}s total, ${p.count}x`);
      } else if (p.type === 'DIAGNOSTICS_ALERTS') {
        lines.push(`  [DIAG_ALERT] ${p.total} diagnostics alerts: ${JSON.stringify(p.by_component)}`);
      } else if (p.type === 'RESOURCE_PRESSURE') {
        lines.push(`  [RESOURCE] ${p.total} pressure events: ${p.high_cpu_count} high CPU, ${p.low_memory_count} low memory`);
      } else if (p.type === 'NON_YIELDING_SCHEDULER') {
        lines.push(`  [NON_YIELDING] ${p.count} events`);
      } else if (p.type === 'DEADLOCKS_DETECTED') {
        lines.push(`  [DEADLOCK] ${p.count} deadlock(s)`);
      } else if (p.type === 'REPEATING_ERROR') {
        lines.push(`  [REPEATING] Error ${p.error_number}: ${p.count}x`);
      }
    }
    lines.push('');
  }

  // ── ERRORLOG Correlation ──
  if (result.correlation) {
    lines.push('══ ERRORLOG Correlation ════════════════════════════');
    lines.push(`  Source: ${result.correlation.errorlog_source}`);
    lines.push(`  In both:       ${result.correlation.errors_in_both.join(', ') || 'none'}`);
    lines.push(`  XEvent only:   ${result.correlation.xevent_only_errors.join(', ') || 'none'}`);
    lines.push(`  Errorlog only: ${result.correlation.errorlog_only_errors.join(', ') || 'none'}`);
    lines.push('');
  }

  return lines.join('\n');
}

// =============================================================================
// CLI
// =============================================================================

function main() {
  const args = process.argv.slice(2);

  if (args.length === 0 || args.includes('--help') || args.includes('-h')) {
    console.log(`
SQL-CSI XEvent Parser

Usage:
  node parse_xevent.js <events.json> [options]

Options:
  --days N              Focus on last N days from latest event
  --json                Output JSON to stdout
  --output <file>       Save JSON output to file
  --errorlog <file>     Errorlog findings JSON for cross-correlation

Examples:
  node parse_xevent.js xevent_extract.json
  node parse_xevent.js xevent_extract.json --days 3 --json --output findings.json
  node parse_xevent.js xevent_extract.json --errorlog errorlog_findings.json
`);
    process.exit(0);
  }

  // Parse args
  const inputFile = args[0];
  let days = 0;
  let jsonOutput = false;
  let outputFile = null;
  let errorlogPath = null;

  for (let i = 1; i < args.length; i++) {
    if (args[i] === '--days' && args[i + 1]) { days = parseInt(args[++i], 10); }
    else if (args[i] === '--json') { jsonOutput = true; }
    else if (args[i] === '--output' && args[i + 1]) { outputFile = args[++i]; }
    else if (args[i] === '--errorlog' && args[i + 1]) { errorlogPath = args[++i]; }
  }

  // Read input
  if (!fs.existsSync(inputFile)) {
    console.error(`Error: file not found: ${inputFile}`);
    process.exit(1);
  }

  let rawText = fs.readFileSync(inputFile, 'utf8');
  // Strip UTF-8 BOM if present (PowerShell Set-Content adds BOM)
  if (rawText.charCodeAt(0) === 0xFEFF) rawText = rawText.slice(1);
  const rawData = JSON.parse(rawText);
  process.stderr.write(`Loaded ${rawData.total_events || (rawData.events || []).length} events from ${inputFile}\n`);

  // Analyze
  const result = analyzeXEvents(rawData, { days, errorlogPath });

  // Output
  if (jsonOutput || outputFile) {
    const json = JSON.stringify(result, null, 2);
    if (outputFile) {
      fs.writeFileSync(outputFile, json, 'utf8');
      process.stderr.write(`JSON output saved to ${outputFile}\n`);
    } else {
      console.log(json);
    }
  }

  if (!jsonOutput && !outputFile) {
    console.log(formatConsole(result));
  }
}

main();
