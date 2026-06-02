#!/usr/bin/env node
/**
 * extract_perfmon_chart_data.js — Extract CPU time series for charting.
 * Outputs JSON with total CPU and top process CPU per sample.
 * Usage: node scripts/extract_perfmon_chart_data.js <csv1> [csv2] ... > output.json
 */
'use strict';
const fs = require('fs');
const readline = require('readline');

async function parsePerfmonCSV(filePath) {
    const rl = readline.createInterface({
        input: fs.createReadStream(filePath, { encoding: 'utf8' }),
        crlfDelay: Infinity
    });

    let headerCols = null;
    const processCpuCols = new Map();
    let totalCpuColIdx = -1;
    let procInfoTotalIdx = -1;

    const rows = [];
    let lineNum = 0;

    for await (const line of rl) {
        lineNum++;
        if (lineNum === 1) {
            headerCols = parseCSVLine(line);
            for (let i = 1; i < headerCols.length; i++) {
                const col = headerCols[i];
                const procMatch = col.match(/\\Process\(([^)]+)\)\\% Processor Time$/i);
                if (procMatch) {
                    const procName = procMatch[1];
                    if (procName !== '_Total' && procName !== 'Idle') {
                        processCpuCols.set(i, procName);
                    }
                }
                if (/\\Processor\(_Total\)\\% Processor Time$/i.test(col)) {
                    totalCpuColIdx = i;
                }
                if (/\\Processor Information\(_Total\)\\% Processor Time$/i.test(col)) {
                    procInfoTotalIdx = i;
                }
            }
            continue;
        }

        const vals = parseCSVLine(line);
        if (vals.length < 2) continue;

        const timestamp = vals[0].trim();
        let totalCpu = NaN;
        if (totalCpuColIdx >= 0 && vals[totalCpuColIdx]) totalCpu = parseFloat(vals[totalCpuColIdx]);
        if (isNaN(totalCpu) && procInfoTotalIdx >= 0 && vals[procInfoTotalIdx]) totalCpu = parseFloat(vals[procInfoTotalIdx]);

        const procCpuMap = {};
        for (const [colIdx, procName] of processCpuCols) {
            const v = parseFloat(vals[colIdx]);
            if (!isNaN(v) && v > 0) {
                const baseName = procName.replace(/#\d+$/, '');
                procCpuMap[baseName] = (procCpuMap[baseName] || 0) + v;
            }
        }

        rows.push({ timestamp, totalCpu, procCpuMap });
    }
    return rows;
}

function parseCSVLine(line) {
    const result = [];
    let current = '';
    let inQuotes = false;
    for (let i = 0; i < line.length; i++) {
        const ch = line[i];
        if (ch === '"') { inQuotes = !inQuotes; }
        else if (ch === ',' && !inQuotes) { result.push(current.trim()); current = ''; }
        else { current += ch; }
    }
    result.push(current.trim());
    return result;
}

async function main() {
    const files = process.argv.slice(2);
    let allRows = [];
    for (const f of files) {
        const rows = await parsePerfmonCSV(f);
        allRows = allRows.concat(rows);
    }
    allRows.sort((a, b) => a.timestamp.localeCompare(b.timestamp));

    // Normalize process CPU to core count (divide by 100)
    const CORES = 32;
    const topProcs = ['sqlservr', 'msmdsrv', 'Microsoft.Mashup.Container.NetFX45', 'MsMpEng', 'DTExec', 'ReportingServicesService', 'RSPowerBI', 'MsSense'];

    const data = allRows.map(r => {
        const entry = {
            t: r.timestamp,
            total: isNaN(r.totalCpu) ? null : Math.round(r.totalCpu * 10) / 10
        };
        for (const p of topProcs) {
            // Convert % Processor Time to "cores used" (value / 100)
            const v = r.procCpuMap[p] || 0;
            entry[p] = Math.round(v * 10) / 1000; // cores, 1 decimal
        }
        return entry;
    });

    // Downsample if too many points (keep every Nth for smooth chart)
    let output = data;
    if (data.length > 5000) {
        const step = Math.ceil(data.length / 5000);
        output = data.filter((_, i) => i % step === 0);
    }

    process.stdout.write(JSON.stringify(output));
}

main().catch(err => { console.error(err); process.exit(1); });
