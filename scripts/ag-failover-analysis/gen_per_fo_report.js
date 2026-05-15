// scripts/ag-failover-analysis/gen_per_fo_report.js
// Generate one HTML report per failover incident
// Includes: raw ERRORLOG evidence, per-host AG flow, per-host per-DB tables
//
// Usage: node scripts/ag-failover-analysis/gen_per_fo_report.js <case_dir> <sql_server> <utc_offset>

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const args = process.argv.slice(2);
if (args.length < 3) { console.error('Usage: node gen_per_fo_report.js <case_dir> <sql_server> <utc_offset>'); process.exit(1); }
const caseDir = args[0];
const sqlServer = args[1];
const utcOffset = parseInt(args[2]);
const caseId = path.basename(caseDir);
const dbName = `ag_${caseId}`;

const schema = JSON.parse(fs.readFileSync(path.join(caseDir, 'ag_schema.json'), 'utf8'));
const incidents = JSON.parse(fs.readFileSync(path.join(caseDir, 'failover_incidents.json'), 'utf8'));
const merged = JSON.parse(fs.readFileSync(path.join(caseDir, 'merged_timeline.json'), 'utf8'));

// Build maps
const hosts = [schema.old_primary.host, schema.new_primary.host];
const dbIdToName = {};  // { host: { id: name } }
const dbNameToId = {};  // { host: { name: id } }
const dbAgMap = {};     // { name: ag }
for (const key of ['old_primary', 'new_primary']) {
  const r = schema[key];
  dbIdToName[r.host] = {};
  dbNameToId[r.host] = {};
  for (const db of r.databases) {
    dbIdToName[r.host][db.id] = db.name;
    dbNameToId[r.host][db.name] = db.id;
    if (!dbAgMap[db.name]) dbAgMap[db.name] = db.ag;
  }
}

// Find ERRORLOG files
const errorlogPaths = {};
for (const host of hosts) {
  const dir = path.join(caseDir, host);
  if (!fs.existsSync(dir)) continue;
  const files = fs.readdirSync(dir).filter(f => f.includes('ERRORLOG')).sort();
  if (files.length > 0) errorlogPaths[host] = files.map(f => path.join(dir, f));
}

function addMinutes(ts, min) {
  const d = new Date(ts.replace(' ', 'T') + 'Z');
  d.setMinutes(d.getMinutes() + min);
  return d.toISOString().replace('T', ' ').replace('Z', '').substring(0, 23);
}
function localToUtc(ts) { const d = new Date(ts.replace(' ', 'T') + 'Z'); d.setHours(d.getHours() - utcOffset); return d.toISOString().replace('T', ' ').replace('Z', '').substring(0, 23); }
function utcToLocal(ts) { const d = new Date(ts.replace(' ', 'T') + 'Z'); d.setHours(d.getHours() + utcOffset); return d.toISOString().replace('T', ' ').replace('Z', '').substring(0, 23); }
function esc(s) { return (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
function ts2t(ts) { return ts ? ts.substring(11, 19) : '-'; }  // extract HH:MM:SS
function ts2tf(ts) { return ts ? ts.substring(11) : '-'; }      // extract HH:MM:SS.fff

let tmpCnt = 0;
function sqlQuery(query) {
  const tmp = path.join(caseDir, `_rpt${tmpCnt++}.sql`);
  fs.writeFileSync(tmp, `SET NOCOUNT ON;\n${query}`);
  try {
    const r = execSync(`sqlcmd -S ${sqlServer} -E -d ${dbName} -W -s "|" -h -1 -i "${tmp}"`, { encoding: 'utf8', maxBuffer: 50 * 1024 * 1024 }).trim();
    fs.unlinkSync(tmp);
    return r;
  } catch (e) { try { fs.unlinkSync(tmp); } catch (_) { } return ''; }
}

// Read raw ERRORLOG lines within a time range for a host
// Returns array of { ts, line }
function readErrorlogLines(host, startTs, endTs, filter) {
  const files = errorlogPaths[host];
  if (!files) return [];
  const results = [];
  const startPrefix = startTs.substring(0, 19);  // "2026-05-11 07:53:53"
  const endPrefix = endTs.substring(0, 19);
  const startHH = parseInt(startTs.substring(11, 13));
  const endHH = parseInt(endTs.substring(11, 13));

  for (const fp of files) {
    // Use Select-String for efficiency on large files
    const startMin = startTs.substring(11, 16);  // HH:MM
    const endMin = endTs.substring(11, 16);
    // Build a powershell regex that matches the time range
    // For simplicity, grep for lines starting with the date
    const dateStr = startTs.substring(0, 10);
    try {
      const cmd = `powershell -NoProfile -Command "Select-String -Path '${fp}' -Pattern '^${dateStr}' | ForEach-Object { $_.Line } | Where-Object { $_ -ge '${startTs.substring(0,19)}' -and $_ -le '${endTs.substring(0,19)}z' }"`;
      const output = execSync(cmd, { encoding: 'utf8', maxBuffer: 100 * 1024 * 1024, timeout: 120000 }).trim();
      for (const line of output.split(/\r?\n/)) {
        if (!line.trim()) continue;
        if (filter && !filter(line)) continue;
        const ts = line.substring(0, 23);
        results.push({ ts, line });
      }
    } catch (e) { /* skip */ }
  }
  return results;
}

// CSS
const CSS = `
:root {
  --bg: #1e1e2e; --surface: #252538; --border: #3a3a55;
  --text: #cdd6f4; --dim: #a6adc8; --accent: #89b4fa;
  --green: #a6e3a1; --yellow: #f9e2af; --orange: #fab387;
  --red: #f38ba8; --teal: #94e2d5; --mauve: #cba6f7;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: var(--bg); color: var(--text); font-family: 'Segoe UI', Consolas, monospace; padding: 2rem; line-height: 1.6; max-width: 1600px; margin: 0 auto; }
h1 { color: var(--accent); margin-bottom: 0.5rem; font-size: 1.6rem; border-bottom: 2px solid var(--accent); padding-bottom: .4rem; }
h2 { color: var(--mauve); margin: 2rem 0 0.8rem; font-size: 1.3rem; border-left: 4px solid var(--mauve); padding-left: .8rem; }
h3 { color: var(--teal); margin: 1.5rem 0 0.6rem; font-size: 1.1rem; }
h4 { color: var(--yellow); margin: 1rem 0 .5rem; }
p, li { margin-bottom: 0.5rem; }
.meta { color: var(--dim); font-size: 0.9rem; margin-bottom: 1.5rem; }
table { border-collapse: collapse; width: 100%; margin: 1rem 0; font-size: 0.82rem; }
th { background: var(--surface); color: var(--accent); text-align: left; padding: 0.4rem 0.5rem; border: 1px solid var(--border); white-space: nowrap; position: sticky; top: 0; }
td { padding: 0.3rem 0.5rem; border: 1px solid var(--border); white-space: nowrap; }
tr:nth-child(even) { background: var(--surface); }
tr:hover { background: rgba(137,180,250,0.06); }
.stuck td { color: var(--red); }
.ok td { color: var(--green); }
.sep td { background: var(--border); height: 2px; padding: 0; }
code { background: var(--surface); color: var(--teal); padding: 0.1rem 0.3rem; border-radius: 3px; font-size: 0.9em; }
pre { background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 0.8rem; overflow-x: auto; font-size: 0.8rem; margin: 0.6rem 0; white-space: pre-wrap; word-break: break-all; }
.section { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 1rem; margin: 1rem 0; }
.badge { display: inline-block; padding: 0.1rem 0.5rem; border-radius: 3px; font-size: 0.8em; font-weight: bold; }
.badge-red { background: var(--red); color: var(--bg); }
.badge-green { background: var(--green); color: var(--bg); }
.badge-orange { background: var(--orange); color: var(--bg); }
.badge-yellow { background: var(--yellow); color: var(--bg); }
ul { padding-left: 1.5rem; }
.db-scroll { overflow-x: auto; max-height: 600px; overflow-y: auto; }
.evidence { background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 1rem; margin: .8rem 0; font-family: 'Cascadia Code', monospace; font-size: .82rem; white-space: pre-wrap; word-break: break-all; }
.evidence .src { color: var(--dim); font-style: italic; display: block; margin-bottom: .3rem; }
.conclusion { background: rgba(137,180,250,0.08); border-left: 3px solid var(--accent); padding: .6rem 1rem; margin: .8rem 0; }
`;

// ============================================================
// Process each FO
// ============================================================
for (let fi = 0; fi < incidents.incidents.length; fi++) {
  const inc = incidents.incidents[fi];
  if (inc.type === 'shutdown') continue;

  const foId = inc.id;  // "FO1", "FO2", "FO3"
  console.log(`\nProcessing ${foId}...`);

  const foStart = inc.start_ts;
  const foEnd = inc.end_ts;
  const preStart = addMinutes(foStart, -2);
  const startUtc = localToUtc(foStart);
  const endUtc = localToUtc(foEnd);
  const preStartUtc = localToUtc(preStart);

  // Determine direction per AG
  const agDirs = inc.ag_directions;

  // ---- 1. Read raw ERRORLOG trigger lines from both hosts ----
  const triggerWindow = { start: addMinutes(foStart, -1), end: addMinutes(foStart, 2) };  // 1 min before to 2 min after (covers delayed host)
  const triggerFilter = (line) => {
    // Core trigger events only: WSFC errors, AG-level role changes, health state, lease, connection timeouts
    // Exclude: DB-level role changes (too many), Remote harden (Error 3303), logins
    if (/Login succeeded|Logon|conn_established|database terminated for|database established for|changing roles|Remote harden/i.test(line)) return false;
    if (/Error: 3303/i.test(line)) return false;  // Remote harden error - too many
    if (/Error: 596/i.test(line)) return false;    // Kill state error - too many
    if (/Error: 983/i.test(line)) return false;    // Database not accessible
    if (/Error: 18456/i.test(line)) return false;  // Login failure
    if (/Error: 35206/i.test(line)) return false;  // Connection terminated
    if (/Error: 35254/i.test(line)) return false;  // Connection terminated
    if (/Error: 22006/i.test(line)) return false;  // ADR VersionCleaner
    if (/Error: 9642/i.test(line)) return false;   // Service Broker
    if (/sp_send_dbmail|Database Mail/i.test(line)) return false;
    return /going offline|has changed from|Error:|41005|41034|41144|41143|41161|1722|CRC|connection timeout|Lease Thread|Health worker|query_processing|SYSTEM_UNHEALTHY|Failed to update|failed state|availability replica manager|lost quorum|NT AUTHORITY\\SYSTEM|stop the lease/i.test(line);
  };

  const rawTrigger = {};
  for (const host of hosts) {
    const all = readErrorlogLines(host, triggerWindow.start, triggerWindow.end, triggerFilter);
    // Deduplicate: for each normalized pattern, keep at most first + last
    const patternMap = new Map();  // norm → { first, last, count }
    const output = [];
    for (const l of all) {
      // Normalize by stripping timestamp prefix, spid, and specific numeric values
      const content = l.line.substring(24).replace(/spid\d+s?\s+/g, '');
      const norm = content.replace(/\d+/g, 'N').substring(0, 100);
      if (!patternMap.has(norm)) {
        patternMap.set(norm, { index: output.length, count: 1, last: l });
        output.push(l);
      } else {
        const entry = patternMap.get(norm);
        entry.count++;
        entry.last = l;
      }
    }
    // For patterns with count > 1, append the last occurrence after the first
    // Build final list maintaining order, inserting collapse markers
    const final = [];
    const inserted = new Set();
    for (let i = 0; i < output.length; i++) {
      final.push(output[i]);
      // Check if this line starts a group
      for (const [norm, entry] of patternMap) {
        if (entry.index === i && entry.count > 1 && !inserted.has(norm)) {
          inserted.add(norm);
          if (entry.count > 2) {
            final.push({ line: `  ... (×${entry.count - 2} more identical) ...`, _collapse: true });
          }
          if (entry.last !== output[i]) {
            final.push(entry.last);
          }
        }
      }
    }
    rawTrigger[host] = final;
    console.log(`  ${host}: ${all.length} trigger lines → ${final.length} after dedup`);
  }

  // ---- 2. Read raw ERRORLOG for per-DB role changes from both hosts ----
  const dbRoleFilter = (line) => {
    return /changing roles|Starting up database|has been released|Initializing.*DTC|ABORT_AFTER_WAIT|Nonqualified|resynchronize|Remote harden.*failed|Error: 22006|recovery completed|connection with.*established/i.test(line)
      && !/Login succeeded|Logon/i.test(line);
  };
  const rawDbEvents = {};
  for (const host of hosts) {
    rawDbEvents[host] = readErrorlogLines(host, foStart, foEnd, dbRoleFilter);
    console.log(`  ${host}: ${rawDbEvents[host].length} DB event lines`);
  }

  // ---- 3. XEvent data ----
  // hadr_replica_state
  const xeReplicaState = sqlQuery(`
    SELECT host, CONVERT(VARCHAR(23), event_time, 121) AS utc, ag_name, previous_state, current_state
    FROM xe.hadr_replica_state
    WHERE event_time BETWEEN '${preStartUtc}' AND '${endUtc}'
    ORDER BY event_time
  `);
  
  // hadr_sync_state (pre-FO context + during FO)
  const xeSyncState = sqlQuery(`
    SELECT host, CONVERT(VARCHAR(23), event_time, 121) AS utc, database_id, sync_state, commit_policy
    FROM xe.hadr_sync_state
    WHERE event_time BETWEEN '${preStartUtc}' AND '${endUtc}'
    ORDER BY event_time
  `);

  // hadr_manager_state
  const xeManagerState = sqlQuery(`
    SELECT host, CONVERT(VARCHAR(23), event_time, 121) AS utc, current_state
    FROM xe.hadr_manager_state
    WHERE event_time BETWEEN '${preStartUtc}' AND '${endUtc}'
    ORDER BY event_time
  `);

  // hadr_trace Reverting
  const xeReverting = sqlQuery(`
    SELECT host, CONVERT(VARCHAR(23), event_time, 121) AS utc,
      CASE WHEN hadr_message LIKE '%begin%' THEN 'begin' ELSE 'finished' END AS phase,
      SUBSTRING(hadr_message, CHARINDEX('[', hadr_message)+1, CHARINDEX(']', hadr_message)-CHARINDEX('[', hadr_message)-1) AS db_name,
      hadr_message
    FROM xe.hadr_trace WHERE event_time BETWEEN '${startUtc}' AND '${endUtc}' AND hadr_message LIKE '%Reverting%'
    ORDER BY event_time
  `);

  // system_health waits
  const xeWaitsRaw = sqlQuery(`
    SELECT TOP 30 host, CONVERT(VARCHAR(23), event_time, 121) AS utc, wait_type,
      CAST(duration_ms AS BIGINT) AS dur
    FROM xe.waits
    WHERE event_time BETWEEN '${preStartUtc}' AND '${endUtc}'
    ORDER BY duration_ms DESC
  `);

  // system_health errors
  const xeErrorsRaw = sqlQuery(`
    SELECT host, error_number, severity, COUNT(*) AS cnt,
      MIN(CONVERT(VARCHAR(23), event_time, 121)) AS first_utc,
      MAX(CONVERT(VARCHAR(23), event_time, 121)) AS last_utc,
      MIN(LEFT(message, 200)) AS msg
    FROM xe.errors
    WHERE event_time BETWEEN '${preStartUtc}' AND '${endUtc}'
    GROUP BY host, error_number, severity
    ORDER BY cnt DESC
  `);

  // SQLDIAG events from merged timeline
  const sqldiagEvents = merged.events.filter(e =>
    e.local_ts >= preStart && e.local_ts <= foEnd &&
    (e.category === 'sqldiag_info' || e.category === 'sqldiag_ag_state')
  );

  // ---- 4. Build per-DB data from failover_incidents.json ----
  const dbStatus = inc.db_status || {};

  // Enrich with conn_established from merged_timeline (first per DB per host)
  const connEvents = merged.events.filter(e =>
    e.local_ts >= foStart && e.local_ts <= foEnd && e.category === 'conn_established'
  );
  for (const ev of connEvents) {
    // "connection with primary database established for secondary database 'X' on ... replica 'Y'"
    // "connection with secondary database established for primary database 'X' on ... replica 'Y'"
    const mSec = ev.detail.match(/for secondary database '([^']+)'/);
    const mPri = ev.detail.match(/for primary database '([^']+)'/);
    const db = mSec ? mSec[1] : (mPri ? mPri[1] : null);
    if (!db || !dbStatus[db]) continue;
    const key = `conn_established_${ev.host}`;
    if (!dbStatus[db][key]) dbStatus[db][key] = ev.local_ts;
  }

  // Enrich with DTC init/release from rawDbEvents (ERRORLOG)
  for (const host of hosts) {
    for (const l of (rawDbEvents[host] || [])) {
      const mInit = l.line.match(/Initializing.*DTC.*resource manager.*for database '([^']+)'/i);
      if (mInit) {
        const db = mInit[1];
        if (dbStatus[db]) {
          const key = `dtc_init_${host}`;
          if (!dbStatus[db][key]) dbStatus[db][key] = l.ts;
        }
      }
      const mRel = l.line.match(/DTC.*resource manager \[([^\]]+)\].*has been released/i);
      if (mRel) {
        // DTC release uses DB name in brackets, e.g. [db_ebiz]
        const db = mRel[1];
        if (dbStatus[db]) {
          const key = `dtc_release_${host}`;
          if (!dbStatus[db][key]) dbStatus[db][key] = l.ts;
        }
      }
    }
  }

  // ---- 4b. Identify thirdPartyPrimary early (needed by Direction table + Conclusion) ----
  // Check trigger lines + conn_terminated for "primary database terminated" to identify
  // old PRIMARY that is a 3rd host not in our 2-host set
  const allTriggerLines = [...(rawTrigger[hosts[0]] || []), ...(rawTrigger[hosts[1]] || [])];
  const thirdPartyPrimary = new Set();
  allTriggerLines.forEach(l => {
    if (l._collapse) return;
    const m = l.line.match(/connection with primary database terminated.*replica '([^']+)'/i);
    if (m && !hosts.includes(m[1])) thirdPartyPrimary.add(m[1]);
  });
  if (thirdPartyPrimary.size === 0) {
    const ctEvents = merged.events.filter(e =>
      e.local_ts >= addMinutes(foStart, -1) && e.local_ts <= addMinutes(foStart, 1) &&
      e.category === 'conn_terminated' && /primary database terminated/.test(e.detail)
    );
    for (const ev of ctEvents) {
      const m = ev.detail.match(/replica '([^']+)'/);
      if (m && !hosts.includes(m[1])) thirdPartyPrimary.add(m[1]);
    }
  }

  // ---- 5. Build HTML ----
  let html = `<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>Case ${caseId} — ${foId} Analysis</title>
<style>${CSS}</style></head>
<body>
<h1>Case ${caseId} — ${foId} Detailed Analysis</h1>
<div class="meta">
  <strong>Time:</strong> ${foStart} — ${foEnd} (local, UTC+${utcOffset})<br>
  <strong>AGs Affected:</strong> ${inc.ags_affected.join(', ')}<br>
  <strong>Hosts:</strong> ${hosts.join(', ')}<br>
  <strong>Total Events:</strong> ${inc.total_events}
</div>\n`;

  // ---- 5.1 FO Direction ----
  html += `<h2>1. Failover Direction</h2>\n`;
  html += `<table><tr><th>AG</th><th>Old PRIMARY</th><th>New PRIMARY</th><th>Detail</th></tr>\n`;
  for (const ag of inc.ags_affected) {
    const dirs = agDirs[ag] || [];
    const fromPriDir = dirs.find(d => d.from.includes('PRIMARY') && d.to.includes('RESOLVING'));
    const toPriDir = dirs.find(d => d.to.includes('PRIMARY_NORMAL'));
    const secDisrupted = dirs.filter(d => d.from.includes('SECONDARY') && d.to.includes('RESOLVING'));
    const secRecov = dirs.filter(d => d.from.includes('RESOLVING') && d.to.includes('SECONDARY'));
    
    let oldPri = '-', newPri = '-', detail = '';
    if (fromPriDir) {
      oldPri = fromPriDir.host;
      if (toPriDir) {
        newPri = toPriDir.host;
        detail = `${oldPri} PRIMARY→RESOLVING at ${ts2tf(fromPriDir.ts)}, ${newPri} →PRIMARY at ${ts2tf(toPriDir.ts)}`;
        // Check if the old primary recovered
        const oldPriRecov = dirs.find(d => d.host === fromPriDir.host && d.to.includes('SECONDARY'));
        if (oldPriRecov) detail += `, ${oldPri} →SECONDARY at ${ts2tf(oldPriRecov.ts)}`;
      } else {
        // Lost PRIMARY but no one in our data set became PRIMARY
        // Could be a 3rd host, or PRIMARY returned to the old host after RESOLVING
        const selfRecov = dirs.find(d => d.host === fromPriDir.host && d.to.includes('SECONDARY'));
        if (selfRecov) {
          detail = `${oldPri} PRIMARY→RESOLVING→SECONDARY (${ts2tf(fromPriDir.ts)}→${ts2tf(selfRecov.ts)})`;
          // ext-ag during FO2: 0011 lost PRIMARY, went to SECONDARY — means PRIMARY went to a 3rd host or stayed
          newPri = thirdPartyPrimary.size > 0 ? [...thirdPartyPrimary][0] : '(3rd node)';
        } else {
          detail = `${oldPri} lost PRIMARY at ${ts2tf(fromPriDir.ts)}`;
        }
      }
    } else {
      // No PRIMARY change — only SECONDARY disruption
      if (secDisrupted.length > 0) {
        const hostNames = secDisrupted.map(d => d.host).join(', ');
        const recovNames = secRecov.map(d => `${d.host} at ${ts2tf(d.ts)}`).join(', ');
        oldPri = '(unchanged)';
        newPri = '(unchanged)';
        detail = `${hostNames} SECONDARY disrupted → recovered: ${recovNames}`;
      }
    }
    html += `<tr><td>${ag}</td><td>${oldPri}</td><td>${newPri}</td><td>${detail}</td></tr>\n`;
  }
  html += `</table>\n`;

  // ---- Key Event Timeline goes here (generated later, inserted now via keyTimelineHtml) ----
  // The Key Event Timeline needs rawDbEvents which is already available at this point.
  // We generate it here, before the Trigger section.
  let keyTimelineHtml = `<h2>2. Key Event Timeline</h2>\n`;
  {
  for (const host of hosts) {
    const hostEvents = [];
    for (const l of (rawTrigger[host] || [])) {
      if (l._collapse) continue;
      let evType = '', annotation = '';
      if (/NT AUTHORITY\\SYSTEM/.test(l.line)) { evType = 'CLUSTER'; annotation = 'NT AUTHORITY\\SYSTEM local login — cluster service triggered'; }
      else if (/has changed from.*PRIMARY.*RESOLVING/.test(l.line)) { const m = l.line.match(/availability group '([^']+)'/); evType = 'FAILOVER'; annotation = `AG ${m?m[1]:'?'}: PRIMARY_NORMAL → RESOLVING_NORMAL — this node lost PRIMARY`; }
      else if (/has changed from.*SECONDARY.*RESOLVING/.test(l.line)) { const m = l.line.match(/availability group '([^']+)'/); evType = 'RESOLVING'; annotation = `AG ${m?m[1]:'?'}: SECONDARY_NORMAL → RESOLVING_NORMAL`; }
      else if (/has changed from.*RESOLVING.*SECONDARY/.test(l.line)) { const m = l.line.match(/availability group '([^']+)'/); evType = 'RECOVERED'; annotation = `AG ${m?m[1]:'?'}: RESOLVING → SECONDARY`; }
      else if (/has changed from.*PRIMARY_PENDING.*PRIMARY_NORMAL/.test(l.line)) { const m = l.line.match(/availability group '([^']+)'/); evType = 'PROMOTED'; annotation = `AG ${m?m[1]:'?'}: PRIMARY_PENDING → PRIMARY_NORMAL — this node is now PRIMARY`; }
      else if (/has changed from.*RESOLVING.*PRIMARY/.test(l.line)) { const m = l.line.match(/availability group '([^']+)'/); evType = 'PROMOTED'; annotation = `AG ${m?m[1]:'?'}: RESOLVING → PRIMARY`; }
      else if (/Error: 41144/.test(l.line)) { evType = 'ERROR'; annotation = 'Error 41144 — AG replica entered failed state'; }
      else if (/Error: 41143/.test(l.line)) { evType = 'ERROR'; annotation = 'Error 41143 — Cannot process operation (replica in failed state)'; }
      else if (/Error: 41161/.test(l.line)) { evType = 'ERROR'; annotation = 'Error 41161 — CRC validation failed → AG taken offline'; }
      else if (/Error code 1722|Error: 41005/.test(l.line)) { evType = 'ERROR'; annotation = 'Error 41005 — Failed to obtain WSFC resource handle (Error 1722)'; }
      else if (/Failed to update.*41034/.test(l.line)) { evType = 'ERROR'; annotation = 'Error 41034 — Failed to read/update persisted config'; }
      else if (/Failed to update.*41005/.test(l.line)) { evType = 'ERROR'; annotation = 'Error 41005 — Failed to update Replica status'; }
      else if (/connection timeout.*previously established/.test(l.line)) { const m = l.line.match(/replica '([^']+)'/); evType = 'TIMEOUT'; annotation = `Connection timeout to ${m?m[1]:'?'}`; }
      else if (/lost quorum/.test(l.line)) { evType = 'QUORUM'; annotation = 'WSFC node lost quorum'; }
      else if (/stop the lease/.test(l.line)) { evType = 'LEASE'; annotation = 'AG stopping lease renewal — going offline'; }
      else if (/going offline/.test(l.line)) { const m = l.line.match(/availability group '([^']+)'/); evType = 'OFFLINE'; annotation = `AG ${m?m[1]:'?'} going offline`; }
      else continue;
      hostEvents.push({ ts: l.ts, evType, annotation });
    }
    // Aggregate DB events
    const dbRC = {};
    const ak = { count: 0, first: null, last: null };
    const dtcR = { count: 0, ts: null }, dtcI = { count: 0, ts: null };
    const su = { count: 0, first: null, last: null, dbs: new Set() }, rs = { count: 0, first: null, last: null, dbs: new Set() };
    const nq = { count: 0, first: null, last: null, dbs: new Set() };
    const rh = { count: 0, first: null, last: null };
    const e22 = { count: 0, first: null };
    const connEstByRep = {};  // per-replica connection established
    const recovComp = { count: 0, first: null, last: null };
    for (const l of (rawDbEvents[host] || [])) {
      const match = (pat, dir) => { if (pat.test(l.line)) { if (!dbRC[dir]) dbRC[dir] = { count: 0, first: l.ts, last: l.ts }; dbRC[dir].count++; dbRC[dir].last = l.ts; return true; } return false; };
      if (match(/changing roles.*"PRIMARY".*"RESOLVING"/, 'PRI→RESOLV')) {}
      else if (match(/changing roles.*"SECONDARY".*"RESOLVING"/, 'SEC→RESOLV')) {}
      else if (match(/changing roles.*"RESOLVING".*"SECONDARY"/, 'RESOLV→SEC')) {}
      else if (match(/changing roles.*"RESOLVING".*"PRIMARY"/, 'RESOLV→PRI')) {}
      else if (/ABORT_AFTER_WAIT/.test(l.line)) { ak.count++; if (!ak.first) ak.first = l.ts; ak.last = l.ts; }
      else if (/DTC.*has been released/i.test(l.line)) { dtcR.count++; if (!dtcR.ts) dtcR.ts = l.ts; }
      else if (/Initializing.*DTC/i.test(l.line)) { dtcI.count++; if (!dtcI.ts) dtcI.ts = l.ts; }
      else if (/Starting up database/i.test(l.line)) { su.count++; if (!su.first) su.first = l.ts; su.last = l.ts; const mdb = l.line.match(/database '([^']+)'/); if (mdb) su.dbs.add(mdb[1]); }
      else if (/resynchronize/i.test(l.line)) { rs.count++; if (!rs.first) rs.first = l.ts; rs.last = l.ts; const mdb = l.line.match(/database '([^']+)'/); if (mdb) rs.dbs.add(mdb[1]); }
      else if (/Nonqualified/i.test(l.line)) { nq.count++; if (!nq.first) nq.first = l.ts; nq.last = l.ts; const m2 = l.line.match(/database (\S+)/); if (m2) nq.dbs.add(m2[1]); }
      else if (/Remote harden.*failed/i.test(l.line)) { rh.count++; if (!rh.first) rh.first = l.ts; rh.last = l.ts; }
      else if (/Error: 22006/i.test(l.line)) { e22.count++; if (!e22.first) e22.first = l.ts; }
      else if (/connection with.*established/i.test(l.line)) {
        const mr = l.line.match(/replica '([^']+)'/i);
        const rep = mr ? mr[1] : 'unknown';
        if (!connEstByRep[rep]) connEstByRep[rep] = { count: 0, first: l.ts, last: l.ts };
        connEstByRep[rep].count++; connEstByRep[rep].last = l.ts;
      }
      else if (/recovery completed/i.test(l.line)) { recovComp.count++; if (!recovComp.first) recovComp.first = l.ts; recovComp.last = l.ts; }
    }
    for (const [dir, d] of Object.entries(dbRC)) {
      const badge = dir.includes('PRI→') ? 'FAILOVER' : (dir.includes('→PRI') ? 'PROMOTED' : (dir.includes('→SEC') ? 'RECOVERED' : 'RESOLVING'));
      hostEvents.push({ ts: d.first, evType: badge, annotation: `${d.count} DBs: ${dir} (${ts2t(d.first)}–${ts2t(d.last)})` });
    }
    if (ak.count > 0) hostEvents.push({ ts: ak.first, evType: 'KILL', annotation: `${ak.count} sessions killed by ABORT_AFTER_WAIT (${ts2t(ak.first)}–${ts2t(ak.last)})` });
    if (dtcR.count > 0) hostEvents.push({ ts: dtcR.ts, evType: 'DTC', annotation: `${dtcR.count} DTC RMs released` });
    if (dtcI.count > 0) hostEvents.push({ ts: dtcI.ts, evType: 'DTC', annotation: `${dtcI.count} DTC RMs initialized` });
    if (su.count > 0) hostEvents.push({ ts: su.first, evType: 'STARTUP', annotation: `${su.dbs.size} unique DBs Starting up (${ts2t(su.first)}–${ts2t(su.last)})` });
    if (rs.count > 0) hostEvents.push({ ts: rs.first, evType: 'RESYNC', annotation: `${rs.dbs.size} unique DBs resync (${ts2t(rs.first)}–${ts2t(rs.last)})` });
    if (nq.count > 0) hostEvents.push({ ts: nq.first, evType: 'NQ_LOOP', annotation: `NQ rollback ×${nq.count} on ${nq.dbs.size} DBs (${[...nq.dbs].join(', ')}) ${ts2t(nq.first)}–${ts2t(nq.last)}` });
    if (rh.count > 0) hostEvents.push({ ts: rh.first, evType: 'RH_FAIL', annotation: `Remote harden failed ×${rh.count} (${ts2t(rh.first)}–${ts2t(rh.last)})` });
    if (e22.count > 0) hostEvents.push({ ts: e22.first, evType: 'ERROR', annotation: `Error 22006 ×${e22.count} — ADR VersionCleaner aborted` });
    if (recovComp.count > 0) hostEvents.push({ ts: recovComp.first, evType: 'RECOVERED', annotation: `${recovComp.count} DBs recovery completed (${ts2t(recovComp.first)}–${ts2t(recovComp.last)})` });
    for (const [rep, info] of Object.entries(connEstByRep)) {
      hostEvents.push({ ts: info.first, evType: 'CONNECTED', annotation: `Connection established with ${rep} (${info.count} DBs, ${ts2t(info.first)}–${ts2t(info.last)})` });
    }
    // SQLDIAG
    for (const ev of sqldiagEvents.filter(e => e.host === host)) {
      if (/Lease Thread terminated/i.test(ev.detail)) hostEvents.push({ ts: ev.local_ts, evType: 'LEASE', annotation: 'Lease Thread terminated' });
      else if (/Health worker.*terminate/i.test(ev.detail)) hostEvents.push({ ts: ev.local_ts, evType: 'LEASE', annotation: 'Health worker asked to terminate' });
      else if (/target=Failed.*SYSTEM_UNHEALTHY/i.test(ev.detail)) { const m = ev.detail.match(/(\S+) target=Failed/); hostEvents.push({ ts: ev.local_ts, evType: 'UNHEALTHY', annotation: `${m?m[1]:'AG'} SYSTEM_UNHEALTHY` }); }
    }
    hostEvents.sort((a, b) => a.ts.localeCompare(b.ts));
    if (hostEvents.length === 0) continue;
    const bc = { FAILOVER:'badge-red', ERROR:'badge-red', UNHEALTHY:'badge-red', KILL:'badge-orange', NQ_LOOP:'badge-red', TIMEOUT:'badge-orange', QUORUM:'badge-orange', LEASE:'badge-orange', RECOVERED:'badge-green', PROMOTED:'badge-green', STARTUP:'badge-green', RESYNC:'badge-green', CONNECTED:'badge-green', DTC:'badge-yellow', OFFLINE:'badge-yellow', RESOLVING:'badge-yellow', CLUSTER:'badge-yellow', RH_FAIL:'badge-orange', HEALTH:'badge-orange' };
    keyTimelineHtml += `<h3>${host}</h3>\n<table><tr><th>Time (local)</th><th>Event</th><th>Detail</th></tr>\n`;
    for (const ev of hostEvents) {
      keyTimelineHtml += `<tr><td>${ts2tf(ev.ts)}</td><td><span class="badge ${bc[ev.evType]||''}">${ev.evType}</span></td><td>${ev.annotation}</td></tr>\n`;
    }
    keyTimelineHtml += `</table>\n`;
  }
  }
  html += keyTimelineHtml;

  // ---- 5.2 Trigger Analysis with raw ERRORLOG ----
  html += `<h2>3. Trigger Analysis (Raw ERRORLOG Evidence)</h2>\n`;
  for (const host of hosts) {
    const lines = rawTrigger[host];
    if (lines.length === 0) continue;
    html += `<h3>${host}</h3>\n<div class="evidence">`;
    html += `<span class="src">Source: ${host} ERRORLOG (${triggerWindow.start.substring(11,19)} — ${triggerWindow.end.substring(11,19)})</span>\n`;

    for (const l of lines) {
      if (l._collapse) {
        html += `<span style="color:var(--dim)">${esc(l.line)}</span>\n`;
        continue;
      }
      let line = esc(l.line);
      if (/Error:|41005|41034|41144|41143|41161|1722|CRC|failed state|Failed to|SYSTEM_UNHEALTHY/.test(l.line)) {
        line = `<span style="color:var(--red)">${line}</span>`;
      } else if (/Lease Thread|Health worker|query_processing/.test(l.line)) {
        line = `<span style="color:var(--orange)">${line}</span>`;
      } else if (/has changed from.*PRIMARY.*RESOLVING|going offline/.test(l.line)) {
        line = `<span style="color:var(--yellow)">${line}</span>`;
      }
      html += `${line}\n`;
    }
    html += `</div>\n`;
  }

  // Also show first/last Remote harden per DB in trigger window
  const rhTrigger = {};
  for (const host of hosts) {
    const rhLines = readErrorlogLines(host, triggerWindow.start, triggerWindow.end,
      (line) => /Remote harden.*failed/.test(line));
    for (const l of rhLines) {
      const m = l.line.match(/database '([^']+)'/);
      const txn = l.line.match(/transaction '([^']+)'/);
      if (!m) continue;
      const key = `${host}|${m[1]}`;
      if (!rhTrigger[key]) rhTrigger[key] = { host, db: m[1], first: l, last: l, count: 0, txns: new Set() };
      rhTrigger[key].count++;
      rhTrigger[key].last = l;
      if (txn) rhTrigger[key].txns.add(txn[1]);
    }
  }
  if (Object.keys(rhTrigger).length > 0) {
    html += `<h3>Remote Harden Failed (trigger window)</h3>\n<div class="evidence">`;
    html += `<span class="src">First and last per database during trigger window</span>\n`;
    for (const [key, rh] of Object.entries(rhTrigger).sort((a,b) => a[1].first.ts.localeCompare(b[1].first.ts))) {
      html += `<span style="color:var(--dim)">[${rh.host}] ${rh.db} — ${rh.count} events, txns: ${[...rh.txns].join(', ')}</span>\n`;
      html += `  First: ${esc(rh.first.line)}\n`;
      if (rh.count > 1) html += `  Last:  ${esc(rh.last.line)}\n`;
    }
    html += `</div>\n`;
  }

  // SQLDIAG events — filter out warning↔clean flapping (only show 'error' transitions or non-health events)
  const sqldiagFiltered = sqldiagEvents.filter(e => {
    if (/health state has been changed/.test(e.detail)) {
      // Only show if 'error' is mentioned (i.e. transition to/from error state)
      return /to 'error'|from 'error'/i.test(e.detail);
    }
    return true;  // keep Lease Thread, Health worker, AG state change, etc.
  });
  if (sqldiagFiltered.length > 0) {
    html += `<h3>SQLDIAG XEvent</h3>\n<div class="evidence">`;
    html += `<span class="src">Source: AlwaysOn_health XEvent (sp_server_diagnostics)</span>\n`;
    for (const ev of sqldiagFiltered) {
      let line = `${ev.local_ts}  [${ev.host}]  ${esc(ev.detail.substring(0, 200))}`;
      if (/SYSTEM_UNHEALTHY|target=Failed/.test(ev.detail)) line = `<span style="color:var(--red)">${line}</span>`;
      else if (/Lease Thread|Health worker|Stopping/.test(ev.detail)) line = `<span style="color:var(--orange)">${line}</span>`;
      else if (/error/.test(ev.detail)) line = `<span style="color:var(--red)">${line}</span>`;
      html += `${line}\n`;
    }
    html += `</div>\n`;
  }

  // system_health waits
  if (xeWaitsRaw) {
    const waits = [];
    for (const line of xeWaitsRaw.split(/\r?\n/)) {
      const p = line.split('|').map(s => s.trim());
      if (p.length >= 4 && p[0]) {
        const durMs = parseInt(p[3]);
        const durStr = durMs > 60000 ? `${(durMs / 60000).toFixed(0)} min` : `${(durMs / 1000).toFixed(0)}s`;
        waits.push({ host: p[0], local: utcToLocal(p[1]), wait: p[2], dur: durStr, durMs });
      }
    }
    if (waits.length > 0) {
      html += `<h3>system_health Long Waits</h3>\n<table><tr><th>Host</th><th>Time (local)</th><th>Wait Type</th><th>Duration</th></tr>\n`;
      for (const w of waits) {
        const cls = w.durMs > 300000 ? ' style="color:var(--red)"' : (w.durMs > 60000 ? ' style="color:var(--orange)"' : '');
        html += `<tr${cls}><td>${w.host}</td><td>${ts2t(w.local)}</td><td>${w.wait}</td><td>${w.dur}</td></tr>\n`;
      }
      html += `</table>\n`;
    }
  }

  // system_health errors
  if (xeErrorsRaw) {
    const errs = [];
    for (const line of xeErrorsRaw.split(/\r?\n/)) {
      const p = line.split('|').map(s => s.trim());
      if (p.length >= 7 && p[0]) {
        errs.push({ host: p[0], error: p[1], sev: p[2], cnt: p[3], first: utcToLocal(p[4]), last: utcToLocal(p[5]), msg: p[6] });
      }
    }
    if (errs.length > 0) {
      html += `<h3>system_health Errors</h3>\n<table><tr><th>Host</th><th>Error</th><th>Sev</th><th>Count</th><th>First</th><th>Last</th><th>Message</th></tr>\n`;
      for (const e of errs) {
        html += `<tr><td>${e.host}</td><td>${e.error}</td><td>${e.sev}</td><td>${e.cnt}</td><td>${ts2t(e.first)}</td><td>${ts2t(e.last)}</td><td>${esc(e.msg.substring(0, 150))}</td></tr>\n`;
      }
      html += `</table>\n`;
    }
  }

  // ---- 5.2c WSFC Error Chain (if 41xxx errors present) ----
  const has41xxx = allTriggerLines.some(l => /41005|41034|41144|41143|41161/.test(l.line));
  if (has41xxx) {
    html += `<h2>4. WSFC Error Chain Analysis</h2>\n<div class="section">`;
    // Identify error codes present
    const errCodes = {};
    for (const l of allTriggerLines) {
      if (l._collapse) continue;
      if (/Error code 1722|Error: 41005/.test(l.line)) errCodes['41005'] = true;
      if (/41034/.test(l.line)) errCodes['41034'] = true;
      if (/41144/.test(l.line)) errCodes['41144'] = true;
      if (/41143/.test(l.line)) errCodes['41143'] = true;
      if (/41161/.test(l.line)) errCodes['41161'] = true;
    }
    html += `<p>The following WSFC error cascade was detected:</p>\n<pre>`;
    if (errCodes['41005']) html += `Error 41005 (Sev 16) — Failed to obtain the WSFC resource handle (Error code 1722 = RPC server unavailable)\n  ↓\n`;
    if (errCodes['41034']) html += `Error 41034           — Failed to read or update the persisted configuration data\n  ↓\n`;
    if (errCodes['41144']) html += `Error 41144 (Sev 16) — Local availability replica entered a failed state\n                       (could not read/update persisted config)\n`;
    if (errCodes['41143']) html += `Error 41143 (Sev 16) — Cannot process the operation (replica is in failed state)\n`;
    if (errCodes['41161']) html += `Error 41161 (Sev 16) — Failed to validate the CRC of the AG configuration → AG taken offline\n`;
    html += `</pre>\n`;
    html += `<p>This error chain indicates that SQL Server on the affected node momentarily lost communication with the Windows Failover Cluster service. Error 1722 (RPC server unavailable) is the root — WSFC was temporarily unreachable, preventing AG configuration reads.</p>`;
    html += `</div>\n`;
  }

  // ---- AG-Level Flow per host (XEvent + ERRORLOG) ----
  let secNum = has41xxx ? 5 : 4;
  html += `<h2>${secNum}. AG-Level State Changes</h2>\n`;
  
  // XEvent hadr_replica_state
  if (xeReplicaState) {
    html += `<h3>XEvent hadr_replica_state</h3>\n<table><tr><th>Host</th><th>Time (UTC)</th><th>Time (local)</th><th>AG</th><th>From</th><th>To</th></tr>\n`;
    for (const line of xeReplicaState.split(/\r?\n/)) {
      const p = line.split('|').map(s => s.trim());
      if (p.length >= 5 && p[0]) {
        const local = utcToLocal(p[1]);
        const cls = p[4].includes('PRIMARY_NORMAL') ? ' class="ok"' : (p[4].includes('RESOLVING') ? ' class="stuck"' : '');
        html += `<tr${cls}><td>${p[0]}</td><td>${ts2tf(p[1])}</td><td>${ts2tf(local)}</td><td>${p[2]}</td><td>${p[3]}</td><td>${p[4]}</td></tr>\n`;
      }
    }
    html += `</table>\n`;
  }

  // XEvent hadr_manager_state
  if (xeManagerState) {
    const lines = xeManagerState.split(/\r?\n/).filter(l => l.trim());
    if (lines.length > 0) {
      html += `<h3>XEvent hadr_manager_state</h3>\n<table><tr><th>Host</th><th>Time (UTC)</th><th>Time (local)</th><th>State</th></tr>\n`;
      for (const line of lines) {
        const p = line.split('|').map(s => s.trim());
        if (p.length >= 3) html += `<tr><td>${p[0]}</td><td>${ts2tf(p[1])}</td><td>${ts2tf(utcToLocal(p[1]))}</td><td>${p[2]}</td></tr>\n`;
      }
      html += `</table>\n`;
    }
  }

  // ERRORLOG AG role changes per host
  for (const host of hosts) {
    const agLines = (rawDbEvents[host] || []).filter(l => /has changed from|changing roles/.test(l.line)).slice(0, 50);
    if (agLines.length === 0) continue;
    // Actually these are already in section 2. Let's show a summary from the db_status
  }

  // ---- 5.4 Per-Host Per-DB Status Tables ----
  secNum++;
  html += `<h2>${secNum}. Per-DB Status Tables</h2>\n`;

  // Parse XEvent Reverting data
  const revertData = {};
  if (xeReverting) {
    for (const line of xeReverting.split(/\r?\n/)) {
      const p = line.split('|').map(s => s.trim());
      if (p.length < 5) continue;
      const [host, utc, phase, dbName2, msg] = p;
      if (!revertData[dbName2]) revertData[dbName2] = {};
      if (phase === 'begin') {
        revertData[dbName2][`begin_${host}`] = utcToLocal(utc);
        const m = msg.match(/\[(\d+)\]/);
        if (m) revertData[dbName2][`bytes_${host}`] = parseInt(m[1]);
      } else {
        revertData[dbName2][`end_${host}`] = utcToLocal(utc);
      }
    }
  }

  // Parse XEvent hadr_sync_state for KillAll events
  const killAllDbs = {};  // { host: Set(db_id) }
  if (xeSyncState) {
    for (const line of xeSyncState.split(/\r?\n/)) {
      const p = line.split('|').map(s => s.trim());
      if (p.length >= 5 && p[4] === 'KillAll') {
        if (!killAllDbs[p[0]]) killAllDbs[p[0]] = new Set();
        killAllDbs[p[0]].add(parseInt(p[2]));
      }
    }
  }

  // For each host, generate a DB status table
  for (const host of hosts) {
    // Determine which role this host had per AG — collect all, then summarize
    const hostRoles = [];
    for (const ag of inc.ags_affected) {
      const dirs = agDirs[ag] || [];
      const fromPri = dirs.find(d => d.host === host && d.from.includes('PRIMARY') && d.to.includes('RESOLVING'));
      const toPri = dirs.find(d => d.host === host && d.to.includes('PRIMARY'));
      const fromSec = dirs.find(d => d.host === host && d.from.includes('SECONDARY') && d.to.includes('RESOLVING'));
      const shortAg = ag.replace('sybasehk-prod-', '');
      if (fromPri && toPri) hostRoles.push(`${shortAg}: PRIMARY→RESOLVING→PRIMARY`);
      else if (fromPri) hostRoles.push(`${shortAg}: demoted from PRIMARY`);
      else if (toPri) hostRoles.push(`${shortAg}: promoted to PRIMARY`);
      else if (fromSec) hostRoles.push(`${shortAg}: SECONDARY disrupted`);
    }
    // Pick the most significant role for the header, show per-AG detail
    let hostRole = hostRoles.length > 0 ? hostRoles.join(' | ') : 'unknown';

    // Collect per-DB data for this host
    const hostDbs = [];
    for (const [db, st] of Object.entries(dbStatus)) {
      const ag = st.ag || dbAgMap[db] || '?';
      const dbId = dbNameToId[host]?.[db] || '?';

      const resolv = st[`to_resolving_${host}`];
      const sec = st[`to_secondary_${host}`];
      const pri = st[`to_primary_${host}`];
      const startup = st[`starting_up_${host}`];
      const resync = st[`resync_${host}`];
      const dtcInit = st[`dtc_init_${host}`];
      const dtcRel = st[`dtc_release_${host}`];
      const abortKill = st[`abort_kill_${host}`];
      // NQ rollback — use host-specific key if available, fall back to legacy key for demoted-only
      const nqHostKey = st[`nonqual_rollback_${host}`];
      const nq = nqHostKey || ((resolv && resolv.from === 'PRIMARY') ? st.nonqual_rollback : null);
      const connEst = st[`conn_established_${host}`];

      // Only show DBs that had events on this host
      if (!resolv && !sec && !pri && !startup) continue;

      const revert = revertData[db] || {};
      const hasKillAll = killAllDbs[host]?.has(parseInt(dbId));

      hostDbs.push({
        ag, db, id: dbId,
        dir: resolv ? `${resolv.from}→RESOLV` : '-',
        resolvTs: resolv ? ts2tf(resolv.ts) : '-',
        dtcInit: dtcInit ? ts2tf(dtcInit) : '-',
        dtcRel: dtcRel ? ts2tf(dtcRel) : '-',
        secTs: sec ? ts2tf(sec) : '-',
        priTs: pri ? ts2tf(pri) : '-',
        startup: startup ? ts2tf(startup) : '-',
        resync: resync ? ts2tf(resync) : '-',
        revertBegin: revert[`begin_${host}`] ? ts2tf(revert[`begin_${host}`]) : '-',
        revertEnd: revert[`end_${host}`] ? ts2tf(revert[`end_${host}`]) : '-',
        revertBytes: revert[`bytes_${host}`] || 0,
        killCount: abortKill ? abortKill.count : 0,
        killTs: abortKill ? ts2tf(abortKill.ts) : '-',
        nqCount: nq ? nq.count : 0,
        nqFirst: nq ? ts2tf(nq.first) : '-',
        nqLast: nq ? ts2tf(nq.last) : '-',
        connEst: connEst ? ts2tf(connEst) : '-',
        hasKillAll,
        // Determine result
        result: pri ? '→PRIMARY ✅' : (sec ? (
          // Check if sec was at shutdown time (more than 60 min after FO)
          (() => {
            const gap = new Date(sec.replace(' ', 'T') + 'Z') - new Date((resolv ? resolv.ts : foStart).replace(' ', 'T') + 'Z');
            return gap > 3600000 ? '→SEC(shutdown) ☠' : '→SEC ✅';
          })()
        ) : (resolv ? 'STUCK ❌' : '-'))
      });
    }

    // Sort by AG then name
    hostDbs.sort((a, b) => a.ag.localeCompare(b.ag) || a.db.localeCompare(b.db));

    if (hostDbs.length === 0) continue;

    html += `<h3>${host} (${hostRole})</h3>\n`;
    html += `<div class="db-scroll"><table>\n`;

    // Determine which columns are relevant
    const hasDtc = hostDbs.some(d => d.dtcInit !== '-' || d.dtcRel !== '-');
    const hasRevert = hostDbs.some(d => d.revertBegin !== '-');
    const hasKills = hostDbs.some(d => d.killCount > 0);
    const hasNq = hostDbs.some(d => d.nqCount > 0);
    const hasConnEst = hostDbs.some(d => d.connEst !== '-');
    const hasPri = hostDbs.some(d => d.priTs !== '-');
    const hasSec = hostDbs.some(d => d.secTs !== '-');

    html += `<tr><th>AG</th><th>DB</th><th>ID</th><th>Direction</th><th>→RESOLV</th>`;
    if (hasDtc) html += `<th>DTC Init</th><th>DTC Release</th>`;
    if (hasSec) html += `<th>→SECONDARY</th>`;
    if (hasPri) html += `<th>→PRIMARY</th>`;
    html += `<th>Starting up</th><th>Resync</th>`;
    if (hasRevert) html += `<th>Revert Begin</th><th>Revert End</th>`;
    if (hasKills) html += `<th>ABORT Kill</th>`;
    if (hasNq) html += `<th>NQ Rollback</th>`;
    html += `<th>Result</th></tr>\n`;

    let lastAg = '', stuckCnt = 0, okCnt = 0;
    for (const d of hostDbs) {
      if (d.ag !== lastAg) { lastAg = d.ag; html += `<tr class="sep"><td colspan="20"></td></tr>\n`; }
      const cls = d.result.includes('STUCK') || d.result.includes('☠') ? 'stuck' : (d.result.includes('✅') ? 'ok' : '');
      if (d.result.includes('STUCK') || d.result.includes('☠')) stuckCnt++;
      else if (d.result.includes('✅')) okCnt++;

      html += `<tr class="${cls}"><td>${d.ag.replace('sybasehk-prod-', '')}</td><td><strong>${d.db}</strong></td><td>${d.id}</td><td>${d.dir}</td><td>${d.resolvTs}</td>`;
      if (hasDtc) html += `<td>${d.dtcInit}</td><td>${d.dtcRel}</td>`;
      if (hasSec) html += `<td>${d.secTs}</td>`;
      if (hasPri) html += `<td>${d.priTs}</td>`;
      html += `<td>${d.startup}</td><td>${d.resync}</td>`;
      if (hasRevert) {
        const rb = d.revertBegin !== '-' ? `${d.revertBegin}${d.revertBytes ? ' (' + (d.revertBytes > 1048576 ? (d.revertBytes/1048576).toFixed(1)+'M' : (d.revertBytes/1024).toFixed(0)+'K') + ')' : ''}` : '-';
        html += `<td>${rb}</td><td>${d.revertEnd}</td>`;
      }
      if (hasKills) html += `<td>${d.killCount > 0 ? '×' + d.killCount + ' ' + d.killTs : '-'}</td>`;
      if (hasNq) html += `<td>${d.nqCount > 0 ? '×' + d.nqCount + ' ' + d.nqFirst + '—' + d.nqLast : '-'}</td>`;
      html += `<td>${d.result}</td></tr>\n`;
    }
    html += `</table></div>\n`;

    // Count DBs on this host that had NO role change (e.g. batch-ag stayed PRIMARY)
    const allDbsOnHost = schema[host === schema.old_primary.host ? 'old_primary' : 'new_primary']?.databases || [];
    const dbsWithEvents = new Set(hostDbs.map(d => d.db));
    const noChangeDbs = allDbsOnHost.filter(db => !dbsWithEvents.has(db.name));
    // Group no-change DBs by AG
    const noChangeByAg = {};
    for (const db of noChangeDbs) {
      const ag = db.ag?.replace('sybasehk-prod-', '') || '?';
      if (!noChangeByAg[ag]) noChangeByAg[ag] = [];
      noChangeByAg[ag].push(db.name);
    }

    html += `<p><strong>Summary:</strong> ${hostDbs.length} DBs with role changes — <span style="color:var(--green)">${okCnt} recovered</span>`;
    if (stuckCnt > 0) html += `, <span style="color:var(--red)">${stuckCnt} stuck</span>`;
    if (noChangeDbs.length > 0) {
      html += `<br><span style="color:var(--dim)">${noChangeDbs.length} DBs had no role change: `;
      const parts = [];
      for (const [ag, dbs] of Object.entries(noChangeByAg)) {
        parts.push(`${ag} (${dbs.length} DBs — PRIMARY unchanged on this node)`);
      }
      html += parts.join(', ');
      html += `</span>`;
    }
    html += `</p>\n`;
  }

  // ---- 5.5 XEvent Reverting Detail ----
  if (xeReverting && xeReverting.trim()) {
    secNum++;
    html += `<h2>${secNum}. XEvent Reverting Detail</h2>\n<table><tr><th>Host</th><th>Time (UTC)</th><th>Time (local)</th><th>Phase</th><th>Database</th><th>Message</th></tr>\n`;
    for (const line of xeReverting.split(/\r?\n/)) {
      const p = line.split('|').map(s => s.trim());
      if (p.length < 5) continue;
      const cls = p[2] === 'finished' ? 'ok' : '';
      html += `<tr class="${cls}"><td>${p[0]}</td><td>${ts2tf(p[1])}</td><td>${ts2tf(utcToLocal(p[1]))}</td><td>${p[2]}</td><td>${p[3]}</td><td>${esc(p[4].substring(0, 150))}</td></tr>\n`;
    }
    html += `</table>\n`;
  }

  // ---- 5.6 Remote Harden + NQ Rollback Summary ----
  if (inc.event_counts.remote_harden > 0 || inc.event_counts.nonqual_rollback > 0) {
    secNum++;
    html += `<h2>${secNum}. Remote Harden &amp; Nonqualified Rollback</h2>\n`;
    if (inc.event_counts.remote_harden > 0) {
      // Get first and last remote harden from raw ERRORLOG
      const rhLines = {};
      for (const host of hosts) {
        const rh = (rawDbEvents[host] || []).filter(l => /Remote harden.*failed/.test(l.line));
        if (rh.length > 0) {
          rhLines[host] = { count: rh.length, first: rh[0], last: rh[rh.length - 1] };
        }
      }
      html += `<div class="section"><strong>Remote Harden Failed:</strong> ${inc.event_counts.remote_harden} total events\n<pre>`;
      for (const [host, rh] of Object.entries(rhLines)) {
        html += `[${host}] First (${rh.first.ts.substring(11, 19)}):\n${esc(rh.first.line)}\n\n`;
        html += `[${host}] Last (${rh.last.ts.substring(11, 19)}):\n${esc(rh.last.line)}\n\n`;
        html += `Total on ${host}: ${rh.count}\n\n`;
      }
      html += `</pre></div>\n`;
    }
    if (inc.event_counts.nonqual_rollback > 0) {
      // Get NQ from raw ERRORLOG
      const nqLines = {};
      for (const host of hosts) {
        const nq = (rawDbEvents[host] || []).filter(l => /Nonqualified/.test(l.line));
        if (nq.length > 0) {
          nqLines[host] = { count: nq.length, first: nq[0], last: nq[nq.length - 1] };
        }
      }
      html += `<div class="section"><strong>Nonqualified Rollback:</strong> ${inc.event_counts.nonqual_rollback} total events\n<pre>`;
      for (const [host, nq] of Object.entries(nqLines)) {
        html += `[${host}] First (${nq.first.ts.substring(11, 19)}):\n${esc(nq.first.line)}\n\n`;
        html += `[${host}] Last (${nq.last.ts.substring(11, 19)}):\n${esc(nq.last.line)}\n\n`;
        html += `Total on ${host}: ${nq.count}\n\n`;
      }
      html += `</pre></div>\n`;
    }
  }

  // ---- Conclusion Section ----
  secNum++;
  html += `<h2>${secNum}. Analysis &amp; Conclusion</h2>\n`;

  // Derive trigger cause from evidence (allTriggerLines and thirdPartyPrimary already defined in Section 4b)
  // Check both ERRORLOG trigger lines AND SQLDIAG XEvent for trigger signals
  const hasLeaseTermination = allTriggerLines.some(l => /Lease Thread terminated/i.test(l.line))
    || sqldiagEvents.some(e => /Lease Thread terminated/i.test(e.detail));
  const hasSystemUnhealthy = sqldiagEvents.some(e => /SYSTEM_UNHEALTHY|target=Failed/i.test(e.detail));
  const hasWsfcOffline = allTriggerLines.some(l => /WSFC.*no longer online|going offline/i.test(l.line));
  const hasError1722 = allTriggerLines.some(l => /Error.*1722|Error code 1722/i.test(l.line));
  const hasError41144 = allTriggerLines.some(l => /41144/i.test(l.line));
  const hasQuorumLoss = allTriggerLines.some(l => /lost quorum/i.test(l.line));
  const hasConnTimeout = allTriggerLines.some(l => /connection timeout.*previously established/i.test(l.line));

  // Count stuck/recovered per host
  const hostSummaries = {};
  for (const host of hosts) {
    const hDbs = Object.entries(dbStatus).filter(([db, st]) => st[`to_resolving_${host}`]);
    const stuck = hDbs.filter(([db, st]) => {
      const fromPri = st[`to_resolving_${host}`]?.from === 'PRIMARY';
      const noStartup = !st[`starting_up_${host}`];
      return fromPri && noStartup;
    });
    const recov = hDbs.length - stuck.length;
    hostSummaries[host] = { total: hDbs.length, stuck: stuck.length, recovered: recov, stuckDbs: stuck.map(([db]) => db) };
  }

  // Identify old PRIMARY and new PRIMARY per AG from ag_directions
  const oldPrimaries = new Set();
  const newPrimaries = new Set();
  for (const ag of inc.ags_affected) {
    const dirs = agDirs[ag] || [];
    const fromPri = dirs.find(d => d.from.includes('PRIMARY') && d.to.includes('RESOLVING'));
    const toPri = dirs.find(d => d.to.includes('PRIMARY_NORMAL') || d.to.includes('PRIMARY_PENDING'));
    if (fromPri) oldPrimaries.add(fromPri.host);
    if (toPri) newPrimaries.add(toPri.host);
  }

  // Derive per-AG direction summary with full detail
  const agSummaries = [];
  for (const ag of inc.ags_affected) {
    const dirs = agDirs[ag] || [];
    const fromPri = dirs.find(d => d.from.includes('PRIMARY') && d.to.includes('RESOLVING'));
    const toPri = dirs.find(d => d.to === 'PRIMARY_NORMAL');
    const toSec = dirs.filter(d => d.to === 'SECONDARY_NORMAL');
    let summary = '';
    if (fromPri && toPri) {
      summary = `PRIMARY moved from <code>${fromPri.host}</code> (${fromPri.from}→RESOLVING at ${ts2tf(fromPri.ts)}) to <code>${toPri.host}</code> (→PRIMARY at ${ts2tf(toPri.ts)})`;
    } else if (fromPri) {
      summary = `<code>${fromPri.host}</code> lost PRIMARY (${fromPri.from}→RESOLVING at ${ts2tf(fromPri.ts)})`;
    } else {
      // No PRIMARY change in ag_directions — both hosts were SECONDARY
      // Find the old PRIMARY from conn_terminated or thirdPartyPrimary (computed later)
      const secDisrupted = dirs.filter(d => d.from.includes('SECONDARY') && d.to.includes('RESOLVING'));
      const secRecov = dirs.filter(d => d.from.includes('RESOLVING') && d.to.includes('SECONDARY'));
      const promoted = dirs.find(d => d.to.includes('PRIMARY'));

      if (secDisrupted.length > 0 && promoted) {
        // One secondary was promoted — identify old PRIMARY
        const oldPriName = thirdPartyPrimary.size > 0 ? [...thirdPartyPrimary].join(', ') : 'unknown (not in log set)';
        summary = `Old PRIMARY <code>${oldPriName}</code> went down. `;
        summary += `<code>${promoted.host}</code> promoted to new PRIMARY at ${ts2tf(promoted.ts)}. `;
        const otherSec = secRecov.find(d => d.host !== promoted.host);
        if (otherSec) {
          summary += `<code>${otherSec.host}</code> (SECONDARY): lost connection to old PRIMARY <code>${oldPriName}</code> at ${ts2tf(secDisrupted.find(d => d.host === otherSec.host)?.ts || '')}, reconnected to new PRIMARY <code>${promoted.host}</code> at ${ts2tf(otherSec.ts)}`;
        }
      } else if (secDisrupted.length > 0) {
        // All secondaries disrupted but recovered
        for (const sd of secDisrupted) {
          const recov = secRecov.find(d => d.host === sd.host);
          if (summary) summary += '. ';
          summary += `<code>${sd.host}</code>: SECONDARY disrupted at ${ts2tf(sd.ts)}`;
          if (recov) summary += `, recovered to SECONDARY at ${ts2tf(recov.ts)}`;
        }
      } else {
        summary = `No role changes detected`;
      }
    }
    agSummaries.push({ ag, summary });
  }

  // Build trigger conclusion

  // Identify connection timeout targets — distinguish old PRIMARY vs other replicas
  const allConnTimeoutTargets = new Set();
  allTriggerLines.forEach(l => {
    if (l._collapse) return;
    const m = l.line.match(/connection timeout.*replica '([^']+)'/i);
    if (m) allConnTimeoutTargets.add(m[1]);
  });

  // Now classify: old PRIMARY = from ag_directions + thirdPartyPrimary + non-local timeout targets
  const allOldPriHosts = new Set([...oldPrimaries, ...thirdPartyPrimary]);
  // Non-local timeout targets that aren't the new PRIMARY are likely old PRIMARY or its replicas
  allConnTimeoutTargets.forEach(t => {
    if (!hosts.includes(t) && !newPrimaries.has(t)) allOldPriHosts.add(t);
  });

  // "Other" = timeout targets that are NOT old PRIMARY and NOT new PRIMARY
  const connTimeoutToOther = new Set();
  allConnTimeoutTargets.forEach(t => {
    if (!allOldPriHosts.has(t) && !newPrimaries.has(t)) connTimeoutToOther.add(t);
  });

  html += `<h3>7.1 Trigger Cause</h3>\n<div class="conclusion">`;
  if (hasLeaseTermination && hasSystemUnhealthy) {
    // Identify which host had the lease termination — check SQLDIAG events first
    const leaseEvt = sqldiagEvents.find(e => /Lease Thread terminated/i.test(e.detail));
    const leaseHostName = leaseEvt ? leaseEvt.host : (allTriggerLines.find(l => !l._collapse && /Lease Thread terminated/i.test(l.line))?.line.match(/HKAZEPWDB\d+/)?.[0] || 'the affected node');
    // Find the SYSTEM_UNHEALTHY event to identify which AG
    const unhealthyEvt = sqldiagEvents.find(e => /target=Failed|SYSTEM_UNHEALTHY/i.test(e.detail));
    html += `<p><strong>Root Cause:</strong> WSFC lease thread termination on <code>${leaseHostName}</code> due to <code>SYSTEM_UNHEALTHY</code> health check failure.</p>\n`;
    html += `<p>The sp_server_diagnostics health worker on <code>${leaseHostName}</code> detected an unhealthy state`;
    if (unhealthyEvt) html += ` (${esc(unhealthyEvt.detail.substring(0, 100))})`;
    html += ` and terminated the lease thread, causing WSFC to take the AGs offline on this node.</p>\n`;
    if (hasConnTimeout) {
      const firstTimeout = allTriggerLines.find(l => !l._collapse && /connection timeout/i.test(l.line));
      html += `<p>Connection timeouts to other replicas preceded the lease termination (first at ${firstTimeout?.ts?.substring(11,19) || '?'}), indicating the node was already experiencing network or resource issues.</p>\n`;
    }
  } else if (hasError1722) {
    // Identify which host logged the 1722 error
    const err1722Host = allTriggerLines.find(l => !l._collapse && /1722/.test(l.line));
    html += `<p><strong>Root Cause:</strong> Transient WSFC communication failure (Error 1722: RPC server unavailable).</p>\n`;
    html += `<p>SQL Server on the affected node momentarily lost communication with the Windows Failover Cluster service. Error chain: 41005 (failed to obtain WSFC resource handle) → 41034 (failed to read/update config) → 41144 (replica entered failed state) → 41161 (CRC validation failed, AG taken offline).</p>\n`;
  } else if (hasWsfcOffline) {
    // Determine the cause: was the old PRIMARY lost (external) or was this node losing WSFC (internal)?
    const uniqueOldPri = [...allOldPriHosts];

    if (uniqueOldPri.length > 0 && uniqueOldPri.every(h => !hosts.includes(h))) {
      // Old PRIMARY is a 3rd host not in our 2-host set — it went down externally
      html += `<p><strong>Root Cause:</strong> The ext-ag PRIMARY node <code>${uniqueOldPri.join(', ')}</code> became unreachable.</p>\n`;
      const firstTimeout = allTriggerLines.find(l => !l._collapse && /connection timeout/i.test(l.line));
      if (firstTimeout) {
        html += `<p>Connection timeouts to <code>${uniqueOldPri.join(', ')}</code> first detected at ${firstTimeout.ts.substring(11,19)} on both HKAZEPWDB0031 and HKAZEPWDB0011 (both were SECONDARY for ext-ag). `;
        html += `WSFC declared the ext-ag resource offline, triggering automatic failover to <code>${[...newPrimaries].join(', ') || 'new PRIMARY'}</code>.</p>\n`;
      }
    } else if (uniqueOldPri.length > 0) {
      // Old PRIMARY is one of our 2 hosts
      html += `<p><strong>Root Cause:</strong> The PRIMARY node <code>${uniqueOldPri.join(', ')}</code> lost WSFC cluster communication, causing AG failover.</p>\n`;
    } else {
      html += `<p><strong>Root Cause:</strong> WSFC cluster resource went offline, triggering AG failover.</p>\n`;
    }
    if (connTimeoutToOther.size > 0) {
      html += `<p>Additionally, connection timeouts were observed to other replicas: ${[...connTimeoutToOther].join(', ')}.</p>\n`;
    }
  } else {
    html += `<p><strong>Root Cause:</strong> AG went to RESOLVING due to WSFC state change. Review cluster logs for details.</p>\n`;
  }

  if (hasQuorumLoss) {
    html += `<p><strong>Note:</strong> The availability replica manager went offline because the local WSFC node lost quorum.</p>\n`;
  }
  html += `</div>\n`;

  // IO context from waits
  let ioWaits = [];
  if (xeWaitsRaw) {
    for (const line of xeWaitsRaw.split(/\r?\n/)) {
      const p = line.split('|').map(s => s.trim());
      if (p.length >= 4 && p[2] === 'ASYNC_IO_COMPLETION') {
        ioWaits.push({ host: p[0], durMs: parseInt(p[3]) });
      }
    }
  }
  if (ioWaits.length > 0) {
    const maxIo = Math.max(...ioWaits.map(w => w.durMs));
    html += `<h3>7.2 IO Context</h3>\n<div class="conclusion">`;
    html += `<p>ASYNC_IO_COMPLETION waits detected: ${ioWaits.length} events, max duration <strong>${maxIo > 60000 ? (maxIo/60000).toFixed(0) + ' min' : (maxIo/1000).toFixed(0) + 's'}</strong>.</p>\n`;
    if (maxIo > 300000) html += `<p style="color:var(--red)"><strong>Severe IO pressure.</strong> This may have contributed to the SYSTEM_UNHEALTHY health check and is likely a contributing factor to the failover.</p>\n`;
    html += `</div>\n`;
  }

  // SQLDIAG health flapping — only report if 'error' state transitions occurred
  const healthErrorFlaps = sqldiagEvents.filter(e => /health state has been changed/.test(e.detail) && /error/i.test(e.detail));
  const healthWarningFlaps = sqldiagEvents.filter(e => /health state has been changed/.test(e.detail) && !/error/i.test(e.detail));
  if (healthErrorFlaps.length > 0 || healthWarningFlaps.length > 10) {
    html += `<h3>7.3 Health State Summary</h3>\n<div class="conclusion">`;
    if (healthErrorFlaps.length > 0) {
      html += `<p><strong>ERROR state transitions (${healthErrorFlaps.length}):</strong></p>\n<pre>`;
      for (const ev of healthErrorFlaps) {
        html += `${ev.local_ts}  [${ev.host}]  ${esc(ev.detail.substring(0, 200))}\n`;
      }
      html += `</pre>\n`;
    }
    if (healthWarningFlaps.length > 0) {
      html += `<p style="color:var(--dim)">Additionally, ${healthWarningFlaps.length} warning↔clean transitions were observed (not shown — indicates sustained resource/query_processing pressure).</p>\n`;
    }
    html += `</div>\n`;
  }

  // Per-AG outcome
  let subSec = ioWaits.length > 0 ? (healthErrorFlaps.length > 0 || healthWarningFlaps.length > 10 ? 4 : 3) : 2;
  html += `<h3>7.${subSec} Outcome per AG</h3>\n<div class="conclusion">`;
  for (const s of agSummaries) {
    html += `<p><strong>${s.ag}:</strong> ${s.summary}</p>\n`;
  }
  html += `</div>\n`;

  // Per-host summary
  subSec++;
  html += `<h3>7.${subSec} Per-Host Recovery Summary</h3>\n<div class="conclusion">`;
  for (const [host, s] of Object.entries(hostSummaries)) {
    if (s.total === 0) continue;
    if (s.stuck === 0) {
      html += `<p><strong>${host}:</strong> All ${s.total} databases recovered successfully. ✅</p>\n`;
    } else {
      html += `<p><strong>${host}:</strong> ${s.recovered} recovered, <span style="color:var(--red)">${s.stuck} stuck ❌</span></p>\n`;
      html += `<p>Stuck databases: <code>${s.stuckDbs.join(', ')}</code></p>\n`;
      // Classify stuck DBs
      const catB = [], catC = [];
      for (const db of s.stuckDbs) {
        const st = dbStatus[db];
        if (st?.nonqual_rollback?.count > 0) catB.push(db);
        else catC.push(db);
      }
      if (catB.length > 0) html += `<p><span class="badge badge-red">Category B</span> ${catB.length} DBs stuck at <code>AcquireXDbLockWithKill</code> (NQ rollback loop): ${catB.join(', ')}</p>\n`;
      if (catC.length > 0) html += `<p><span class="badge badge-orange">Category C</span> ${catC.length} DBs stuck at sub-manager Stop (silent, no NQ rollback): ${catC.join(', ')}</p>\n`;
    }
  }
  html += `</div>\n`;

  // Key observations (if there are stuck DBs or interesting patterns)
  const totalStuck = Object.values(hostSummaries).reduce((a, s) => a + s.stuck, 0);
  if (totalStuck > 0) {
    subSec++;
    html += `<h3>7.${subSec} Key Observations</h3>\n<div class="conclusion">`;

    // Check which DBs have Reverting events
    const revertDbs = Object.keys(revertData);
    const stuckNoRevert = Object.values(hostSummaries).flatMap(s => s.stuckDbs).filter(db => !revertDbs.includes(db));
    if (stuckNoRevert.length > 0) {
      html += `<p><strong>No Reverting events for stuck DBs:</strong> ${stuckNoRevert.length} stuck databases have zero Reverting begin/finished events in XEvent. This confirms they never completed the <code>DatabaseSwitchRoles</code> pipeline to the undo phase.</p>\n`;
    }

    // Remote harden as evidence
    if (inc.event_counts.remote_harden > 0) {
      html += `<p><strong>Remote harden failures:</strong> ${inc.event_counts.remote_harden} events — system threads (Ghost cleanup, QDS, Checkpoint) were still actively writing to stuck databases, confirming Step 21 (exclusive DB lock) was never acquired.</p>\n`;
    }

    // Compare with other AGs
    const recoveredAgs = inc.ags_affected.filter(ag => {
      const dbs = Object.entries(dbStatus).filter(([db, st]) => st.ag === ag);
      return dbs.every(([db, st]) => {
        const anyStuck = Object.values(hostSummaries).some(s => s.stuckDbs.includes(db));
        return !anyStuck;
      });
    });
    if (recoveredAgs.length > 0 && totalStuck > 0) {
      html += `<p><strong>Cross-AG comparison:</strong> ${recoveredAgs.join(', ')} recovered fully while intl-ag had stuck databases. `;
      const batchAg = recoveredAgs.find(ag => ag.includes('batch'));
      if (batchAg) {
        html += `batch-ag (DTC_SUPPORT=PER_DB) released all DTC resource managers and completed Reverting for all 12 databases.`;
      }
      html += `</p>\n`;
    }
    html += `</div>\n`;
  }

  html += `\n<hr style="border-color:var(--border);margin:2rem 0;">
<p style="color:var(--dim);font-size:.8rem;">Generated: ${new Date().toISOString().substring(0, 10)} | Case: ${caseId} | ${foId}</p>
</body></html>`;

  // Save HTML
  const outDir = 'reports';
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir);
  const outPath = path.join(outDir, `${caseId}_${foId.toLowerCase()}_analysis.html`);
  fs.writeFileSync(outPath, html);
  console.log(`  Saved: ${outPath} (${(html.length / 1024).toFixed(0)} KB)`);

  // ---- Generate Markdown version ----
  let md = `# Case ${caseId} — ${foId} Detailed Analysis\n\n`;
  md += `**Time:** ${foStart} — ${foEnd} (local, UTC+${utcOffset})  \n`;
  md += `**AGs Affected:** ${inc.ags_affected.join(', ')}  \n`;
  md += `**Hosts:** ${hosts.join(', ')}  \n`;
  md += `**Total Events:** ${inc.total_events}\n\n`;
  md += `---\n\n`;

  // 1. Direction table
  md += `## 1. Failover Direction\n\n`;
  md += `| AG | Old PRIMARY | New PRIMARY | Detail |\n|---|---|---|---|\n`;
  for (const ag of inc.ags_affected) {
    const dirs = agDirs[ag] || [];
    const fromPriDir = dirs.find(d => d.from.includes('PRIMARY') && d.to.includes('RESOLVING'));
    const toPriDir = dirs.find(d => d.to.includes('PRIMARY_NORMAL'));
    const secDisrupted = dirs.filter(d => d.from.includes('SECONDARY') && d.to.includes('RESOLVING'));
    const secRecov = dirs.filter(d => d.from.includes('RESOLVING') && d.to.includes('SECONDARY'));
    let oldP = '-', newP = '-', det = '';
    if (fromPriDir && toPriDir) {
      oldP = fromPriDir.host; newP = toPriDir.host;
      det = `${oldP} PRI→RESOLV at ${ts2tf(fromPriDir.ts)}, ${newP} →PRI at ${ts2tf(toPriDir.ts)}`;
      const r = dirs.find(d => d.host === fromPriDir.host && d.to.includes('SECONDARY'));
      if (r) det += `, ${oldP} →SEC at ${ts2tf(r.ts)}`;
    } else if (fromPriDir) {
      oldP = fromPriDir.host;
      const r = dirs.find(d => d.host === fromPriDir.host && d.to.includes('SECONDARY'));
      if (r) { det = `${oldP} PRI→RESOLV→SEC`; newP = thirdPartyPrimary.size > 0 ? [...thirdPartyPrimary][0] : '(3rd node)'; }
      else det = `${oldP} lost PRIMARY`;
    } else if (secDisrupted.length > 0) {
      oldP = '(unchanged)'; newP = '(unchanged)';
      det = secDisrupted.map(d => `${d.host} SEC disrupted`).join(', ');
      if (secRecov.length > 0) det += ` → recovered`;
    }
    md += `| ${ag.replace('sybasehk-prod-','')} | ${oldP} | ${newP} | ${det} |\n`;
  }
  md += `\n`;

  // 2. Key Event Timeline
  md += `## 2. Key Event Timeline\n\n`;
  // Reuse the same data as HTML version
  for (const host of hosts) {
    const hostEvts = [];
    for (const l of (rawTrigger[host] || [])) {
      if (l._collapse) continue;
      let ev = '', ann = '';
      if (/has changed from.*PRIMARY.*RESOLVING/.test(l.line)) { const m = l.line.match(/availability group '([^']+)'/); ev='FAILOVER'; ann=`AG ${m?m[1]:'?'}: PRI→RESOLVING`; }
      else if (/has changed from.*SECONDARY.*RESOLVING/.test(l.line)) { const m = l.line.match(/availability group '([^']+)'/); ev='RESOLVING'; ann=`AG ${m?m[1]:'?'}: SEC→RESOLVING`; }
      else if (/has changed from.*RESOLVING.*SECONDARY/.test(l.line)) { const m = l.line.match(/availability group '([^']+)'/); ev='RECOVERED'; ann=`AG ${m?m[1]:'?'}: →SECONDARY`; }
      else if (/has changed from.*PRIMARY_PENDING.*PRIMARY_NORMAL/.test(l.line)) { const m = l.line.match(/availability group '([^']+)'/); ev='PROMOTED'; ann=`AG ${m?m[1]:'?'}: →PRIMARY`; }
      else if (/Error: 41144/.test(l.line)) { ev='ERROR'; ann='Error 41144 — replica failed state'; }
      else if (/Error: 41005|Error code 1722/.test(l.line)) { ev='ERROR'; ann='Error 41005/1722 — WSFC handle failure'; }
      else if (/Error: 41161/.test(l.line)) { ev='ERROR'; ann='Error 41161 — CRC failed, AG offline'; }
      else if (/connection timeout/.test(l.line)) { const m = l.line.match(/replica '([^']+)'/); ev='TIMEOUT'; ann=`Timeout to ${m?m[1]:'?'}`; }
      else if (/going offline/.test(l.line)) { const m = l.line.match(/availability group '([^']+)'/); ev='OFFLINE'; ann=`AG ${m?m[1]:'?'} going offline`; }
      else if (/lost quorum/.test(l.line)) { ev='QUORUM'; ann='WSFC lost quorum'; }
      else if (/stop the lease/.test(l.line)) { ev='LEASE'; ann='Stopping lease renewal'; }
      else if (/NT AUTHORITY/.test(l.line)) { ev='CLUSTER'; ann='Cluster service login'; }
      else continue;
      hostEvts.push({ ts: ts2tf(l.ts), ev, ann });
    }
    // Aggregated DB events
    const cats = {};
    for (const l of (rawDbEvents[host] || [])) {
      if (/changing roles.*"PRIMARY".*"RESOLVING"/.test(l.line)) { if (!cats.priRes) cats.priRes={n:0,f:l.ts,l:l.ts}; cats.priRes.n++; cats.priRes.l=l.ts; }
      else if (/changing roles.*"RESOLVING".*"SECONDARY"/.test(l.line)) { if (!cats.resSec) cats.resSec={n:0,f:l.ts,l:l.ts}; cats.resSec.n++; cats.resSec.l=l.ts; }
      else if (/changing roles.*"RESOLVING".*"PRIMARY"/.test(l.line)) { if (!cats.resPri) cats.resPri={n:0,f:l.ts,l:l.ts}; cats.resPri.n++; cats.resPri.l=l.ts; }
      else if (/ABORT_AFTER_WAIT/.test(l.line)) { if (!cats.kill) cats.kill={n:0,f:l.ts,l:l.ts}; cats.kill.n++; cats.kill.l=l.ts; }
      else if (/DTC.*released/i.test(l.line)) { if (!cats.dtcR) cats.dtcR={n:0,f:l.ts}; cats.dtcR.n++; }
      else if (/Initializing.*DTC/i.test(l.line)) { if (!cats.dtcI) cats.dtcI={n:0,f:l.ts}; cats.dtcI.n++; }
      else if (/Starting up database/i.test(l.line)) { if (!cats.su) cats.su={n:0,f:l.ts,l:l.ts,dbs:new Set()}; const mdb=l.line.match(/database '([^']+)'/); if(mdb) cats.su.dbs.add(mdb[1]); cats.su.n++; cats.su.l=l.ts; }
      else if (/resynchronize/i.test(l.line)) { if (!cats.rs) cats.rs={n:0,f:l.ts,l:l.ts,dbs:new Set()}; const mdb=l.line.match(/database '([^']+)'/); if(mdb) cats.rs.dbs.add(mdb[1]); cats.rs.n++; cats.rs.l=l.ts; }
      else if (/Nonqualified/i.test(l.line)) { if (!cats.nq) cats.nq={n:0,f:l.ts,l:l.ts,dbs:new Set()}; cats.nq.n++; cats.nq.l=l.ts; const m=l.line.match(/database (\S+)/); if(m)cats.nq.dbs.add(m[1]); }
      else if (/Remote harden.*failed/i.test(l.line)) { if (!cats.rh) cats.rh={n:0,f:l.ts,l:l.ts}; cats.rh.n++; cats.rh.l=l.ts; }
      else if (/connection with.*established/i.test(l.line)) {
        // Track per-replica connection established
        const mRep = l.line.match(/replica '([^']+)'/i);
        const rep = mRep ? mRep[1] : 'unknown';
        if (!cats.connEst) cats.connEst = {};
        if (!cats.connEst[rep]) cats.connEst[rep] = { n: 0, f: l.ts, l: l.ts };
        cats.connEst[rep].n++; cats.connEst[rep].l = l.ts;
      }
      else if (/recovery completed/i.test(l.line)) { if (!cats.recov) cats.recov={n:0,f:l.ts,l:l.ts}; cats.recov.n++; cats.recov.l=l.ts; }
    }
    if (cats.priRes) hostEvts.push({ ts: ts2t(cats.priRes.f), ev:'FAILOVER', ann:`${cats.priRes.n} DBs PRI→RESOLV` });
    if (cats.kill) hostEvts.push({ ts: ts2t(cats.kill.f), ev:'KILL', ann:`${cats.kill.n} ABORT kills` });
    if (cats.dtcR) hostEvts.push({ ts: ts2t(cats.dtcR.f), ev:'DTC', ann:`${cats.dtcR.n} DTC RMs released` });
    if (cats.dtcI) hostEvts.push({ ts: ts2t(cats.dtcI.f), ev:'DTC', ann:`${cats.dtcI.n} DTC RMs initialized` });
    if (cats.resSec) hostEvts.push({ ts: ts2t(cats.resSec.f), ev:'RECOVERED', ann:`${cats.resSec.n} DBs →SEC` });
    if (cats.resPri) hostEvts.push({ ts: ts2t(cats.resPri.f), ev:'PROMOTED', ann:`${cats.resPri.n} DBs →PRI` });
    if (cats.su) hostEvts.push({ ts: ts2t(cats.su.f), ev:'STARTUP', ann:`${cats.su.dbs.size} unique DBs Starting up (${ts2t(cats.su.f)}–${ts2t(cats.su.l)})` });
    if (cats.rs) hostEvts.push({ ts: ts2t(cats.rs.f), ev:'RESYNC', ann:`${cats.rs.dbs.size} unique DBs resync (${ts2t(cats.rs.f)}–${ts2t(cats.rs.l)})` });
    if (cats.nq) hostEvts.push({ ts: ts2t(cats.nq.f), ev:'NQ_LOOP', ann:`NQ rollback ×${cats.nq.n} on ${cats.nq.dbs.size} DBs (${[...cats.nq.dbs].join(', ')})` });
    if (cats.rh) hostEvts.push({ ts: ts2t(cats.rh.f), ev:'RH_FAIL', ann:`Remote harden ×${cats.rh.n} (${ts2t(cats.rh.f)}–${ts2t(cats.rh.l)})` });
    if (cats.recov) hostEvts.push({ ts: ts2t(cats.recov.f), ev:'RECOVERED', ann:`${cats.recov.n} DBs recovery completed` });
    if (cats.connEst) {
      for (const [rep, info] of Object.entries(cats.connEst)) {
        hostEvts.push({ ts: ts2t(info.f), ev:'CONNECTED', ann:`Connection established with ${rep} (${info.n} DBs, ${ts2t(info.f)}–${ts2t(info.l)})` });
      }
    }
    // SQLDIAG
    for (const e of sqldiagEvents.filter(e => e.host === host)) {
      if (/Lease Thread terminated/i.test(e.detail)) hostEvts.push({ ts: ts2t(e.local_ts), ev:'LEASE', ann:'Lease Thread terminated' });
      else if (/target=Failed.*SYSTEM_UNHEALTHY/i.test(e.detail)) { const m=e.detail.match(/(\S+) target/); hostEvts.push({ ts: ts2t(e.local_ts), ev:'UNHEALTHY', ann:`${m?m[1]:'AG'} SYSTEM_UNHEALTHY` }); }
    }
    hostEvts.sort((a,b) => a.ts.localeCompare(b.ts));
    if (hostEvts.length === 0) continue;
    md += `### ${host}\n\n| Time | Event | Detail |\n|---|---|---|\n`;
    for (const e of hostEvts) md += `| ${e.ts} | **${e.ev}** | ${e.ann} |\n`;
    md += `\n`;
  }

  // 3. Trigger raw evidence (abbreviated for MD)
  md += `## 3. Trigger Analysis (Raw ERRORLOG Evidence)\n\n`;
  for (const host of hosts) {
    const lines = rawTrigger[host];
    if (lines.length === 0) continue;
    md += `### ${host}\n\n\`\`\`\n`;
    for (const l of lines) {
      if (l._collapse) { md += `${l.line}\n`; continue; }
      md += `${l.line}\n`;
    }
    md += `\`\`\`\n\n`;
  }

  // 4. WSFC error chain
  if (has41xxx) {
    md += `## 4. WSFC Error Chain\n\n\`\`\`\n`;
    if (allTriggerLines.some(l => /41005/.test(l.line))) md += `Error 41005 — Failed to obtain WSFC resource handle (Error 1722 = RPC unavailable)\n  ↓\n`;
    if (allTriggerLines.some(l => /41034/.test(l.line))) md += `Error 41034 — Failed to read/update persisted config\n  ↓\n`;
    if (allTriggerLines.some(l => /41144/.test(l.line))) md += `Error 41144 — Replica entered failed state\n`;
    if (allTriggerLines.some(l => /41143/.test(l.line))) md += `Error 41143 — Cannot process operation (failed state)\n`;
    if (allTriggerLines.some(l => /41161/.test(l.line))) md += `Error 41161 — CRC validation failed → AG taken offline\n`;
    md += `\`\`\`\n\n`;
  }

  // Per-DB Status Tables (MD format)
  md += `## ${has41xxx ? '6' : '5'}. Per-DB Status Tables\n\n`;
  for (const host of hosts) {
    const hostRolesArr = [];
    for (const ag of inc.ags_affected) {
      const dirs = agDirs[ag] || [];
      const fp = dirs.find(d => d.host === host && d.from.includes('PRIMARY') && d.to.includes('RESOLVING'));
      const tp = dirs.find(d => d.host === host && d.to.includes('PRIMARY'));
      const fs2 = dirs.find(d => d.host === host && d.from.includes('SECONDARY') && d.to.includes('RESOLVING'));
      const short = ag.replace('sybasehk-prod-','');
      if (fp) hostRolesArr.push(`${short}: demoted`);
      else if (tp) hostRolesArr.push(`${short}: promoted`);
      else if (fs2) hostRolesArr.push(`${short}: SEC disrupted`);
    }

    const hostDbRows = [];
    for (const [db, st] of Object.entries(dbStatus)) {
      const resolv = st[`to_resolving_${host}`];
      const sec = st[`to_secondary_${host}`];
      const pri = st[`to_primary_${host}`];
      const startup = st[`starting_up_${host}`];
      const resync = st[`resync_${host}`];
      const dtcI = st[`dtc_init_${host}`];
      const dtcR = st[`dtc_release_${host}`];
      const ak = st[`abort_kill_${host}`];
      const nqH = st[`nonqual_rollback_${host}`];
      const nqFallback = (resolv && resolv.from === 'PRIMARY') ? st.nonqual_rollback : null;
      const nq2 = nqH || nqFallback;
      const revert = revertData[db] || {};
      if (!resolv && !sec && !pri && !startup) continue;
      const ag = (st.ag || dbAgMap[db] || '?').replace('sybasehk-prod-','');
      const id = dbNameToId[host]?.[db] || '?';
      let result = pri ? '→PRI ✅' : (sec ? (() => { const g = new Date(sec.replace(' ','T')+'Z') - new Date((resolv?resolv.ts:foStart).replace(' ','T')+'Z'); return g > 3600000 ? '→SEC(shut) ☠' : '→SEC ✅'; })() : (resolv ? 'STUCK ❌' : '-'));
      hostDbRows.push({
        ag, db, id,
        dir: resolv ? `${resolv.from}→RESOLV` : '-',
        resolv: resolv ? ts2t(resolv.ts) : '-',
        dtcR: dtcR ? ts2t(dtcR) : '',
        sec: sec ? ts2t(sec) : '-',
        pri: pri ? ts2t(pri) : '',
        startup: startup ? ts2t(startup) : '-',
        resync: resync ? ts2t(resync) : '-',
        revertB: revert[`begin_${host}`] ? ts2t(revert[`begin_${host}`]) : '-',
        revertE: revert[`end_${host}`] ? ts2t(revert[`end_${host}`]) : '-',
        kill: ak ? `×${ak.count} ${ts2t(ak.ts)}` : '-',
        nq: nq2 ? `×${nq2.count} ${ts2t(nq2.first)}—${ts2t(nq2.last)}` : '-',
        result
      });
    }
    hostDbRows.sort((a,b) => a.ag.localeCompare(b.ag) || a.db.localeCompare(b.db));
    if (hostDbRows.length === 0) continue;

    const hasDtc = hostDbRows.some(d => d.dtcR);
    const hasKill = hostDbRows.some(d => d.kill !== '-');
    const hasNq = hostDbRows.some(d => d.nq !== '-');
    const hasRevert = hostDbRows.some(d => d.revertB !== '-');
    const hasPri = hostDbRows.some(d => d.pri);

    md += `### ${host} (${hostRolesArr.join(' | ')})\n\n`;
    let hdr = '| AG | DB | ID | Direction | →RESOLV |';
    let sep = '|---|---|---|---|---|';
    if (hasDtc) { hdr += ' DTC Rel |'; sep += '---|'; }
    hdr += ' →SEC |';  sep += '---|';
    if (hasPri) { hdr += ' →PRI |'; sep += '---|'; }
    hdr += ' Starting | Resync |'; sep += '---|---|';
    if (hasRevert) { hdr += ' Revert B | Revert E |'; sep += '---|---|'; }
    if (hasKill) { hdr += ' ABORT Kill |'; sep += '---|'; }
    if (hasNq) { hdr += ' NQ Rollback |'; sep += '---|'; }
    hdr += ' Result |'; sep += '---|';
    md += `${hdr}\n${sep}\n`;

    let stuckN = 0, okN = 0;
    for (const d of hostDbRows) {
      let row = `| ${d.ag} | ${d.db} | ${d.id} | ${d.dir} | ${d.resolv} |`;
      if (hasDtc) row += ` ${d.dtcR || '-'} |`;
      row += ` ${d.sec} |`;
      if (hasPri) row += ` ${d.pri || '-'} |`;
      row += ` ${d.startup} | ${d.resync} |`;
      if (hasRevert) row += ` ${d.revertB} | ${d.revertE} |`;
      if (hasKill) row += ` ${d.kill} |`;
      if (hasNq) row += ` ${d.nq} |`;
      row += ` ${d.result} |`;
      md += `${row}\n`;
      if (d.result.includes('STUCK') || d.result.includes('☠')) stuckN++;
      else if (d.result.includes('✅')) okN++;
    }

    const allDbsOnHost = schema[host === schema.old_primary.host ? 'old_primary' : 'new_primary']?.databases || [];
    const evtDbs = new Set(hostDbRows.map(d => d.db));
    const noChange = allDbsOnHost.filter(d => !evtDbs.has(d.name));
    md += `\n**Summary:** ${hostDbRows.length} DBs with role changes — ${okN} recovered`;
    if (stuckN > 0) md += `, ${stuckN} stuck`;
    if (noChange.length > 0) {
      const byAg = {};
      noChange.forEach(d => { const a = (d.ag||'?').replace('sybasehk-prod-',''); if (!byAg[a]) byAg[a]=[]; byAg[a].push(d.name); });
      md += `  \n${noChange.length} DBs no role change: ${Object.entries(byAg).map(([a,ds]) => `${a} (${ds.length} DBs — PRIMARY unchanged)`).join(', ')}`;
    }
    md += `\n\n`;
  }

  // Conclusion
  md += `## ${has41xxx ? '9' : '8'}. Analysis & Conclusion\n\n`;
  md += `### Trigger Cause\n\n`;
  if (hasLeaseTermination && hasSystemUnhealthy) {
    const leaseEvt = sqldiagEvents.find(e => /Lease Thread terminated/i.test(e.detail));
    md += `**Root Cause:** WSFC lease thread termination on \`${leaseEvt?leaseEvt.host:'affected node'}\` due to SYSTEM_UNHEALTHY.\n\n`;
  } else if (hasError1722) {
    md += `**Root Cause:** Transient WSFC communication failure (Error 1722: RPC server unavailable).\n\n`;
    md += `Error chain: 41005 → 41034 → 41144 → 41161 → AG taken offline.\n\n`;
  } else if (hasWsfcOffline) {
    const uop = [...allOldPriHosts];
    if (uop.length > 0 && uop.every(h => !hosts.includes(h))) {
      md += `**Root Cause:** PRIMARY node \`${uop.join(', ')}\` became unreachable. Automatic failover triggered.\n\n`;
    } else {
      md += `**Root Cause:** WSFC cluster resource went offline, triggering failover.\n\n`;
    }
  }

  md += `### Per-AG Outcome\n\n`;
  for (const s of agSummaries) {
    md += `- **${s.ag}:** ${s.summary.replace(/<\/?code>/g,'`')}\n`;
  }
  md += `\n`;

  md += `### Per-Host Recovery\n\n`;
  for (const [host, s] of Object.entries(hostSummaries)) {
    if (s.total === 0) continue;
    if (s.stuck === 0) {
      md += `- **${host}:** All ${s.total} DBs recovered ✅\n`;
    } else {
      md += `- **${host}:** ${s.recovered} recovered, **${s.stuck} stuck** ❌\n`;
      const catB = s.stuckDbs.filter(db => dbStatus[db]?.[`nonqual_rollback_${host}`] || (dbStatus[db]?.nonqual_rollback && dbStatus[db]?.[`to_resolving_${host}`]?.from === 'PRIMARY'));
      const catC = s.stuckDbs.filter(db => !catB.includes(db));
      if (catB.length > 0) md += `  - **Cat B** (AcquireXDbLockWithKill loop, ${catB.length}): ${catB.join(', ')}\n`;
      if (catC.length > 0) md += `  - **Cat C** (sub-manager Stop, silent, ${catC.length}): ${catC.join(', ')}\n`;
    }
  }
  md += `\n`;

  // ---- Stuck DB Comparative Analysis (only if there are stuck DBs) ----
  const totalStuckMd = Object.values(hostSummaries).reduce((a, s) => a + s.stuck, 0);
  if (totalStuckMd > 0) {
    md += `## Stuck DB — Comparative Analysis & Source Code Mapping\n\n`;
    md += `Each database independently executes \`DatabaseSwitchRoles\` to transition from PRIMARY → RESOLVING.\n`;
    md += `The pipeline steps and their ERRORLOG/XEvent evidence:\n\n`;
    md += `\`\`\`\nDatabaseSwitchRoles(HADR_ROLE_RESOLVING)  [HadrDbMgrApi.cpp]\n`;
    md += `│\n`;
    md += `├─ Step 6:     ★ ERRORLOG "is changing roles from PRIMARY to RESOLVING"\n`;
    md += `│              (printed BEFORE any real work)\n`;
    md += `├─ Step 11-13: m_userMgr/m_scanMgr/m_redoMgr.Stop()  ← CAN BLOCK\n`;
    md += `├─ Step 20:    StopDtcForDb() → "DTC resource manager released"\n`;
    md += `├─ Step 21:    ★★★ AcquireXDbLockWithKill(INFINITE) ★★★\n`;
    md += `│              → loop: kill sessions → try exclusive lock → if timeout → Error 35299\n`;
    md += `│                "Nonqualified rollback 100%" ← system threads not killable\n`;
    md += `├─ Step 24:    SetRole(RESOLVING) → role changes\n`;
    md += `└─ After:      RESOLVING→SECONDARY → Starting up → Reverting → Resync\n`;
    md += `\`\`\`\n\n`;

    // Pick representative DBs from each category on the demoted host
    for (const [host, s] of Object.entries(hostSummaries)) {
      if (s.stuck === 0) continue;

      // Find a recovered DB on same host same AG
      const stuckAg = dbStatus[s.stuckDbs[0]]?.ag || '';
      const recoveredOnHost = Object.entries(dbStatus).find(([db, st]) => {
        return st.ag === stuckAg && st[`to_resolving_${host}`]?.from === 'PRIMARY' &&
          (st[`starting_up_${host}`] || st[`to_secondary_${host}`]) && !s.stuckDbs.includes(db);
      });
      const catBDb = s.stuckDbs.find(db => dbStatus[db]?.[`nonqual_rollback_${host}`] ||
        (dbStatus[db]?.nonqual_rollback && dbStatus[db]?.[`to_resolving_${host}`]?.from === 'PRIMARY'));
      const catCDb = s.stuckDbs.find(db => db !== catBDb &&
        !(dbStatus[db]?.[`nonqual_rollback_${host}`]) &&
        !(dbStatus[db]?.nonqual_rollback && dbStatus[db]?.[`to_resolving_${host}`]?.from === 'PRIMARY'));

      const picks = [];
      if (recoveredOnHost) picks.push({ label: 'Cat A ✅ Recovered', db: recoveredOnHost[0], st: recoveredOnHost[1] });
      if (catBDb) picks.push({ label: 'Cat B ❌ AcquireXDbLock', db: catBDb, st: dbStatus[catBDb] });
      if (catCDb) picks.push({ label: 'Cat C ❌ Sub-mgr Stop', db: catCDb, st: dbStatus[catCDb] });

      if (picks.length < 2) continue;  // need at least recovered + stuck for comparison

      md += `### ${host} — Representative DB Comparison\n\n`;

      // Build comparison table
      const steps = [
        { name: 'PRIMARY → RESOLVING (Step 6)', key: (db, st) => st[`to_resolving_${host}`]?.ts },
        { name: 'ABORT Kill', key: (db, st) => st[`abort_kill_${host}`] ? `×${st[`abort_kill_${host}`].count} at ${ts2t(st[`abort_kill_${host}`].ts)}` : null },
        { name: 'DTC Release (Step 20)', key: (db, st) => st[`dtc_release_${host}`] },
        { name: 'Nonqualified Rollback (Step 21)', key: (db, st) => {
          const nq = st[`nonqual_rollback_${host}`] || ((st[`to_resolving_${host}`]?.from === 'PRIMARY') ? st.nonqual_rollback : null);
          return nq ? `×${nq.count} ${ts2t(nq.first)}—${ts2t(nq.last)}` : null;
        }},
        { name: 'hadr_sync_state KillAll (XEvent)', key: (db, st) => {
          const id = dbNameToId[host]?.[db];
          return killAllDbs[host]?.has(parseInt(id)) ? `db_id=${id} ✅` : null;
        }},
        { name: 'RESOLVING → SECONDARY', key: (db, st) => st[`to_secondary_${host}`] },
        { name: 'Starting up', key: (db, st) => st[`starting_up_${host}`] },
        { name: 'Reverting begin (XEvent)', key: (db, st) => revertData[db]?.[`begin_${host}`] },
        { name: 'Reverting finished (XEvent)', key: (db, st) => revertData[db]?.[`end_${host}`] },
        { name: 'Resync', key: (db, st) => st[`resync_${host}`] },
        { name: 'Remote harden failed', key: (db, st) => {
          // Count from rawDbEvents
          const rh = (rawDbEvents[host] || []).filter(l => new RegExp(`Remote harden.*database '${db}'`, 'i').test(l.line));
          return rh.length > 0 ? `×${rh.length} ${ts2t(rh[0].ts)}—${ts2t(rh[rh.length-1].ts)}` : null;
        }},
      ];

      // Header
      md += `| Pipeline Step |`;
      for (const p of picks) md += ` ${p.db} (${p.label.split(' ')[0]} ${p.label.split(' ')[1]}) |`;
      md += `\n|---|`;
      for (const p of picks) md += `---|`;
      md += `\n`;

      // Rows
      for (const step of steps) {
        md += `| ${step.name} |`;
        for (const p of picks) {
          const val = step.key(p.db, p.st);
          md += ` ${val ? (typeof val === 'string' && val.length > 10 ? ts2t(val) || val : val) : '—'} |`;
        }
        md += `\n`;
      }
      md += `\n`;

      // Interpretation
      md += `**Interpretation:**\n\n`;
      if (recoveredOnHost) {
        const rdb = recoveredOnHost[0];
        md += `- **${rdb}** (Cat A): Completed the entire \`DatabaseSwitchRoles\` pipeline in ~30s. `;
        md += `All steps from ABORT kill through Reverting and Resync completed.\n`;
      }
      if (catBDb) {
        md += `- **${catBDb}** (Cat B): Reached Step 21 \`AcquireXDbLockWithKill\` `;
        const nq = dbStatus[catBDb]?.[`nonqual_rollback_${host}`] || dbStatus[catBDb]?.nonqual_rollback;
        if (nq) md += `and entered infinite loop (×${nq.count} NQ rollbacks, always "100%"). `;
        md += `System threads (Ghost/QDS/Checkpoint) hold shared DB locks → exclusive lock never acquired. `;
        md += `\`lck_GetRollBackProgress()\` skips system threads (not FKill-marked) → reports "100%" forever.\n`;
      }
      if (catCDb) {
        md += `- **${catCDb}** (Cat C): **Never reached Step 21** — no NQ rollback, no ABORT kill (after initial wave). `;
        md += `Stuck at Steps 11-13 (\`m_userMgr.Stop\`/\`m_scanMgr.Stop\`/\`m_redoMgr.Stop\`). `;
        md += `Completely silent — only evidence is continued Remote harden failures (system threads still writing). `;
        md += `**Memory dump required** to determine which sub-manager Stop call is blocked.\n`;
      }
      md += `\n`;
    }
  }

  // Save MD
  const mdPath = path.join(outDir, `${caseId}_${foId.toLowerCase()}_analysis.md`);
  fs.writeFileSync(mdPath, md);
  console.log(`  Saved: ${mdPath} (${(md.length / 1024).toFixed(0)} KB)`);
}

console.log('\nDone.');
