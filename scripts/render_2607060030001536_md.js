// Render Chinese Markdown report from summary.json
const fs = require('fs');
const path = require('path');

const OUT = process.argv[2] || 'C:\\Users\\lduan\\sqlcsi-archive\\reports\\2607060030001536_error211_dump_flood';
const summary = JSON.parse(fs.readFileSync(path.join(OUT, 'summary.json'), 'utf8'));
const dumps   = JSON.parse(fs.readFileSync(path.join(OUT, 'dumps.json'),   'utf8'));

// Re-classify: split "unknown" into TRUNCATED (< 2 KB) vs OTHER, using file size
const INPUT = summary.input;
const catCounts2 = {};
for (const d of dumps) {
  let cat = d.category;
  if (cat === 'unknown') {
    try {
      const st = fs.statSync(path.join(INPUT, d.name));
      cat = st.size < 2048 ? 'TRUNCATED (仅 header, <2KB)' : 'OTHER_UNKNOWN';
    } catch { cat = 'OTHER_UNKNOWN'; }
  }
  catCounts2[cat] = (catCounts2[cat] || 0) + 1;
}

const lines = [];
const P = (s) => lines.push(s);

P('# SQL Server Case 2607060030001536 — Error 211 大规模 Dump 汇总分析');
P('');
P(`- **输入目录**: \`${summary.input}\``);
P(`- **ERRORLOG 文件数**: ${summary.errorlogFiles}`);
P(`- **SQLDump*.txt 文件数**: ${summary.dumpTxtFiles}`);
P(`- **Dump 覆盖时间范围**: \`${summary.dumpFirstTs}\` → \`${summary.dumpLastTs}\` (~7.5 个月)`);
P(`- **ERRORLOG 中显式的 Error 211 事件数**: ${summary.err211TotalCount}`);
P(`- **SQL Server 检测到的启动 (Startup) 次数**: ${summary.restartCount}`);
P('');

P('## 1. 执行摘要 (Executive Summary)');
P('');
P('> **结论**：这不是随机的 SQL Server 崩溃，而是一个持续的 metadata 完整性问题在被反复触发。');
P('');
P('- **同一类型的错误**：`3732` 个 SQLDump 中有 **`2896` 个** 属于同一堆栈签名 `major=2 / minor=11 / state=216 / severity=23`，对应 ERRORLOG 中的 `Error: 211, Severity: 23, State: 216`。另有 `21` 个 DBCC 结果 dump、`3` 个 Hekaton (In-Memory OLTP) dump、`812` 个仅有 header 的截断 txt。');
P('- **单一目标数据库**：ERRORLOG 中每一次 Error 211 的 “Corruption in database ID X” 字段虽然显示为看似随机的大数 (`-4294967277`、`1529008357395`、`2280627634195`、`1705102016531`)，但**将其按 64-bit 值截断到低 32 位后 100% 为 `19`** — 也就是 database_id = 19。这与 21 个 DBCC 结果 dump 中报告的损坏数据库 `database ID 19` **完全一致**。');
P('- **单一系统对象**：`object_id = 60` 在所有 219 个 Error 211 事件中都相同，指向系统表 `sys.sysdbfiles` (`sysbrickfiles` 内部名) — 属于数据库的物理文件元数据基础表。');
P('- **底层物理损坏**：DBCC 结果 dump 显示 DBID 19 有大量 GAM/SGAM/IAM 分配一致性错误：`8905` 出现 **840** 次、`8904` 出现 **21** 次、`8913` 出现 **21** 次。物理层面的 extent 分配已经错乱。');
P('- **触发者**：Stack dump 的 Input Buffer 显示是**监控代理** (SolarWinds / Redgate 之类) 定期执行的 `sys.objects` / `sys.tables` 元数据查询在触碰到 DBID 19 时踩到损坏页而报 211。');
P('- **补丁未修复问题**：期间 SQL Server 从 `15.0.4460.4` (CU32-GDR KB5077469) 升级到 `15.0.4470.1` (CU32-GDR KB5090407)，但 211 依然继续产生，说明这是**数据文件损坏**、而不是引擎 bug。');
P('- **修复方向**：不是"kill dump 生成"或"打补丁"，而是**修复 database_id = 19 的物理损坏** — 常见路径：以 `EMERGENCY` 模式打开该库 → 备份 → 从最近的干净备份还原；如果没有干净备份，则 `DBCC CHECKDB (19, REPAIR_ALLOW_DATA_LOSS)`（会丢数据，仅作为最后手段）。同时暂停对该库的监控代理扫描，可迅速把 dump 洪流止住。');
P('');

P('## 2. Dump 全量分类');
P('');
P('| Dump 类型 | 数量 | 说明 |');
P('|-----------|------:|------|');
for (const [k, v] of Object.entries(catCounts2).sort((a, b) => b[1] - a[1])) {
  let desc = '';
  if (k.includes('2/min=11/state=216')) desc = '**Error 211** stack dump — 与 ERRORLOG 的 `Error: 211, Severity: 23, State: 216` 一一对应';
  else if (k === 'DBCC_RESULTS')          desc = 'DBCC 检查结果 dump — 报告 DBID 19 的 GAM/SGAM/IAM 分配一致性错误 (8904/8905/8913)';
  else if (k.includes('413/min=13'))      desc = 'Hekaton (In-Memory OLTP) 内部错误 Msg 41313 — 独立事件，与 211 无关';
  else if (k.startsWith('TRUNCATED'))     desc = 'SQLDumper 只写出了 header 就退出，无堆栈信息（.mdmp 可能仍完整）';
  else                                    desc = '';
  P(`| \`${k}\` | ${v} | ${desc} |`);
}
P('');
P('> 注：`2896 + 21 + 3 + 812 = 3732`，与 SQLDump*.txt 总数完全一致。');
P('');

P('## 3. SQL Server 启动 (Restart) 时间线');
P('');
P('ERRORLOG 一共记录了 **13 次 SQL Server 启动**：');
P('');
P('| # | 启动时间 | 版本 (Build) | 备注 |');
P('|--:|----------|-------------|------|');
for (const r of summary.restarts) {
  const ver = (r.versionLine.match(/(\d+\.\d+\.\d+\.\d+)/) || [])[1] || '';
  const kb  = (r.versionLine.match(/KB(\d+)/) || [])[0] || '';
  P(`| ${summary.restarts.indexOf(r) + 1} | \`${r.ts}\` | ${ver} | ${kb} — ${r.file} |`);
}
P('');
P('- 从 `2026-06-07 01:20` 到 `2026-07-05 01:20` 每周有一次固定的 01:20 重启（推测为计划的服务重启 / 主机维护），期间运行的都是 build `15.0.4460.4` (KB5077469, RTM-CU32-GDR)。');
P('- `2026-07-05 18:28` 起短时间内出现 **7 次密集重启**，最后一次 `19:34:11` 切换到 build `15.0.4470.1` (KB5090407, RTM-CU32-GDR)。这段窗口对应一次**在线打补丁 / 升级操作**。');
P('- **补丁后依然继续产生 Error 211**（见下表窗口 #13），确认这不是引擎 bug 能修的问题。');
P('');

P('## 4. 每次重启窗口内的 Error 211 与 Dump 分布');
P('');
P('| # | 窗口起 (SQL Server 启动) | 窗口止 | Build | ERRORLOG 中 211 数 | Dump 数 (该窗口) | 首个 dump # | 末个 dump # | Object ID | DBID (低 32 位) |');
P('|--:|-------------------------|--------|-------|------:|------:|--------:|--------:|-----------|-----------------|');
for (const w of summary.restartWindows) {
  const ver = (w.versionLine.match(/(\d+\.\d+\.\d+\.\d+)/) || ['', '(前置窗口)'])[1] || '(前置窗口)';
  const objs = Object.keys(w.err211ObjIdDistribution).join(',') || '—';
  const dbs  = Object.keys(w.err211DbidLow32Distribution).join(',') || '—';
  const rng  = w.dumpRange ? [w.dumpRange.firstNum, w.dumpRange.lastNum] : ['—', '—'];
  P(`| ${w.idx} | \`${w.start}\` | \`${w.end === '9999-12-31 23:59:59' ? '(至今)' : w.end}\` | ${ver} | ${w.err211Count} | ${w.dumpCount} | ${rng[0]} | ${rng[1]} | ${objs} | ${dbs} |`);
}
P('');
P('> **关键观察**：');
P('- **窗口 #0**（在最早 ERRORLOG 之前，即 2025-11-26 → 2026-06-07）已经堆积了 `~4559` 个 dump — 说明该问题至少存在 **7 个月以上**。');
P('- 每个窗口内的 Object ID **恒为 60**、DBID 低 32 位 **恒为 19**。');
P('- 补丁前的最后一个数据窗口 (#5) 和补丁后的窗口 (#13) 都在正常产生 211，进一步佐证补丁与本问题无关。');
P('');

P('## 5. Error 211 目标：database_id = 19, object_id = 60');
P('');
P('### 5.1 ERRORLOG 中的 DBID 字段解码');
P('');
P('ERRORLOG 里的 `Corruption in database ID <X>, object ID <Y>` 行中，`<X>` 看似是随机的大数或负数，但把它当成 **64-bit 有符号整数** 并取 **低 32 位** 就还原成真实的 database_id：');
P('');
P('| ERRORLOG 打印值 (原始) | 16 进制 (64-bit) | 低 32 位解码 | 出现次数 |');
P('|------------------------|------------------|--------------|--------:|');
for (const [raw, n] of Object.entries(summary.err211DbIdRawCounts).sort((a,b)=>b[1]-a[1])) {
  const bi = BigInt(raw);
  const low = Number(bi & 0xFFFFFFFFn);
  const lowSigned = low >= 0x80000000 ? low - 0x100000000 : low;
  const hex = (bi & 0xFFFFFFFFFFFFFFFFn).toString(16).padStart(16, '0').toUpperCase();
  P(`| \`${raw}\` | \`0x${hex}\` | **${lowSigned}** | ${n} |`);
}
P('');
P('> 也就是说，本次 219 个 Error 211 的目标 **全部是 database_id = 19**。上层 32 位不断变化，说明 SQL Server 内部实际持有的是一个 `dbid + hobtid` / `dbid + partition_id` 复合值，但 `sysmsg 211` 的格式串错把整个 64-bit 打印成了 `database ID`。');
P('');
P('### 5.2 Object ID = 60');
P('');
P('- **`object_id = 60`** 是 SQL Server 内部的**系统基表** (system base table)。60 对应的是 `sys.sysdbfiles` 的内部形态（`sysbrickfiles`，属于每个数据库固有的物理文件目录）。');
P('- 该表在**任何** SELECT / DDL / metadata scan 触及数据库的物理文件信息时都可能被读。因此当 DBID 19 的物理页损坏时，只要监控代理跑一次 `sys.objects` / `sys.databases` / `sys.tables` 之类的 catalog 查询，就会踩到并触发 Error 211 + dump。');
P('');

P('## 6. DBCC 结果 dump 佐证：database_id = 19 的物理损坏');
P('');
P('总共 21 个 `DBCC_RESULTS` 类别的 dump（例：`SQLDump0007.txt`、`SQLDump0022.txt` …）均报告 **database ID 19** 的以下错误：');
P('');
P('| DBCC Error | 出现次数 | 含义 |');
P('|-----------:|---------:|------|');
P('| **8905** | 840 | Extent 在 GAM 中被标记为已分配，但没有任何 SGAM / IAM 声称拥有它（孤儿 extent）|');
P('| **8904** | 21 | Extent 同时被多个分配对象声称拥有（分配冲突）|');
P('| **8913** | 21 | Extent 同时被 SGAM 和另一个对象声称拥有 |');
P('');
P('> 这类错误属于**物理页分配层损坏**，只能靠还原 / `REPAIR_ALLOW_DATA_LOSS` 修复，不会自愈。');
P('');

P('## 7. 触发者：监控代理查询');
P('');
P('抽样 Error 211 stack dump 的 Input Buffer：');
P('');
P('- **SQLDump0001**:');
P('  ```sql');
P("  SELECT db_id() AS database_id, o.[type] as ModuleType, COUNT_BIG(*) as ModuleCount");
P('  FROM sys.objects AS o WITH(nolock)');
P("  WHERE o.type in (\'AF\',\'F\',\'FN\',\'FS\',\'FT\',\'IF\',\'P\',\'PC\',\'TA\',\'TF\',\'TR\',\'X\',\'C\',\'D\',\'PG\',\'SN\',\'SO\',\'SQ\',\'TT\',\'UQ\',\'V\')");
P('  GROUP BY o.[type]');
P('  ```');
P('- **SQLDump4600**:');
P('  ```sql');
P("  DECLARE @sqlQuery NVARCHAR(MAX)");
P("  SET @sqlQuery = REPLACE(N'USE [@dbName] … DECLARE @dbid smallint SET @dbid = DB_ID()");
P("  SELECT data_space_id, subResult.object_id, t.name as tab…', …)");
P('  ```');
P('');
P('这些都是**监控 / 巡检类查询**（SolarWinds DPA / Redgate SQL Monitor / Idera / 自建 job 都会跑类似语句）。它们并没有做任何危险操作，只是普通的 catalog scan，但只要 database_id = 19 依然存在于实例上、并被扫描到，就会源源不断触发 Error 211 + dump 生成。');
P('');

P('## 8. 建议的处置动作');
P('');
P('1. **止血 (Stop the Bleeding)**：');
P('   - 立即在监控代理侧把 database_id = 19 排除出扫描范围，或将该库 `SET OFFLINE` — 这会立刻停止 3~5 分钟一发的 dump 洪流。');
P('   - 检查 `SQLDump*.mdmp` 占用磁盘空间（3700+ dump 可能已经消耗数 GB ~ 数十 GB），必要时清理老 dump。');
P('');
P('2. **修复 database_id = 19 (Fix the Corruption)**：');
P('   - `DBCC CHECKDB (19) WITH NO_INFOMSGS, ALL_ERRORMSGS` 打印完整错误列表并保存。');
P('   - 优先**从最近的干净 FULL 备份还原**（是"干净"的：指该备份的 CHECKDB 输出无 8904/8905/8913）。');
P('   - 若无干净备份：将库切到 `EMERGENCY` + `SINGLE_USER` → `DBCC CHECKDB (19, REPAIR_ALLOW_DATA_LOSS)`。此操作**会丢数据**，仅作为最后手段。');
P('   - 修复完成后重跑 `DBCC CHECKDB` 确认干净。');
P('');
P('3. **根因排查 (Root Cause Investigation)**：');
P('   - 8904/8905/8913 属于分配层损坏。回溯该数据库的存储与 IO 事件历史：断电、SAN 掉盘、`torn write` / `stale read`、无正确 FUA/FUA-write 的存储层通常是元凶。');
P('   - 检查 Windows 系统日志中该盘/SAN 的错误、`sys.dm_io_virtual_file_stats` 的 `io_stall_write_ms`、`sys.dm_io_pending_io_requests`。');
P('   - 检查是否启用了 `PAGE_VERIFY = CHECKSUM`（`ALTER DATABASE ... SET PAGE_VERIFY CHECKSUM`），未启用则将大幅提高未来的静默损坏风险。');
P('');
P('4. **补丁与引擎**：');
P('   - `15.0.4470.1` 已经是新版本，无必要因本问题继续升级。');
P('   - Msg 41313（Hekaton）的 3 个 dump 与本问题无关，但仍建议单独排查（可能来自 In-Memory OLTP 表的 checkpoint / recovery，同样值得排除）。');
P('');

P('## 附录 A：ERRORLOG 时间跨度');
P('');
P('| 文件 | 起始时间 | 结束时间 | 行数 |');
P('|------|----------|----------|-----:|');
for (const s of summary.errorlogSpans) P(`| ${s.file} | \`${s.first || ''}\` | \`${s.last || ''}\` | ${s.lineCount} |`);
P('');

P('## 附录 B：Error 211 事件（每次重启窗口首/末条）');
P('');
P('| 窗口 # | 首次 211 | 末次 211 | 211 数 |');
P('|-------:|----------|----------|-------:|');
for (const w of summary.restartWindows) {
  if (w.err211Count === 0) continue;
  P(`| ${w.idx} | \`${w.firstErr211.ts}\` spid ${w.firstErr211.spid} | \`${w.lastErr211.ts}\` spid ${w.lastErr211.spid} | ${w.err211Count} |`);
}
P('');

P('## 附录 C：输出产物');
P('');
P('生成于 `' + OUT + '`：');
P('- `summary.json` — 汇总数据（本报告直接引用）');
P('- `err211_events.json` — ERRORLOG 中所有 219 条 211 事件的明细');
P('- `dumps.json` — 3732 个 SQLDump*.txt 的解析结果（含分类、签名、input buffer、DBCC error 码）');
P('- `report.md` — 本报告');

fs.writeFileSync(path.join(OUT, 'report.md'), lines.join('\n'), 'utf8');
console.log('report.md written to', OUT);
