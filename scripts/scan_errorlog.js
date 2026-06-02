const fs = require('fs');
const path = process.argv[2];
const b = fs.readFileSync(path);
const t = b[0] === 0xFF ? b.toString('utf16le') : b.toString('utf8');
const lines = t.split(/\r?\n/);
console.log('Total lines: ' + lines.length);

// First/last timestamps
for (let i = 0; i < lines.length; i++) {
  const m = lines[i].match(/^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})/);
  if (m) { console.log('First timestamp: ' + m[1]); break; }
}
for (let i = lines.length - 1; i >= 0; i--) {
  const m = lines[i].match(/^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})/);
  if (m) { console.log('Last timestamp: ' + m[1]); break; }
}

// Count Error lines
let errCount = 0;
let errSamples = [];
for (const line of lines) {
  if (/Error:\s*\d+,\s*Severity:\s*\d+/.test(line)) {
    errCount++;
    if (errSamples.length < 10) errSamples.push(line.substring(0, 300));
  }
}
console.log('Error lines: ' + errCount);
errSamples.forEach(s => console.log('ERR: ' + s));

// Special patterns
const specials = [
  ['latch timeout', /latch.*timeout/i],
  ['non-yielding', /non.?yielding/i],
  ['stack dump', /stack dump/i],
  ['IO stall', /I\/O requests taking longer/i],
  ['shutdown', /shutting down|shutdown/i],
  ['failover', /failover/i],
  ['lease', /lease.*(expired|timeout)/i],
  ['memory', /insufficient memory|paged out/i],
  ['threadpool', /THREADPOOL/i],
  ['corruption', /page.*corruption|checkdb/i],
  ['killed', /killed.*process|was deadlocked/i],
  ['login failed', /Login failed/i],
  ['Resource Monitor', /Resource Monitor/i],
  ['suspect', /suspect|recovery pending/i],
  ['backup', /BACKUP.*error|backup failed/i],
];

console.log('\n=== Special Events ===');
for (const [name, pat] of specials) {
  let cnt = 0, samps = [];
  for (const line of lines) {
    if (pat.test(line)) { cnt++; if (samps.length < 3) samps.push(line.substring(0, 250)); }
  }
  if (cnt > 0) {
    console.log(`\n[${name}] Count: ${cnt}`);
    samps.forEach(s => console.log('  ' + s));
  }
}

// Lines around 10:00 AM June 1
console.log('\n=== Around 10:00 AM June 1 ===');
let cnt1000 = 0;
for (let i = 0; i < lines.length; i++) {
  if (/^2026-06-01\s+(09:5[5-9]|10:0[0-9]|10:1[0-5])/.test(lines[i])) {
    if (cnt1000 < 50) console.log(lines[i].substring(0, 300));
    cnt1000++;
  }
}
console.log('Total lines in window: ' + cnt1000);

// Last 30 timestamped lines
console.log('\n=== Last 30 timestamped lines ===');
let lastLines = [];
for (let i = lines.length - 1; i >= 0 && lastLines.length < 30; i--) {
  if (/^\d{4}-\d{2}-\d{2}/.test(lines[i])) lastLines.unshift(lines[i].substring(0, 300));
}
lastLines.forEach(s => console.log(s));
