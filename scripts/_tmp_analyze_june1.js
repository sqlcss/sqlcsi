const fs = require('fs');
const b = fs.readFileSync('C:\\Temp\\2606010030001676\\db02log0601\\db02log519\\ERRORLOG.1');
const t = b[0] === 0xFF ? b.toString('utf16le') : b.toString('utf8');
const lines = t.split(/\r?\n/);

// Count messages per hour on June 1
let hourCounts = {};
let nonLoginByHour = {};
for (const line of lines) {
  const m = line.match(/^2026-06-01\s+(\d{2}):\d{2}:\d{2}/);
  if (m) {
    const hr = m[1];
    hourCounts[hr] = (hourCounts[hr] || 0) + 1;
    if (!/Login (succeeded|failed)/.test(line) && !/错误: 18456/.test(line) && !/错误: 18451/.test(line)) {
      nonLoginByHour[hr] = (nonLoginByHour[hr] || 0) + 1;
    }
  }
}
console.log('=== Hourly message count (June 1) ===');
for (const hr of Object.keys(hourCounts).sort()) {
  console.log(`Hour ${hr}: total=${hourCounts[hr]}, non-login=${nonLoginByHour[hr] || 0}`);
}

// Show all non-login-audit lines on June 1
console.log('\n=== Non-login events on June 1 ===');
let nonLogin = [];
for (const line of lines) {
  if (/^2026-06-01/.test(line) && !/Login (succeeded|failed)/.test(line) && !/错误: 18456/.test(line) && !/错误: 18451/.test(line)) {
    nonLogin.push(line.substring(0, 350));
  }
}
nonLogin.forEach(s => console.log(s));
console.log('Total non-login lines on June 1: ' + nonLogin.length);

// Look for any gap > 60s in timestamped lines between 9:00 and 11:15
console.log('\n=== Gaps > 60s on June 1 (9:00-11:15) ===');
let prevTs = null;
for (const line of lines) {
  const m = line.match(/^(2026-06-01\s+(\d{2}):(\d{2}):(\d{2}))/);
  if (m) {
    const hr = parseInt(m[2]), mn = parseInt(m[3]), sc = parseInt(m[4]);
    if (hr >= 9 && hr <= 11) {
      const secs = hr * 3600 + mn * 60 + sc;
      if (prevTs !== null && (secs - prevTs.secs) > 60) {
        console.log(`Gap: ${secs - prevTs.secs}s between ${prevTs.ts} and ${m[1]}`);
      }
      prevTs = { ts: m[1], secs };
    }
  }
}
