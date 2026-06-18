---
name: docs-lookup
description: >-
  Research SQL Server errors, wait types, latch classes, and technical topics using
  multiple knowledge sources in parallel. Dispatches sub-agents to search different
  MCP sources, saves results locally, then synthesizes findings.
  Use after ERRORLOG/XEvent analysis identifies top issues, or when the user asks
  "research error XXXX", "look up KB for error", "what causes WRITELOG wait",
  or when another agent passes a search query (e.g. latch class name).
tools: [execute, read, edit, search, agent, microsoft-learn/*, csswiki/*, msdata/*, enghub/*, github-mcp-server/*]
---

# Multi-Source Docs Lookup

Research SQL Server topics by dispatching parallel searches across multiple knowledge sources,
saving results locally, and synthesizing findings.

## Search Sources & Sub-Agents

This is the **parent orchestrator**. It (1) understands the user's input — *what* to look up
and *which sources* (scope) — then (2) dispatches the matching **sub-agents** in **parallel**
(via `runSubagent`). Each sub-agent does **only search + fetch**, saving all fetched content
to a **temp session folder**. Finally the parent (3) reads **all** the saved content and
writes the answer.

| # | Source | Sub-Agent | What it provides | Scope param |
|---|--------|-----------|------------------|-------------|
| 1 | Web | `search-web` | Public web search (Tavily) | — |
| 2 | Microsoft Learn | `search-microsoft-learn` | Official docs, KB articles, code samples | — |
| 3 | CSS Wiki | `search-csswiki` | Internal TSGs (SQLServerWindows / AzureSQLMI / AzureSQLDB) | `projects: ...` |
| 4 | msdata | `search-msdata` | Internal wiki, source code, work items | `modes: wiki, code, workitems` |
| 5 | EngHub | `search-enghub` | Engineering docs (eng.ms) | — |
| 6 | GitHub | `search-github` | Repos, issues, pull requests | — |

## Workflow

### Step 1: Understand Input (content + scope)

From the user's request, determine **two things**:
- **What to look up** — the search keywords / topic (error number, wait type, latch class, feature…).
- **Scope** — which sources to search. If the user already states a scope, use it; otherwise ask (Step 2).

The request can come from:
- User directly: "research error 19419", "what causes WRITELOG wait"
- Another agent: latch skill passes `ACCESS_METHODS_DATASET_PARENT`
- Orchestrator: passes top error numbers from ERRORLOG analysis

### Step 2: Ask Search Scope (ALWAYS, unless caller already specified)

Before dispatching, **ask the user which sources to search**. Use the ask-questions tool
with multi-select so the user can pick one or more:

```
Question: "要在哪些来源搜索 \"{query}\"？(可多选)"
Header: "Search Scope"
multiSelect: true
Options:
  - "Web"                    (recommended) — 公网搜索 (Tavily)
  - "Microsoft Learn"        (recommended) — 官方文档 / KB / 代码示例
  - "CSS Wiki"               — 内部 TSG (SQLServerWindows / AzureSQLMI / AzureSQLDB)
  - "msdata"                 — 内部 wiki / 源码 / work items
  - "EngHub"                 — eng.ms 工程文档
  - "GitHub"                 — repos / issues / PRs
```

If the caller (another agent / orchestrator) already passed a `sources:` line, **skip the
question** and use it directly. Default when nothing is specified: Web + Microsoft Learn.

### Step 3: Dispatch Selected Sub-Agents in Parallel

Dispatch the sub-agent for **each selected source in a single parallel batch** using
`runSubagent`. Each sub-agent does **only search + fetch** (no analysis) and saves all
fetched content to the shared temp session folder. Pass each sub-agent a prompt containing
`Search query:` and `out_dir:` (plus its scope param where applicable):

| Selected | `runSubagent` agentName | Prompt to pass |
|----------|-------------------------|----------------|
| Web | `search-web` | `Search query: {query}`<br>`out_dir: {temp_dir}` |
| Microsoft Learn | `search-microsoft-learn` | `Search query: {query}`<br>`out_dir: {temp_dir}` |
| CSS Wiki | `search-csswiki` | `projects: SQLServerWindows, AzureSQLMI, AzureSQLDB`<br>`Search query: {query}`<br>`out_dir: {temp_dir}` |
| msdata | `search-msdata` | `modes: wiki, code, workitems`<br>`Search query: {query}`<br>`out_dir: {temp_dir}` |
| EngHub | `search-enghub` | `Search query: {query}`<br>`out_dir: {temp_dir}` |
| GitHub | `search-github` | `Search query: {query}`<br>`out_dir: {temp_dir}` |

> ⚠️ **MANDATORY RULE (Microsoft Learn MCP):** Whenever the Microsoft Learn scope is
> selected, `search-microsoft-learn` **MUST** call `microsoft-learn-microsoft_docs_search`
> **FIRST** to ground results, **before** any `microsoft_docs_fetch` / `microsoft_code_sample_search`.
> The parent verifies this in Step 4 — if a `search-microsoft-learn` result was fetched without
> a prior `microsoft_docs_search`, re-dispatch or run `microsoft_docs_search` directly before answering.

**Temp session folder** (`{temp_dir}`): `~/.copilot/agents/search_result_{session_id}/`
(on Windows `~` = `C:\Users\lduan`). Use one folder per session so all sub-agents write
to the **same** directory and the parent can read everything in one place. This is
intentional **temporary** storage — it holds intermediate fetched content only and may be
auto-cleaned after the session. Pass the **same** `{temp_dir}` to every sub-agent.

Each sub-agent searches its source, fetches the top results, saves the full content under
`{temp_dir}`, and returns: title, URL (or wiki path), brief summary, local file path.

### Step 4: Read All Content & Synthesize

After all sub-agents complete, **read every file** they saved under `{temp_dir}` — the
sub-agents only return summaries, so the full content lives in the temp files:

**Layer 1 — Index**: Read sub-agent return messages for titles + URLs + saved file paths.

**Layer 2 — Read all saved content**: Read **all** files in `{temp_dir}` (list the directory,
then read each `.md`). Prioritize reading order: CSS Wiki TSGs > EngHub > msdata Wiki >
Microsoft Learn > GitHub, but do not skip any — the answer is grounded in the full content.

**Layer 2b — Verify Microsoft Learn rule**: If the Microsoft Learn scope was used, confirm
`search-microsoft-learn` actually ran `microsoft_docs_search` first (it should have surfaced search hits,
not just fetched URLs). If that step appears to have been skipped — or key page types
(what's-new / known-issues / discontinued / release-notes) are missing — the parent **MUST**
run `microsoft-learn-microsoft_docs_search` itself before synthesizing, then fetch the
highest-value hits with `microsoft_docs_fetch`.

**Layer 3 — On-demand**: If a referenced page needs deeper detail, re-fetch via the relevant source.

### Step 5: Return to Caller

Return format — **each finding MUST include original text excerpt + URL**:

```
## Docs Research: {query}

### Source 1: Microsoft Learn
1. [{title}]({url})
   📄 Saved: {temp_dir}/learn_{title}.md
   > {relevant paragraph quoted from the doc}

2. [{title}]({url})
   📄 Saved: {temp_dir}/learn_{title2}.md
   > {relevant paragraph quoted from the doc}

### Source 2: CSS Wiki
1. [{title}]({wiki_url})
   📄 Saved: {temp_dir}/csswiki_{title}.md
   > {relevant paragraph quoted from the TSG}

### Source 3: msdata / EngHub
(same format)

### Synthesis
{Cross-reference analysis: consensus, conflicts, key takeaways}

### Key Findings
1. {Finding} — Source: [{title}]({url})
2. {Finding} — Source: [{title}]({url})
```

**Rules:**
- Every finding MUST include a quoted original paragraph (not just a summary)
- Every finding MUST include a clickable URL
- The answer MUST be grounded in the full content read from `{temp_dir}` (not just summaries)
- CSS Wiki URLs follow format: `https://dev.azure.com/Supportability/{project}/_wiki/...`

## Required MCP Servers

| Server | Purpose | Required |
|--------|---------|----------|
| `microsoft-learn` | Search docs, KB articles, diagnostic queries (Step 7) | **Yes** for Step 7 |

If `microsoft-learn` MCP is not connected, skip Step 7 and fall back to Workflow 3 directly.

## Step 7: Microsoft Docs Lookup (MANDATORY after Step 6)

After the user selects error(s) to investigate, use the Microsoft Learn MCP tools to
search for official documentation, known fixes (KB articles), and diagnostic queries.

### 7.1 Parallel Search — Docs + Code Reference

For each selected error, run **two parallel searches**:

**Search A — Conceptual docs (microsoft_docs_search):**
```
Query 1: "SQL Server Error {error_number} {error_message_keywords}"
Query 2: "SQL Server {subsystem_keyword} troubleshoot {symptom_keywords}"
```
Where:
- `{error_message_keywords}` = key phrases from the error message (e.g., "missing log block", "transport")
- `{subsystem_keyword}` = human-readable subsystem (e.g., "Always On Availability Groups" for HADR errors)
- `{symptom_keywords}` = observable behavior (e.g., "data movement secondary replica")

**Search B — KB fix + CU (microsoft_docs_search):**
```
Query 3: "SQL Server {version_short} cumulative update fix {error_number} {subsystem_keyword}"
Query 4: "KB {error_number} {error_message_keyword} fix cumulative update"
```
Where `{version_short}` comes from `server_info.version_short` in the JSON findings.

**Search C — Diagnostic queries (microsoft_code_sample_search):**
```
microsoft_code_sample_search(
  query: "{dmv_or_diagnostic_topic} {subsystem_keyword}",
  language: "sql"
)
```
DMV topic mapping by subsystem:

| Subsystem | DMV / Diagnostic Topic |
|-----------|----------------------|
| HADR_ERROR* | `sys.dm_hadr_database_replica_states log_send_queue_size redo_queue_size` |
| LOCKING | `sys.dm_tran_locks sys.dm_exec_requests blocking` |
| MEMORY | `sys.dm_os_memory_clerks sys.dm_os_process_memory` |
| LOG | `sys.dm_db_log_info sys.dm_db_log_stats transaction log` |
| SERVICE | `sys.dm_server_services sys.dm_os_sys_info` |
| LOGIN* | `sys.dm_exec_sessions login failed audit` |
| FULLTEXT | `sys.dm_fts_index_population fulltext catalog` |
| BACKUP | `sys.dm_exec_requests backup restore progress` |
| STORAGE_PAGE | `sys.dm_db_index_physical_stats sys.dm_io_virtual_file_stats` |

### 7.2 Analyze KB Fix Applicability

After finding KB articles, determine if the fix applies to the current server:

```
1. Extract KB number and the CU that contains the fix
2. Compare fix CU build number against server_info.build
3. Determine:
   - FIX_NOT_APPLIED: server build < fix build → recommend upgrade
   - FIX_ALREADY_APPLIED: server build >= fix build → fix didn't resolve, investigate further
   - NO_KB_FOUND: no known fix → may be a configuration/environment issue
```

### 7.3 Fetch Deep Content (Conditional)

If search results reference a highly relevant troubleshooting page, use `microsoft_docs_fetch`
to get the full page content. Fetch when:

- The search excerpt mentions the exact error number but is truncated
- A troubleshooting guide with step-by-step resolution is found
- A KB article has detailed workaround or trace flag information

### 7.4 Compile Analysis Report

After gathering docs, KB info, and diagnostic queries, present a structured summary:

```markdown
## Error {XXXX} — Microsoft Docs Analysis

### 错误含义
{1-2 sentence explanation from official docs}

### 已知 Fix
| 项目 | 详情 |
|------|------|
| KB | {KB number and title, or "未找到已知 KB"} |
| 修复版本 | {CU version that contains the fix} |
| 当前版本 | {server_info.version_short} ({server_info.build}) |
| 状态 | {FIX_NOT_APPLIED / FIX_ALREADY_APPLIED / NO_KB_FOUND} |

### 根因分析
{Based on docs + errorlog patterns, list likely causes with evidence}

### 诊断查询
{SQL queries from microsoft_code_sample_search, ready to run}

### 建议修复方案
1. {Priority action items based on KB status and root cause}
2. ...
```

### 7.5 Ask Next Step

After presenting the analysis, ask the user:

```
Question: "Microsoft Docs 分析完成。接下来你想怎么做？"
Header: "Next Step"
Options:
  - "搜索源码 (Workflow 3)" — 在 SQL Server 源码中搜索 Error {XXXX} 的代码路径
  - "查看其他错误" — 返回 Step 6 选择另一个错误
  - "分析完成" — 结束分析
```

### 7.6 Example Interaction

```
Agent: [并行调用 microsoft_docs_search × 2 + microsoft_code_sample_search × 1]

       ## Error 19432 — Microsoft Docs Analysis

       ### 错误含义
       HADR transport 层在 secondary 副本接收 log block 时检测到不连续的
       LSN gap，触发 log scan 重启自我修复。

       ### 已知 Fix
       | 项目 | 详情 |
       |------|------|
       | KB | KB4541309 — "Missing log block may occur with Always On AG" |
       | 修复版本 | SQL Server 2016 SP2 CU12 (13.0.5698.0) |
       | 当前版本 | SQL Server 2016 SP2-CU15-GDR (13.0.5865.1) |
       | 状态 | FIX_ALREADY_APPLIED — CU15 > CU12 |

       ### 根因分析
       - KB4541309 已包含，但错误仍出现 → 非该 KB 修复的场景
       - Error 9642 同期出现 → 副本间版本不匹配
       - 4 副本跨 SGA/SGB 数据中心 → 网络延迟可能导致 transport gap

       ### 诊断查询
       [DMV queries for log_send_queue_size, redo_queue_size, etc.]

       ### 建议修复方案
       1. 统一所有副本到相同 CU 版本 (消除 Error 9642)
       2. 升级到 SQL Server 2016 SP3
       3. 检查跨数据中心网络质量

       [接下来你想怎么做？]

User: 执行诊断查询

Agent: → 通过 sqlcmd 执行 DMV 查询...
```

---

