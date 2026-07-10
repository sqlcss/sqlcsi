// Extract ERRORLOG records corresponding to the 21 DBCC_RESULTS dumps.
// Strategy: for each DBCC dump (from dumps.json), find its dump number and
// timestamp, then in every ERRORLOG* file look for lines that either:
//   (a) reference SQLDump<num>.txt, or
//   (b) fall within ±120 seconds of the dump's timestamp AND contain DBCC / 890x / 8913
// Emit both a JSON and a markdown-ish text with grouped output.

const fs = require('fs');
const path = require('path');

const INPUT  = 'C:\\Temp\\2607060030001536\\dump_files_ToMS\\dump_files_ToMS';
const OUT    = 'C:\\Users\\lduan\\sqlcsi-archive\\reports\\2607060030001536_error211_dump_flood';
const dumps  = JSON.parse(fs.readFileSync(path.join(OUT, 'dumps.json'), 'utf8'));

function readUtf16(fp) {
  const buf = fs.readFileSync(fp);
  const start = (buf.length >= 2 && buf[0] === 0xFF && buf[1] === 0xFE) ? 2 : 0;
  return buf.slice(start).toString('utf16le');
}
const TS_RE = /^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{2})\s+(\S+)\s+(.*)$/;

const dbccDumps = dumps.filter(d => d.category === 'DBCC_RESULTS')
  .sort((a, b) => a.num - b.num);
console.log(`DBCC dumps to trace: ${dbccDumps.length}`);

// Load every ERRORLOG* into memory once
const errorlogs = fs.readdirSync(INPUT)
  .filter(f => /^ERRORLOG(\.\d+)?$/i.test(f));
const logLines = []; // { file, ts, source, body, raw }
for (const name of errorlogs) {
  const lines = readUtf16(path.join(INPUT, name)).split(/\r?\n/);
  for (const raw of lines) {
    const m = raw.match(TS_RE);
    if (!m) continue;
    logLines.push({ file: name, ts: m[1], source: m[2], body: m[3], raw });
  }
}
logLines.sort((a, b) => a.ts.localeCompare(b.ts));
console.log(`Total parsed ERRORLOG lines with timestamps: ${logLines.length}`);

// Helper: find dump # in body
const dumpRefRe = /SQLDump(\d+)\.txt/i;

function tsToDate(ts) {
  // "2026-07-05 20:01:50.28" -> Date
  const m = ts.match(/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{2})$/);
  if (!m) return null;
  return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6], +m[7] * 10));
}

const results = [];
for (const d of dbccDumps) {
  const dumpDate = d.ts ? tsToDate(d.ts) : null;
  const hits = new Set(); // dedup by raw

  // (a) explicit reference in ERRORLOG body
  for (const ln of logLines) {
    const rm = ln.body.match(dumpRefRe);
    if (rm && parseInt(rm[1], 10) === d.num) hits.add(JSON.stringify(ln));
  }

  // (b) time-window match: ± 120 seconds AND contains DBCC / 8904 / 8905 / 8913
  if (dumpDate) {
    for (const ln of logLines) {
      const t = tsToDate(ln.ts);
      if (!t) continue;
      const dt = Math.abs(t - dumpDate) / 1000;
      if (dt > 120) continue;
      if (/DBCC|8904|8905|8913|checkdb|checktable|consistency/i.test(ln.body))
        hits.add(JSON.stringify(ln));
    }
  }

  const rows = [...hits].map(x => JSON.parse(x)).sort((a, b) => a.ts.localeCompare(b.ts));
  results.push({
    dumpName: d.name,
    dumpNum:  d.num,
    dumpTs:   d.ts,
    spid:     d.spid,
    dbccDbId: d.dbcc && d.dbcc.dbId,
    dbccErrorCodes: d.dbcc && d.dbcc.errorCodes,
    errorlogHits: rows,
  });
}

fs.writeFileSync(path.join(OUT, 'dbcc_errorlog_records.json'), JSON.stringify(results, null, 2), 'utf8');

// Also emit a human-readable Chinese text file
const md = [];
md.push('# 21 个 DBCC_RESULTS Dump 对应的 ERRORLOG 记录');
md.push('');
md.push(`- 数据来源: \`${INPUT}\``);
md.push(`- Dump 数: **${dbccDumps.length}**`);
md.push('');
md.push('匹配策略：(a) ERRORLOG body 中直接引用了 `SQLDump<num>.txt`；或 (b) 时间戳在 dump 时间 ±120 秒内 且包含 `DBCC` / `8904` / `8905` / `8913` / `CHECKDB` / `consistency`。');
md.push('');

for (const r of results) {
  md.push(`## ${r.dumpName}  (dump #${r.dumpNum})`);
  md.push('');
  md.push(`- **Dump 时间**: \`${r.dumpTs || '(无)'}\` — spid ${r.spid || 'n/a'}`);
  md.push(`- **DBCC 报告的 database ID**: \`${r.dbccDbId || 'n/a'}\``);
  md.push(`- **DBCC 错误码分布**: ${JSON.stringify(r.dbccErrorCodes || {})}`);
  md.push(`- **ERRORLOG 命中数**: ${r.errorlogHits.length}`);
  md.push('');
  if (r.errorlogHits.length === 0) {
    md.push('> ⚠️ 该 dump 时间点不在任何 ERRORLOG 文件覆盖范围内（属于 ERRORLOG 已滚动丢失的历史时段）。');
    md.push('');
    continue;
  }
  md.push('```');
  for (const h of r.errorlogHits) md.push(`[${h.file}] ${h.raw}`);
  md.push('```');
  md.push('');
}
fs.writeFileSync(path.join(OUT, 'dbcc_errorlog_records.md'), md.join('\n'), 'utf8');
console.log('wrote dbcc_errorlog_records.json + .md to', OUT);
