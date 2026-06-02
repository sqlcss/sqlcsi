#!/usr/bin/env node
/**
 * parse_perfmon_cpu.js — Parse PDH-CSV perfmon logs to find high-CPU periods and top processes.
 * Usage: node scripts/parse_perfmon_cpu.js <csv_file1> [csv_file2] ...
 *
 * Outputs: top processes during high CPU periods (>70% total CPU utilization).
 */
'use strict';
const fs = require('fs');
const readline = require('readline');
const path = require('path');

const HIGH_CPU_THRESHOLD = 70; // percent total CPU to flag as "high"

async function parsePerfmonCSV(filePath) {
    const rl = readline.createInterface({
        input: fs.createReadStream(filePath, { encoding: 'utf8' }),
        crlfDelay: Infinity
    });

    let headerCols = null;
    // Map: colIndex -> processName for Process(*)\% Processor Time
    const processCpuCols = new Map();
    // Map: colIndex -> counterName for Processor(_Total)\% Processor Time
    let totalCpuColIdx = -1;
    // Also track Processor Information
    let procInfoTotalIdx = -1;

    const rows = []; // { timestamp, totalCpu, processCpuMap: { procName: value } }
    let lineNum = 0;

    for await (const line of rl) {
        lineNum++;
        if (lineNum === 1) {
            // Parse header - split by ","
            headerCols = parseCSVLine(line);
            for (let i = 1; i < headerCols.length; i++) {
                const col = headerCols[i];
                // Match Process(xxx)\% Processor Time
                const procMatch = col.match(/\\Process\(([^)]+)\)\\% Processor Time$/i);
                if (procMatch) {
                    const procName = procMatch[1];
                    if (procName !== '_Total' && procName !== 'Idle') {
                        processCpuCols.set(i, procName);
                    }
                }
                // Match Processor(_Total)\% Processor Time
                if (/\\Processor\(_Total\)\\% Processor Time$/i.test(col)) {
                    totalCpuColIdx = i;
                }
                if (/\\Processor Information\(_Total\)\\% Processor Time$/i.test(col)) {
                    procInfoTotalIdx = i;
                }
            }
            console.log(`File: ${path.basename(filePath)}`);
            console.log(`  Total columns: ${headerCols.length}`);
            console.log(`  Process CPU columns: ${processCpuCols.size}`);
            console.log(`  Total CPU column index: ${totalCpuColIdx} (ProcInfo: ${procInfoTotalIdx})`);
            continue;
        }

        const vals = parseCSVLine(line);
        if (vals.length < 2) continue;

        const timestamp = vals[0].trim();
        
        // Get total CPU
        let totalCpu = NaN;
        if (totalCpuColIdx >= 0 && vals[totalCpuColIdx]) {
            totalCpu = parseFloat(vals[totalCpuColIdx]);
        }
        if (isNaN(totalCpu) && procInfoTotalIdx >= 0 && vals[procInfoTotalIdx]) {
            totalCpu = parseFloat(vals[procInfoTotalIdx]);
        }

        // Get per-process CPU
        const procCpuMap = {};
        for (const [colIdx, procName] of processCpuCols) {
            const v = parseFloat(vals[colIdx]);
            if (!isNaN(v) && v > 0) {
                // Aggregate same process names (e.g., svchost, svchost#1, etc.)
                const baseName = procName.replace(/#\d+$/, '');
                procCpuMap[baseName] = (procCpuMap[baseName] || 0) + v;
            }
        }

        rows.push({ timestamp, totalCpu, procCpuMap });
    }

    return rows;
}

function parseCSVLine(line) {
    // Simple CSV parser handling quoted fields
    const result = [];
    let current = '';
    let inQuotes = false;
    for (let i = 0; i < line.length; i++) {
        const ch = line[i];
        if (ch === '"') {
            inQuotes = !inQuotes;
        } else if (ch === ',' && !inQuotes) {
            result.push(current.trim());
            current = '';
        } else {
            current += ch;
        }
    }
    result.push(current.trim());
    return result;
}

function analyzeHighCPU(allRows) {
    // Find periods where total CPU > threshold
    const highCpuPeriods = [];
    let currentPeriod = null;

    for (const row of allRows) {
        if (row.totalCpu >= HIGH_CPU_THRESHOLD) {
            if (!currentPeriod) {
                currentPeriod = { start: row.timestamp, end: row.timestamp, rows: [row] };
            } else {
                currentPeriod.end = row.timestamp;
                currentPeriod.rows.push(row);
            }
        } else {
            if (currentPeriod) {
                highCpuPeriods.push(currentPeriod);
                currentPeriod = null;
            }
        }
    }
    if (currentPeriod) highCpuPeriods.push(currentPeriod);

    return highCpuPeriods;
}

function printReport(allRows, highCpuPeriods) {
    console.log(`\n${'='.repeat(80)}`);
    console.log(`PERFMON CPU ANALYSIS REPORT`);
    console.log(`${'='.repeat(80)}`);
    console.log(`Total data points: ${allRows.length}`);
    if (allRows.length > 0) {
        console.log(`Time range: ${allRows[0].timestamp} → ${allRows[allRows.length - 1].timestamp}`);

        // Overall CPU stats
        const cpuVals = allRows.filter(r => !isNaN(r.totalCpu)).map(r => r.totalCpu);
        if (cpuVals.length > 0) {
            const avg = cpuVals.reduce((a, b) => a + b, 0) / cpuVals.length;
            const max = Math.max(...cpuVals);
            const min = Math.min(...cpuVals);
            const p95idx = Math.floor(cpuVals.length * 0.95);
            const sorted = [...cpuVals].sort((a, b) => a - b);
            console.log(`\nOverall CPU: avg=${avg.toFixed(1)}%, min=${min.toFixed(1)}%, max=${max.toFixed(1)}%, P95=${sorted[p95idx].toFixed(1)}%`);
        }
    }

    console.log(`\n${'─'.repeat(80)}`);
    console.log(`HIGH CPU PERIODS (>${HIGH_CPU_THRESHOLD}%): ${highCpuPeriods.length} found`);
    console.log(`${'─'.repeat(80)}`);

    if (highCpuPeriods.length === 0) {
        console.log('No periods with CPU above threshold.');
        // Still show top 10 highest CPU samples
        const top10 = [...allRows].filter(r => !isNaN(r.totalCpu)).sort((a, b) => b.totalCpu - a.totalCpu).slice(0, 10);
        console.log('\nTop 10 highest CPU samples:');
        for (const r of top10) {
            const topProcs = Object.entries(r.procCpuMap).sort((a, b) => b[1] - a[1]).slice(0, 5);
            const procStr = topProcs.map(([n, v]) => `${n}:${v.toFixed(1)}%`).join(', ');
            console.log(`  ${r.timestamp}  Total: ${r.totalCpu.toFixed(1)}%  Top: ${procStr}`);
        }
        return;
    }

    for (let i = 0; i < highCpuPeriods.length; i++) {
        const p = highCpuPeriods[i];
        const duration = p.rows.length;
        const avgCpu = p.rows.reduce((s, r) => s + r.totalCpu, 0) / p.rows.length;
        const maxCpu = Math.max(...p.rows.map(r => r.totalCpu));

        console.log(`\n[Period ${i + 1}] ${p.start} → ${p.end} (${duration} samples)`);
        console.log(`  Avg CPU: ${avgCpu.toFixed(1)}%, Max CPU: ${maxCpu.toFixed(1)}%`);

        // Aggregate process CPU across the period
        const aggProc = {};
        for (const row of p.rows) {
            for (const [proc, cpu] of Object.entries(row.procCpuMap)) {
                if (!aggProc[proc]) aggProc[proc] = { total: 0, max: 0, count: 0 };
                aggProc[proc].total += cpu;
                aggProc[proc].max = Math.max(aggProc[proc].max, cpu);
                aggProc[proc].count++;
            }
        }

        // Sort by avg CPU
        const sortedProcs = Object.entries(aggProc)
            .map(([name, data]) => ({
                name,
                avg: data.total / duration,
                max: data.max,
                count: data.count
            }))
            .sort((a, b) => b.avg - a.avg)
            .slice(0, 15);

        console.log(`\n  Top processes (avg CPU during period):`);
        console.log(`  ${'Process'.padEnd(45)} ${'Avg%'.padStart(8)} ${'Max%'.padStart(8)} ${'Samples'.padStart(8)}`);
        console.log(`  ${'─'.repeat(45)} ${'─'.repeat(8)} ${'─'.repeat(8)} ${'─'.repeat(8)}`);
        for (const proc of sortedProcs) {
            console.log(`  ${proc.name.padEnd(45)} ${proc.avg.toFixed(1).padStart(8)} ${proc.max.toFixed(1).padStart(8)} ${String(proc.count).padStart(8)}`);
        }

        // Per-sample breakdown for short periods (show each timestamp)
        if (duration <= 20) {
            console.log(`\n  Per-sample breakdown:`);
            for (const row of p.rows) {
                const topProcs = Object.entries(row.procCpuMap).sort((a, b) => b[1] - a[1]).slice(0, 5);
                const procStr = topProcs.map(([n, v]) => `${n}:${v.toFixed(1)}%`).join(', ');
                console.log(`    ${row.timestamp}  Total: ${row.totalCpu.toFixed(1)}%  | ${procStr}`);
            }
        }
    }

    // Summary: processes that appear most in high CPU periods
    console.log(`\n${'─'.repeat(80)}`);
    console.log(`OVERALL TOP CPU CONSUMERS ACROSS ALL HIGH-CPU PERIODS`);
    console.log(`${'─'.repeat(80)}`);
    const globalAgg = {};
    let totalHighSamples = 0;
    for (const p of highCpuPeriods) {
        totalHighSamples += p.rows.length;
        for (const row of p.rows) {
            for (const [proc, cpu] of Object.entries(row.procCpuMap)) {
                if (!globalAgg[proc]) globalAgg[proc] = { total: 0, max: 0, count: 0 };
                globalAgg[proc].total += cpu;
                globalAgg[proc].max = Math.max(globalAgg[proc].max, cpu);
                globalAgg[proc].count++;
            }
        }
    }
    const globalSorted = Object.entries(globalAgg)
        .map(([name, data]) => ({
            name,
            avg: data.total / totalHighSamples,
            max: data.max,
            count: data.count,
            pctPresent: ((data.count / totalHighSamples) * 100).toFixed(0)
        }))
        .sort((a, b) => b.avg - a.avg)
        .slice(0, 20);

    console.log(`  Total high-CPU samples: ${totalHighSamples}`);
    console.log(`  ${'Process'.padEnd(45)} ${'Avg%'.padStart(8)} ${'Max%'.padStart(8)} ${'Present'.padStart(8)}`);
    console.log(`  ${'─'.repeat(45)} ${'─'.repeat(8)} ${'─'.repeat(8)} ${'─'.repeat(8)}`);
    for (const proc of globalSorted) {
        console.log(`  ${proc.name.padEnd(45)} ${proc.avg.toFixed(1).padStart(8)} ${proc.max.toFixed(1).padStart(8)} ${(proc.pctPresent + '%').padStart(8)}`);
    }
}

async function main() {
    const files = process.argv.slice(2);
    if (files.length === 0) {
        console.error('Usage: node parse_perfmon_cpu.js <csv_file1> [csv_file2] ...');
        process.exit(1);
    }

    let allRows = [];
    for (const f of files) {
        console.log(`\nParsing: ${f}`);
        const rows = await parsePerfmonCSV(f);
        console.log(`  Parsed ${rows.length} data rows`);
        allRows = allRows.concat(rows);
    }

    // Sort by timestamp
    allRows.sort((a, b) => a.timestamp.localeCompare(b.timestamp));

    const highCpuPeriods = analyzeHighCPU(allRows);
    printReport(allRows, highCpuPeriods);
}

main().catch(err => { console.error(err); process.exit(1); });
