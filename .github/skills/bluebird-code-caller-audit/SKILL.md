---
name: bluebird-code-caller-audit
description: "Find every source-level caller of a symbol in a Bluebird MCP repository without losing branch-specific call sites. Use when asked to search a function/class symbol, enumerate all callers, trace callers upward, compare Bluebird branches, identify XDB/Forwarder paths, or audit a call chain with a user-supplied MCP server name and code symbol."
argument-hint: "MCP server name, repository branch, and symbol; e.g. bluebird-mcp-sql master ResyncWithPrimary"
user-invocable: true
---

# Bluebird Code Caller Audit

## Required inputs

Collect or infer these values from the request:

- **MCP server**: for example `bluebird-mcp-sql`.
- **Scope**: organization, project, repository, and branch. Read the selected MCP configuration if any scope value is unknown.
- **Symbol**: the function, method, class, or identifier to audit.
- **Depth**: caller traversal depth; default to three upstream levels.
- **Branch role conditions** to label, when relevant: `IsXDBInstance`, `HADR_ROLE_FORWARDING_SECONDARY`, `IsForwarderRole`, GeoDR, LogReplica, and feature switches.

Use the selected server's Bluebird tools only. Every Bluebird request must receive the user's original question unchanged.

## Goal

Produce a complete **source-level caller set on the requested branch**, then add graph-based upstream paths. Do not treat a graph result as proof that all callers were found.

## Procedure

### 1. Establish the exact target scope

1. Use the selected Bluebird MCP's `metadata.connection_info` when scope is not fully known.
2. Verify the requested branch explicitly. Do not silently substitute a default branch.
3. State any tool warning that the graph index ignores the requested branch.

### 2. Build the complete direct-caller candidate set from branch-aware source search

Run both searches against the requested branch using `code_search(method=keyword)`:

1. `query=ref:<Symbol>`
2. `query=<Symbol>`

Use `ref:` only as an accelerator. It can miss member calls, macro-mediated calls, parser-unrecognized expressions, or newer branch content. The unprefixed search is the completeness check.

For the unprefixed results, classify every occurrence as one of:

- direct invocation: `Symbol(...)`, `object->Symbol(...)`, `object.Symbol(...)`, or an equivalent qualified call;
- declaration or definition;
- indirect callback, task dispatch, message routing, macro, or function-pointer reference;
- comment, log text, test text, trace flag, feature switch, or documentation.

Use `code_read(method=content, branch=<requested branch>)` on each candidate file and inspect enough surrounding source to determine the containing function and conditions. Never assume snippets alone are enough.

### 3. Record each confirmed direct caller

For every real invocation, report:

- caller function;
- repository source path and source line/range returned by the search;
- full argument list;
- immediate outer conditions (`case`, `if`, retry loop, state/role checks);
- whether it is **XDB-only**, **XDB-capable/conditional**, or **not XDB-specific**;
- evidence for the classification.

Use these classification rules:

- **XDB-only**: guarded exclusively by a true XDB/Forwarder/GeoDR condition.
- **XDB-capable/conditional**: receives `IsXDBInstance()` or has an XDB-specific behavior, but can also execute for non-XDB.
- **Not XDB-specific**: no XDB-specific condition or parameter affects entry.

Do not call a shared `case HADR_ROLE_SECONDARY` / `case HADR_ROLE_FORWARDING_SECONDARY` block XDB-only. It is XDB-capable unless the conditions narrow execution to Forwarding Secondary.

### 4. Find indirect routes

For each callback/task-based direct caller, search the enqueuing or dispatch symbol on the same branch. Examples include `Queue*Task`, `Handle*Task`, recovery callbacks, partner routing, and work-pool dispatch.

Read the source around each dispatch point and present the actual execution order, distinguishing:

- source-level direct invocation of the audited symbol;
- queued/async path that later reaches that invocation;
- recovery callback path;
- test-only or simulator-only route.

### 5. Trace upward with `code_navigate`

Only after the direct caller set is fixed, call `code_navigate(method=CALLED_BY)` for each confirmed caller and recursively for its callers up to the requested depth.

- Pass a node ID whenever the graph returns one.
- Prefer `view=call_site` when exact call locations are needed.
- Keep branch-aware source-search findings separate from graph findings.
- If Bluebird reports that the requested branch is ignored by graph tools, label graph edges as **default-branch supplementary evidence**. Do not discard source-confirmed branch-specific callers.
- If a graph edge is absent, search the dispatch identifier on the requested branch before concluding that there is no upstream path.

### 6. Completeness gate

Before reporting completion, verify all of the following:

- Both `ref:<Symbol>` and bare `<Symbol>` searches ran on the requested branch.
- Every file with potential engine code was read around its match.
- Definitions, declarations, comments, tests, and feature switches are separated from actual calls.
- Every confirmed direct call has role and XDB classification.
- All graph warnings are retained.
- Upstream paths are clearly marked as source-confirmed or graph-supplementary.

## Output format

1. **Scope and branch**: selected MCP server, repository, and requested branch.
2. **Search coverage**: counts/results from `ref:` and bare searches; explain any discrepancy.
3. **Direct callers**: table with caller, location, arguments, outer conditions, XDB classification, and evidence.
4. **Upstream sequences**: one arrow-separated path per caller, to the requested depth. Label test/simulator paths.
5. **XDB / Forwarder summary**: distinguish exclusive from shared paths.
6. **Limitations**: branch-index warnings, unresolved dispatch edges, and any excluded non-code matches.

## Non-negotiable rules

- Do not report the graph's `CALLED_BY` list as the complete caller set.
- Do not omit bare keyword search after `ref:` search.
- Do not call a branch-specific search complete unless all source candidates were reviewed.
- Do not use the symbol's mentions in comments or configuration as callers.
- Do not invent an upstream edge not shown in source or graph output.
