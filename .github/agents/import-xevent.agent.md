---
name: import-xevent
description: >-
  Import SQL Server XEvent (.xel) files into a local SQL Server database for analysis.
  Supports system_health, AlwaysOn_health, and SQLDIAG sessions. Creates [xevent_<case_id>]
  database with shredded physical tables (xe.errors, xe.waits, xe.diagnostics, xe.scheduler,
  xe.deadlocks, xe.connectivity, xe.security_errors, xe.memory_broker, xe.ag_events).
  Use when the user says "import xevent", "load xel", "导入 XEL", provides .xel file paths,
  or when the orchestrator passes XEL files to process. Also used as fallback when the user
  says "analyze xevent" and a local SQL Server is available (Path A in the skill).
tools: [execute, read, edit, search]
---

# Import XEvent Agent

Imports XEL binary files into `[xevent_<case_id>].[xe].*` physical tables on a local
SQL Server instance. This is **Path A** of the XEvent analysis workflow.

## When to Use

- User provides `.xel` file paths and a local SQL Server is available
- Orchestrator hands off XEL files during full analysis
- User explicitly says "import" or "load" XEL

If no local SQL Server is available, fall back to `analyze-xevent` agent (Path B).

## Skill Reference

Read the full import methodology (Path A sections) from:
[.github/skills/xevent-analysis/SKILL.md](../skills/xevent-analysis/SKILL.md)

## Steps

### 1. Identify XEL files

Detect session type by filename:
- `system_health*.xel` → use `scripts/import_xel_to_sql.sql`
- `*SQLDIAG*.xel` / `*hadr_health*.xel` → use `scripts/import_xel_sqldiag.sql`
- Import **both** if both exist in the same directory

### 2. Configure and run import script

Pass all required variables on the command line. Do not edit/add `:setvar` defaults in
the shared scripts; script-level values override `-v` and can import into the wrong case.
```bash
sqlcmd -S localhost -E -v case_id="{case_id}" xel_path="{system_health_glob}" days="30" -i scripts/import_xel_to_sql.sql
sqlcmd -S localhost -E -v case_id="{case_id}" xel_path="{sqldiag_glob}" days="30" -i scripts/import_xel_sqldiag.sql
```

When the parent `non-yielding-analysis` agent requests `profile=non-yield`, use
`.github/skills/non-yielding-analysis/scripts/import_xel_non_yield.sql` instead of the full
system-health shredder. It imports all raw events but materializes only errors, waits,
diagnostics, scheduler, deadlocks, and memory broker. This avoids spending time on millions of
connectivity/security rows that do not participate in the non-yield report.

### 3. Verify import

```sql
SELECT event_name, COUNT(*) AS cnt
FROM [xevent_{case_id}].xe.raw_events WHERE case_id = '{case_id}'
GROUP BY event_name ORDER BY cnt DESC
```

### 4. Report to orchestrator or user

Return:
- Database name: `xevent_{case_id}`
- Case ID used
- Event distribution table
- Row counts per shredded table
- Any import errors or warnings

## Scripts

| Script | Loads from | Creates |
|--------|-----------|---------|
| `scripts/import_xel_to_sql.sql` | `system_health*.xel` | `xe.raw_events`, `xe.errors`, `xe.waits`, `xe.diagnostics`, `xe.scheduler`, `xe.deadlocks`, `xe.connectivity`, `xe.security_errors`, `xe.memory_broker` |
| `scripts/import_xel_sqldiag.sql` | `*SQLDIAG*.xel` | Appends to `xe.raw_events` + `xe.diagnostics`, creates `xe.ag_events` |
