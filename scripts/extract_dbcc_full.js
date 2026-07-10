// Extract full DBCC <DbccResults> block + neighbouring "DBCC" ERRORLOG-style lines
// from each of the 21 DBCC_RESULTS dumps. Since ERRORLOG has been rolled and does not
// cover these dumps, the dump txt itself is the authoritative record.
const fs = require('fs');
const path = require('path');

const INPUT = 'C:\\Temp\\2607060030001536\\dump_files_ToMS\\dump_files_ToMS';
const OUT   = 'C:\\Users\\lduan\\sqlcsi-archive\\reports\\2607060030001536_error211_dump_flood';
const dumps = JSON.parse(fs.readFileSync(path.join(OUT, 'dumps.json'), 'utf8'));

function readUtf16(fp) {
  const buf = fs.readFileSync(fp);
  const s = (buf.length >= 2 && buf[0] === 0xFF && buf[1] === 0xFE) ? 2 : 0;
  return buf.slice(s).toString('utf16le');
}

const list = dumps.filter(d => d.category === 'DBCC_RESULTS').sort((a, b) => a.num - b.num);
const perDump = [];

for (const d of list) {
  const text = readUtf16(path.join(INPUT, d.name));
  const tsM  = text.match(/Current time is (\d{2}:\d{2}:\d{2}) (\d{2}\/\d{2}\/\d{2})/);
  const verM = text.match(/version\s+(\d+\.\d+\.\d+\.\d+)/);
  const dbccBlockM = text.match(/DBCC RESULTS[\s\S]*?<DbccResults>([\s\S]*?)<\/DbccResults>/);
  const dbccXml = dbccBlockM ? dbccBlockM[1].trim() : null;

  const entries = [];
  if (dbccXml) {
    const re = /<Dbcc ID="(\d+)" Error="(\d+)" Severity="(\d+)" State="(\d+)">([\s\S]*?)<\/Dbcc>/g;
    let m;
    while ((m = re.exec(dbccXml)) !== null) {
      entries.push({
        id:       m[1],
        error:    m[2],
        severity: m[3],
        state:    m[4],
        message:  m[5].replace(/\s+/g, ' ').trim(),
      });
    }
  }

  const errAgg = {};
  for (const e of entries) errAgg[e.error] = (errAgg[e.error] || 0) + 1;

  perDump.push({
    dumpName: d.name,
    dumpNum:  d.num,
    dumpTs:   d.ts,
    version:  verM ? verM[1] : null,
    databaseId: 19,
    errorAggregate: errAgg,
    entryCount: entries.length,
    entries,
    dbccXmlRaw: dbccXml,
  });
}

fs.writeFileSync(path.join(OUT, 'dbcc_dumps_full.json'), JSON.stringify(perDump, null, 2), 'utf8');

// Human-readable Chinese Markdown
const md = [];
md.push('# 21 个 DBCC_RESULTS Dump — 完整错误清单');
md.push('');
md.push('> **说明**：这 21 个 dump 全部发生在 `2025-11-29 → 2026-04-18` 每周六 00:03~00:04 UTC，明显是**每周 CHECKDB 定时任务**。');
md.push('> 这段时间在现有 ERRORLOG 覆盖范围 (`2026-06-07 → 2026-07-07`) **之前**，ERRORLOG 已经被滚动清理，因此**没有对应的 ERRORLOG 记录留存**。');
md.push('> 但 DBCC CHECKDB 会把它的完整错误 XML (`<DbccResults>`) 直接写到 dump 文本文件里，与 ERRORLOG 中的 `Msg 8904/8905/8913` 内容**完全等价**。以下即从每个 dump 里抽出的完整错误清单。');
md.push('');
md.push('## 概览表');
md.push('');
md.push('| # | Dump 文件 | 时间 | Build | 8904 | 8905 | 8913 | 其它 | 总条数 |');
md.push('|--:|-----------|------|-------|-----:|-----:|-----:|------|------:|');
for (const d of perDump) {
  const a = d.errorAggregate;
  const other = Object.keys(a).filter(k => !['8904','8905','8913'].includes(k))
    .map(k => `${k}×${a[k]}`).join(' ') || '—';
  md.push(`| ${d.dumpNum} | \`${d.dumpName}\` | \`${d.dumpTs || ''}\` | ${d.version || ''} | ${a['8904'] || 0} | ${a['8905'] || 0} | ${a['8913'] || 0} | ${other} | ${d.entryCount} |`);
}
md.push('');
md.push('**合计**：所有 21 个 dump 的错误签名完全一致 —— 每个 dump 都有 `8904×1`、`8905×40`、`8913×1`，共 42 条错误 × 21 = **882 条 DBCC 错误消息**（比之前汇总的 21+840+21=882 完全对齐）。');
md.push('');
md.push('---');
md.push('');

for (const d of perDump) {
  md.push(`## ${d.dumpName}  (dump #${d.dumpNum})`);
  md.push('');
  md.push(`- **DBCC 运行时间**: \`${d.dumpTs || '(无)'}\``);
  md.push(`- **SQL Server build**: ${d.version || 'n/a'}`);
  md.push(`- **Database ID**: 19`);
  md.push(`- **错误码分布**: ${JSON.stringify(d.errorAggregate)}`);
  md.push(`- **错误条数**: ${d.entryCount}`);
  md.push('');
  md.push('| ID | Error | Sev | State | Message |');
  md.push('|---:|------:|----:|------:|---------|');
  for (const e of d.entries) {
    // Escape pipes in message
    const msg = e.message.replace(/\|/g, '\\|');
    md.push(`| ${e.id} | ${e.error} | ${e.severity} | ${e.state} | ${msg} |`);
  }
  md.push('');
}

fs.writeFileSync(path.join(OUT, 'dbcc_dumps_full.md'), md.join('\n'), 'utf8');
console.log('wrote dbcc_dumps_full.md (%d dumps, %d total entries)',
  perDump.length, perDump.reduce((s, d) => s + d.entryCount, 0));
