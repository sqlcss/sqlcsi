// scripts/parse_alwayson_out.js
// Parse AlwaysOn.OUT files to build AG → DB schema mapping
//
// Usage: node scripts/parse_alwayson_out.js <case_dir> <old_primary_host> <new_primary_host>
// Output: <case_dir>/ag_schema.json

const fs = require('fs');
const path = require('path');

// --- Args ---
const args = process.argv.slice(2);
if (args.length < 3) {
  console.error('Usage: node parse_alwayson_out.js <case_dir> <old_primary_host> <new_primary_host>');
  console.error('Example: node parse_alwayson_out.js C:/Temp/case123 HKAZEPWDB0031 HKAZEPWDB0011');
  process.exit(1);
}
const [caseDir, oldHost, newHost] = args;

// --- Fixed-width table parser ---
function parseFixedWidth(lines) {
  if (lines.length < 2) return [];
  const header = lines[0];
  const sep = lines[1];
  const cols = [];
  for (const m of sep.matchAll(/-+/g)) {
    cols.push({ start: m.index, end: m.index + m[0].length });
  }
  const colNames = cols.map(c => header.substring(c.start, c.end).trim());
  const rows = [];
  for (let i = 2; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim() || line.startsWith('===') || line.startsWith('->')) break;
    const row = {};
    cols.forEach((c, j) => {
      row[colNames[j]] = line.substring(c.start, Math.min(c.end, line.length)).trim();
    });
    rows.push(row);
  }
  return rows;
}

function findSection(allLines, sectionTitle) {
  for (let i = 0; i < allLines.length; i++) {
    if (allLines[i].includes(sectionTitle)) {
      let j = i + 1;
      while (j < allLines.length && (allLines[j].startsWith('=') || !allLines[j].trim())) j++;
      if (j + 1 < allLines.length) {
        const dataLines = [];
        for (let k = j; k < allLines.length; k++) {
          if (!allLines[k].trim() && k > j + 1) break;
          if (allLines[k].startsWith('===') && k > j) break;
          dataLines.push(allLines[k]);
        }
        return parseFixedWidth(dataLines);
      }
    }
  }
  return [];
}

// --- Read file with encoding detection ---
function readFileAuto(filePath) {
  const buf = fs.readFileSync(filePath);
  if (buf[0] === 0xFF && buf[1] === 0xFE) return buf.toString('utf16le');
  if (buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) return buf.toString('utf8');
  return buf.toString('utf8');
}

// --- Find AlwaysOn.OUT file ---
function findAlwaysOnOut(dir, hostName) {
  // Only look in {case_dir}/{host}/ subdirectory
  const hostDir = path.join(dir, hostName);
  if (!fs.existsSync(hostDir) || !fs.statSync(hostDir).isDirectory()) return null;
  // Prefer exact match, then any *AlwaysOn.OUT
  const exact = path.join(hostDir, `${hostName}_MSSQLSERVER_1033_AlwaysOn.OUT`);
  if (fs.existsSync(exact)) return exact;
  for (const f of fs.readdirSync(hostDir)) {
    if (f.endsWith('AlwaysOn.OUT')) return path.join(hostDir, f);
  }
  return null;
}

// --- Parse one AlwaysOn.OUT ---
function parseAlwaysOnOut(filePath, hostName) {
  console.log(`Parsing ${hostName}: ${filePath}`);
  const content = readFileAuto(filePath);
  const lines = content.split(/\r?\n/);

  const agState = findSection(lines, 'AlwaysOn Availability Group State');
  const replicaState = findSection(lines, 'AlwaysOn Availability Replica State');
  const dbState = findSection(lines, 'AlwaysOn Availability Database Identification');
  const listeners = findSection(lines, 'Availability Group Listeners');

  const ags = {};
  for (const ag of agState) {
    ags[ag.availability_group] = {
      group_id: ag.group_id,
      primary_replica: ag.primary_replica,
      dtc_support: false,
      listener: null,
      replicas: []
    };
  }

  // Listeners — match by AG name = listener dns_name
  const seenListeners = new Set();
  for (const l of listeners) {
    const lid = l.dns_name;
    if (lid && !seenListeners.has(lid)) {
      seenListeners.add(lid);
      for (const agName of Object.keys(ags)) {
        if (agName === lid) {
          ags[agName].listener = { dns_name: lid, port: l.port, ip: l.ip_address };
        }
      }
    }
  }

  // Replicas
  for (const r of replicaState) {
    const agName = r.group_name;
    if (ags[agName]) {
      ags[agName].replicas.push({
        server: r.replica_server_name,
        is_local: r.is_local === '1',
        role: r.role_desc,
        availability_mode: r.availability_mode_Desc || r.availability_mode,
        failover_mode: r.failover_mode_desc
      });
    }
  }

  // Databases (local only)
  const databases = [];
  for (const db of dbState) {
    if (db.is_local !== '1') continue;
    let agName = '?';
    for (const [name, info] of Object.entries(ags)) {
      if (info.group_id === db.group_id) { agName = name; break; }
    }
    databases.push({
      name: db.database_name,
      id: parseInt(db.database_id),
      ag: agName,
      group_id: db.group_id,
      sync_state: db.synchronization_state_desc,
      db_state: db.database_state_desc
    });
  }
  databases.sort((a, b) => a.ag.localeCompare(b.ag) || a.id - b.id);

  return { host: hostName, ags, databases };
}

// --- Main ---
const oldFile = findAlwaysOnOut(caseDir, oldHost);
const newFile = findAlwaysOnOut(caseDir, newHost);

if (!oldFile) { console.error(`AlwaysOn.OUT not found for ${oldHost}`); process.exit(1); }
if (!newFile) { console.error(`AlwaysOn.OUT not found for ${newHost}`); process.exit(1); }

const old_primary = parseAlwaysOnOut(oldFile, oldHost);
const new_primary = parseAlwaysOnOut(newFile, newHost);

const schema = {
  old_primary,
  new_primary,
  summary: {
    ag_count: Object.keys(old_primary.ags).length,
    db_count: old_primary.databases.length,
    ags: Object.entries(old_primary.ags).map(([name, info]) => ({
      name,
      primary_replica: info.primary_replica,
      dtc_support: info.dtc_support,
      has_listener: !!info.listener,
      listener_name: info.listener?.dns_name || null,
      db_count: old_primary.databases.filter(d => d.ag === name).length,
      replica_count: info.replicas.length
    }))
  }
};

const outPath = path.join(caseDir, 'ag_schema.json');
fs.writeFileSync(outPath, JSON.stringify(schema, null, 2));

// Print summary
console.log('\n=== AG Schema Summary ===\n');
for (const ag of schema.summary.ags) {
  console.log(`AG: ${ag.name}`);
  console.log(`  Primary: ${ag.primary_replica}  |  Listener: ${ag.has_listener ? ag.listener_name : 'NONE'}  |  DTC: ${ag.dtc_support}  |  DBs: ${ag.db_count}  |  Replicas: ${ag.replica_count}`);
}

for (const replica of [old_primary, new_primary]) {
  console.log(`\n--- ${replica.host} — ${replica.databases.length} DBs ---`);
  let lastAg = '';
  for (const db of replica.databases) {
    if (db.ag !== lastAg) { console.log(`\n  [${db.ag}]`); lastAg = db.ag; }
    console.log(`    ${db.id.toString().padStart(3)} ${db.name.padEnd(25)} ${db.sync_state.padEnd(20)} ${db.db_state}`);
  }
}

console.log(`\nSaved to: ${outPath}`);
