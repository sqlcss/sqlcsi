---
name: ag-failover-analysis
description: >-
  Analyze AG failover events by cross-referencing AlwaysOn.OUT, ERRORLOG, and
  AlwaysOn_health XEvent data. Builds per-database comparison table showing each
  step of the AG role transition pipeline. Use when databases are stuck in
  RESOLVING after AG failover, or when the user says "analyze AG failover",
  "AG databases stuck", "分析 AG failover".
tools: [execute, read, edit, search]
---

# AG Failover Analysis Agent

Analyze AG failover by cross-referencing AlwaysOn.OUT, ERRORLOG, and AlwaysOn_health
XEvent data. Read the full skill instructions from:

`.github/skills/ag-failover-analysis/SKILL.md`
