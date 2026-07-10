// Parse task.js sweep log (===TASK_<TID>_<ROLE>=== blocks) into structured JSON.
const fs = require('fs');
const path = process.argv[2];
const out = process.argv[3];
const text = fs.readFileSync(path, 'utf8');
const lines = text.split(/\r?\n/);
const blocks = [];
let cur = null;
for (const ln of lines) {
  const m = ln.match(/===TASK_(\d+)_?\s*([A-Z\-]+)===/) || ln.match(/===TASK_(\d+)\s+([A-Z\-]+)===/);
  if (m) {
    if (cur) blocks.push(cur);
    cur = { tid: parseInt(m[1]), role: m[2], raw: [] };
    continue;
  }
  if (cur) cur.raw.push(ln);
}
if (cur) blocks.push(cur);

function grab(raw, re) { for (const l of raw) { const m = l.match(re); if (m) return m[1].trim(); } return null; }

const rows = blocks.map(b => {
  const j = b.raw.join('\n');
  const sos = grab(b.raw, /SOS_Task\s*:\s*(.+)$/);
  const spid = grab(b.raw, /SPID:(\d+)/);
  const wrk = grab(b.raw, /Wrk:(0x[0-9A-Fa-f]+)/);
  const sched = grab(b.raw, /Sch0?:(0x[0-9A-Fa-f]+)/);
  const dbgThread = grab(b.raw, /~(\d+)s/);
  const taskState = grab(b.raw, /Task state, paramflags\s*:\s*(.+)$/);
  const workerState = grab(b.raw, /Worker state\s*:\s*(.+)$/);
  const workerStatus = grab(b.raw, /Worker status\s*:\s*(.+)$/);
  const taskFlags = grab(b.raw, /Task Flags\s*:\s*(.+)$/);
  const elapsed = grab(b.raw, /Elapsed time\s*:\s*(.+?)\s+At /) || grab(b.raw, /Elapsed time\s*:\s*(.+)$/);
  const cpu = grab(b.raw, /CPU time\s*:\s*(.+)$/);
  const progress = grab(b.raw, /Task progress mark\s*:\s*(.+)$/);
  const taskFunc = grab(b.raw, /Task function\s*:\s*(.+)$/);
  const noBlockers = /No blockers were found/.test(j);
  // blocker lines
  const blockers = [];
  const bl = j.match(/Blocked by[\s\S]*?(?=\n\n|-----|$)/);
  return {
    tid: b.tid, role: b.role, dbgThread: dbgThread ? parseInt(dbgThread) : null,
    spid: spid ? parseInt(spid) : null,
    worker: wrk, scheduler: sched,
    taskState, workerState, workerStatus, taskFlags,
    elapsed, cpu, progress, taskFunc,
    noBlockers,
  };
});

fs.writeFileSync(out, JSON.stringify(rows, null, 2));
// summary
const bySpid = {};
rows.forEach(r => { if (r.spid != null) { (bySpid[r.spid] = bySpid[r.spid] || []).push(r.tid); } });
console.log('blocks:', rows.length);
console.log('distinct SPIDs:', Object.keys(bySpid).length);
console.log('states:', JSON.stringify(rows.reduce((a, r) => { const k = (r.taskState || '?').split(' ')[0]; a[k] = (a[k] || 0) + 1; return a; }, {})));
console.log('funcs:', JSON.stringify(rows.reduce((a, r) => { const k = r.taskFunc || '?'; a[k] = (a[k] || 0) + 1; return a; }, {})));
console.log('noBlockers count:', rows.filter(r => r.noBlockers).length);
