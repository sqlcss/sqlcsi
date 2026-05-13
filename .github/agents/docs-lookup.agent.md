---
name: docs-lookup
description: >-
  Research SQL Server errors, wait types, latch classes, and technical topics using
  multiple knowledge sources in parallel. Dispatches sub-agents to search different
  MCP sources, saves results locally, then synthesizes findings.
  Use after ERRORLOG/XEvent analysis identifies top issues, or when the user asks
  "research error XXXX", "look up KB for error", "what causes WRITELOG wait",
  or when another agent passes a search query (e.g. latch class name).
tools: [execute, read, edit, search, agent, microsoft-learn/*, csswiki/*, msdata/*, enghub/*]
---

# Multi-Source Docs Lookup

Research SQL Server topics by dispatching parallel searches across multiple knowledge sources,
saving results locally, and synthesizing findings.

## Search Sources

| # | Source | MCP Tools | What it provides |
|---|--------|-----------|-----------------|
| 1 | Microsoft Learn | `microsoft-learn-*` | Official docs, KB articles, code samples |
| 2 | CSS Wiki | `csswiki-search_wiki` | Internal TSGs, troubleshooting guides |
| 3 | msdata Wiki | `msdata-search_wiki` | Internal engineering wiki |
| 4 | EngHub | `enghub-search`, `enghub-fetch` | Engineering docs (eng.ms) |

## Workflow

### Step 1: Receive Search Query

The query can come from:
- User directly: "research error 19419", "what causes WRITELOG wait"
- Another agent: latch skill passes `ACCESS_METHODS_DATASET_PARENT`
- Orchestrator: passes top error numbers from ERRORLOG analysis

### Step 2: Dispatch Parallel Searches

For each source, use `runSubagent` with detailed search instructions.
Each sub-agent:
1. Searches its MCP source with the query
2. Fetches the **top 3 most relevant** full page content
3. Saves each fetched page to `reports/{case_id}_docs/{source}_{sanitized_title}.md`
4. Returns: title, URL, brief summary, local file path

**Output directory**: `reports/{case_id}_docs/`

### Sub-Agent Instructions by Source

**Microsoft Learn** (`microsoft-learn-*`):
- `microsoft_docs_search(query)` → get URLs
- `microsoft_docs_fetch(url)` → get full page markdown
- Save to `reports/{case_id}_docs/learn_{title}.md`
- Return URL: the learn.microsoft.com URL

**CSS Wiki** (`csswiki-*`):
- `csswiki-search_wiki(searchText, project: ["SQLServerWindows"])` → get results with paths
- `csswiki-repo_get_file_content(project, repositoryId, path, version: "main", versionType: "Branch")` → fetch full page
- Known wiki repositoryId: SQLServerWindows = `d33c9417-111f-4539-99c6-de85ae587620`
- Save to `reports/{case_id}_docs/csswiki_{title}.md`
- **Return URL**: `https://dev.azure.com/Supportability/{project}/_wiki/wikis/{wiki-name}/{page-path}`
- ⚠️ Do NOT use `wiki_get_page_content` — often fails with 404. Use `repo_get_file_content`.

**msdata Wiki** (`msdata-*`):
- `msdata-search_wiki(searchText)` → get results
- `msdata-repo_get_file_content(...)` → fetch full page if available
- Save to `reports/{case_id}_docs/msdata_{title}.md`

**EngHub** (`enghub-*`):
- `enghub-search(query)` → get results
- `enghub-fetch(url)` → get full page
- Save to `reports/{case_id}_docs/enghub_{title}.md`

### Step 3: Collect & Synthesize

After all sub-agents complete:

**Layer 1 — Summaries**: Read sub-agent return messages for titles + URLs + file paths.

**Layer 2 — Selective read**: Pick the 3-5 most relevant saved files and read them.
Prioritize: CSS Wiki TSGs > EngHub > msdata Wiki > Microsoft Learn.

**Layer 3 — On-demand**: If caller needs deeper info, read additional files.

### Step 4: Return to Caller

Return format — **each finding MUST include original text excerpt + URL**:

```
## Docs Research: {query}

### Source 1: Microsoft Learn
1. [{title}]({url})
   📄 Saved: reports/{case_id}_docs/learn_{title}.md
   > {relevant paragraph quoted from the doc}

2. [{title}]({url})
   📄 Saved: reports/{case_id}_docs/learn_{title2}.md
   > {relevant paragraph quoted from the doc}

### Source 2: CSS Wiki
1. [{title}]({wiki_url})
   📄 Saved: reports/{case_id}_docs/csswiki_{title}.md
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
- Every fetched doc MUST be saved to `reports/{case_id}_docs/`
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

