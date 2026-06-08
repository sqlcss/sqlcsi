---
name: sql-av-analysis
description: '**WORKFLOW SKILL** — Root-cause a SQL Server Access Violation (AV) from a TTD/dump and write a product-group-ready ICM. USE FOR: analyzing AV/crash dumps in sqllang/sqlmin; reverse-engineering hash-table / disjoint-set / container corruption; tracing a NULL/bad pointer back to the C++ object and the missing code path; deriving and validating hash/bucket placement in WinDbg; writing an evidence-backed bug report (ICM) for the SQL Server product team. DO NOT USE FOR: general T-SQL questions; query tuning; setup/config issues without a dump. PRINCIPLE: every claim must be backed by raw WinDbg output + matching source code; never guess from local variable names.'
---

# SQL Server AV Analysis + ICM Authoring

A reusable workflow for taking a SQL Server crash (TTD trace or dump) all the way to a
fix-ready ICM for the product group. Distilled from a real case:
`AV in sqllang!CDisjointSet<...>::FindNoCompression`, triggered by
`EXEC sp_describe_undeclared_parameters` on a `SELECT IDENTITY(...) INTO #t` query.

> **Iron rule:** the conclusion goes straight to the product group to change code.
> One wrong inference misleads the fix. Every reasoning step needs **disassembly + source**
> double-confirmation. Never infer call arguments from local variable names (callee-saved
> registers only hold caller-frame leftovers).

## Recommended setup

This skill works best with a TTD trace or dump already opened in WinDbg and exposed through the
WinDbg MCP Server. Configure WinDbg MCP Server before starting analysis so the agent can run
debugger commands, query TTD events, retrieve source, inspect `dx` objects, and preserve raw output
for the evidence chain. Setup reference:
https://www.osgwiki.com/wiki/WinDbg_MCP_Server

If WinDbg MCP Server is not available, you can still use this skill as a manual checklist, but you
must paste the raw WinDbg command output and matching source snippets into the conversation. Do not
replace missing debugger evidence with assumptions.

## When to use

| You have… | Use this skill to… |
|-----------|--------------------|
| A TTD trace / crash dump of an AV in SQL Server engine code | Find the faulting instruction, the bad object, the missing code path |
| A container corruption (hash table, disjoint set, map, tree) | Dump buckets, derive & validate the hash, find the unregistered node |
| A confirmed root cause | Write a product-group ICM in the established evidence-chain format |

## Three bundled references

| Step | Reference | What it gives you |
|------|-----------|-------------------|
| 1. Analyze | [reference/analysis-methodology.md](reference/analysis-methodology.md) | Iron rules, 7-step flow, report presentation rules, hash-functor-first rule, 3-datapoint validation |
| 2. Operate WinDbg | [reference/windbg-cheatsheet.md](reference/windbg-cheatsheet.md) | Tested commands: radix/truncation/register traps, one-line bucket dump, `dx -r3` tree, hash/layout validation, reverse breakpoints |
| 3. Report | [reference/icm-writing.md](reference/icm-writing.md) | 10-section ICM structure + 7-part evidence chain (raw output paired with source) |

## Workflow

1. **Pin the AV** — `.exr -1`, `r`, `u rip L3`, `k`, `!ttdext.position`. Identify read/write,
   target address, the dereferenced `[reg+off]`, and which C++ field/object that offset is.
2. **Identify the bad object** — the NULL/bad pointer is which member of which runtime object?
   (Not the source-level name — the actual runtime arg/field.)
3. **Explain why it's bad** — walk back: who should have constructed / inserted / registered it?
   Which path skipped it?
4. **Compare siblings** — why did the other objects in the same container not AV? Find the
   differing branch; map it to a source line.
5. **Validate every computed value against memory** — any hash/bucket/offset/field you compute
   from source MUST be printed from memory and matched ("computed = X, dump = X ✓"). If it
   doesn't match, stop and re-investigate — never "force-fit".
6. **Locate the code & version** — which commit/branch introduced the differing branch; is it
   already fixed upstream? Search msdata / GitHub history.
7. **Write the ICM** — follow [reference/icm-writing.md](reference/icm-writing.md): every claim
   is raw WinDbg output immediately followed by the matching source. End with a self-contained
   T-SQL repro and 2–3 fix directions for the PG to choose.

## Non-negotiables

- Find the **hash functor source first** — don't assume hash key == container KeyType. A functor
  may transform the key (e.g. `ScaOp_Identifier` hashes its `CValRef*`, not the `COptExpr*`).
- **≥3 independent data points must all match** before declaring "the algorithm is correct".
- Treat hash arithmetic as version/source-specific. If a guessed `Hash64bits` formula fails to
  match live `m_hashVal` values, stop using it; prove absence by full bucket enumeration or by
  stepping the actual hash call in TTD.
- Validate container/layout through `dx` field paths before using raw offsets. Do not cast a
  `CAutoP`/wrapper object's first qword as the contained pointer unless `dx` proves that layout.
- WinDbg defaults to **hex** — prefix decimal constants with `0n`. Source `(UINT32)` casts need
  `& 0xFFFFFFFF`. Temp registers are numeric only: `$t0`–`$t9`. `.for`/`.while` must be one line.
- In RETAIL builds, `Assert(FContains(...))` guards are compiled out — a missing/unregistered
  node silently becomes a NULL deref. Always check whether a DEBUG assert would have caught it.
