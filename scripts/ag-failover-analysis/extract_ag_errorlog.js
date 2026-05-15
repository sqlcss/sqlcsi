// scripts/extract_ag_errorlog.js
// Extract AG-related events from ERRORLOG files, categorize, and save timeline
//
// Usage: node scripts/extract_ag_errorlog.js <case_dir> <target_date> <host1:file1> [host2:file2] ...
// Example: node scripts/extract_ag_errorlog.js C:/Temp/case123 2026-05-11 \
//          HKAZEPWDB0031:HKAZEPWDB0031/HKAZEPWDB0031_MSSQLSERVER_1033_ERRORLOG.1 \
//          HKAZEPWDB0011:HKAZEPWDB0011/HKAZEPWDB0011_MSSQLSERVER_1033_ERRORLOG
//
// If host:file args are omitted, auto-discovers ERRORLOG files in {case_dir}/{host}/ subdirs
// using ag_schema.json for host names.
//
// Output: <case_dir>/ag_errorlog_events.json, <case_dir>/ag_timeline.txt

const fs = require('fs');
const path = require('path');

// --- Args ---
const args = process.argv.slice(2);
if (args.length < 2) {
  console.error('Usage: node extract_ag_errorlog.js <case_dir> <target_date> [host1:file1] ...');
  console.error('  target_date format: YYYY-MM-DD');
  process.exit(1);
}
const caseDir = args[0];
const targetDate = args[1];

// Build list of errorlogs to parse
const errorlogs = [];
if (args.length > 2) {
  // Explicit host:file pairs
  for (let i = 2; i < args.length; i++) {
    const [host, relFile] = args[i].split(':');
    errorlogs.push({ host, file: path.join(caseDir, relFile) });
  }
} else {
  // Auto-discover from ag_schema.json
  const schemaPath = path.join(caseDir, 'ag_schema.json');
  if (!fs.existsSync(schemaPath)) {
    console.error('No host:file args and no ag_schema.json found. Run parse_alwayson_out.js first.');
    process.exit(1);
  }
  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
  for (const key of ['old_primary', 'new_primary']) {
    const host = schema[key]?.host;
    if (!host) continue;
    // Only look in {case_dir}/{host}/ subdirectory
    const hostDir = path.join(caseDir, host);
    if (fs.existsSync(hostDir) && fs.statSync(hostDir).isDirectory()) {
      for (const f of fs.readdirSync(hostDir)) {
        if (/ERRORLOG/i.test(f) && !f.includes('AlwaysOn')) {
          errorlogs.push({ host, file: path.join(hostDir, f) });
        }
      }
    }
  }
}

if (errorlogs.length === 0) {
  console.error('No ERRORLOG files found.');
  process.exit(1);
}
console.log(`Target date: ${targetDate}`);
console.log(`ERRORLOG files to parse: ${errorlogs.length}`);
errorlogs.forEach(e => console.log(`  ${e.host}: ${e.file}`));

// --- AG-related patterns ---
const AG_PATTERNS = [
  /availability.*(group|replica|database)/i,
  /AlwaysOn/i,
  /HADR/i,
  /changing roles/i,
  /RESOLVING/i,
  /Starting up database/i,
  /resynchronize/i,
  /Nonqualified transactions/i,
  /Remote harden/i,
  /ABORT_AFTER_WAIT/i,
  /was killed/i,
  /connection with.*database (established|terminated)/i,
  /Reverting/i,
  /Windows Server Failover Cluster/i,
  /WSFC/i,
  /quorum/i,
  /lease/i,
  /resource.*offline/i,
  /resource.*online/i,
  /node.*down/i,
  /Error.*1722/i,
  /DTC|MSDTC|Distributed Transaction/i,
  /resource manager/i,
  /Recovery completed/i,
  /Recovery of database/i,
  /redo thread/i,
  /Error 35/i,
  /Error 41/i,
  /Error 983/i,
  /Error 9642/i,
  /Error 3303/i,
  /Error 904/i,
  /Error 18456.*State 38/i,
  /Error 22006/i,
  /ADR VersionCleaner/i,
  /SQL Server is terminating/i,
  /SQL Server is starting/i,
  /system shutdown/i,
  /Service Broker|transport/i,
];

const SPID_LINE = /^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)\s+(\S+)\s+(.*)/;

// --- Read file with encoding detection ---
function readFileAuto(filePath) {
  const buf = fs.readFileSync(filePath);
  if (buf[0] === 0xFF && buf[1] === 0xFE) {
    console.log('  Encoding: UTF-16LE');
    return buf.toString('utf16le');
  }
  if (buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) {
    console.log('  Encoding: UTF-8 BOM');
    return buf.toString('utf8');
  }
  console.log('  Encoding: UTF-8');
  return buf.toString('utf8');
}

// --- Parse one ERRORLOG ---
function parseErrorlog(filePath, hostName) {
  console.log(`\nParsing ${hostName}: ${path.basename(filePath)}`);
  const content = readFileAuto(filePath);
  const lines = content.split(/\r?\n/);
  console.log(`  Total lines: ${lines.length}`);

  const events = [];
  let currentTs = null;
  let currentSpid = null;
  let currentMsg = null;
  let inTargetDate = false;
  let lineCount = 0;

  function flushEvent() {
    if (currentTs && currentMsg && inTargetDate) {
      for (const pat of AG_PATTERNS) {
        if (pat.test(currentMsg)) {
          events.push({
            timestamp: currentTs,
            spid: currentSpid,
            message: currentMsg.substring(0, 500),
            host: hostName
          });
          break;
        }
      }
    }
  }

  for (const line of lines) {
    const m = SPID_LINE.exec(line);
    if (m) {
      flushEvent();
      currentTs = m[1];
      currentSpid = m[2];
      currentMsg = m[3];
      inTargetDate = currentTs.startsWith(targetDate);
      lineCount++;
    } else if (currentMsg !== null && line.trim()) {
      currentMsg += ' ' + line.trim();
    }
  }
  flushEvent();

  console.log(`  Lines scanned: ${lineCount}, AG events on ${targetDate}: ${events.length}`);
  return events;
}

// --- Categorize ---
function categorize(allEvents) {
  const categories = {
    ag_role_change: [],
    db_role_change: [],
    wsfc_cluster: [],
    dtc: [],
    abort_kill: [],
    nonqual_rollback: [],
    remote_harden: [],
    starting_up: [],
    recovery_progress: [],
    recovery_completed: [],
    resync: [],
    conn_established: [],
    conn_terminated: [],
    adr_version: [],
    errors: [],
    other_ag: []
  };

  for (const ev of allEvents) {
    const msg = ev.message;
    if (/availability replica.*has changed from/i.test(msg)) {
      categories.ag_role_change.push(ev);
    } else if (/changing roles from/i.test(msg)) {
      categories.db_role_change.push(ev);
    } else if (/WSFC|quorum|error.*(41005|41034|41143|41144|41161)|error code 1722|failed state.*41\d{3}|Failed to obtain the.*cluster resource|Failed to validate the.*CRC|lease.*expired/i.test(msg)) {
      categories.wsfc_cluster.push(ev);
    } else if (/DTC|MSDTC|Distributed Transaction|resource manager/i.test(msg)) {
      categories.dtc.push(ev);
    } else if (/ABORT_AFTER_WAIT|was killed/i.test(msg)) {
      categories.abort_kill.push(ev);
    } else if (/Nonqualified/i.test(msg)) {
      categories.nonqual_rollback.push(ev);
    } else if (/Remote harden/i.test(msg)) {
      categories.remote_harden.push(ev);
    } else if (/Starting up database/i.test(msg)) {
      categories.starting_up.push(ev);
    } else if (/Recovery completed for database/i.test(msg)) {
      categories.recovery_completed.push(ev);
    } else if (/Recovery of database/i.test(msg)) {
      categories.recovery_progress.push(ev);
    } else if (/resynchronize/i.test(msg)) {
      categories.resync.push(ev);
    } else if (/connection with.*database established/i.test(msg)) {
      categories.conn_established.push(ev);
    } else if (/connection with.*database terminated/i.test(msg)) {
      categories.conn_terminated.push(ev);
    } else if (/ADR VersionCleaner|Error 22006/i.test(msg)) {
      categories.adr_version.push(ev);
    } else if (/Error \d+|terminating|shutdown|starting/i.test(msg)) {
      categories.errors.push(ev);
    } else {
      categories.other_ag.push(ev);
    }
  }
  return categories;
}

// --- Main ---
const allEvents = [];
for (const { host, file } of errorlogs) {
  allEvents.push(...parseErrorlog(file, host));
}
allEvents.sort((a, b) => a.timestamp.localeCompare(b.timestamp));

const categories = categorize(allEvents);

// Print summary
console.log('\n========================================');
console.log(`Total AG-related events on ${targetDate}: ${allEvents.length}`);
console.log('========================================\n');

for (const [cat, evts] of Object.entries(categories)) {
  if (evts.length === 0) continue;
  console.log(`--- ${cat} (${evts.length}) ---`);
  const show = evts.length > 20 ? [...evts.slice(0, 5), null, ...evts.slice(-3)] : evts;
  for (const ev of show) {
    if (!ev) { console.log(`  ... (${evts.length - 8} more) ...`); continue; }
    const shortMsg = ev.message.length > 150 ? ev.message.substring(0, 150) + '...' : ev.message;
    console.log(`  [${ev.host.slice(-4)}] ${ev.timestamp} ${ev.spid.padEnd(10)} ${shortMsg}`);
  }
  console.log('');
}

// Save
const output = {
  target_date: targetDate,
  total_events: allEvents.length,
  category_counts: Object.fromEntries(Object.entries(categories).map(([k, v]) => [k, v.length])),
  categories,
  all_events_sorted: allEvents
};

const jsonPath = path.join(caseDir, 'ag_errorlog_events.json');
fs.writeFileSync(jsonPath, JSON.stringify(output, null, 2));
console.log(`Saved to: ${jsonPath}`);

const timeline = allEvents.map(ev => `[${ev.host.slice(-4)}] ${ev.timestamp} ${ev.spid.padEnd(10)} ${ev.message}`);
const txtPath = path.join(caseDir, 'ag_timeline.txt');
fs.writeFileSync(txtPath, timeline.join('\n'));
console.log(`Saved timeline to: ${txtPath}`);

// --- Update ag_schema.json with DTC info from ERRORLOG ---
const schemaPath = path.join(caseDir, 'ag_schema.json');
if (fs.existsSync(schemaPath)) {
  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));

  // Extract per-DB DTC RM init events: "Initializing ... resource manager [...] for database 'X'"
  const dtcDbPattern = /Initializing.*resource manager \[([^\]]+)\] for database '([^']+)'/i;
  const dtcDbs = new Map(); // db_name → guid
  for (const ev of categories.dtc) {
    const m = dtcDbPattern.exec(ev.message);
    if (m) dtcDbs.set(m[2], m[1]);
  }

  if (dtcDbs.size > 0) {
    console.log(`\n--- DTC_SUPPORT detected for ${dtcDbs.size} databases ---`);

    // For each replica, mark databases with DTC and set AG-level dtc_support
    for (const replicaKey of ['old_primary', 'new_primary']) {
      const replica = schema[replicaKey];
      if (!replica) continue;
      const agDtcDbs = {}; // ag_name → [db_names]
      for (const db of replica.databases) {
        if (dtcDbs.has(db.name)) {
          db.dtc_rm_guid = dtcDbs.get(db.name);
          if (!agDtcDbs[db.ag]) agDtcDbs[db.ag] = [];
          agDtcDbs[db.ag].push(db.name);
        }
      }
      for (const [agName, dbs] of Object.entries(agDtcDbs)) {
        if (replica.ags[agName]) {
          replica.ags[agName].dtc_support = true;
          replica.ags[agName].dtc_db_count = dbs.length;
        }
      }
    }

    // Update summary
    if (schema.summary) {
      for (const ag of schema.summary.ags) {
        const agInfo = schema.old_primary?.ags[ag.name] || schema.new_primary?.ags[ag.name];
        if (agInfo) {
          ag.dtc_support = agInfo.dtc_support;
          ag.dtc_db_count = agInfo.dtc_db_count || 0;
        }
      }
    }

    fs.writeFileSync(schemaPath, JSON.stringify(schema, null, 2));
    console.log('Updated ag_schema.json with DTC info');

    for (const [db, guid] of dtcDbs) {
      console.log(`  ${db.padEnd(25)} DTC RM: ${guid}`);
    }
  }
}
