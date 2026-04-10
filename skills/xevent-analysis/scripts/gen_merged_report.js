#!/usr/bin/env node
// Merge: take v5 errorlog HTML + XEvent findings JSON → combined HTML
const fs = require('fs');
function loadJson(p) { let t = fs.readFileSync(p, 'utf8'); if (t.charCodeAt(0) === 0xFEFF) t = t.slice(1); return JSON.parse(t); }

const elHtmlPath = process.argv[2];
const xeFindingsPath = process.argv[3];
const outPath = process.argv[4];

const elHtml = fs.readFileSync(elHtmlPath, 'utf8');
const xe = loadJson(xeFindingsPath);

// Find insertion point (before footer)
const insertIdx = elHtml.indexOf('<div class="footer">');
if (insertIdx < 0) { console.error('Cannot find footer in errorlog HTML'); process.exit(1); }

// Build XEvent sections
const lines = [];

lines.push('<h1 style="margin-top:3rem;border-top:3px solid var(--ac);padding-top:2rem">Part B: XEvent Analysis (system_health)</h1>');
lines.push('<p style="font-size:.88rem;color:var(--dim)">Source: 10 XEL files (180MB) | Period: 7 days aligned with ERRORLOG | Events: ' + xe.total_events_analyzed + '</p>');

// Section 8: Wait Analysis
lines.push('<h2>8. Wait Analysis (Top Finding)</h2>');
lines.push('<div class="sec">');
lines.push('<p><strong>Total wait events:</strong> ' + xe.wait_analysis.total_wait_events + ' — system_health captures waits exceeding internal threshold (~5s)</p>');
lines.push('<table><thead><tr><th>Wait Type</th><th>Category</th><th>Count</th><th>Total(s)</th><th>Avg(s)</th><th>Max(s)</th></tr></thead><tbody>');
for (const w of xe.wait_analysis.wait_summary || []) {
  lines.push('<tr><td><strong>' + w.wait_type + '</strong></td><td>' + w.category + '</td><td>' + w.count + '</td><td>' + Math.round(w.total_duration_ms / 1000) + '</td><td>' + Math.round(w.avg_ms / 1000) + '</td><td>' + Math.round(w.max_duration_ms / 1000) + '</td></tr>');
}
lines.push('</tbody></table></div>');

// Section 9: Wait Timeline
lines.push('<h2>9. Wait Events Timeline</h2>');
lines.push('<div class="sec">');
lines.push('<p style="font-size:.82rem;color:var(--dim);margin-bottom:.5rem">' + xe.wait_analysis.total_wait_events + ' events chronologically</p>');
for (const w of xe.wait_analysis.all_waits || []) {
  const ts = w.timestamp.substring(0, 19).replace('T', ' ');
  const dur = Math.round(w.duration_ms / 1000);
  lines.push('<div class="tl-row"><span class="tl-ts">' + ts + '</span><span class="tl-icon" style="color:var(--or)">\u23F3</span><span class="tl-desc">' + w.wait_type + ' ' + dur + 's (' + w.category + ')</span></div>');
}
lines.push('</div>');

// Section 10: sp_server_diagnostics
lines.push('<h2>10. sp_server_diagnostics</h2>');
lines.push('<div class="sec">');
lines.push('<p>Total records: ' + xe.diagnostics.total_records + ' (only WARNING/ERROR shown)</p>');
if ((xe.diagnostics.alerts || []).length === 0) {
  lines.push('<div class="insight" style="border-left-color:var(--gn)"><strong style="color:var(--gn)">\u2713 All components CLEAN</strong> \u2014 No WARNING or ERROR states in the analysis period.</div>');
} else {
  lines.push('<div class="insight" style="border-left-color:var(--rd)"><strong style="color:var(--rd)">\u26A0 ' + xe.diagnostics.alerts.length + ' alerts</strong></div>');
}
lines.push('<table><thead><tr><th>Component</th><th>State</th><th>Count</th></tr></thead><tbody>');
for (const [k, v] of Object.entries(xe.diagnostics.state_distribution || {}).sort()) {
  const comp = k.replace(/_CLEAN$/, '').replace(/_WARNING$/, '').replace(/_ERROR$/, '');
  const state = k.split('_').pop();
  lines.push('<tr><td>' + comp + '</td><td>' + state + '</td><td>' + v + '</td></tr>');
}
lines.push('</tbody></table></div>');

// Section 11: Scheduler Monitor
lines.push('<h2>11. Scheduler Monitor</h2>');
lines.push('<div class="sec">');
lines.push('<p>Total records: ' + xe.scheduler.total_records + ' (filtered: CPU&gt;75% or Memory&lt;80%)</p>');
if ((xe.scheduler.alerts || []).length === 0) {
  lines.push('<div class="insight" style="border-left-color:var(--gn)"><strong style="color:var(--gn)">\u2713 No resource pressure</strong> \u2014 CPU \u226475% and Memory \u226580% throughout.</div>');
} else {
  lines.push('<div class="insight" style="border-left-color:var(--rd)"><strong style="color:var(--rd)">\u26A0 ' + xe.scheduler.alerts.length + ' pressure events</strong></div>');
}
lines.push('</div>');

// Section 12: error_reported
lines.push('<h2>12. XEvent error_reported (ERRORLOG Complement)</h2>');
lines.push('<div class="sec">');
lines.push('<table><thead><tr><th>Error</th><th>Severity</th><th>Count</th><th>Subsystem</th><th>Status</th><th>Message</th></tr></thead><tbody>');
for (const e of xe.errors || []) {
  lines.push('<tr><td>' + e.error_number + '</td><td>' + e.severity + '</td><td>' + e.count + '</td><td>' + e.subsystem + '</td><td>' + (e.is_benign ? 'benign' : '') + '</td><td>' + (e.message_sample || '').substring(0, 120) + '</td></tr>');
}
lines.push('</tbody></table></div>');

// Section 13: Cross-Correlation
lines.push('<h2>13. Cross-Correlation</h2>');
lines.push('<div class="sec">');
if (xe.correlation) {
  lines.push('<table><thead><tr><th>Category</th><th>Errors</th></tr></thead><tbody>');
  lines.push('<tr><td>In both ERRORLOG + XEvent</td><td>' + (xe.correlation.errors_in_both.join(', ') || 'none') + '</td></tr>');
  lines.push('<tr><td>XEvent only</td><td>' + (xe.correlation.xevent_only_errors.join(', ') || 'none') + '</td></tr>');
  lines.push('<tr><td>ERRORLOG only</td><td>' + (xe.correlation.errorlog_only_errors.join(', ') || 'none') + '</td></tr>');
  lines.push('</tbody></table>');
}
lines.push('</div>');

// Part C: Microsoft Docs
lines.push('<h1 style="margin-top:3rem;border-top:3px solid var(--mv);padding-top:2rem">Part C: Microsoft Docs Research</h1>');

lines.push('<h2>14. Error 19432 \u2014 Missing Log Block</h2>');
lines.push('<div class="sec">');
lines.push('<div class="insight" style="border-left-color:var(--ac)"><strong>Official:</strong> <em>"AG transport has detected a missing log block. Log scan will be restarted."</em></div>');
lines.push('<div class="grid2"><div>');
lines.push('<div class="kv"><span class="k">Known Fix</span><span class="v"><a href="https://support.microsoft.com/help/4541309" style="color:var(--ac)">KB4541309</a></span></div>');
lines.push('<div class="kv"><span class="k">Fixed In</span><span class="v">SP2 CU12 (13.0.5698.0)</span></div>');
lines.push('<div class="kv"><span class="k">Current Build</span><span class="v">SP2 CU15+GDR (13.0.5865.1)</span></div>');
lines.push('<div class="kv"><span class="k">Status</span><span class="v" style="color:var(--yl)">FIX_ALREADY_APPLIED</span></div>');
lines.push('</div><div>');
lines.push('<div class="insight" style="border-left-color:var(--yl)">KB4541309 already included in CU15. Error persists \u2192 <strong>root cause is environmental</strong> (I/O subsystem), not a code bug.</div>');
lines.push('</div></div></div>');

lines.push('<h2>15. WRITELOG Wait \u2014 Transaction Log I/O Bottleneck</h2>');
lines.push('<div class="sec">');
lines.push('<div class="insight" style="border-left-color:var(--rd)"><strong style="color:var(--rd)">This is the #1 root cause.</strong> WRITELOG = waiting for transaction log flush to disk. 83 occurrences averaging 58 seconds \u2014 <strong>~4000x above the 10-15ms threshold</strong>.</div>');
lines.push('<p style="margin-top:.8rem"><strong>Common causes</strong> (<a href="https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/troubleshoot-sql-io-performance" style="color:var(--ac)">CSS I/O Guide</a>):</p>');
lines.push('<table><thead><tr><th>Cause</th><th>Description</th><th>This Case?</th></tr></thead><tbody>');
lines.push('<tr><td style="font-weight:700;color:var(--yl)">Log disk latency</td><td>Data+log on same volume; sequential log writes mixed with random data I/O</td><td style="color:var(--rd)">LIKELY \u2014 58s avg strongly suggests shared/slow disk</td></tr>');
lines.push('<tr><td>Too many VLFs</td><td>Excessive virtual log files cause WRITELOG waits</td><td>Check: DBCC LOGINFO</td></tr>');
lines.push('<tr><td>Small transactions</td><td>Auto-commit per statement generates excessive flushes</td><td>Less likely on secondary</td></tr>');
lines.push('<tr><td>Log Writer scheduling</td><td>SQL 2016 has single Log Writer thread</td><td>Possible contributing factor</td></tr>');
lines.push('</tbody></table></div>');

lines.push('<h2>16. ASYNC_IO_COMPLETION \u2014 Backup I/O</h2>');
lines.push('<div class="sec">');
lines.push('<div class="insight" style="border-left-color:var(--or)">Occurs during <strong>data file reads during backup</strong>. 6 daily occurrences at 15:09-15:11 UTC \u2192 <strong>scheduled backup job</strong>. Duration increasing daily (588s\u2192665s).</div></div>');

lines.push('<h2>17. Sector Size Mismatch (AG-specific)</h2>');
lines.push('<div class="sec">');
lines.push('<div class="insight" style="border-left-color:var(--tl)"><a href="https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/performance-degradation-misaligned-io-sector-error" style="color:var(--ac)">Misaligned I/O sector sizes</a> between replicas can cause slow AG sync. Check with <code>fsutil fsinfo sectorinfo</code>. Consider <strong>TF1800</strong>.</div></div>');

// Part D: Root Cause
lines.push('<h1 style="margin-top:3rem;border-top:3px solid var(--rd);padding-top:2rem">Part D: Root Cause & Recommendations</h1>');

lines.push('<h2>18. Root Cause Chain</h2>');
lines.push('<div class="sec"><div style="font-family:Consolas,monospace;font-size:.9rem;line-height:2">');
lines.push('<span style="color:var(--rd)">\u25CF</span> <strong>WRITELOG storm</strong> (83x, avg 58s) on 05-01 19:04~21:29 UTC<br>');
lines.push('&nbsp;&nbsp;&nbsp;\u2193 Transaction log disk severely congested<br>');
lines.push('&nbsp;&nbsp;&nbsp;\u2193 AG transport cannot read/send log blocks in time<br>');
lines.push('<span style="color:var(--rd)">\u25CF</span> <strong>Error 19432 \u00D7 42</strong> on 05-02 03:05~05:22 (missing log block)<br>');
lines.push('&nbsp;&nbsp;&nbsp;\u2193 Log scan restarts repeatedly<br>');
lines.push('<span style="color:var(--or)">\u25CF</span> <strong>Error 9642 \u00D7 10</strong> on 05-02 01:01~01:02 (endpoint version mismatch)<br>');
lines.push('&nbsp;&nbsp;&nbsp;\u2193 Compounds transport instability<br>');
lines.push('<span style="color:var(--yl)">\u25CF</span> <strong>Error 17830 \u00D7 22</strong> (XEvent: network resets 0x2746)<br>');
lines.push('&nbsp;&nbsp;&nbsp;\u2193 Endpoint connections drop and reconnect<br>');
lines.push('<span style="color:var(--or)">\u25CF</span> <strong>ASYNC_IO_COMPLETION daily ~15:09</strong> (backup, 10+ min)<br>');
lines.push('&nbsp;&nbsp;&nbsp;\u2193 Further I/O pressure during backup window');
lines.push('</div></div>');

lines.push('<h2>19. Recommendations (Merged)</h2>');
lines.push('<div class="sec"><table><thead><tr><th style="width:50px">#</th><th style="width:80px">Priority</th><th>Action</th><th>Rationale</th></tr></thead><tbody>');
const recs = [
  ['HIGH', 'Isolate transaction log to dedicated SSD/NVMe volume', 'WRITELOG 58s avg vs 10-15ms threshold. Root cause of Error 19432.'],
  ['HIGH', 'Check disk latency: Perfmon Avg Disk sec/Write on log volume', 'Confirm I/O subsystem bottleneck vs filter drivers or antivirus.'],
  ['MEDIUM', 'Review backup at ~15:09 UTC; consider compression or off-peak', 'ASYNC_IO_COMPLETION 10+ min/day, duration increasing.'],
  ['MEDIUM', 'Check VLF count: <code>DBCC LOGINFO(\'ICADB\')</code>', 'Excessive VLFs compound WRITELOG waits.'],
  ['MEDIUM', 'Verify sector sizes across all 4 replicas; consider TF1800', 'Misaligned sectors cause slow AG sync.'],
  ['MEDIUM', 'Upgrade all replicas to same CU (fix Error 9642)', '"Remote endpoint lower version" 10x.'],
  ['MEDIUM', 'Check HADR endpoint / network between SGA \u2194 SGB', 'Error 17830 (22x) repeated connection resets.'],
  ['LOW', 'Check filter drivers: <code>fltmc instances</code>', 'AV/backup filter drivers can serialize I/O.'],
];
recs.forEach((r, i) => {
  const badge = r[0] === 'HIGH'
    ? '<span style="background:#f38ba8;color:#1e1e2e;padding:2px 8px;border-radius:10px;font-size:.78rem;font-weight:700">HIGH</span>'
    : r[0] === 'MEDIUM'
    ? '<span style="background:#fab387;color:#1e1e2e;padding:2px 8px;border-radius:10px;font-size:.78rem;font-weight:700">MEDIUM</span>'
    : '<span style="color:var(--dim);font-size:.78rem">LOW</span>';
  lines.push('<tr><td>' + (i + 1) + '</td><td>' + badge + '</td><td>' + r[1] + '</td><td>' + r[2] + '</td></tr>');
});
lines.push('</tbody></table></div>');

// Merge
const merged = elHtml.substring(0, insertIdx) + lines.join('\n') + '\n' + elHtml.substring(insertIdx);
fs.writeFileSync(outPath, merged, 'utf8');
console.log('Merged report: ' + outPath + ' (' + Math.round(fs.statSync(outPath).size / 1024) + ' KB)');
