// Enhanced analyzer v2 — also classifies DBCC-results dumps + decodes DBID low-32 bits.

const fs   = require('fs');
const path = require('path');

const INPUT = process.argv[2] || 'C:\\Temp\\2607060030001536\\dump_files_ToMS\\dump_files_ToMS';
const OUT   = process.argv[3] || 'C:\\Users\\lduan\\sqlcsi-archive\\reports\\2607060030001536_error211_dump_flood';
fs.mkdirSync(OUT, { recursive: true });

function readUtf16(fp) {
  const buf = fs.readFileSync(fp);
  let start = (buf.length >= 2 && buf[0] === 0xFF && buf[1] === 0xFE) ? 2 : 0;
  return buf.slice(start).toString('utf16le');
}

const files      = fs.readdirSync(INPUT);
const errorlogs  = files.filter(f => /^ERRORLOG(\.\d+)?$/i.test(f));
const dumps      = files.filter(f => /^SQLDump\d+\.txt$/i.test(f))
  .sort((a, b) => parseInt(a.match(/\d+/)[0], 10) - parseInt(b.match(/\d+/)[0], 10));

const TS_RE = /^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{2})\s+(\S+)\s+(.*)$/;
const restartEvents = [], err211Events = [], errorLogSpans = [];

for (const name of errorlogs) {
  const text = readUtf16(path.join(INPUT, name));
  const lines = text.split(/\r?\n/);
  let first = null, last = null;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(TS_RE);
    if (!m) continue;
    const [ , ts, source, body ] = m;
    if (!first) first = ts;
    last = ts;
    if (/Microsoft SQL Server \d{4}.*\(X64\)/.test(body))
      restartEvents.push({ file: name, ts, versionLine: body.trim() });
    if (/Error:\s*211,\s*Severity:\s*23/.test(body)) {
      let dbid = null, objid = null;
      for (let k = 1; k <= 4 && i + k < lines.length; k++) {
        const nm = lines[i + k].match(TS_RE);
        if (!nm) continue;
        const cm = nm[3].match(/Corruption in database ID (-?\d+), object ID (-?\d+)/i);
        if (cm) { dbid = cm[1]; objid = cm[2]; break; }
      }
      const spidM = source.match(/spid(\d+)/i);
      let dbidLow32 = null;
      if (dbid !== null) {
        const bi = BigInt(dbid);
        const low = Number(bi & 0xFFFFFFFFn);
        dbidLow32 = low >= 0x80000000 ? low - 0x100000000 : low;
      }
      err211Events.push({ file: name, ts, spid: spidM ? spidM[1] : source, dbid, dbidLow32, objid });
    }
  }
  errorLogSpans.push({ file: name, first, last, lineCount: lines.length });
}
errorLogSpans.sort((a, b) => (a.first || '').localeCompare(b.first || ''));
restartEvents.sort((a, b) => a.ts.localeCompare(b.ts));
err211Events.sort((a, b) => a.ts.localeCompare(b.ts));

// ---------- Parse SQLDump*.txt with three categories ----------
const dumpInfo = [];
for (const name of dumps) {
  const fp = path.join(INPUT, name);
  let text;
  try { text = readUtf16(fp); } catch { continue; }
  const num = parseInt(name.match(/\d+/)[0], 10);
  const head = text.slice(0, 12000);
  const tsM   = head.match(/Current time is (\d{2}:\d{2}:\d{2}) (\d{2}\/\d{2}\/\d{2})/);
  const verM  = head.match(/version\s+(\d+\.\d+\.\d+\.\d+)/);
  const beginM = head.match(/BEGIN STACK DUMP:\s*\r?\n\*\s+(\d{2}\/\d{2}\/\d{2}) (\d{2}:\d{2}:\d{2}) spid (\d+)/);
  const exM   = head.match(/ex_dump_if_requested:\s*Exception raised,\s*major=(-?\d+),\s*minor=(-?\d+),\s*state=(-?\d+),\s*severity=(-?\d+)/);
  const inbufM = head.match(/\* Input Buffer \d+ bytes -\s*\r?\n\*\s+(.{0,140})/);

  let category = 'unknown';
  if (exM) category = `STACK maj=${exM[1]}/min=${exM[2]}/state=${exM[3]}/sev=${exM[4]}`;
  else if (/DBCC RESULTS/.test(head)) category = 'DBCC_RESULTS';

  let dbccInfo = null;
  if (category === 'DBCC_RESULTS') {
    const errs = {};
    let dbId = null;
    const m1 = head.match(/database ID (\d+)/);
    if (m1) dbId = m1[1];
    for (const em of head.matchAll(/Error="(\d+)"/g)) {
      errs[em[1]] = (errs[em[1]] || 0) + 1;
    }
    dbccInfo = { dbId, errorCodes: errs };
  }

  const ts = beginM
    ? `20${beginM[1].slice(6,8)}-${beginM[1].slice(0,2)}-${beginM[1].slice(3,5)} ${beginM[2]}`
    : (tsM ? `20${tsM[2].slice(6,8)}-${tsM[2].slice(0,2)}-${tsM[2].slice(3,5)} ${tsM[1]}` : null);

  dumpInfo.push({
    name, num, ts,
    spid: beginM ? beginM[3] : null,
    category,
    major:    exM ? exM[1] : null,
    minor:    exM ? exM[2] : null,
    state:    exM ? exM[3] : null,
    severity: exM ? exM[4] : null,
    inputHead: inbufM ? inbufM[1].trim() : null,
    version:  verM ? verM[1] : null,
    dbcc: dbccInfo,
  });
}

const catCounts = {};
for (const d of dumpInfo) catCounts[d.category] = (catCounts[d.category] || 0) + 1;
const dumpTsAll = dumpInfo.map(d => d.ts).filter(x => x).sort();
const dumpFirstTs = dumpTsAll[0] || null;
const dumpLastTs  = dumpTsAll[dumpTsAll.length - 1] || null;

const dbccDbidCounts = {}, dbccErrCounts = {};
for (const d of dumpInfo) {
  if (d.category !== 'DBCC_RESULTS' || !d.dbcc) continue;
  const k = d.dbcc.dbId || 'n/a';
  dbccDbidCounts[k] = (dbccDbidCounts[k] || 0) + 1;
  for (const [ec, n] of Object.entries(d.dbcc.errorCodes || {}))
    dbccErrCounts[ec] = (dbccErrCounts[ec] || 0) + n;
}

const restartWindows = [];
for (let i = 0; i < restartEvents.length; i++) {
  restartWindows.push({
    idx: i + 1,
    start: restartEvents[i].ts,
    end:   i + 1 < restartEvents.length ? restartEvents[i + 1].ts : '9999-12-31 23:59:59',
    versionLine: restartEvents[i].versionLine,
    err211: [], dumps: [],
  });
}
const preWin = { idx: 0, start: '0000-01-01 00:00:00', end: restartEvents[0].ts, versionLine: '(在最早的 ERRORLOG 时间点之前 — 无 ERRORLOG 覆盖)', err211: [], dumps: [] };
const allWins = [preWin, ...restartWindows];
function findWindow(ts) {
  for (let i = allWins.length - 1; i >= 0; i--)
    if (ts >= allWins[i].start && ts < allWins[i].end) return allWins[i];
  return null;
}
for (const e of err211Events) { const w = findWindow(e.ts); if (w) w.err211.push(e); }
for (const d of dumpInfo)     { if (d.ts) { const w = findWindow(d.ts); if (w) w.dumps.push(d); } }

const summary = {
  input: INPUT,
  errorlogFiles: errorlogs.length,
  dumpTxtFiles: dumps.length,
  errorlogSpans: errorLogSpans,
  restartCount: restartEvents.length,
  restarts: restartEvents,
  err211TotalCount: err211Events.length,
  dumpCategoryCounts: catCounts,
  dumpFirstTs, dumpLastTs,
  dbccDbidCounts, dbccErrCounts,
  err211ObjIdCounts: err211Events.reduce((a, e) => { const k = e.objid ?? 'n/a'; a[k]=(a[k]||0)+1; return a; }, {}),
  err211DbIdLow32Counts: err211Events.reduce((a, e) => { const k = e.dbidLow32 ?? 'n/a'; a[k]=(a[k]||0)+1; return a; }, {}),
  err211DbIdRawCounts:   err211Events.reduce((a, e) => { const k = e.dbid ?? 'n/a'; a[k]=(a[k]||0)+1; return a; }, {}),
  restartWindows: allWins.map(w => ({
    idx: w.idx, start: w.start, end: w.end,
    versionLine: w.versionLine,
    err211Count: w.err211.length,
    dumpCount:   w.dumps.length,
    dumpByCategory: w.dumps.reduce((a, d) => { a[d.category]=(a[d.category]||0)+1; return a; }, {}),
    dumpRange: w.dumps.length > 0 ? {
      firstNum: Math.min(...w.dumps.map(d=>d.num)),
      lastNum:  Math.max(...w.dumps.map(d=>d.num)),
      firstTs:  w.dumps.map(d=>d.ts).filter(x=>x).sort()[0],
      lastTs:   w.dumps.map(d=>d.ts).filter(x=>x).sort().slice(-1)[0],
    } : null,
    err211DbidLow32Distribution: w.err211.reduce((a, e) => { const k = e.dbidLow32 ?? 'n/a'; a[k]=(a[k]||0)+1; return a; }, {}),
    err211ObjIdDistribution:     w.err211.reduce((a, e) => { const k = e.objid ?? 'n/a'; a[k]=(a[k]||0)+1; return a; }, {}),
    firstErr211: w.err211[0] || null,
    lastErr211:  w.err211[w.err211.length - 1] || null,
    sampleInputBuffers: [...new Set(w.dumps.map(d => d.inputHead).filter(x => x))].slice(0, 3),
  })),
};

fs.writeFileSync(path.join(OUT, 'summary.json'),       JSON.stringify(summary, null, 2), 'utf8');
fs.writeFileSync(path.join(OUT, 'err211_events.json'), JSON.stringify(err211Events, null, 2), 'utf8');
fs.writeFileSync(path.join(OUT, 'dumps.json'),         JSON.stringify(dumpInfo, null, 2), 'utf8');

console.log('done. restarts=%d err211=%d dumps=%d', restartEvents.length, err211Events.length, dumps.length);
console.log('dump categories:', catCounts);
console.log('err211 DBID low32:', summary.err211DbIdLow32Counts);
console.log('DBCC dbid:', dbccDbidCounts, '  errs:', dbccErrCounts);
console.log('dump timespan:', dumpFirstTs, '->', dumpLastTs);
