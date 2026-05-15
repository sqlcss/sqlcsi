// scripts/ag-failover-analysis/gen_fo_report.js
// Step 6: Generate HTML report for AG failover analysis
//
// Usage: node scripts/ag-failover-analysis/gen_fo_report.js <case_dir> <sql_server> <utc_offset>
// Output: reports/{case_id}_ag_failover_report.html

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const args = process.argv.slice(2);
if (args.length < 3) {
  console.error('Usage: node gen_fo_report.js <case_dir> <sql_server> <utc_offset>');
  process.exit(1);
}
const caseDir = args[0];
const sqlServer = args[1];
const utcOffset = parseInt(args[2]);
const caseId = path.basename(caseDir);
const dbName = `ag_${caseId}`;

const schema = JSON.parse(fs.readFileSync(path.join(caseDir, 'ag_schema.json'), 'utf8'));
const incidents = JSON.parse(fs.readFileSync(path.join(caseDir, 'failover_incidents.json'), 'utf8'));
const merged = JSON.parse(fs.readFileSync(path.join(caseDir, 'merged_timeline.json'), 'utf8'));

const dbIdMap = {};
for (const key of ['old_primary', 'new_primary']) {
  const r = schema[key];
  dbIdMap[r.host] = {};
  for (const db of r.databases) dbIdMap[r.host][db.id] = db.name;
}
const dbAgMap = {};
for (const key of ['old_primary', 'new_primary']) {
  for (const db of schema[key].databases) { if (!dbAgMap[db.name]) dbAgMap[db.name] = db.ag; }
}

function localToUtc(ts) { const d = new Date(ts.replace(' ','T')+'Z'); d.setHours(d.getHours()-utcOffset); return d.toISOString().replace('T',' ').replace('Z','').substring(0,23); }
function utcToLocal(ts) { const d = new Date(ts.replace(' ','T')+'Z'); d.setHours(d.getHours()+utcOffset); return d.toISOString().replace('T',' ').replace('Z','').substring(0,23); }

let tmpCnt = 0;
function sqlQuery(query) {
  const tmp = path.join(caseDir, `_rpt${tmpCnt++}.sql`);
  fs.writeFileSync(tmp, `SET NOCOUNT ON;\n${query}`);
  try {
    const r = execSync(`sqlcmd -S ${sqlServer} -E -d ${dbName} -W -s "|" -h -1 -i "${tmp}"`, { encoding:'utf8', maxBuffer:50*1024*1024 }).trim();
    fs.unlinkSync(tmp);
    return r;
  } catch(e) { try{fs.unlinkSync(tmp);}catch(_){} return ''; }
}

const h0 = schema.old_primary.host;
const h1 = schema.new_primary.host;
const h0s = h0.slice(-4), h1s = h1.slice(-4);

// --- Build HTML ---
let html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Case ${caseId} — AG Failover Analysis Report</title>
<style>
:root {
  --bg: #1e1e2e; --surface: #252538; --border: #3a3a55;
  --text: #cdd6f4; --dim: #a6adc8; --accent: #89b4fa;
  --green: #a6e3a1; --yellow: #f9e2af; --orange: #fab387;
  --red: #f38ba8; --teal: #94e2d5; --mauve: #cba6f7;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: var(--bg); color: var(--text); font-family: 'Segoe UI', Consolas, monospace; padding: 2rem; line-height: 1.6; }
h1 { color: var(--accent); margin-bottom: 0.5rem; font-size: 1.6rem; }
h2 { color: var(--mauve); margin: 2rem 0 0.8rem; font-size: 1.3rem; border-bottom: 1px solid var(--border); padding-bottom: 0.4rem; }
h3 { color: var(--teal); margin: 1.5rem 0 0.6rem; font-size: 1.1rem; }
p, li { color: var(--text); margin-bottom: 0.5rem; }
.meta { color: var(--dim); font-size: 0.9rem; margin-bottom: 1.5rem; }
table { border-collapse: collapse; width: 100%; margin: 1rem 0; font-size: 0.82rem; }
th { background: var(--surface); color: var(--accent); text-align: left; padding: 0.4rem 0.5rem; border: 1px solid var(--border); white-space: nowrap; }
td { padding: 0.3rem 0.5rem; border: 1px solid var(--border); white-space: nowrap; }
tr:nth-child(even) { background: var(--surface); }
.stuck td { color: var(--red); }
.ok td { color: var(--green); }
.sep td { background: var(--border); height: 2px; padding: 0; }
code { background: var(--surface); color: var(--teal); padding: 0.1rem 0.3rem; border-radius: 3px; font-size: 0.9em; }
pre { background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 0.8rem; overflow-x: auto; font-size: 0.8rem; margin: 0.6rem 0; }
.section { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 1rem; margin: 1rem 0; }
.badge { display: inline-block; padding: 0.1rem 0.5rem; border-radius: 3px; font-size: 0.8em; font-weight: bold; }
.badge-red { background: var(--red); color: var(--bg); }
.badge-green { background: var(--green); color: var(--bg); }
.badge-orange { background: var(--orange); color: var(--bg); }
ul { padding-left: 1.5rem; }
.fo-nav { display: flex; gap: 1rem; margin: 1rem 0; flex-wrap: wrap; }
.fo-nav a { color: var(--accent); text-decoration: none; padding: 0.3rem 0.8rem; border: 1px solid var(--border); border-radius: 4px; }
.fo-nav a:hover { background: var(--surface); }
</style>
</head>
<body>

<h1>Case ${caseId} — AG Failover Analysis Report</h1>
<div class="meta">
  <strong>Old Primary:</strong> ${h0} &nbsp;|&nbsp; <strong>New Primary:</strong> ${h1}<br>
  <strong>SQL Version:</strong> ${schema.old_primary.ags[Object.keys(schema.old_primary.ags)[0]]?.primary_replica || 'N/A'}<br>
  <strong>AG Count:</strong> ${schema.summary.ag_count} &nbsp;|&nbsp; <strong>DB Count:</strong> ${schema.summary.db_count}<br>
  <strong>UTC Offset:</strong> +${utcOffset}h &nbsp;|&nbsp; <strong>Report Generated:</strong> ${new Date().toISOString().substring(0,10)}
</div>
`;

// --- Section 1: AG Configuration ---
html += `<h2>1. AG Configuration</h2>
<table>
<tr><th>AG Name</th><th>Primary (current)</th><th>Listener</th><th>DTC</th><th>DBs</th></tr>
`;
for (const ag of schema.summary.ags) {
  html += `<tr><td>${ag.name}</td><td>${ag.primary_replica}</td><td>${ag.has_listener ? '✅ ' + ag.listener_name : '❌'}</td><td>${ag.dtc_support ? '✅ PER_DB (' + ag.dtc_db_count + ')' : '❌'}</td><td>${ag.db_count}</td></tr>\n`;
}
html += `</table>\n`;

// --- Section 2: Failover Incidents Overview ---
html += `<h2>2. Failover Incidents Overview</h2>
<div class="fo-nav">`;
for (const inc of incidents.incidents) {
  const label = inc.type === 'shutdown' ? 'SHUTDOWN' : inc.id;
  html += `<a href="#${inc.id || 'shutdown'}">${label} (${inc.start_ts.substring(11,19)})</a>`;
}
html += `</div>
<table>
<tr><th>ID</th><th>Time (local)</th><th>Type</th><th>AGs</th><th>Duration</th><th>Result</th></tr>
`;
for (const inc of incidents.incidents) {
  const dur = ((new Date(inc.end_ts.replace(' ','T')+'Z') - new Date(inc.start_ts.replace(' ','T')+'Z')) / 60000).toFixed(0);
  // Count stuck DBs
  let stuck = 0, total = 0;
  if (inc.db_status) {
    for (const [db, st] of Object.entries(inc.db_status)) {
      if (Object.keys(st).length <= 1) continue;
      total++;
      const r0 = st[`to_resolving_${h0}`];
      if (r0 && !st[`to_primary_${h0}`] && !st[`to_secondary_${h0}`]) stuck++;
    }
  }
  const result = inc.type === 'shutdown' ? 'SQL shutdown' : (stuck > 0 ? `<span class="badge badge-red">${stuck} STUCK</span>` : '<span class="badge badge-green">All OK</span>');
  html += `<tr><td>${inc.id || 'SHUTDOWN'}</td><td>${inc.start_ts.substring(0,19)}</td><td>${inc.type}</td><td>${inc.ags_affected.join(', ')}</td><td>${dur} min</td><td>${result}</td></tr>\n`;
}
html += `</table>\n`;

// --- Section 3+: Per-FO Details ---
let sectionNum = 3;
for (const inc of incidents.incidents) {
  const startUtc = localToUtc(inc.start_ts);
  const endUtc = localToUtc(inc.end_ts);
  const label = inc.type === 'shutdown' ? 'SHUTDOWN' : inc.id;

  html += `<h2 id="${inc.id || 'shutdown'}">${sectionNum}. ${label}: ${inc.start_ts.substring(0,19)} — ${inc.end_ts.substring(0,19)}</h2>\n`;

  // AG Flow
  html += `<h3>${sectionNum}.1 AG-Level Flow</h3>\n<pre>`;
  const agEvents = merged.events.filter(e =>
    e.local_ts >= inc.start_ts && e.local_ts <= inc.end_ts &&
    (e.category === 'ag_role_change' || e.category === 'hadr_replica_state')
  );
  const seenAg = new Set();
  for (const ev of agEvents) {
    let ag, from, to;
    const m1 = ev.detail.match(/availability group '([^']+)'.*from '([^']+)' to '([^']+)'/);
    const m2 = ev.detail.match(/([^:]+): (\S+) -> (\S+)/);
    if (m1) { ag = m1[1]; from = m1[2]; to = m1[3]; }
    else if (m2) { ag = m2[1].trim(); from = m2[2]; to = m2[3]; }
    else continue;
    const key = `${ev.host}|${ag}|${from}|${to}`;
    if (seenAg.has(key)) continue;
    seenAg.add(key);
    html += `[${ev.host.slice(-4)}] ${ev.local_ts}  ${ag.padEnd(28)} ${from} → ${to}\n`;
  }
  html += `</pre>\n`;

  // --- FO Trigger Context: 5 min before FO start ---
  const preStartTs = addMinutes(inc.start_ts, -5);
  const preStartUtc = localToUtc(preStartTs);
  
  // Collect pre-FO events from merged timeline
  const preEvents = merged.events.filter(e =>
    e.local_ts >= preStartTs && e.local_ts <= inc.start_ts &&
    !['nonqual_rollback', 'remote_harden', 'conn_established', 'conn_terminated', 'other_ag'].includes(e.category)
  );
  // Also get WSFC/error events during the FO itself
  const foErrorEvents = merged.events.filter(e =>
    e.local_ts >= inc.start_ts && e.local_ts <= inc.end_ts &&
    ['error', 'wsfc_cluster'].includes(e.category)
  );
  // SQLDIAG diagnostics state transitions in pre-FO and during FO
  const diagTransitions = merged.events.filter(e =>
    e.local_ts >= preStartTs && e.local_ts <= inc.end_ts &&
    e.category === 'sqldiag_diag'
  );
  // SQLDIAG info (Lease Thread, health state changes) around FO
  const sqldiagInfoAll = merged.events.filter(e =>
    e.local_ts >= preStartTs && e.local_ts <= inc.end_ts &&
    e.category === 'sqldiag_info'
  );

  // XEvent: system_health errors around this FO
  const xeErrors = [];
  const xeErrResult = sqlQuery(`
    SELECT host, CONVERT(VARCHAR(23), event_time, 121) AS utc, error_number, severity,
      LEFT(message, 250) AS msg
    FROM xe.errors
    WHERE event_time >= '${preStartUtc}' AND event_time <= '${endUtc}'
    ORDER BY event_time
  `);
  for (const line of (xeErrResult||'').split(/\r?\n/)) {
    if (!line.trim()) continue;
    const p = line.split('|').map(s => s.trim());
    if (p.length >= 5) {
      xeErrors.push({ host: p[0], utc: p[1], local: utcToLocal(p[1]), error: p[2], severity: p[3], msg: p[4] });
    }
  }

  // XEvent: wait_info around this FO
  const xeWaits = [];
  const xeWaitResult = sqlQuery(`
    SELECT host, CONVERT(VARCHAR(23), event_time, 121) AS utc,
      event_data.value('(event/data[@name=''wait_type'']/text)[1]', 'nvarchar(100)') AS wait_type,
      event_data.value('(event/data[@name=''duration'']/value)[1]', 'bigint') AS duration_ms
    FROM xe.raw_events
    WHERE session = 'system_health' AND event_name IN ('wait_info', 'wait_info_external')
      AND event_time >= '${preStartUtc}' AND event_time <= '${endUtc}'
    ORDER BY event_time
  `);
  for (const line of (xeWaitResult||'').split(/\r?\n/)) {
    if (!line.trim()) continue;
    const p = line.split('|').map(s => s.trim());
    if (p.length >= 4) {
      xeWaits.push({ host: p[0], local: utcToLocal(p[1]), wait_type: p[2], duration_ms: parseInt(p[3]) });
    }
  }

  // === Render Trigger Context ===
  const hasContext = preEvents.length > 0 || xeErrors.length > 0 || diagTransitions.length > 0 || xeWaits.length > 0;
  if (hasContext) {
    html += `<h3>${sectionNum}.2 Trigger Context (${preStartTs.substring(11,19)} — ${inc.start_ts.substring(11,19)})</h3>\n`;

    // SQLDIAG diagnostics transitions
    if (diagTransitions.length > 0) {
      html += `<div class="section"><strong>Diagnostics State Transitions:</strong><pre>`;
      for (const ev of diagTransitions) {
        html += `[${ev.host.slice(-4)}] ${ev.local_ts}  ${esc(ev.detail)}\n`;
      }
      html += `</pre></div>\n`;
    }

    // SQLDIAG info messages (including health state changes)
    if (sqldiagInfoAll.length > 0) {
      html += `<div class="section"><strong>SQLDIAG Info Messages:</strong><pre>`;
      for (const ev of sqldiagInfoAll) {
        html += `[${ev.host.slice(-4)}] ${ev.local_ts}  ${esc(ev.detail.substring(0, 150))}\n`;
      }
      html += `</pre></div>\n`;
    }

    // WSFC / cluster errors from ERRORLOG
    const wsfcEvents = [...preEvents, ...foErrorEvents].filter(e =>
      e.category === 'error' || e.category === 'wsfc_cluster'
    );
    if (wsfcEvents.length > 0) {
      html += `<div class="section"><strong>WSFC / Errors (ERRORLOG):</strong><pre>`;
      for (const ev of wsfcEvents.slice(0, 30)) {
        html += `[${ev.host.slice(-4)}] ${ev.local_ts}  ${esc(ev.detail.substring(0, 200))}\n`;
      }
      if (wsfcEvents.length > 30) html += `... (${wsfcEvents.length - 30} more)\n`;
      html += `</pre></div>\n`;
    }

    // system_health errors (from XEvent)
    if (xeErrors.length > 0) {
      // Summarize by error number
      const errSummary = {};
      for (const e of xeErrors) {
        const key = e.error;
        if (!errSummary[key]) errSummary[key] = { error: e.error, severity: e.severity, count: 0, first: e.local, last: e.local, msg: e.msg };
        errSummary[key].count++;
        errSummary[key].last = e.local;
      }
      html += `<div class="section"><strong>system_health Errors (XEvent):</strong>
<table><tr><th>Error</th><th>Sev</th><th>Count</th><th>First</th><th>Last</th><th>Message</th></tr>\n`;
      for (const [_, e] of Object.entries(errSummary).sort((a,b) => b[1].count - a[1].count)) {
        html += `<tr><td>${e.error}</td><td>${e.severity}</td><td>${e.count}</td><td>${e.first.substring(11,19)}</td><td>${e.last.substring(11,19)}</td><td>${esc(e.msg.substring(0, 150))}</td></tr>\n`;
      }
      html += `</table></div>\n`;
    }

    // wait_info
    if (xeWaits.length > 0) {
      html += `<div class="section"><strong>Long Waits (system_health):</strong>
<table><tr><th>Host</th><th>Time</th><th>Wait Type</th><th>Duration</th></tr>\n`;
      for (const w of xeWaits) {
        const durStr = w.duration_ms > 60000 ? `${(w.duration_ms/60000).toFixed(0)} min` : `${(w.duration_ms/1000).toFixed(0)}s`;
        html += `<tr><td>${w.host.slice(-4)}</td><td>${w.local.substring(11,19)}</td><td>${w.wait_type}</td><td>${durStr}</td></tr>\n`;
      }
      html += `</table></div>\n`;
    }
  }

  // SQLDIAG key events (Lease Thread, Disconnect, AG state change)
  const sqldiagEvents = merged.events.filter(e =>
    e.local_ts >= inc.start_ts && e.local_ts <= inc.end_ts &&
    (e.category === 'sqldiag_ag_state' || e.category === 'sqldiag_info') &&
    !e.detail.includes('health state has been changed')
  );
  if (sqldiagEvents.length > 0) {
    html += `<h3>${sectionNum}.3 SQLDIAG Key Events</h3>\n<pre>`;
    for (const ev of sqldiagEvents) {
      html += `[${ev.host.slice(-4)}] ${ev.local_ts}  ${esc(ev.detail.substring(0, 150))}\n`;
    }
    html += `</pre>\n`;
  }

  // Per-DB Status Table
  const subSec = hasContext ? 4 : 3;
  html += `<h3>${sectionNum}.${subSec} Per-DB Status</h3>\n`;

  // Collect per-DB data
  const dbData = {};
  const windowEvents = merged.events.filter(e => e.local_ts >= inc.start_ts && e.local_ts <= inc.end_ts);

  for (const ev of windowEvents) {
    if (ev.category === 'db_role_change') {
      const m = ev.detail.match(/database "([^"]+)".*from "([^"]+)" to "([^"]+)"/);
      if (!m) continue;
      const [, db, from, to] = m;
      if (!dbData[db]) dbData[db] = { ag: dbAgMap[db] || '?' };
      if (to === 'RESOLVING') dbData[db][`resolving_${ev.host}`] = { ts: ev.local_ts, from };
      else if (to === 'PRIMARY') dbData[db][`primary_${ev.host}`] = ev.local_ts;
      else if (to === 'SECONDARY') dbData[db][`secondary_${ev.host}`] = ev.local_ts;
    } else if (ev.category === 'starting_up') {
      const m = ev.detail.match(/database '([^']+)'/);
      if (m) { if (!dbData[m[1]]) dbData[m[1]] = { ag: dbAgMap[m[1]] || '?' }; dbData[m[1]][`startup_${ev.host}`] = ev.local_ts; }
    } else if (ev.category === 'recovery_completed') {
      const m = ev.detail.match(/database (\S+)/);
      if (m) { if (!dbData[m[1]]) dbData[m[1]] = { ag: dbAgMap[m[1]] || '?' }; dbData[m[1]][`recovery_${ev.host}`] = ev.local_ts; }
    } else if (ev.category === 'resync') {
      const m = ev.detail.match(/database '([^']+)'/);
      if (m) { if (!dbData[m[1]]) dbData[m[1]] = { ag: dbAgMap[m[1]] || '?' }; dbData[m[1]][`resync_${ev.host}`] = ev.local_ts; }
    } else if (ev.category === 'abort_kill') {
      const m = ev.detail.match(/database_id = (\d+)/);
      if (m) {
        const dbName2 = dbIdMap[ev.host]?.[parseInt(m[1])] || `id${m[1]}`;
        if (!dbData[dbName2]) dbData[dbName2] = { ag: dbAgMap[dbName2] || '?' };
        dbData[dbName2][`kills_${ev.host}`] = (dbData[dbName2][`kills_${ev.host}`] || 0) + 1;
      }
    } else if (ev.category === 'nonqual_rollback') {
      const m = ev.detail.match(/database (\S+)/);
      if (m) {
        if (!dbData[m[1]]) dbData[m[1]] = { ag: dbAgMap[m[1]] || '?' };
        if (!dbData[m[1]].nonqual) dbData[m[1]].nonqual = { count: 0, first: ev.local_ts, last: ev.local_ts };
        dbData[m[1]].nonqual.count++;
        dbData[m[1]].nonqual.last = ev.local_ts;
      }
    } else if (ev.category === 'dtc') {
      const mInit = ev.detail.match(/Initializing.*for database '([^']+)'/);
      if (mInit) { if (!dbData[mInit[1]]) dbData[mInit[1]] = { ag: dbAgMap[mInit[1]] || '?' }; dbData[mInit[1]][`dtc_init_${ev.host}`] = ev.local_ts; }
      const mRel = ev.detail.match(/resource manager \[([^\]]+)\].*has been released/);
      // DTC release — hard to map to DB name, skip
    }
  }

  // XEvent: Reverting
  const revertResult = sqlQuery(`
    SELECT host, CONVERT(VARCHAR(23), event_time, 121) AS utc,
      CASE WHEN hadr_message LIKE '%begin%' THEN 'begin' ELSE 'finished' END AS phase,
      SUBSTRING(hadr_message, CHARINDEX('[', hadr_message)+1, CHARINDEX(']', hadr_message)-CHARINDEX('[', hadr_message)-1) AS db_name
    FROM xe.hadr_trace WHERE event_time >= '${startUtc}' AND event_time <= '${endUtc}' AND hadr_message LIKE '%Reverting%'
    ORDER BY event_time
  `);
  for (const line of (revertResult||'').split(/\r?\n/)) {
    if (!line.trim()) continue;
    const p = line.split('|').map(s => s.trim());
    if (p.length < 4) continue;
    const [host, utc, phase, db] = p;
    if (!dbData[db]) dbData[db] = { ag: dbAgMap[db] || '?' };
    if (phase === 'begin') dbData[db][`revert_begin_${host}`] = utcToLocal(utc);
    else dbData[db][`revert_end_${host}`] = utcToLocal(utc);
  }

  // Build table
  const sorted = Object.entries(dbData)
    .filter(([_, d]) => Object.keys(d).length > 1)
    .sort((a, b) => (a[1].ag||'').localeCompare(b[1].ag||'') || a[0].localeCompare(b[0]));

  if (sorted.length === 0) {
    html += `<p>No DB-level events in this window.</p>\n`;
  } else {
    html += `<table>
<tr><th>AG</th><th>Database</th><th>${h0s} Direction</th><th>${h0s} DTC</th><th>${h0s} Kill</th><th>${h0s} Starting</th><th>${h0s} Recovery</th><th>${h0s} Revert</th><th>${h0s} Resync</th><th>${h0s} Result</th><th>${h1s} Direction</th><th>${h1s} Result</th><th>NQ Rollback</th></tr>\n`;

    let lastAg = '', stuckCount = 0, okCount = 0;
    for (const [db, d] of sorted) {
      if (d.ag !== lastAg) { lastAg = d.ag; html += `<tr class="sep"><td colspan="13"></td></tr>\n`; }

      // Host 0
      const r0 = d[`resolving_${h0}`];
      let dir0 = '-', dtc0 = '-', kill0 = '-', start0 = '-', recov0 = '-', revert0 = '-', resync0 = '-', res0 = '-';
      if (r0) {
        dir0 = `${r0.from}→RESOLV`;
        if (d[`dtc_init_${h0}`]) dtc0 = d[`dtc_init_${h0}`].substring(11,19);
        if (d[`kills_${h0}`]) kill0 = `×${d[`kills_${h0}`]}`;
        if (d[`startup_${h0}`]) start0 = d[`startup_${h0}`].substring(11,19);
        if (d[`recovery_${h0}`]) recov0 = d[`recovery_${h0}`].substring(11,19);
        if (d[`revert_begin_${h0}`] && d[`revert_end_${h0}`]) {
          const dur = ((new Date(d[`revert_end_${h0}`].replace(' ','T')+'Z') - new Date(d[`revert_begin_${h0}`].replace(' ','T')+'Z')) / 1000).toFixed(0);
          revert0 = `${dur}s ✅`;
        } else if (d[`revert_begin_${h0}`]) revert0 = 'begin';
        if (d[`resync_${h0}`]) resync0 = d[`resync_${h0}`].substring(11,19);

        if (d[`primary_${h0}`]) { res0 = '→PRIMARY ✅'; okCount++; }
        else if (d[`secondary_${h0}`]) {
          const gap = new Date(d[`secondary_${h0}`].replace(' ','T')+'Z') - new Date(r0.ts.replace(' ','T')+'Z');
          res0 = gap < 300000 ? '→SEC ✅' : '→SEC(shut)';
          okCount++;
        }
        else { res0 = 'STUCK ❌'; stuckCount++; }
      } else { okCount++; }

      // Host 1
      const r1 = d[`resolving_${h1}`];
      let dir1 = '-', res1 = '-';
      if (r1) {
        dir1 = `${r1.from}→RESOLV`;
        if (d[`primary_${h1}`]) res1 = '→PRIMARY ✅';
        else if (d[`secondary_${h1}`]) res1 = '→SEC ✅';
        else res1 = 'STUCK ❌';
      }

      // NQ
      let nq = '-';
      if (d.nonqual) nq = `×${d.nonqual.count}`;

      const rowClass = res0.includes('STUCK') ? 'stuck' : (res0.includes('✅') ? 'ok' : '');
      html += `<tr class="${rowClass}"><td>${d.ag}</td><td><strong>${db}</strong></td><td>${dir0}</td><td>${dtc0}</td><td>${kill0}</td><td>${start0}</td><td>${recov0}</td><td>${revert0}</td><td>${resync0}</td><td>${res0}</td><td>${dir1}</td><td>${res1}</td><td>${nq}</td></tr>\n`;
    }
    html += `</table>\n`;
    html += `<p><strong>Summary:</strong> ${sorted.length} DBs — <span style="color:var(--green)">${okCount} recovered</span>, <span style="color:var(--red)">${stuckCount} stuck</span></p>\n`;
  }

  // Nonqual detail
  const nqDbs = sorted.filter(([_, d]) => d.nonqual);
  if (nqDbs.length > 0) {
    html += `<h3>${sectionNum}.4 Nonqualified Rollback Detail</h3>\n<pre>`;
    for (const [db, d] of nqDbs) {
      html += `${db.padEnd(22)} ${d.nonqual.first.substring(11,19)} — ${d.nonqual.last.substring(11,19)}  ×${d.nonqual.count}\n`;
    }
    html += `</pre>\n`;
  }

  // Remote harden summary
  const rhEvents = windowEvents.filter(e => e.category === 'remote_harden');
  if (rhEvents.length > 0) {
    const rhDbs = new Set();
    rhEvents.forEach(e => { const m = e.detail.match(/database '([^']+)'/); if (m) rhDbs.add(m[1]); });
    html += `<div class="section"><strong>Remote Harden Failed:</strong> ${rhEvents.length} events, ${rhDbs.size} DBs<br>
First: ${rhEvents[0].local_ts.substring(11,19)} Last: ${rhEvents[rhEvents.length-1].local_ts.substring(11,19)}</div>\n`;
  }

  sectionNum++;
}

html += `\n</body>\n</html>`;

// Save
const reportsDir = path.join(path.dirname(caseDir), 'sqlcsi', 'reports');
// Try workspace reports/ first, fallback to case_dir
let outDir = 'reports';
if (!fs.existsSync(outDir)) { outDir = caseDir; }
const outPath = path.join(outDir, `${caseId}_ag_failover_report.html`);
fs.writeFileSync(outPath, html);
console.log(`Report saved to: ${outPath}`);
console.log(`Sections: ${sectionNum - 1} (${incidents.incidents.length} incidents)`);

function esc(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
