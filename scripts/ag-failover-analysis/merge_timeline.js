// scripts/ag-failover-analysis/merge_timeline.js
// Step 5: Merge ERRORLOG events + XEvent data into unified chronological timeline
//
// Usage: node scripts/ag-failover-analysis/merge_timeline.js <case_dir> <sql_server> <utc_offset>
// Example: node scripts/ag-failover-analysis/merge_timeline.js C:\Temp\2605110030000091 localhost 8
//
// Prereq: ag_schema.json, ag_errorlog_events.json, ag_{case_id} database with XEvent data
// Output: <case_dir>/merged_timeline.json, <case_dir>/merged_timeline.txt

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const args = process.argv.slice(2);
if (args.length < 3) {
  console.error('Usage: node merge_timeline.js <case_dir> <sql_server> <utc_offset_hours>');
  process.exit(1);
}

const caseDir = args[0];
const sqlServer = args[1];
const utcOffset = parseInt(args[2]);
const caseId = path.basename(caseDir);
const dbName = `ag_${caseId}`;

const schema = JSON.parse(fs.readFileSync(path.join(caseDir, 'ag_schema.json'), 'utf8'));
const errorlogData = JSON.parse(fs.readFileSync(path.join(caseDir, 'ag_errorlog_events.json'), 'utf8'));

// --- Build db_id → db_name map per host ---
const dbIdMap = {};
for (const key of ['old_primary', 'new_primary']) {
  const r = schema[key];
  if (!r) continue;
  dbIdMap[r.host] = {};
  for (const db of r.databases) {
    dbIdMap[r.host][db.id] = db.name;
  }
}

// --- Helper: UTC ↔ local ---
function utcToLocal(utcTs) {
  const d = new Date(utcTs.replace(' ', 'T') + 'Z');
  d.setHours(d.getHours() + utcOffset);
  return d.toISOString().replace('T', ' ').replace('Z', '').substring(0, 23);
}
function localToUtc(localTs) {
  const d = new Date(localTs.replace(' ', 'T') + 'Z');
  d.setHours(d.getHours() - utcOffset);
  return d.toISOString().replace('T', ' ').replace('Z', '').substring(0, 23);
}

// --- Helper: run SQL query via temp file ---
let tmpCounter = 0;
function sqlQuery(query) {
  const tmpFile = path.join(caseDir, `_tmp_query_${tmpCounter++}.sql`);
  fs.writeFileSync(tmpFile, `SET NOCOUNT ON;\n${query}`);
  const cmd = `sqlcmd -S ${sqlServer} -E -d ${dbName} -W -s "|" -h -1 -i "${tmpFile}"`;
  try {
    const result = execSync(cmd, { encoding: 'utf8', maxBuffer: 100 * 1024 * 1024 }).trim();
    fs.unlinkSync(tmpFile);
    return result;
  } catch (e) {
    console.error('SQL error:', e.stderr?.substring(0, 300));
    try { fs.unlinkSync(tmpFile); } catch(_) {}
    return '';
  }
}

// --- Step 1: Get ERRORLOG events (already in local time) ---
console.log('Loading ERRORLOG events...');
const errorlogEvents = errorlogData.all_events_sorted.map(ev => ({
  local_ts: ev.timestamp,
  host: ev.host,
  source: 'ERRORLOG',
  category: categorizeErrorlog(ev.message),
  detail: ev.message.substring(0, 300),
  spid: ev.spid
}));
console.log(`  ERRORLOG: ${errorlogEvents.length} events`);

// --- Step 2: Get XEvent data from SQL (UTC, convert to local) ---
console.log('Querying XEvent data...');

// Determine time range from ERRORLOG
const firstTs = errorlogData.all_events_sorted[0]?.timestamp;
const lastTs = errorlogData.all_events_sorted[errorlogData.all_events_sorted.length - 1]?.timestamp;
const startUtc = localToUtc(firstTs);
const endUtc = localToUtc(lastTs);
console.log(`  Time range: ${firstTs} — ${lastTs} (local)`);
console.log(`              ${startUtc} — ${endUtc} (UTC)`);

// Query each XEvent table
const xeEvents = [];

// hadr_replica_state
const repResult = sqlQuery(`
  SELECT host + '|' + CONVERT(VARCHAR(23), event_time, 121) + '|hadr_replica_state|' +
    ISNULL(ag_name,'') + ': ' + ISNULL(previous_state,'') + ' -> ' + ISNULL(current_state,'')
  FROM xe.hadr_replica_state
  WHERE event_time >= '${startUtc}' AND event_time <= '${endUtc}'
  ORDER BY event_time
`);
parseXeRows(repResult, xeEvents);

// hadr_manager_state
const mgrResult = sqlQuery(`
  SELECT host + '|' + CONVERT(VARCHAR(23), event_time, 121) + '|hadr_manager_state|' + ISNULL(current_state,'')
  FROM xe.hadr_manager_state
  WHERE event_time >= '${startUtc}' AND event_time <= '${endUtc}'
  ORDER BY event_time
`);
parseXeRows(mgrResult, xeEvents);

// hadr_sync_state (resolve db_id to db_name in JS)
const syncResult = sqlQuery(`
  SELECT host + '|' + CONVERT(VARCHAR(23), event_time, 121) + '|hadr_sync_state|' +
    CAST(database_id AS VARCHAR) + '|' + ISNULL(sync_state,'') + '|' + ISNULL(commit_policy,'')
  FROM xe.hadr_sync_state
  WHERE event_time >= '${startUtc}' AND event_time <= '${endUtc}'
  ORDER BY event_time
`);
for (const line of (syncResult || '').split(/\r?\n/)) {
  if (!line.trim()) continue;
  const parts = line.split('|');
  if (parts.length < 6) continue;
  const host = parts[0].trim();
  const utcTs = parts[1].trim();
  const dbId = parseInt(parts[3]);
  const dbName2 = dbIdMap[host]?.[dbId] || `db_id_${dbId}`;
  const sync = parts[4].trim();
  const policy = parts[5].trim();
  xeEvents.push({
    local_ts: utcToLocal(utcTs),
    host,
    source: 'XEvent',
    category: 'hadr_sync_state',
    detail: `${dbName2} (id=${dbId}) sync=${sync} policy=${policy}`
  });
}

// hadr_trace — Reverting events only
const revertResult = sqlQuery(`
  SELECT host + '|' + CONVERT(VARCHAR(23), event_time, 121) + '|hadr_trace_revert|' +
    LEFT(hadr_message, 200)
  FROM xe.hadr_trace
  WHERE event_time >= '${startUtc}' AND event_time <= '${endUtc}'
    AND hadr_message LIKE '%Reverting%'
  ORDER BY event_time
`);
parseXeRows(revertResult, xeEvents);

// hadr_ddl
const ddlResult = sqlQuery(`
  SELECT host + '|' + CONVERT(VARCHAR(23), event_time, 121) + '|hadr_ddl|' +
    ISNULL(ddl_action,'') + ' ' + ISNULL(ddl_phase,'') + ' ' + LEFT(ISNULL(statement,''), 100)
  FROM xe.hadr_ddl
  WHERE event_time >= '${startUtc}' AND event_time <= '${endUtc}'
  ORDER BY event_time
`);
parseXeRows(ddlResult, xeEvents);

// SQLDIAG: info_message
const sqldiagInfoResult = sqlQuery(`
  SELECT host + '|' + CONVERT(VARCHAR(23), event_time, 121) + '|sqldiag_info|' +
    ISNULL(message, '')
  FROM xe.sqldiag_info
  WHERE event_time >= '${startUtc}' AND event_time <= '${endUtc}'
  ORDER BY event_time
`);
if (sqldiagInfoResult) parseXeRows(sqldiagInfoResult, xeEvents);

// SQLDIAG: availability_group_state_change
const sqldiagAgResult = sqlQuery(`
  SELECT host + '|' + CONVERT(VARCHAR(23), event_time, 121) + '|sqldiag_ag_state|' +
    ISNULL(ag_name,'') + ' target=' + ISNULL(target_state,'') + ' failure=' + ISNULL(failure_condition,'')
  FROM xe.sqldiag_ag_state
  WHERE event_time >= '${startUtc}' AND event_time <= '${endUtc}'
  ORDER BY event_time
`);
if (sqldiagAgResult) parseXeRows(sqldiagAgResult, xeEvents);

// SQLDIAG: diagnostics state transitions only (not every 20s clean)
const sqldiagDiagResult = sqlQuery(`
  ;WITH ordered AS (
    SELECT host, event_time, component, state,
      LAG(state) OVER (PARTITION BY host, component ORDER BY event_time) AS prev_state
    FROM xe.diagnostics
  )
  SELECT host + '|' + CONVERT(VARCHAR(23), event_time, 121) + '|sqldiag_diag|' +
    component + ' ' + ISNULL(prev_state,'(start)') + ' -> ' + state
  FROM ordered
  WHERE event_time >= '${startUtc}' AND event_time <= '${endUtc}'
    AND (state <> ISNULL(prev_state, '') OR prev_state IS NULL)
  ORDER BY event_time
`);
if (sqldiagDiagResult) parseXeRows(sqldiagDiagResult, xeEvents);

console.log(`  XEvent: ${xeEvents.length} events`);

// --- Step 3: Merge and sort by local timestamp ---
const merged = [...errorlogEvents, ...xeEvents];
merged.sort((a, b) => a.local_ts.localeCompare(b.local_ts));
console.log(`  Merged: ${merged.length} total events`);

// --- Step 4: Save ---
// JSON
const jsonOut = {
  case_id: caseId,
  utc_offset: utcOffset,
  errorlog_count: errorlogEvents.length,
  xevent_count: xeEvents.length,
  total_count: merged.length,
  events: merged
};
const jsonPath = path.join(caseDir, 'merged_timeline.json');
fs.writeFileSync(jsonPath, JSON.stringify(jsonOut, null, 2));

// Text
const txtLines = merged.map(ev => {
  const src = ev.source === 'ERRORLOG' ? 'EL' : 'XE';
  const hostShort = ev.host.slice(-4);
  return `[${hostShort}] ${ev.local_ts} [${src}] ${ev.category.padEnd(22)} ${ev.detail}`;
});
const txtPath = path.join(caseDir, 'merged_timeline.txt');
fs.writeFileSync(txtPath, txtLines.join('\n'));

console.log(`\nSaved: ${jsonPath}`);
console.log(`Saved: ${txtPath}`);

// Print summary by source and category
console.log('\n=== Event Summary ===');
const summary = {};
for (const ev of merged) {
  const key = `${ev.source}|${ev.category}`;
  summary[key] = (summary[key] || 0) + 1;
}
for (const [key, count] of Object.entries(summary).sort((a, b) => b[1] - a[1])) {
  const [src, cat] = key.split('|');
  console.log(`  ${src.padEnd(8)} ${cat.padEnd(25)} ${count}`);
}

// --- Helpers ---
function parseXeRows(text, arr) {
  if (!text) return;
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const i1 = line.indexOf('|');
    const i2 = line.indexOf('|', i1 + 1);
    const i3 = line.indexOf('|', i2 + 1);
    if (i1 < 0 || i2 < 0 || i3 < 0) continue;
    const host = line.substring(0, i1).trim();
    const utcTs = line.substring(i1 + 1, i2).trim();
    const category = line.substring(i2 + 1, i3).trim();
    const detail = line.substring(i3 + 1).trim();
    arr.push({
      local_ts: utcToLocal(utcTs),
      host,
      source: 'XEvent',
      category,
      detail
    });
  }
}

function categorizeErrorlog(msg) {
  if (/availability replica.*has changed from/i.test(msg)) return 'ag_role_change';
  if (/changing roles from/i.test(msg)) return 'db_role_change';
  if (/DTC|MSDTC|Distributed Transaction|resource manager/i.test(msg)) return 'dtc';
  if (/ABORT_AFTER_WAIT|was killed/i.test(msg)) return 'abort_kill';
  if (/Nonqualified/i.test(msg)) return 'nonqual_rollback';
  if (/Remote harden/i.test(msg)) return 'remote_harden';
  if (/Starting up database/i.test(msg)) return 'starting_up';
  if (/Recovery completed for database/i.test(msg)) return 'recovery_completed';
  if (/Recovery of database/i.test(msg)) return 'recovery_progress';
  if (/resynchronize/i.test(msg)) return 'resync';
  if (/connection with.*database established/i.test(msg)) return 'conn_established';
  if (/connection with.*database terminated/i.test(msg)) return 'conn_terminated';
  if (/ADR VersionCleaner|Error 22006/i.test(msg)) return 'adr_version';
  if (/WSFC|quorum|error.*(41005|41034|41143|41144|41161)|error code 1722|failed state.*41\d{3}|Failed to obtain the.*cluster resource|Failed to validate the.*CRC|lease.*expired/i.test(msg)) return 'wsfc_error';
  if (/SQL Server is terminating/i.test(msg)) return 'shutdown';
  if (/Error \d+/i.test(msg)) return 'error';
  return 'other_ag';
}
