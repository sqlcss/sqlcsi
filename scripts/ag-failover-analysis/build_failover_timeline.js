// scripts/ag-failover-analysis/build_failover_timeline.js
// Step 3: Detect failover incidents and build per-incident timeline
//
// Usage: node scripts/ag-failover-analysis/build_failover_timeline.js <case_dir>
// Prereq: ag_schema.json and ag_errorlog_events.json must exist (run Step 1 & 2 first)
// Output: <case_dir>/failover_incidents.json

const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
if (args.length < 1) {
  console.error('Usage: node build_failover_timeline.js <case_dir>');
  process.exit(1);
}
const caseDir = args[0];

const schema = JSON.parse(fs.readFileSync(path.join(caseDir, 'ag_schema.json'), 'utf8'));
const events = JSON.parse(fs.readFileSync(path.join(caseDir, 'ag_errorlog_events.json'), 'utf8'));

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

// --- Build db_name → ag map (from old_primary, fallback new_primary) ---
const dbAgMap = {};
for (const key of ['old_primary', 'new_primary']) {
  for (const db of schema[key].databases) {
    if (!dbAgMap[db.name]) dbAgMap[db.name] = db.ag;
  }
}

// --- Step 1: Detect failover incidents from AG role changes ---
// An AG role change to RESOLVING marks the start of a failover.
// Cluster changes within 30 seconds of each other belong to the same incident.
const agChanges = events.categories.ag_role_change;
const incidents = [];
let currentIncident = null;

for (const ev of agChanges) {
  const m = ev.message.match(/availability group '([^']+)'.*from '([^']+)' to '([^']+)'/);
  if (!m) continue;
  const agName = m[1];
  const fromState = m[2];
  const toState = m[3];

  // Only RESOLVING transitions mark a new failover
  if (!toState.includes('RESOLVING')) {
    // Attach recovery events to existing incident
    if (currentIncident) {
      currentIncident.ag_events.push({ ...ev, ag: agName, from: fromState, to: toState });
      currentIncident.end_ts = ev.timestamp;
    }
    continue;
  }

  // Check if this belongs to current incident (within 120s to cover cross-host delay)
  if (currentIncident) {
    const gap = tsToMs(ev.timestamp) - tsToMs(currentIncident.start_ts);
    if (gap < 120000) {
      currentIncident.ag_events.push({ ...ev, ag: agName, from: fromState, to: toState });
      if (!currentIncident.ags_affected.includes(agName)) {
        currentIncident.ags_affected.push(agName);
      }
      continue;
    }
  }

  // New incident
  currentIncident = {
    id: `FO${incidents.length + 1}`,
    start_ts: ev.timestamp,
    end_ts: ev.timestamp,
    ags_affected: [agName],
    ag_events: [{ ...ev, ag: agName, from: fromState, to: toState }],
  };
  incidents.push(currentIncident);
}

// --- Step 2: Reclassify shutdown-triggered RESOLVING as shutdown event ---
const shutdownEvent = events.all_events_sorted.find(e => /SQL Server is terminating/i.test(e.message));
if (shutdownEvent) {
  const shutdownMs = tsToMs(shutdownEvent.timestamp);
  for (const inc of incidents) {
    const incMs = tsToMs(inc.start_ts);
    if (Math.abs(incMs - shutdownMs) < 10000) {
      inc.type = 'shutdown';
      inc.shutdown_host = shutdownEvent.host;
    }
  }
}

// Label real failovers vs shutdown
let foNum = 1;
for (const inc of incidents) {
  if (inc.type === 'shutdown') {
    inc.id = 'SHUTDOWN';
  } else {
    inc.type = 'failover';
    inc.id = `FO${foNum++}`;
  }
}

// --- Step 3: Determine end time for each incident ---
// End = next incident start (events between incidents belong to the earlier one)
// For the last incident, extend to shutdown or shutdown + 5 min
for (let i = 0; i < incidents.length; i++) {
  if (i < incidents.length - 1) {
    inc = incidents[i];
    inc.end_ts = addMinutes(incidents[i + 1].start_ts, -0.1);
  }
}

// For the last real incident, extend to shutdown event time
const lastInc = incidents[incidents.length - 1];
if (shutdownEvent && shutdownEvent.timestamp > lastInc.start_ts) {
  lastInc.end_ts = shutdownEvent.timestamp;
} else {
  lastInc.end_ts = addMinutes(lastInc.start_ts, 60);
}

console.log(`\nDetected ${incidents.filter(i => i.type === 'failover').length} failover incidents, ${incidents.filter(i => i.type === 'shutdown').length} shutdown event:`);
incidents.forEach(inc => {
  const label = inc.type === 'shutdown' ? `SHUTDOWN (${inc.shutdown_host})` : inc.id;
  console.log(`  ${label.padEnd(20)} ${inc.start_ts} — ${inc.end_ts}  AGs: ${inc.ags_affected.join(', ')}`);
});

// --- Step 3: For each incident, gather all events and build detail ---
for (const inc of incidents) {
  const windowEvents = events.all_events_sorted.filter(
    e => e.timestamp >= inc.start_ts && e.timestamp <= inc.end_ts
  );

  // Categorize events
  const cat = {
    ag_role_change: [], db_to_resolving: [], db_to_primary: [], db_to_secondary: [],
    dtc_init: [], dtc_release: [], dtc_other: [],
    abort_kill: [], nonqual_rollback: [], remote_harden: [],
    starting_up: [], resync: [], connection_established: [], connection_terminated: [],
    errors: [], other: []
  };

  for (const ev of windowEvents) {
    const msg = ev.message;
    if (/availability replica.*has changed from/i.test(msg)) {
      cat.ag_role_change.push(ev);
    } else if (/changing roles from.*to "RESOLVING"/i.test(msg)) {
      cat.db_to_resolving.push(ev);
    } else if (/changing roles from.*to "PRIMARY"/i.test(msg)) {
      cat.db_to_primary.push(ev);
    } else if (/changing roles from.*to "SECONDARY"/i.test(msg)) {
      cat.db_to_secondary.push(ev);
    } else if (/Initializing.*resource manager.*for database/i.test(msg)) {
      cat.dtc_init.push(ev);
    } else if (/resource manager.*has been released/i.test(msg)) {
      cat.dtc_release.push(ev);
    } else if (/DTC|MSDTC|Distributed Transaction|resource manager/i.test(msg)) {
      cat.dtc_other.push(ev);
    } else if (/ABORT_AFTER_WAIT|was killed/i.test(msg)) {
      cat.abort_kill.push(ev);
    } else if (/Nonqualified/i.test(msg)) {
      cat.nonqual_rollback.push(ev);
    } else if (/Remote harden/i.test(msg)) {
      cat.remote_harden.push(ev);
    } else if (/Starting up database/i.test(msg)) {
      cat.starting_up.push(ev);
    } else if (/resynchronize/i.test(msg)) {
      cat.resync.push(ev);
    } else if (/connection with.*database established/i.test(msg)) {
      cat.connection_established.push(ev);
    } else if (/connection with.*database terminated/i.test(msg)) {
      cat.connection_terminated.push(ev);
    } else if (/Error \d+|terminating|shutdown/i.test(msg)) {
      cat.errors.push(ev);
    } else {
      cat.other.push(ev);
    }
  }

  // --- Build per-AG direction summary ---
  const agDirections = {};
  for (const ev of cat.ag_role_change) {
    const m = ev.message.match(/availability group '([^']+)'.*from '([^']+)' to '([^']+)'/);
    if (!m) continue;
    const ag = m[1];
    if (!agDirections[ag]) agDirections[ag] = [];
    agDirections[ag].push({ host: ev.host, from: m[2], to: m[3], ts: ev.timestamp });
  }

  // --- Build per-DB status table ---
  const dbStatus = {};
  // DB → RESOLVING
  for (const ev of cat.db_to_resolving) {
    const m = ev.message.match(/database "([^"]+)".*from "([^"]+)" to "RESOLVING"/);
    if (!m) continue;
    const dbName = m[1];
    const fromRole = m[2];
    if (!dbStatus[dbName]) dbStatus[dbName] = { ag: dbAgMap[dbName] || '?' };
    dbStatus[dbName][`to_resolving_${ev.host}`] = { ts: ev.timestamp, from: fromRole };
  }
  // DB → PRIMARY
  for (const ev of cat.db_to_primary) {
    const m = ev.message.match(/database "([^"]+)"/);
    if (!m) continue;
    if (!dbStatus[m[1]]) dbStatus[m[1]] = { ag: dbAgMap[m[1]] || '?' };
    dbStatus[m[1]][`to_primary_${ev.host}`] = ev.timestamp;
  }
  // DB → SECONDARY
  for (const ev of cat.db_to_secondary) {
    const m = ev.message.match(/database "([^"]+)"/);
    if (!m) continue;
    if (!dbStatus[m[1]]) dbStatus[m[1]] = { ag: dbAgMap[m[1]] || '?' };
    dbStatus[m[1]][`to_secondary_${ev.host}`] = ev.timestamp;
  }
  // Starting up
  for (const ev of cat.starting_up) {
    const m = ev.message.match(/database '([^']+)'/);
    if (!m) continue;
    if (!dbStatus[m[1]]) dbStatus[m[1]] = { ag: dbAgMap[m[1]] || '?' };
    dbStatus[m[1]][`starting_up_${ev.host}`] = ev.timestamp;
  }
  // Resync
  for (const ev of cat.resync) {
    const m = ev.message.match(/database '([^']+)'/);
    if (!m) continue;
    if (!dbStatus[m[1]]) dbStatus[m[1]] = { ag: dbAgMap[m[1]] || '?' };
    dbStatus[m[1]][`resync_${ev.host}`] = ev.timestamp;
  }
  // DTC release
  for (const ev of cat.dtc_release) {
    const m = ev.message.match(/resource manager \[([^\]]*)\]/i);
    // DTC release uses RM name/GUID, hard to map to DB. Skip for now.
  }
  // DTC init — per DB
  for (const ev of cat.dtc_init) {
    const m = ev.message.match(/for database '([^']+)'/);
    if (!m) continue;
    if (!dbStatus[m[1]]) dbStatus[m[1]] = { ag: dbAgMap[m[1]] || '?' };
    dbStatus[m[1]][`dtc_init_${ev.host}`] = ev.timestamp;
  }
  // ABORT Kill — map db_id to db_name
  const killsByDb = {};
  for (const ev of cat.abort_kill) {
    const m = ev.message.match(/database_id = (\d+)/);
    if (!m) continue;
    const dbId = parseInt(m[1]);
    const dbName = dbIdMap[ev.host]?.[dbId] || `db_id_${dbId}`;
    if (!killsByDb[dbName]) killsByDb[dbName] = { count: 0, first: ev.timestamp, host: ev.host };
    killsByDb[dbName].count++;
  }
  for (const [dbName, info] of Object.entries(killsByDb)) {
    if (!dbStatus[dbName]) dbStatus[dbName] = { ag: dbAgMap[dbName] || '?' };
    dbStatus[dbName][`abort_kill_${info.host}`] = { ts: info.first, count: info.count };
  }
  // Nonqualified rollback — summary per DB per HOST
  const nonqualByDbHost = {};  // key: "db|host"
  for (const ev of cat.nonqual_rollback) {
    const m = ev.message.match(/database (\S+)/);
    if (!m) continue;
    const db = m[1];
    const host = ev.host || 'unknown';
    const key = `${db}|${host}`;
    if (!nonqualByDbHost[key]) nonqualByDbHost[key] = { count: 0, first: ev.timestamp, last: ev.timestamp, spid: ev.spid, host };
    nonqualByDbHost[key].count++;
    nonqualByDbHost[key].last = ev.timestamp;
  }
  for (const [key, info] of Object.entries(nonqualByDbHost)) {
    const [db] = key.split('|');
    if (!dbStatus[db]) dbStatus[db] = { ag: dbAgMap[db] || '?' };
    dbStatus[db][`nonqual_rollback_${info.host}`] = { count: info.count, first: info.first, last: info.last, spid: info.spid };
    // Also keep the legacy key (without host) for backward compat with old reports
    if (!dbStatus[db].nonqual_rollback) {
      dbStatus[db].nonqual_rollback = { count: info.count, first: info.first, last: info.last, spid: info.spid };
    }
  }

  // Store in incident
  inc.event_counts = Object.fromEntries(Object.entries(cat).map(([k, v]) => [k, v.length]));
  inc.ag_directions = agDirections;
  inc.db_status = dbStatus;
  inc.total_events = windowEvents.length;

  // --- Print ---
  console.log(`\n${'='.repeat(80)}`);
  console.log(`${inc.id}: ${inc.start_ts} — ${inc.end_ts}`);
  console.log(`AGs: ${inc.ags_affected.join(', ')}   Total events: ${inc.total_events}`);
  console.log('='.repeat(80));

  // Event counts
  console.log('\n  Event Counts:');
  for (const [k, v] of Object.entries(inc.event_counts)) {
    if (v > 0) console.log(`    ${k.padEnd(30)} ${v}`);
  }

  // AG directions
  console.log('\n  AG Role Transitions:');
  for (const [ag, transitions] of Object.entries(agDirections)) {
    for (const t of transitions) {
      console.log(`    [${t.host.slice(-4)}] ${t.ts}  ${ag.padEnd(28)} ${t.from} → ${t.to}`);
    }
  }

  // DB status table — group by AG, show key columns
  console.log('\n  Per-DB Status:');
  const hosts = [schema.old_primary.host, schema.new_primary.host];
  const h0 = hosts[0].slice(-4);
  const h1 = hosts[1].slice(-4);
  console.log(`  ${'DB'.padEnd(22)} ${'AG'.padEnd(18)} ${h0+' direction'.padEnd(26)} ${h0+' result'.padEnd(15)} ${h1+' direction'.padEnd(26)} ${h1+' result'.padEnd(15)}`);
  console.log('  ' + '-'.repeat(110));

  const sortedDbs = Object.entries(dbStatus).sort((a, b) => {
    const agCmp = (a[1].ag || '').localeCompare(b[1].ag || '');
    return agCmp !== 0 ? agCmp : a[0].localeCompare(b[0]);
  });

  let lastAg = '';
  for (const [db, st] of sortedDbs) {
    if (st.ag !== lastAg) { lastAg = st.ag; console.log(`  [${st.ag}]`); }

    // Determine direction and result per host
    let dir0 = '-', res0 = '-', dir1 = '-', res1 = '-';

    const r0 = st[`to_resolving_${hosts[0]}`];
    const r1 = st[`to_resolving_${hosts[1]}`];

    if (r0) {
      dir0 = `${r0.from}→RESOLVING`;
      if (st[`to_primary_${hosts[0]}`]) { res0 = '→PRIMARY ✅'; }
      else if (st[`to_secondary_${hosts[0]}`]) {
        const secTs = st[`to_secondary_${hosts[0]}`];
        // Check if secondary happened quickly or only at shutdown
        const gap = tsToMs(secTs) - tsToMs(r0.ts);
        res0 = gap < 300000 ? '→SEC ✅' : '→SEC (shutdown)';
      }
      else { res0 = 'STUCK ❌'; }
    }

    if (r1) {
      dir1 = `${r1.from}→RESOLVING`;
      if (st[`to_primary_${hosts[1]}`]) { res1 = '→PRIMARY ✅'; }
      else if (st[`to_secondary_${hosts[1]}`]) {
        const secTs = st[`to_secondary_${hosts[1]}`];
        const gap = tsToMs(secTs) - tsToMs(r1.ts);
        res1 = gap < 300000 ? '→SEC ✅' : '→SEC (shutdown)';
      }
      else { res1 = 'STUCK ❌'; }
    }

    // Add nonqual indicator
    if (st.nonqual_rollback) {
      res0 += ` NQ×${st.nonqual_rollback.count}`;
    }

    console.log(`  ${db.padEnd(22)} ${(st.ag||'?').padEnd(18)} ${dir0.padEnd(26)} ${res0.padEnd(15)} ${dir1.padEnd(26)} ${res1.padEnd(15)}`);
  }

  // DTC summary
  if (cat.dtc_init.length > 0 || cat.dtc_release.length > 0) {
    console.log(`\n  DTC: ${cat.dtc_init.length} init, ${cat.dtc_release.length} release, ${cat.dtc_other.length} other`);
    cat.dtc_init.forEach(e => {
      const m = e.message.match(/for database '([^']+)'/);
      console.log(`    [${e.host.slice(-4)}] INIT  ${m ? m[1] : '?'}`);
    });
  }

  // Nonqual summary
  if (Object.keys(nonqualByDbHost).length > 0) {
    console.log('\n  Nonqualified Rollback:');
    for (const [key, info] of Object.entries(nonqualByDbHost)) {
      const [db] = key.split('|');
      console.log(`    ${db.padEnd(20)} [${info.host}] ${info.first} — ${info.last}  ×${info.count}  (${info.spid})`);
    }
  }

  // Remote harden
  if (cat.remote_harden.length > 0) {
    const rhDbs = new Set();
    cat.remote_harden.forEach(e => { const m = e.message.match(/database '([^']+)'/); if (m) rhDbs.add(m[1]); });
    console.log(`\n  Remote Harden Failed: ${cat.remote_harden.length} events, ${rhDbs.size} DBs`);
    console.log(`    First: ${cat.remote_harden[0].timestamp}  Last: ${cat.remote_harden[cat.remote_harden.length - 1].timestamp}`);
  }
}

// --- Save output ---
const output = {
  case_dir: caseDir,
  hosts: { old_primary: schema.old_primary.host, new_primary: schema.new_primary.host },
  incidents: incidents.map(inc => ({
    id: inc.id,
    type: inc.type,
    shutdown_host: inc.shutdown_host || null,
    start_ts: inc.start_ts,
    end_ts: inc.end_ts,
    ags_affected: inc.ags_affected,
    total_events: inc.total_events,
    event_counts: inc.event_counts,
    ag_directions: inc.ag_directions,
    db_status: inc.db_status
  }))
};

const outPath = path.join(caseDir, 'failover_incidents.json');
fs.writeFileSync(outPath, JSON.stringify(output, null, 2));
console.log(`\nSaved to: ${outPath}`);

// --- Helpers ---
function tsToMs(ts) {
  // "2026-05-11 07:53:53.85" → ms since epoch
  return new Date(ts.replace(' ', 'T') + 'Z').getTime();
}

function addMinutes(ts, min) {
  const d = new Date(ts.replace(' ', 'T') + 'Z');
  d.setMinutes(d.getMinutes() + min);
  return d.toISOString().replace('T', ' ').replace('Z', '').substring(0, 23);
}
