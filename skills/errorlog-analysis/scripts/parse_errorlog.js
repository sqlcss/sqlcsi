#!/usr/bin/env node
// =============================================================================
// SQL-CSI: ERRORLOG Parser
// Parses SQL Server ERRORLOG files into structured JSON output.
// Handles UTF-16LE/UTF-8 encoding, multi-line messages, pattern detection.
//
// Usage:
//   node parse_errorlog.js <path1> [path2] [path3] ... [--output <file>] [--from <datetime>] [--to <datetime>]
//
// Examples:
//   node parse_errorlog.js C:\logs\ERRORLOG
//   node parse_errorlog.js C:\logs\ERRORLOG C:\logs\ERRORLOG.1 C:\logs\ERRORLOG.2
//   node parse_errorlog.js \\server\share\ERRORLOG* --output findings.json
//   node parse_errorlog.js C:\logs\ERRORLOG --from "2021-05-02 03:00" --to "2021-05-02 04:00"
// =============================================================================

const fs = require('fs');
const path = require('path');

// =============================================================================
// Encoding Detection & File Reading
// =============================================================================

function readErrorlog(filePath) {
  const buf = fs.readFileSync(filePath);

  // Detect encoding from BOM
  if (buf.length >= 2 && buf[0] === 0xFF && buf[1] === 0xFE) {
    // UTF-16LE with BOM
    return buf.slice(2).toString('utf16le');
  }
  if (buf.length >= 2 && buf[0] === 0xFE && buf[1] === 0xFF) {
    // UTF-16BE with BOM
    return buf.swap16().slice(2).toString('utf16le');
  }
  if (buf.length >= 3 && buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) {
    // UTF-8 with BOM
    return buf.slice(3).toString('utf8');
  }

  // No BOM — heuristic: if every other byte is 0x00, it's UTF-16LE
  let nullCount = 0;
  const sample = Math.min(buf.length, 200);
  for (let i = 1; i < sample; i += 2) {
    if (buf[i] === 0x00) nullCount++;
  }
  if (nullCount > sample / 4) {
    return buf.toString('utf16le');
  }

  return buf.toString('utf8');
}

// =============================================================================
// Line Parsing
// =============================================================================

// Timestamp pattern: 2021-05-02 03:05:42.04
const RE_TIMESTAMP = /^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{2})\s+(\S+)\s{2,}(.*)/;

// Error pattern: Error: 19432, Severity: 16, State: 0.
const RE_ERROR = /Error:\s*(\d+),\s*Severity:\s*(\d+),\s*State:\s*(\d+)/;

// AG state change
const RE_AG_STATE = /availability group '([^']+)'.*changed from '([^']+)' to '([^']+)'/i;

// AG role change (database level)
const RE_DB_ROLE = /database "([^"]+)" is changing roles from "([^"]+)" to "([^"]+)"/i;

// AG connection established/terminated
const RE_AG_CONN = /availability group '([^']+)'.*(?:established|terminated).*'([^']+)'/i;

// Server start/stop
const RE_START = /SQL Server is start/i;
const RE_READY = /SQL Server is now ready for client connections/i;
const RE_SHUTDOWN = /SQL Server is shutting down/i;

// Stack dump
const RE_STACKDUMP = /Stack Dump being sent/i;

// IO warning
const RE_IO_WARN = /I\/O requests taking longer than/i;

// Memory pressure
const RE_MEM_PRESSURE = /insufficient.*memory|process memory has been paged out/i;

// Login failure
const RE_LOGIN_FAIL = /Login failed for user '([^']+)'/i;

// LSN pattern in error messages
const RE_LSN = /LSN[:\s]*\(?(\d+:\d+:\d+)\)?/i;

// Missing log block (specific to 19432)
const RE_MISSING_LOG = /missing log block.*database "([^"]+)"/i;

// =============================================================================
// Subsystem Classification
// =============================================================================

const SUBSYSTEM_MAP = [
  [1, 100, 'GENERAL'],
  [101, 299, 'METADATA'],
  [301, 499, 'DATATYPE'],
  [501, 599, 'DBCC'],
  [601, 699, 'STORAGE_PAGE'],
  [701, 899, 'MEMORY'],
  [901, 999, 'RESOURCE'],
  [1001, 1099, 'ENGINE'],
  [1101, 1299, 'LOCKING'],
  [1401, 1499, 'MIRRORING'],
  [1501, 1599, 'REPLICATION'],
  [2001, 2399, 'CHECKDB'],
  [2501, 2599, 'TABLE_INDEX'],
  [3001, 3999, 'BACKUP'],
  [4001, 4999, 'PARSER'],
  [5001, 5499, 'DDL'],
  [5501, 5999, 'DBCC'],
  [7001, 7999, 'LINKEDSERVER'],
  [8001, 8099, 'NETWORK'],
  [8101, 8199, 'OPTIMIZER'],
  [8601, 8699, 'QUERYPROC'],
  [9001, 9100, 'LOG'],
  [9501, 9999, 'FULLTEXT'],
  [10001, 10999, 'SERVER'],
  [14001, 14999, 'SECURITY'],
  [15001, 15999, 'CATALOG'],
  [17001, 17999, 'SERVICE'],
  [18001, 18449, 'LOGIN'],
  [18450, 18499, 'LOGIN_AUDIT'],
  [19001, 19399, 'HADR_ERROR1'],
  [19400, 19499, 'HADR_ERROR2'],
  [19500, 19599, 'HADR_ERROR3'],
  [21001, 21999, 'REPL_AGENT'],
  [22001, 22999, 'SSIS'],
  [25001, 25999, 'SPATIAL'],
  [33001, 33999, 'FILETABLE'],
  [35001, 35999, 'HADR_ADDITIONAL'],
  [41001, 41399, 'HEKATON'],
  [41401, 41499, 'HEKATON_XTP'],
];

function getSubsystem(errorNumber) {
  for (const [lo, hi, name] of SUBSYSTEM_MAP) {
    if (errorNumber >= lo && errorNumber <= hi) return name;
  }
  return 'UNKNOWN';
}

// =============================================================================
// Severity Classification
// =============================================================================

function getSeverityClass(sev) {
  if (sev >= 20) return 'FATAL';
  if (sev >= 17) return 'RESOURCE';
  if (sev === 16) return 'USER_ERROR';
  if (sev >= 11) return 'WARNING';
  return 'INFO';
}

// =============================================================================
// Known Benign Errors
// =============================================================================

const BENIGN_ERRORS = new Set([
  17054, // Event not reported to Windows log
  5701,  // Changed database context
  5703,  // Changed language setting
  8153,  // Null value eliminated by aggregate
  15457, // Configuration option changed
  17830, // Network error establishing connection (transient)
  4014,  // Fatal error reading input stream (client disconnect)
  35262, // Database startup skipped (AG managed)
  33204, // Online index checking (startup)
]);

// =============================================================================
// Main Parser
// =============================================================================

function parseErrorlog(filePath) {
  const text = readErrorlog(filePath);
  const rawLines = text.split(/\r?\n/);
  const fileName = path.basename(filePath);

  const records = [];
  let current = null;

  for (let i = 0; i < rawLines.length; i++) {
    const line = rawLines[i];
    const match = RE_TIMESTAMP.exec(line);

    if (match) {
      // New record starts
      if (current) records.push(current);

      current = {
        timestamp: match[1].trim(),
        source: match[2].trim(),
        message: match[3].trim(),
        file: fileName,
        line_number: i + 1,
        // Will be populated later
        error_number: null,
        severity: null,
        state: null,
        event_type: null,
        details: {},
      };
    } else if (current && line.match(/^\s+\S/)) {
      // Continuation line — append to current message
      current.message += '\n' + line.trim();
    }
  }
  if (current) records.push(current);

  // Post-process: merge Error lines with their following message lines
  // In ERRORLOG, errors appear as:
  //   2021-05-02 03:05:42.04 spid47s  Error: 19432, Severity: 16, State: 0.
  //   2021-05-02 03:05:42.04 spid47s  Always On AG transport detected a missing log block...
  // Both have timestamps, so they're parsed as separate records.
  // Merge the second line into the first if: same timestamp, same source, first is Error line.
  const merged = [];
  for (let i = 0; i < records.length; i++) {
    const rec = records[i];
    const isErrorLine = RE_ERROR.test(rec.message);

    if (isErrorLine && i + 1 < records.length) {
      const next = records[i + 1];
      // Same timestamp and same source = this is the error's message text
      if (next.timestamp === rec.timestamp && next.source === rec.source && !RE_ERROR.test(next.message)) {
        rec.message += '\n' + next.message;
        i++; // skip the merged record
      }
    }
    merged.push(rec);
  }

  // Second pass: classify each record
  for (const rec of merged) {
    classifyRecord(rec);
  }

  return merged;
}

function classifyRecord(rec) {
  const msg = rec.message;

  // Error line
  const errMatch = RE_ERROR.exec(msg);
  if (errMatch) {
    rec.error_number = parseInt(errMatch[1]);
    rec.severity = parseInt(errMatch[2]);
    rec.state = parseInt(errMatch[3]);
    rec.event_type = 'ERROR';
    rec.details.subsystem = getSubsystem(rec.error_number);
    rec.details.severity_class = getSeverityClass(rec.severity);
    rec.details.is_benign = BENIGN_ERRORS.has(rec.error_number);

    // Extract LSN if present
    const lsnMatch = RE_LSN.exec(msg);
    if (lsnMatch) rec.details.lsn = lsnMatch[1];

    // Missing log block specific
    const mlbMatch = RE_MISSING_LOG.exec(msg);
    if (mlbMatch) rec.details.database = mlbMatch[1];

    return;
  }

  // AG state change
  const agMatch = RE_AG_STATE.exec(msg);
  if (agMatch) {
    rec.event_type = 'AG_STATE_CHANGE';
    rec.details = { ag_name: agMatch[1], from_state: agMatch[2], to_state: agMatch[3] };
    return;
  }

  // Database role change
  const dbMatch = RE_DB_ROLE.exec(msg);
  if (dbMatch) {
    rec.event_type = 'DB_ROLE_CHANGE';
    rec.details = { database: dbMatch[1], from_role: dbMatch[2], to_role: dbMatch[3] };
    return;
  }

  // Server start
  if (RE_START.test(msg)) { rec.event_type = 'SERVER_START'; return; }
  if (RE_READY.test(msg)) { rec.event_type = 'SERVER_READY'; return; }
  if (RE_SHUTDOWN.test(msg)) { rec.event_type = 'SERVER_SHUTDOWN'; return; }

  // Stack dump
  if (RE_STACKDUMP.test(msg)) { rec.event_type = 'STACK_DUMP'; return; }

  // IO warning
  if (RE_IO_WARN.test(msg)) { rec.event_type = 'IO_WARNING'; return; }

  // Memory pressure
  if (RE_MEM_PRESSURE.test(msg)) { rec.event_type = 'MEMORY_PRESSURE'; return; }

  // Login failure
  const loginMatch = RE_LOGIN_FAIL.exec(msg);
  if (loginMatch) {
    rec.event_type = 'LOGIN_FAILURE';
    rec.details = { user: loginMatch[1] };
    return;
  }

  // AG connection
  if (RE_AG_CONN.test(msg)) {
    rec.event_type = msg.includes('terminated') ? 'AG_CONN_TERMINATED' : 'AG_CONN_ESTABLISHED';
    return;
  }

  // Default
  rec.event_type = 'INFO';
}

// =============================================================================
// Pattern Detection
// =============================================================================

function detectPatterns(errors) {
  const patterns = [];

  // 1. Error Cascade: multiple different errors within 30 seconds
  const cascades = [];
  let cascadeStart = 0;
  for (let i = 1; i < errors.length; i++) {
    const dt = timeDiffSeconds(errors[cascadeStart].timestamp, errors[i].timestamp);
    if (dt > 30) {
      if (i - cascadeStart >= 3) {
        const unique = new Set(errors.slice(cascadeStart, i).map(e => e.error_number));
        if (unique.size >= 2) {
          cascades.push({
            start: errors[cascadeStart].timestamp,
            end: errors[i - 1].timestamp,
            count: i - cascadeStart,
            unique_errors: [...unique],
            root_error: errors[cascadeStart].error_number,
          });
        }
      }
      cascadeStart = i;
    }
  }
  if (cascades.length > 0) {
    patterns.push({ type: 'ERROR_CASCADE', instances: cascades });
  }

  // 2. Repeating errors: same error > 5 times
  const counts = {};
  for (const e of errors) {
    if (!counts[e.error_number]) counts[e.error_number] = [];
    counts[e.error_number].push(e.timestamp);
  }
  const repeating = [];
  for (const [errNum, timestamps] of Object.entries(counts)) {
    if (timestamps.length >= 5) {
      repeating.push({
        error_number: parseInt(errNum),
        count: timestamps.length,
        first_seen: timestamps[0],
        last_seen: timestamps[timestamps.length - 1],
      });
    }
  }
  if (repeating.length > 0) {
    patterns.push({ type: 'REPEATING_ERROR', instances: repeating.sort((a, b) => b.count - a.count) });
  }

  // 3. Paired errors: same error appearing 2x at the exact same timestamp
  const paired = [];
  for (let i = 0; i < errors.length - 1; i++) {
    if (errors[i].error_number === errors[i + 1].error_number &&
        errors[i].timestamp === errors[i + 1].timestamp) {
      paired.push({
        error_number: errors[i].error_number,
        timestamp: errors[i].timestamp,
      });
      i++; // skip the pair
    }
  }
  if (paired.length > 0) {
    const uniquePaired = {};
    for (const p of paired) {
      if (!uniquePaired[p.error_number]) uniquePaired[p.error_number] = 0;
      uniquePaired[p.error_number]++;
    }
    patterns.push({
      type: 'PAIRED_ERRORS',
      instances: Object.entries(uniquePaired).map(([e, c]) => ({
        error_number: parseInt(e), pair_count: c,
      })),
    });
  }

  // 4. LSN progression: for errors with LSN, check if LSN is advancing
  const lsnErrors = errors.filter(e => e.details.lsn);
  if (lsnErrors.length >= 3) {
    const lsns = lsnErrors.map(e => {
      const parts = e.details.lsn.split(':').map(Number);
      return { timestamp: e.timestamp, lsn: e.details.lsn, lsn_file: parts[0] };
    });
    const advancing = lsns.every((l, i) => i === 0 || l.lsn_file >= lsns[i - 1].lsn_file);
    if (advancing) {
      patterns.push({
        type: 'LSN_ADVANCING',
        detail: 'LSN is progressing despite errors — data flow is intermittent, not stopped',
        first_lsn: lsns[0].lsn,
        last_lsn: lsns[lsns.length - 1].lsn,
        count: lsns.length,
      });
    }
  }

  return patterns;
}

function timeDiffSeconds(ts1, ts2) {
  const d1 = new Date(ts1.replace(/\s+/, 'T'));
  const d2 = new Date(ts2.replace(/\s+/, 'T'));
  return Math.abs((d2 - d1) / 1000);
}

// =============================================================================
// Timeline Builder
// =============================================================================

function buildTimeline(records) {
  const significantTypes = new Set([
    'ERROR', 'SERVER_START', 'SERVER_READY', 'SERVER_SHUTDOWN',
    'AG_STATE_CHANGE', 'DB_ROLE_CHANGE', 'STACK_DUMP',
    'IO_WARNING', 'MEMORY_PRESSURE',
  ]);

  return records
    .filter(r => {
      if (!significantTypes.has(r.event_type)) return false;
      // For errors, only include severity >= 16 (or non-benign)
      if (r.event_type === 'ERROR') {
        return r.severity >= 16 && !r.details.is_benign;
      }
      return true;
    })
    .map(r => {
      let icon = '[INFO]';
      let desc = r.message.substring(0, 120);

      switch (r.event_type) {
        case 'ERROR':
          icon = r.severity >= 20 ? '[FATAL]' : '[ERROR]';
          desc = `Error ${r.error_number} (Sev ${r.severity}, State ${r.state}) — ${r.details.subsystem}`;
          break;
        case 'SERVER_START': icon = '[START]'; desc = 'SQL Server starting'; break;
        case 'SERVER_READY': icon = '[READY]'; desc = 'SQL Server ready for connections'; break;
        case 'SERVER_SHUTDOWN': icon = '[STOP]'; desc = 'SQL Server shutting down'; break;
        case 'AG_STATE_CHANGE':
          icon = '[HADR]';
          desc = `AG '${r.details.ag_name}': ${r.details.from_state} → ${r.details.to_state}`;
          break;
        case 'DB_ROLE_CHANGE':
          icon = '[HADR]';
          desc = `DB '${r.details.database}': ${r.details.from_role} → ${r.details.to_role}`;
          break;
        case 'STACK_DUMP': icon = '[DUMP]'; desc = 'Stack dump generated'; break;
        case 'IO_WARNING': icon = '[IO]'; desc = 'I/O stall detected'; break;
        case 'MEMORY_PRESSURE': icon = '[MEMORY]'; desc = 'Memory pressure detected'; break;
      }

      return { timestamp: r.timestamp, icon, description: desc, file: r.file };
    });
}

// =============================================================================
// Gap Analysis
// =============================================================================

function findGaps(timeline, thresholdSeconds = 60) {
  const gaps = [];
  for (let i = 1; i < timeline.length; i++) {
    const diff = timeDiffSeconds(timeline[i - 1].timestamp, timeline[i].timestamp);
    if (diff >= thresholdSeconds) {
      gaps.push({
        after: timeline[i - 1].timestamp,
        before: timeline[i].timestamp,
        duration_seconds: Math.round(diff),
        duration_human: formatDuration(diff),
      });
    }
  }
  return gaps;
}

function formatDuration(seconds) {
  if (seconds < 60) return `${Math.round(seconds)}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${Math.round(seconds % 60)}s`;
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return `${h}h ${m}m`;
}

// =============================================================================
// Error Summary
// =============================================================================

function buildErrorSummary(errors) {
  const groups = {};
  for (const e of errors) {
    const key = e.error_number;
    if (!groups[key]) {
      groups[key] = {
        error_number: key,
        severity: e.severity,
        state: e.state,
        subsystem: e.details.subsystem,
        severity_class: e.details.severity_class,
        is_benign: e.details.is_benign,
        count: 0,
        first_seen: e.timestamp,
        last_seen: e.timestamp,
        message_sample: e.message.split('\n')[0].substring(0, 200),
        last_full_message: e.message,
      };
    }
    groups[key].count++;
    groups[key].last_seen = e.timestamp;
    // Always keep the most recent full message
    groups[key].last_full_message = e.message;
  }

  return Object.values(groups).sort((a, b) => {
    // Sort by: severity DESC, then count DESC
    if (b.severity !== a.severity) return b.severity - a.severity;
    return b.count - a.count;
  });
}

// =============================================================================
// Priority Assignment
// =============================================================================

function assignPriorities(errorSummary, patterns) {
  const cascadeRoots = new Set();
  for (const p of patterns) {
    if (p.type === 'ERROR_CASCADE') {
      for (const c of p.instances) cascadeRoots.add(c.root_error);
    }
  }

  return errorSummary
    .filter(e => !e.is_benign)
    .map(e => {
      let priority = 'LOW';
      const reasons = [];

      if (e.severity >= 20) { priority = 'HIGH'; reasons.push('fatal severity (>= 20)'); }
      else if (e.severity >= 16 && e.count >= 5) { priority = 'HIGH'; reasons.push(`severity ${e.severity} with ${e.count} occurrences`); }
      else if (e.severity >= 16) { priority = 'MEDIUM'; reasons.push(`severity ${e.severity}`); }

      if (cascadeRoots.has(e.error_number)) { priority = 'HIGH'; reasons.push('first error in cascade chain'); }

      return { ...e, priority, priority_reasons: reasons };
    })
    .sort((a, b) => {
      const pri = { HIGH: 3, MEDIUM: 2, LOW: 1 };
      return (pri[b.priority] || 0) - (pri[a.priority] || 0);
    });
}

// =============================================================================
// Time Range Filter
// =============================================================================

function filterByTimeRange(records, from, to) {
  return records.filter(r => {
    const ts = r.timestamp;
    if (from && ts < from) return false;
    if (to && ts > to) return false;
    return true;
  });
}

function filterByDays(records, days) {
  if (!days || records.length === 0) return records;

  // Find the latest timestamp in all records
  let latest = '';
  for (const r of records) {
    if (r.timestamp && r.timestamp > latest) latest = r.timestamp;
  }
  if (!latest) return records;

  // Parse latest timestamp and subtract N days
  const latestDate = new Date(latest.replace(/\s+/, 'T'));
  const cutoff = new Date(latestDate.getTime() - days * 24 * 60 * 60 * 1000);
  const cutoffStr = cutoff.toISOString().replace('T', ' ').substring(0, 23);

  process.stderr.write(`Latest log entry: ${latest}\n`);
  process.stderr.write(`Focus period: last ${days} days (from ${cutoffStr})\n`);

  return records.filter(r => r.timestamp && r.timestamp >= cutoffStr);
}

// =============================================================================
// Output Formatters
// =============================================================================

function formatConsole(output) {
  const lines = [];

  lines.push('='.repeat(70));
  lines.push('SQL-CSI ERRORLOG ANALYSIS');
  lines.push('='.repeat(70));
  lines.push('');
  lines.push(`Server:      ${output.server_info.instance || 'unknown'}`);
  lines.push(`Version:     ${output.server_info.version || 'unknown'}`);
  lines.push(`Time Range:  ${output.time_range.first} → ${output.time_range.last}`);
  lines.push(`Files:       ${output.files_analyzed.join(', ')}`);
  lines.push(`Total Lines: ${output.total_lines}`);
  lines.push('');

  lines.push('--- ERROR SUMMARY (sorted by severity, then count) ---');
  lines.push('');
  lines.push(pad('Error', 8) + pad('Sev', 5) + pad('Count', 7) + pad('Subsystem', 18) + pad('Priority', 10) + 'Message');
  lines.push('-'.repeat(120));

  for (const e of output.code_search_targets) {
    const marker = e.priority === 'HIGH' ? '>>>' : e.priority === 'MEDIUM' ? ' > ' : '   ';
    lines.push(
      marker +
      pad(String(e.error_number), 6) +
      pad(String(e.severity), 5) +
      pad(String(e.count), 7) +
      pad(e.subsystem, 18) +
      pad(e.priority, 10) +
      (e.message_sample || '').substring(0, 60)
    );
  }
  lines.push('');

  lines.push('--- TIMELINE ---');
  lines.push('');
  for (const t of output.timeline) {
    lines.push(`[${t.timestamp}] ${pad(t.icon, 10)} ${t.description}`);
  }

  if (output.gaps.length > 0) {
    lines.push('');
    lines.push('--- TIME GAPS (> 60 seconds) ---');
    for (const g of output.gaps) {
      lines.push(`  GAP: ${g.duration_human} between ${g.after} and ${g.before}`);
    }
  }

  if (output.patterns.length > 0) {
    lines.push('');
    lines.push('--- PATTERNS DETECTED ---');
    for (const p of output.patterns) {
      lines.push(`  [${p.type}]`);
      if (p.type === 'REPEATING_ERROR') {
        for (const i of p.instances) {
          lines.push(`    Error ${i.error_number}: ${i.count} times (${i.first_seen} → ${i.last_seen})`);
        }
      } else if (p.type === 'PAIRED_ERRORS') {
        for (const i of p.instances) {
          lines.push(`    Error ${i.error_number}: appears in pairs ${i.pair_count} times`);
        }
      } else if (p.type === 'LSN_ADVANCING') {
        lines.push(`    ${p.detail}`);
        lines.push(`    First LSN: ${p.first_lsn}, Last LSN: ${p.last_lsn} (${p.count} samples)`);
      } else if (p.type === 'ERROR_CASCADE') {
        for (const i of p.instances) {
          lines.push(`    Cascade at ${i.start}: ${i.count} errors, ${i.unique_errors.length} unique (root: ${i.root_error})`);
        }
      }
    }
  }

  lines.push('');
  lines.push('--- CODE SEARCH TARGETS ---');
  for (const t of output.code_search_targets.filter(t => t.priority !== 'LOW')) {
    lines.push(`  [${t.priority}] Error ${t.error_number} (${t.subsystem}, Sev ${t.severity}, ${t.count}x)`);
    if (t.priority_reasons.length) lines.push(`         Reasons: ${t.priority_reasons.join('; ')}`);
  }

  lines.push('');
  lines.push('--- NEXT STEP: DEEP-DIVE ---');
  lines.push('Select an error to search source code:');
  const targets = output.code_search_targets.filter(t => t.priority !== 'LOW');
  for (let i = 0; i < targets.length && i < 5; i++) {
    const t = targets[i];
    const rec = i === 0 ? ' (recommended)' : '';
    lines.push(`  ${i + 1}. search error ${t.error_number}  — ${t.subsystem}, Sev ${t.severity}, ${t.count}x${rec}`);
  }

  return lines.join('\n');
}

function pad(str, len) {
  return (str + ' '.repeat(len)).substring(0, len);
}

// =============================================================================
// HTML Report Generator
// =============================================================================

function formatHtml(output) {
  const esc = s => String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  const sevColor = sev => sev >= 20 ? '#f38ba8' : sev >= 17 ? '#fab387' : sev >= 16 ? '#f9e2af' : '#a6adc8';
  const priLabel = p => p === 'HIGH' ? '<span style="background:#f38ba8;color:#1e1e2e;padding:2px 8px;border-radius:10px;font-size:.78rem;font-weight:700">HIGH</span>' : p === 'MEDIUM' ? '<span style="background:#fab387;color:#1e1e2e;padding:2px 8px;border-radius:10px;font-size:.78rem;font-weight:700">MEDIUM</span>' : '<span style="color:#a6adc8;font-size:.78rem">LOW</span>';
  const si = output.server_info;
  const ag = output.ag_info;
  const ramGB = si.ram ? Math.round(si.ram / 1024) : '?';

  // --- Top 3 issues ---
  const topIssues = output.code_search_targets.filter(e => e.priority === 'HIGH').slice(0, 3);
  if (topIssues.length < 3) {
    for (const e of output.code_search_targets.filter(e => e.priority === 'MEDIUM')) {
      if (topIssues.length >= 3) break;
      topIssues.push(e);
    }
  }

  // --- Executive summary (auto-generated) ---
  let summaryText = '';
  const highErrors = output.code_search_targets.filter(e => e.priority === 'HIGH');
  if (highErrors.length > 0) {
    const topErr = highErrors[0];
    const subsystems = [...new Set(highErrors.map(e => e.subsystem))];
    summaryText = `In the analyzed period, <strong>${output.error_summary.total_occurrences} error occurrences</strong> were detected across <strong>${output.error_summary.total_unique} unique error types</strong>. `;
    if (output.error_summary.fatal_count > 0) {
      summaryText += `<span style="color:#f38ba8"><strong>${output.error_summary.fatal_count} fatal errors (Severity &ge; 20)</strong></span> were found. `;
    }
    summaryText += `The primary issue is <strong>Error ${topErr.error_number}</strong> (${topErr.subsystem}, ${topErr.count} occurrences). `;
    if (subsystems.some(s => s.startsWith('HADR'))) {
      summaryText += `The errors indicate <strong>HADR/Availability Group instability</strong>`;
      if (ag && ag.ag_name) summaryText += ` affecting AG '<strong>${esc(ag.ag_name)}</strong>'`;
      summaryText += '. ';
    }
    if (output.patterns.some(p => p.type === 'LSN_ADVANCING')) {
      summaryText += 'LSN is advancing despite errors, suggesting <strong>intermittent connectivity</strong> rather than a complete disconnect. ';
    }
  } else {
    summaryText = `${output.error_summary.total_occurrences} error occurrences found. No high-priority issues detected in the analyzed period.`;
  }

  let html = `<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SQL-CSI — ${esc(si.instance||'Errorlog Analysis')}</title>
<style>
:root{--bg:#1e1e2e;--s1:#252538;--s2:#2a2a40;--bd:#3a3a55;--tx:#cdd6f4;--dim:#a6adc8;--ac:#89b4fa;--gn:#a6e3a1;--yl:#f9e2af;--or:#fab387;--rd:#f38ba8;--tl:#94e2d5;--mv:#cba6f7;}
*{margin:0;padding:0;box-sizing:border-box;}
body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--tx);line-height:1.6;padding:2rem;max-width:1300px;margin:0 auto;}
h1{color:var(--ac);font-size:1.7rem;border-bottom:2px solid var(--ac);padding-bottom:.5rem;margin-bottom:1.2rem;}
h2{color:var(--mv);font-size:1.2rem;margin:1.8rem 0 .7rem;border-left:4px solid var(--mv);padding-left:.7rem;}
.sec{background:var(--s1);border:1px solid var(--bd);border-radius:8px;padding:1.2rem;margin:.8rem 0;}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:.8rem;}
.grid3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:.8rem;}
@media(max-width:900px){.grid2,.grid3{grid-template-columns:1fr;}}
.kv{display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid var(--bd);font-size:.88rem;}
.kv:last-child{border-bottom:none;}
.kv .k{color:var(--dim);} .kv .v{font-weight:600;text-align:right;}
.num-card{text-align:center;background:var(--s1);border:1px solid var(--bd);border-radius:8px;padding:.8rem;}
.num-card .n{font-size:1.8rem;font-weight:800;} .num-card .l{font-size:.75rem;color:var(--dim);margin-top:.2rem;}
.issue-card{border-left:4px solid var(--rd);background:var(--s1);border-radius:0 8px 8px 0;padding:1rem;margin:.6rem 0;}
.issue-card.medium{border-left-color:var(--or);}
table{width:100%;border-collapse:collapse;margin:.6rem 0;font-size:.85rem;}
th,td{padding:6px 10px;border:1px solid var(--bd);text-align:left;}
th{background:var(--s2);color:var(--ac);font-weight:600;font-size:.82rem;}
tr:hover{background:rgba(137,180,250,.05);}
.tl-row{display:flex;gap:.5rem;padding:3px 0;font-size:.83rem;border-left:2px solid var(--bd);margin-left:.8rem;padding-left:.6rem;}
.tl-row:hover{background:var(--s1);}
.tl-ts{color:var(--dim);white-space:nowrap;min-width:170px;font-family:Consolas,monospace;font-size:.8rem;}
.tl-icon{min-width:24px;font-weight:700;font-size:.75rem;}
.tl-desc{flex:1;}
.tl-gap{border-left:2px dashed var(--or);margin-left:.8rem;padding:3px .6rem;color:var(--or);font-size:.8rem;font-style:italic;}
.role-tag{display:inline-block;padding:2px 8px;border-radius:4px;font-size:.78rem;font-weight:700;}
.role-PRIMARY{background:rgba(166,227,161,.2);color:var(--gn);border:1px solid var(--gn);}
.role-SECONDARY{background:rgba(137,180,250,.15);color:var(--ac);border:1px solid var(--ac);}
.role-RESOLVING{background:rgba(243,139,168,.15);color:var(--rd);border:1px solid var(--rd);}
.sub-group{margin:1rem 0;}
.sub-group-title{font-weight:700;color:var(--tl);font-size:.95rem;margin-bottom:.4rem;padding:4px 8px;background:var(--s2);border-radius:4px;display:inline-block;}
.insight{background:var(--s2);border-left:3px solid var(--tl);border-radius:0 6px 6px 0;padding:.8rem 1rem;margin:.5rem 0;font-size:.88rem;}
.footer{margin-top:2rem;padding-top:1rem;border-top:1px solid var(--bd);font-size:.78rem;color:var(--dim);text-align:center;}
code{font-family:'Cascadia Code',Consolas,monospace;background:var(--s2);padding:1px 5px;border-radius:3px;font-size:.83rem;}
</style></head><body>

<h1>SQL-CSI Errorlog Analysis</h1>

<!-- ========== Section 1: Server Profile ========== -->
<h2>1. Server Profile</h2>
<div class="grid2">
  <div class="sec">
    <div class="kv"><span class="k">Instance</span><span class="v">${esc(si.instance)}</span></div>
    <div class="kv"><span class="k">Version</span><span class="v">${esc(si.version_short||si.version_full||'unknown')}</span></div>
    <div class="kv"><span class="k">Build</span><span class="v"><code>${esc(si.build)}</code></span></div>
    <div class="kv"><span class="k">Edition</span><span class="v">${esc(si.edition)}</span></div>
    <div class="kv"><span class="k">OS</span><span class="v">${esc(si.os)}</span></div>
  </div>
  <div class="sec">
    <div class="kv"><span class="k">RAM</span><span class="v">${ramGB} GB (${si.ram||'?'} MB)</span></div>
    <div class="kv"><span class="k">CPUs</span><span class="v">${si.cpus||'?'} logical (${si.sockets||'?'} sockets &times; ${si.cores_per_socket||'?'} cores)</span></div>
    <div class="kv"><span class="k">Service Account</span><span class="v">${esc(si.service_account)}</span></div>
    <div class="kv"><span class="k">Auth Mode</span><span class="v">${esc(si.auth_mode)}</span></div>
    <div class="kv"><span class="k">Collation</span><span class="v">${esc(si.collation)}</span></div>
  </div>
</div>
<div class="sec" style="margin-top:.5rem">
  <div class="kv"><span class="k">Focus Period</span><span class="v" style="color:var(--ac);font-weight:700">${esc(output.focus_period)}</span></div>
  <div class="kv"><span class="k">Time Range</span><span class="v">${esc(output.time_range.first)} &rarr; ${esc(output.time_range.last)}</span></div>
  <div class="kv"><span class="k">Files Analyzed</span><span class="v">${output.files_analyzed.join(', ')}</span></div>
  <div class="kv"><span class="k">Records Parsed</span><span class="v">${output.total_lines}</span></div>
</div>
`;

  // --- AG Configuration (if detected) ---
  if (ag) {
    const roleClass = (ag.current_role||'').includes('PRIMARY') ? 'PRIMARY' : (ag.current_role||'').includes('SECONDARY') ? 'SECONDARY' : 'RESOLVING';
    html += `
<h2>AG Configuration</h2>
<div class="sec">
  <div class="grid2">
    <div>
      <div class="kv"><span class="k">AG Name</span><span class="v" style="color:var(--tl)">${esc(ag.ag_name)}</span></div>
      <div class="kv"><span class="k">Current Role</span><span class="v"><span class="role-tag role-${roleClass}">${esc(ag.current_role||'UNKNOWN')}</span></span></div>
      <div class="kv"><span class="k">Databases</span><span class="v">${ag.ag_databases.map(d=>'<code>'+esc(d)+'</code>').join(', ') || 'none detected'}</span></div>
    </div>
    <div>
      <div class="kv"><span class="k">Known Replicas</span><span class="v">${ag.replica_names.map(r=>esc(r)).join('<br>') || 'none detected'}</span></div>
      <div class="kv"><span class="k">Role Changes (total)</span><span class="v">${ag.role_changes.length}</span></div>
      <div class="kv"><span class="k">Role Changes (focus period)</span><span class="v" style="color:${ag.role_changes_in_period.length > 0 ? 'var(--or)' : 'var(--gn)'}">${ag.role_changes_in_period.length}</span></div>
    </div>
  </div>
</div>
`;

    // AG Role Change Timeline
    const roleChanges = ag.role_changes_in_period.length > 0 ? ag.role_changes_in_period : (ag.last_role_change ? [ag.last_role_change] : []);
    if (roleChanges.length > 0) {
      const label = ag.role_changes_in_period.length > 0 ? 'Role Changes in Focus Period' : 'Last Known Role Change (before focus period)';
      html += `<h2>AG Role Change Timeline</h2>
<p style="font-size:.85rem;color:var(--dim);margin-bottom:.5rem">${label}</p>
<table><thead><tr><th>Time</th><th>From</th><th>&rarr;</th><th>To</th><th>File</th></tr></thead><tbody>`;
      for (const rc of roleChanges) {
        const fromClass = rc.from_state.includes('PRIMARY') ? 'PRIMARY' : rc.from_state.includes('SECONDARY') ? 'SECONDARY' : 'RESOLVING';
        const toClass = rc.to_state.includes('PRIMARY') ? 'PRIMARY' : rc.to_state.includes('SECONDARY') ? 'SECONDARY' : 'RESOLVING';
        html += `<tr><td style="font-family:Consolas,monospace;font-size:.82rem">${esc(rc.timestamp)}</td>`;
        html += `<td><span class="role-tag role-${fromClass}">${esc(rc.from_state)}</span></td>`;
        html += `<td style="color:var(--dim)">&rarr;</td>`;
        html += `<td><span class="role-tag role-${toClass}">${esc(rc.to_state)}</span></td>`;
        html += `<td style="font-size:.8rem;color:var(--dim)">${esc(rc.file)}</td></tr>`;
      }
      html += `</tbody></table>\n`;
    }
  }

  // ========== Section 2: Executive Summary ==========
  html += `
<h2>2. Executive Summary</h2>
<div class="sec" style="border-left:4px solid var(--ac);font-size:.92rem;line-height:1.7">
  ${summaryText}
</div>
<div class="grid3" style="margin-top:.6rem">
  <div class="num-card"><div class="n" style="color:var(--ac)">${output.error_summary.total_unique}</div><div class="l">Unique Errors</div></div>
  <div class="num-card"><div class="n" style="color:var(--rd)">${output.error_summary.fatal_count}</div><div class="l">Fatal (Sev &ge; 20)</div></div>
  <div class="num-card"><div class="n" style="color:var(--or)">${output.error_summary.high_severity_count - output.error_summary.fatal_count}</div><div class="l">High Severity (16-19)</div></div>
</div>
`;

  // ========== Section 3: Top Issues ==========
  html += `<h2>3. Top Issues</h2>\n`;
  for (let i = 0; i < topIssues.length; i++) {
    const e = topIssues[i];
    const cardClass = e.priority === 'HIGH' ? '' : ' medium';
    html += `<div class="issue-card${cardClass}">
  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.5rem">
    <span style="font-size:1.1rem;font-weight:700;color:${sevColor(e.severity)}">Issue #${i+1}: Error ${e.error_number}</span>
    ${priLabel(e.priority)}
  </div>
  <div class="grid2" style="gap:.4rem">
    <div class="kv"><span class="k">Severity</span><span class="v" style="color:${sevColor(e.severity)}">${e.severity} (${esc(e.severity_class)})</span></div>
    <div class="kv"><span class="k">Occurrences</span><span class="v">${e.count}</span></div>
    <div class="kv"><span class="k">Subsystem</span><span class="v"><code>${esc(e.subsystem)}</code></span></div>
    <div class="kv"><span class="k">Time Range</span><span class="v" style="font-size:.82rem">${esc(e.first_seen)} &rarr; ${esc(e.last_seen)}</span></div>
  </div>
  <div style="margin-top:.5rem;font-size:.85rem;color:var(--dim)">${esc((e.message_sample||'').replace(/^Error:.*State:\s*\d+\.\s*/, '').substring(0, 200))}</div>
  ${e.priority_reasons.length ? '<div style="margin-top:.3rem;font-size:.82rem">Reasons: ' + esc(e.priority_reasons.join('; ')) + '</div>' : ''}
  <div style="margin-top:.6rem;background:#1a1a2e;border:1px solid var(--bd);border-radius:6px;padding:.6rem .8rem;font-family:Consolas,monospace;font-size:.8rem;white-space:pre-wrap;word-break:break-word;color:var(--dim);max-height:120px;overflow-y:auto">
<span style="color:var(--rd);font-weight:700">Latest occurrence (${esc(e.last_seen)}):</span>
${esc(e.last_full_message || e.message_sample || '')}</div>
</div>\n`;
  }

  // ========== Section 4: Error Detail by Subsystem ==========
  html += `<h2>4. Error Detail by Subsystem</h2>\n`;
  for (const [sub, errs] of Object.entries(output.errors_by_subsystem || {})) {
    html += `<div class="sub-group"><span class="sub-group-title">${esc(sub)}</span>
<table><thead><tr><th>Error</th><th>Sev</th><th>Count</th><th>First</th><th>Last</th><th>Message</th></tr></thead><tbody>`;
    for (const e of errs) {
      html += `<tr><td style="font-weight:700;color:${sevColor(e.severity)}">${e.error_number}</td>`;
      html += `<td style="color:${sevColor(e.severity)}">${e.severity}</td><td>${e.count}</td>`;
      html += `<td style="font-size:.8rem;color:var(--dim)">${esc(e.first_seen)}</td>`;
      html += `<td style="font-size:.8rem;color:var(--dim)">${esc(e.last_seen)}</td>`;
      html += `<td style="font-size:.82rem">${esc((e.message_sample||'').replace(/^Error:.*State:\s*\d+\.\s*/, '').substring(0, 120))}</td></tr>`;
    }
    html += `</tbody></table></div>\n`;
  }
  // Benign errors (collapsed)
  const benign = output.errors.filter(e => e.is_benign);
  if (benign.length > 0) {
    html += `<div class="sub-group"><span class="sub-group-title" style="background:var(--s1);color:var(--dim)">Benign / Informational (deprioritized)</span>
<table style="opacity:.6"><thead><tr><th>Error</th><th>Sev</th><th>Count</th><th>Message</th></tr></thead><tbody>`;
    for (const e of benign) {
      html += `<tr><td>${e.error_number}</td><td>${e.severity}</td><td>${e.count}</td><td style="font-size:.82rem">${esc((e.message_sample||'').substring(0, 100))}</td></tr>`;
    }
    html += `</tbody></table></div>\n`;
  }

  // ========== Section 5: Patterns & Insights ==========
  html += `<h2>5. Patterns &amp; Insights</h2>\n`;
  if (output.patterns.length === 0) {
    html += `<div class="insight">No significant patterns detected.</div>\n`;
  }
  for (const p of output.patterns) {
    if (p.type === 'ERROR_CASCADE') {
      html += `<div class="insight" style="border-left-color:var(--rd)">
<strong style="color:var(--rd)">Error Cascades</strong> &mdash; ${p.instances.length} cascade events detected.
Each cascade is a cluster of &ge; 3 errors from &ge; 2 different error types within 30 seconds.
The <strong>root error</strong> (first in the cascade) is most likely the cause; subsequent errors are side effects.
<table style="margin-top:.5rem"><thead><tr><th>Time</th><th>Count</th><th>Root Error</th><th>Involved Errors</th></tr></thead><tbody>`;
      for (const c of p.instances.slice(0, 10)) {
        html += `<tr><td style="font-size:.82rem">${esc(c.start)}</td><td>${c.count}</td><td style="color:var(--rd);font-weight:700">${c.root_error}</td><td>${c.unique_errors.join(', ')}</td></tr>`;
      }
      if (p.instances.length > 10) html += `<tr><td colspan="4" style="color:var(--dim);text-align:center">+ ${p.instances.length - 10} more</td></tr>`;
      html += `</tbody></table></div>\n`;
    }
    if (p.type === 'REPEATING_ERROR') {
      html += `<div class="insight" style="border-left-color:var(--or)">
<strong style="color:var(--or)">Repeating Errors</strong> &mdash; These errors occurred &ge; 5 times, suggesting a recurring condition or retry loop.
<table style="margin-top:.5rem"><thead><tr><th>Error</th><th>Count</th><th>First Seen</th><th>Last Seen</th><th>Duration</th></tr></thead><tbody>`;
      for (const r of p.instances) {
        const dur = formatDuration(timeDiffSeconds(r.first_seen, r.last_seen));
        html += `<tr><td style="font-weight:700">${r.error_number}</td><td>${r.count}</td><td style="font-size:.82rem">${esc(r.first_seen)}</td><td style="font-size:.82rem">${esc(r.last_seen)}</td><td>${dur}</td></tr>`;
      }
      html += `</tbody></table></div>\n`;
    }
    if (p.type === 'PAIRED_ERRORS') {
      html += `<div class="insight" style="border-left-color:var(--yl)">
<strong style="color:var(--yl)">Paired Errors</strong> &mdash; These errors appear exactly 2 times at the same timestamp, suggesting two code paths or a loop executing the same scierrlog call.
<ul style="margin:.3rem 0 0 1.2rem">`;
      for (const pe of p.instances) html += `<li>Error <strong>${pe.error_number}</strong>: ${pe.pair_count} pairs</li>`;
      html += `</ul></div>\n`;
    }
    if (p.type === 'LSN_ADVANCING') {
      html += `<div class="insight" style="border-left-color:var(--gn)">
<strong style="color:var(--gn)">LSN Advancing</strong> &mdash; ${esc(p.detail)}
<div style="margin-top:.3rem">First LSN: <code>${esc(p.first_lsn)}</code> &rarr; Last LSN: <code>${esc(p.last_lsn)}</code> (${p.count} samples)</div>
</div>\n`;
    }
  }
  // Time gaps as insight
  if (output.gaps.length > 0) {
    html += `<div class="insight" style="border-left-color:var(--or)">
<strong style="color:var(--or)">Time Gaps</strong> &mdash; ${output.gaps.length} gaps &gt; 60 seconds found between significant events. Gaps may indicate server hangs, I/O stalls, or network partitions.
<table style="margin-top:.5rem"><thead><tr><th>After</th><th>Before</th><th>Duration</th></tr></thead><tbody>`;
    for (const g of output.gaps.slice(0, 10)) {
      html += `<tr><td style="font-size:.82rem">${esc(g.after)}</td><td style="font-size:.82rem">${esc(g.before)}</td><td style="font-weight:700;color:var(--or)">${esc(g.duration_human)}</td></tr>`;
    }
    if (output.gaps.length > 10) html += `<tr><td colspan="3" style="color:var(--dim);text-align:center">+ ${output.gaps.length - 10} more</td></tr>`;
    html += `</tbody></table></div>\n`;
  }

  // ========== Section 6: Incident Timeline (condensed) ==========
  html += `<h2>6. Incident Timeline</h2>
<p style="font-size:.82rem;color:var(--dim);margin-bottom:.5rem">${output.timeline.length} events shown (severity &ge; 16 errors, AG state changes, server start/stop)</p>\n`;
  const iconMap = { '[FATAL]':'!!', '[ERROR]':'!', '[START]':'▶', '[READY]':'✓', '[STOP]':'■', '[HADR]':'AG', '[DUMP]':'!!', '[IO]':'IO', '[MEMORY]':'M' };
  const iconColor = icon => {
    if (icon==='[FATAL]'||icon==='[DUMP]') return 'var(--rd)';
    if (icon==='[ERROR]') return 'var(--or)';
    if (icon==='[HADR]') return 'var(--mv)';
    if (icon==='[START]'||icon==='[READY]') return 'var(--gn)';
    if (icon==='[STOP]') return 'var(--yl)';
    return 'var(--dim)';
  };
  let gapIdx = 0;
  const maxTl = 60; // show at most 60 timeline events in HTML
  const tlSlice = output.timeline.length > maxTl ? output.timeline.slice(0, maxTl) : output.timeline;
  for (let i = 0; i < tlSlice.length; i++) {
    const t = tlSlice[i];
    while (gapIdx < output.gaps.length && i > 0 && output.gaps[gapIdx].after === tlSlice[i-1].timestamp) {
      html += `<div class="tl-gap">⏸ GAP: ${esc(output.gaps[gapIdx].duration_human)}</div>\n`;
      gapIdx++;
    }
    html += `<div class="tl-row"><span class="tl-ts">${esc(t.timestamp)}</span><span class="tl-icon" style="color:${iconColor(t.icon)}">${iconMap[t.icon]||'-'}</span><span class="tl-desc">${esc(t.description)}</span></div>\n`;
  }
  if (output.timeline.length > maxTl) {
    html += `<div style="text-align:center;color:var(--dim);font-size:.82rem;padding:.5rem">... ${output.timeline.length - maxTl} more events (use --json for full data)</div>`;
  }

  // ========== Section 7: Recommended Actions ==========
  html += `<h2>7. Recommended Actions</h2>
<div class="sec">
<table><thead><tr><th style="width:80px">Priority</th><th>Action</th><th>Target</th></tr></thead><tbody>`;
  for (const t of output.code_search_targets.filter(t => t.priority !== 'LOW').slice(0, 5)) {
    html += `<tr><td>${priLabel(t.priority)}</td>`;
    html += `<td>Search source code for error definition and raising code</td>`;
    html += `<td><code>search error ${t.error_number}</code> &mdash; ${esc(t.subsystem)}, Sev ${t.severity}, ${t.count}x</td></tr>`;
  }
  if (ag) {
    html += `<tr><td>${priLabel('MEDIUM')}</td><td>Check HADR transport / endpoint connectivity</td><td>Verify network between replicas: ${ag.replica_names.map(r=>esc(r)).join(', ')}</td></tr>`;
    html += `<tr><td>${priLabel('MEDIUM')}</td><td>Check HADR endpoint configuration and certificates</td><td><code>SELECT * FROM sys.database_mirroring_endpoints</code></td></tr>`;
  }
  html += `<tr><td>${priLabel('LOW')}</td><td>Collect dump for deeper analysis</td><td>If errors persist, generate dump with Mirrors commands</td></tr>`;
  html += `</tbody></table>

<div style="margin-top:1rem;background:rgba(137,180,250,.08);border:2px solid var(--ac);border-radius:8px;padding:1rem 1.2rem">
  <div style="font-weight:700;color:var(--ac);font-size:1rem;margin-bottom:.5rem">Next: Deep-Dive into Source Code</div>
  <div style="font-size:.88rem;color:var(--dim);margin-bottom:.8rem">Select an error to search the SQL Server source code for its definition, raising code, function logic, and root cause analysis.</div>
  <div style="display:flex;flex-wrap:wrap;gap:.5rem">`;
  for (const t of output.code_search_targets.filter(t => t.priority !== 'LOW').slice(0, 5)) {
    const bg = t.priority === 'HIGH' ? 'rgba(243,139,168,.15)' : 'rgba(250,179,135,.1)';
    const bc = t.priority === 'HIGH' ? 'var(--rd)' : 'var(--or)';
    html += `<div style="background:${bg};border:1px solid ${bc};border-radius:6px;padding:.5rem .8rem;font-size:.88rem">
<code style="font-weight:700;color:${bc}">search error ${t.error_number}</code>
<span style="color:var(--dim);font-size:.8rem"> — ${esc(t.subsystem)}, Sev ${t.severity}, ${t.count}x</span></div>`;
  }
  html += `</div></div>
</div>\n`;

  // Footer
  html += `
<div class="footer">
  SQL-CSI &middot; parse_errorlog.js &middot; ${output.analysis_date.split('T')[0]} &middot;
  ${output.files_analyzed.join(', ')} &middot; ${output.total_lines} records
</div>
</body></html>`;

  return html;
}

// =============================================================================
// Server Info Extraction (Enhanced)
// =============================================================================

function extractServerInfo(records) {
  const info = {
    version_full: null,    // "Microsoft SQL Server 2016 (SP2-CU17) ..."
    version_short: null,   // "SQL Server 2016 SP2-CU17"
    build: null,           // "13.0.5888.11"
    instance: null,        // "SGPICAA04"
    edition: null,         // "Enterprise Edition: Core-based Licensing (64-bit)"
    os: null,              // "Windows Server 2016 Standard 10.0"
    ram: null,             // 49150 (MB)
    cpus: null,            // 20
    sockets: null,         // 2
    cores_per_socket: null,// 10
    service_account: null, // "NCAINTRA\\svc-sql-ica$"
    collation: null,       // "Latin1_General_CI_AI"
    auth_mode: null,       // "WINDOWS-ONLY"
    errorlog_path: null,   // "E:\\MSSQL\\..."
    startup_time: null,    // first "SQL Server is starting" timestamp
  };

  for (const r of records.slice(0, 80)) {
    const msg = r.message;

    if (msg.includes('Microsoft SQL Server') && !info.version_full) {
      info.version_full = msg.split('\n')[0].trim();
      // Extract short version
      const mv = msg.match(/SQL Server (\d{4})\s*(\([^)]+\))?/);
      if (mv) info.version_short = `SQL Server ${mv[1]} ${(mv[2]||'').replace(/[()]/g,'')}`.trim();
      // Extract build
      const bv = msg.match(/(\d+\.\d+\.\d+\.\d+)/);
      if (bv) info.build = bv[1];
    }
    if (msg.includes('Logging SQL Server messages in file') && !info.instance) {
      const m = msg.match(/MSSQL\d+\.(\w+)/);
      if (m) info.instance = m[1];
      info.errorlog_path = msg.replace(/^.*file\s+'?/, '').replace(/'?\s*\.?\s*$/, '').trim();
    }
    if (msg.includes('Edition') && msg.includes('on Windows') && !info.edition) {
      const parts = msg.trim().split(/\s+on\s+/);
      info.edition = (parts[0] || '').trim();
      if (parts[1]) info.os = parts[1].trim();
    }
    if (msg.includes('Detected') && msg.includes('MB of RAM') && !info.ram) {
      const m = msg.match(/(\d+)\s*MB/);
      if (m) info.ram = parseInt(m[1]);
    }
    if (msg.includes('logical processors') && !info.cpus) {
      const m = msg.match(/(\d+)\s*total logical processors/);
      if (m) info.cpus = parseInt(m[1]);
      const s = msg.match(/(\d+)\s*sockets?\s+with\s+(\d+)\s*cores?\s+per\s+socket/i);
      if (s) { info.sockets = parseInt(s[1]); info.cores_per_socket = parseInt(s[2]); }
    }
    if (msg.includes('service account is') && !info.service_account) {
      const m = msg.match(/service account is '([^']+)'/);
      if (m) info.service_account = m[1];
    }
    if (msg.includes('Default collation') && !info.collation) {
      const m = msg.match(/collation:\s*(\S+)/);
      if (m) info.collation = m[1];
    }
    if (msg.includes('Authentication mode') && !info.auth_mode) {
      const m = msg.match(/mode is (\S+)/);
      if (m) info.auth_mode = m[1].replace('.', '');
    }
    if (msg.includes('SQL Server is start') && !info.startup_time) {
      info.startup_time = r.timestamp;
    }
  }
  return info;
}

// =============================================================================
// AG Info Extraction
// =============================================================================

function extractAgInfo(allRecords, filteredRecords) {
  const agInfo = {
    ag_name: null,
    ag_databases: [],
    replica_names: [],
    current_role: null,
    role_changes: [],          // all role changes found
    role_changes_in_period: [],// role changes within --days filter
    last_role_change: null,    // most recent role change overall
    state_machine: [],         // AG state transitions
  };

  // Scan ALL records (not filtered) for AG configuration
  const dbSet = new Set();
  const replicaSet = new Set();

  for (const r of allRecords) {
    const msg = r.message;

    // AG name
    if (!agInfo.ag_name) {
      const m = msg.match(/availability group '([^']+)'/i);
      if (m) agInfo.ag_name = m[1];
    }

    // AG databases
    const dbm = msg.match(/database "([^"]+)".*(?:changing roles|availability group)/i) ||
                msg.match(/database '([^']+)'.*availability/i) ||
                msg.match(/availability.*database '([^']+)'/i);
    if (dbm && dbm[1] !== 'master' && dbm[1] !== 'tempdb') dbSet.add(dbm[1]);

    // Replica names
    const rm = msg.match(/availability replica '([^']+)'/i);
    if (rm) replicaSet.add(rm[1]);

    // AG state changes (full dataset)
    if (r.event_type === 'AG_STATE_CHANGE') {
      const rc = {
        timestamp: r.timestamp,
        ag_name: r.details.ag_name,
        from_state: r.details.from_state,
        to_state: r.details.to_state,
        file: r.file,
      };
      agInfo.role_changes.push(rc);
      agInfo.last_role_change = rc;

      // Derive role from state
      if (r.details.to_state.includes('PRIMARY')) agInfo.current_role = 'PRIMARY';
      else if (r.details.to_state.includes('SECONDARY')) agInfo.current_role = 'SECONDARY';
      else if (r.details.to_state.includes('RESOLVING')) agInfo.current_role = 'RESOLVING';
    }

    // DB role changes
    if (r.event_type === 'DB_ROLE_CHANGE') {
      agInfo.state_machine.push({
        timestamp: r.timestamp,
        database: r.details.database,
        from_role: r.details.from_role,
        to_role: r.details.to_role,
      });
    }
  }

  agInfo.ag_databases = [...dbSet].sort();
  agInfo.replica_names = [...replicaSet].sort();

  // Role changes within filtered period
  if (filteredRecords.length > 0) {
    const firstTs = filteredRecords[0].timestamp;
    agInfo.role_changes_in_period = agInfo.role_changes.filter(rc => rc.timestamp >= firstTs);
  }

  // If no AG detected
  if (!agInfo.ag_name) return null;

  return agInfo;
}

// =============================================================================
// Error Time Distribution (which time periods each error appears in)
// =============================================================================

function buildErrorTimeDistribution(errors) {
  const dist = {};
  for (const e of errors) {
    if (!dist[e.error_number]) dist[e.error_number] = [];
    dist[e.error_number].push(e.timestamp);
  }
  // For each error, compute time clusters (gaps > 1 hour = new cluster)
  const result = {};
  for (const [errNum, timestamps] of Object.entries(dist)) {
    const clusters = [];
    let clusterStart = timestamps[0];
    let clusterEnd = timestamps[0];
    for (let i = 1; i < timestamps.length; i++) {
      const diff = timeDiffSeconds(clusterEnd, timestamps[i]);
      if (diff > 3600) {
        clusters.push({ from: clusterStart, to: clusterEnd, count: i });
        clusterStart = timestamps[i];
      }
      clusterEnd = timestamps[i];
    }
    clusters.push({ from: clusterStart, to: clusterEnd, count: timestamps.length });
    result[errNum] = clusters;
  }
  return result;
}

// =============================================================================
// Main
// =============================================================================

function main() {
  const args = process.argv.slice(2);
  if (args.length === 0 || args.includes('--help') || args.includes('-h')) {
    console.log(`
SQL-CSI ERRORLOG Parser

Usage:
  node parse_errorlog.js <file1> [file2] [...] [options]

Options:
  --output <file>     Save JSON output to file (default: stdout)
  --html <file>       Generate HTML report and save to file
  --days <N>          Only analyze the most recent N days (calculated from latest log entry)
  --from <datetime>   Filter: only include records after this time
  --to <datetime>     Filter: only include records before this time
  --json              Output raw JSON (default: formatted console output)
  --open              Open HTML report in browser after generation
  --help, -h          Show this help

Examples:
  node parse_errorlog.js C:\\logs\\ERRORLOG
  node parse_errorlog.js C:\\logs\\ERRORLOG* --days 7 --html report.html --open
  node parse_errorlog.js C:\\logs\\ERRORLOG C:\\logs\\ERRORLOG.1 --json --output findings.json
  node parse_errorlog.js C:\\logs\\ERRORLOG --from "2021-05-02 03:00" --to "2021-05-02 04:00"
`);
    process.exit(0);
  }

  // Parse arguments
  const files = [];
  let outputFile = null;
  let htmlFile = null;
  let fromTime = null;
  let toTime = null;
  let days = null;
  let jsonOutput = false;
  let openBrowser = false;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--output' && i + 1 < args.length) { outputFile = args[++i]; }
    else if (args[i] === '--html' && i + 1 < args.length) { htmlFile = args[++i]; }
    else if (args[i] === '--from' && i + 1 < args.length) { fromTime = args[++i]; }
    else if (args[i] === '--to' && i + 1 < args.length) { toTime = args[++i]; }
    else if (args[i] === '--days' && i + 1 < args.length) { days = parseInt(args[++i]); }
    else if (args[i] === '--json') { jsonOutput = true; }
    else if (args[i] === '--open') { openBrowser = true; }
    else if (!args[i].startsWith('--')) { files.push(args[i]); }
  }

  if (files.length === 0) {
    console.error('Error: no ERRORLOG files specified');
    process.exit(1);
  }

  // Parse all files
  let allRecords = [];
  const filesAnalyzed = [];

  // Sort files: ERRORLOG.12 → ERRORLOG.1 → ERRORLOG (oldest first)
  const sorted = files.sort((a, b) => {
    const numA = a.match(/\.(\d+)$/);
    const numB = b.match(/\.(\d+)$/);
    const na = numA ? parseInt(numA[1]) : 0;
    const nb = numB ? parseInt(numB[1]) : 0;
    return nb - na; // Higher number = older = first
  });

  for (const f of sorted) {
    try {
      const records = parseErrorlog(f);
      allRecords = allRecords.concat(records);
      filesAnalyzed.push(path.basename(f));
      process.stderr.write(`Parsed ${path.basename(f)}: ${records.length} records\n`);
    } catch (err) {
      process.stderr.write(`Warning: failed to parse ${f}: ${err.message}\n`);
    }
  }

  // Apply time range filter
  const allRecordsBeforeFilter = [...allRecords]; // keep full history for AG/server info
  if (fromTime || toTime) {
    allRecords = filterByTimeRange(allRecords, fromTime, toTime);
    process.stderr.write(`After time filter: ${allRecords.length} records\n`);
  }

  // Apply --days filter (from latest log entry minus N days)
  if (days) {
    allRecords = filterByDays(allRecords, days);
    process.stderr.write(`After --days ${days} filter: ${allRecords.length} records\n`);
  }

  // Extract server info from ALL records (before filtering)
  // We need full history for server info and AG config
  const serverInfo = extractServerInfo(allRecordsBeforeFilter);

  // Extract AG info from ALL records, pass filtered for period detection
  const agInfo = extractAgInfo(allRecordsBeforeFilter, allRecords);

  // Separate errors from other records
  const errors = allRecords.filter(r => r.event_type === 'ERROR');
  const errorSummary = buildErrorSummary(errors);

  // Error time distribution
  const errorTimeDist = buildErrorTimeDistribution(errors);

  // Detect patterns
  const patterns = detectPatterns(errors);

  // Build timeline
  const timeline = buildTimeline(allRecords);

  // Find gaps
  const gaps = findGaps(timeline);

  // Assign priorities
  const codeSearchTargets = assignPriorities(errorSummary, patterns);

  // Time range
  const timestamps = allRecords.filter(r => r.timestamp).map(r => r.timestamp);
  const timeRange = {
    first: timestamps[0] || 'unknown',
    last: timestamps[timestamps.length - 1] || 'unknown',
  };

  // Group errors by subsystem for the report
  const errorsBySubsystem = {};
  for (const e of codeSearchTargets) {
    const sub = e.subsystem || 'UNKNOWN';
    if (!errorsBySubsystem[sub]) errorsBySubsystem[sub] = [];
    errorsBySubsystem[sub].push(e);
  }

  // Build output
  const output = {
    analysis_type: 'sql-csi-errorlog',
    analysis_date: new Date().toISOString(),
    focus_period: days ? `Last ${days} days (from latest entry)` : (fromTime || toTime) ? `${fromTime || 'start'} → ${toTime || 'end'}` : 'All records',
    server_info: serverInfo,
    ag_info: agInfo,
    files_analyzed: filesAnalyzed,
    total_lines: allRecords.length,
    time_range: timeRange,
    error_summary: {
      total_unique: errorSummary.length,
      total_occurrences: errors.length,
      fatal_count: errors.filter(e => e.severity >= 20).length,
      high_severity_count: errors.filter(e => e.severity >= 16).length,
    },
    errors: errorSummary,
    errors_by_subsystem: errorsBySubsystem,
    error_time_distribution: errorTimeDist,
    patterns,
    timeline,
    gaps,
    code_search_targets: codeSearchTargets,
  };

  // Output
  if (htmlFile) {
    const html = formatHtml(output);
    fs.writeFileSync(htmlFile, html, 'utf8');
    process.stderr.write(`HTML report saved to ${htmlFile}\n`);
    if (openBrowser) {
      const { exec } = require('child_process');
      const cmd = process.platform === 'win32' ? `start "" "${htmlFile}"` : `open "${htmlFile}"`;
      exec(cmd);
    }
  }

  if (jsonOutput || outputFile) {
    const json = JSON.stringify(output, null, 2);
    if (outputFile) {
      fs.writeFileSync(outputFile, json, 'utf8');
      process.stderr.write(`JSON output saved to ${outputFile}\n`);
    } else {
      console.log(json);
    }
  }

  if (!htmlFile && !jsonOutput && !outputFile) {
    console.log(formatConsole(output));
  }
}

main();
