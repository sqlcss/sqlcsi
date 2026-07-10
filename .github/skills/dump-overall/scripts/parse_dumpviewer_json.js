#!/usr/bin/env node
/*
 * parse_dumpviewer_json.js — SQL-CSI dump-overall (PRIMARY mode helper)
 *
 * DumpViewer emits each report table as a JavaScript sidecar `X_..._json.js`:
 *
 *     var var_ThreadDe_ThreadDe_2_json = [{
 *       header: [ {"thread_id":"number"}, {"worker_state":"string"}, ... ],
 *       multiLineCols: ["call_stack"],
 *       data: [ [0, 0, "", ...], ... ]
 *     }];
 *
 * The keys are unquoted (JS object literal, not strict JSON), so JSON.parse
 * fails. This helper evaluates the single `var ... = [ ... ];` assignment in a
 * minimal sandbox and re-emits a clean, normalized JSON document:
 *
 *     { "columns": ["thread_id", ...], "types": {"thread_id":"number", ...},
 *       "multiLineCols": ["call_stack"], "rowCount": N, "rows": [ {..}, .. ] }
 *
 * Usage:
 *   node parse_dumpviewer_json.js <path-to-X_..._json.js> [--out out.json] [--array]
 *     --out    write to a file instead of stdout
 *     --array  emit rows as raw arrays (no header keys) — faster for big tables
 *
 * Only used against our own DumpViewer output; the sandbox blocks require/process.
 */
'use strict';
const fs = require('fs');
const path = require('path');

const argv = process.argv.slice(2);
const src = argv.find(a => !a.startsWith('--'));
const outFlag = argv.indexOf('--out');
const outPath = outFlag >= 0 ? argv[outFlag + 1] : null;
const asArray = argv.includes('--array');

if (!src) {
  console.error('usage: node parse_dumpviewer_json.js <X_..._json.js> [--out out.json] [--array]');
  process.exit(2);
}
if (!fs.existsSync(src)) {
  console.error('[parse_dumpviewer_json] file not found: ' + src);
  process.exit(1);
}

let text = fs.readFileSync(src, 'utf8');
// strip a UTF-8 BOM if present
if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);

// Extract the RHS of the single `var <name> = <expr>;` assignment.
const m = text.match(/var\s+[A-Za-z0-9_]+\s*=\s*([\s\S]+);?\s*$/);
if (!m) {
  console.error('[parse_dumpviewer_json] no `var NAME = ...` assignment found in ' + src);
  process.exit(1);
}
let rhs = m[1].trim().replace(/;+\s*$/, '');

let obj;
try {
  // Evaluate the object/array literal in an isolated function scope. The sidecar
  // is our own generated data; block ambient globals defensively.
  // eslint-disable-next-line no-new-func
  obj = new Function('require', 'process', 'module', 'global', '"use strict"; return (' + rhs + ');')
        (undefined, undefined, undefined, undefined);
} catch (e) {
  console.error('[parse_dumpviewer_json] failed to evaluate sidecar: ' + e.message);
  process.exit(1);
}

// DumpViewer wraps the table in a one-element array: [{ header, data, ... }]
const tbl = Array.isArray(obj) ? obj[0] : obj;
if (!tbl || !Array.isArray(tbl.header) || !Array.isArray(tbl.data)) {
  console.error('[parse_dumpviewer_json] unexpected shape (missing header/data) in ' + src);
  process.exit(1);
}

const columns = tbl.header.map(h => Object.keys(h)[0]);
const types = {};
tbl.header.forEach(h => { const k = Object.keys(h)[0]; types[k] = h[k]; });

let out;
if (asArray) {
  out = {
    source: path.basename(src),
    columns,
    types,
    multiLineCols: tbl.multiLineCols || [],
    rowCount: tbl.data.length,
    data: tbl.data,
  };
} else {
  const rows = tbl.data.map(r => {
    const o = {};
    columns.forEach((c, i) => { o[c] = r[i]; });
    return o;
  });
  out = {
    source: path.basename(src),
    columns,
    types,
    multiLineCols: tbl.multiLineCols || [],
    rowCount: rows.length,
    rows,
  };
}

const json = JSON.stringify(out, null, 2);
if (outPath) {
  fs.writeFileSync(outPath, json, 'utf8');
  console.error(`[parse_dumpviewer_json] wrote ${out.rowCount} rows, ${columns.length} cols -> ${outPath}`);
} else {
  process.stdout.write(json + '\n');
}
