---
name: cluster-review
description: >-
  WSFC quorum & cluster-configuration forensics. Reconstructs WHO lost quorum,
  WHY, and WHICH node was destined to win arbitration, by cross-referencing the
  cluster.log from BOTH nodes with the authoritative Cluster registry hive
  (CLUSDB / *_reg_Cluster.hiv). Classifies the config-level root cause
  (zero-weight node, missing witness, single-site fault-domain misconfig, single
  heartbeat path) and emits a remediation command template. Invoked automatically
  by ag-failover-analysis when ERRORLOG shows Cluster Service / WSFC errors, or
  manually when the user says "analyze cluster log", "review cluster config",
  "lost quorum", "node quarantined", "why did only one node fail", "5925",
  "5985", "分析 cluster log", "节点丢失 quorum", "仲裁分析".
context: fork
---

# Cluster Review — WSFC Quorum & Arbitration Forensics

## Overview

This skill answers a **different question** than the SQL-engine-side skills:

| Skill | Question it answers | Primary evidence |
|-------|--------------------|------------------|
| `ag-failover-analysis` | What was the failover sequence / trigger? | ERRORLOG, AlwaysOn.OUT, XEvent |
| `stuck-db-analysis` | Where did a DB get stuck in `DatabaseSwitchRoles`? | ERRORLOG NQ-rollback, XEvent hadr_trace |
| **`cluster-review`** (this) | **Why did WSFC lose quorum, and why does the SAME node always lose?** | **cluster.log (both nodes) + Cluster registry hive** |

A SQL AG goes offline the instant the underlying WSFC node loses quorum and the
Cluster Service stops. When a failover keeps taking down **the same node every
time**, the cause is almost always a **cluster configuration asymmetry** (vote
weights, witness placement, fault domains), not the SQL workload. This skill
proves that from authoritative sources.

## When to Invoke

Invoke when ANY of these are true:

1. `ag-failover-analysis` Phase 4b Step 3 routed to the **Cluster / Infrastructure**
   branch (trigger was a cluster error, not a SQL lease/health timeout).
2. **ERRORLOG contains AG / WSFC error numbers** — this is the usual **entry
   signal**, because the investigation starts from AG failover analysis and these
   ERRORLOG errors are where the cluster-side cause first surfaces:

   | Error | Meaning |
   |-------|---------|
   | `1135` | Cluster node evicted/removed from active membership (heartbeat loss) |
   | `19407` | Lease between AG and WSFC expired |
   | `19419` | WSFC did not receive a process event signal from SQL (lease renewal timeout) |
   | `19421` | SQL did not receive a process event signal from WSFC (diagnostics heartbeat lost) |
   | `41005` | WSFC cluster event notification operation failed |
   | `41009` | WSFC service not running / cannot be reached |
   | `41034` | AG/WSFC resource could not be brought online / cluster operation error (common AG-failover entry signal) |
   | `41048` / `41049` | Failed to access / retrieve the local WSFC cluster |
   | `41066` | WSFC node is offline |
   | `41091` | AG going offline — local WSFC node no longer online / WSFC lost quorum |
   | `41142` | Replica cannot become primary (WSFC online but replica failed/resolving) |
   | `41143` | WSFC connectivity issue |
   | `41144` | WSFC lease for the AG could not be renewed |
   | `41160` | Failed to designate the local replica as primary |
   | `41161` | Local WSFC node could not bring the AG resource online |

   Also treat any `The Cluster service ...` / `WSFC ...` / `node ... was removed`
   text as a match.
3. cluster.log / System event log shows `5925` (lost quorum), `5985`
   (node quarantined), `1177` (quorum-loss shutdown), `1564` (file-share witness
   failure), `1069` (resource failed).
4. User asks directly: "analyze cluster log", "review cluster config",
   "why did only <node> fail", "lost quorum", "仲裁分析".

If NONE of these apply (failover trigger was SQL CPU/lease/health timeout with
no quorum loss), this skill is **not** needed — stay in `ag-failover-analysis`.

## Required Inputs

| # | Input | Source | Why |
|---|-------|--------|-----|
| 1 | **cluster.log — BOTH nodes** | `Get-ClusterLog -Destination <dir>` (run on each node) | Heartbeat/route/regroup/quorum events. Each node only logs its own view — you MUST compare both. **Validate each file's header (`Current node` / `Build Number` / TZ offset) belongs to THIS cluster — discard stray `node1/node2_Cluster.log` from other clusters.** |
| 2 | **Cluster registry hive** | `%SystemRoot%\Cluster\CLUSDB`, or a collected `*_reg_Cluster.hiv` | The ONLY authoritative source of vote weights, witness, fault domains, networks, tunables. |
| 3 | **Windows event logs (BOTH nodes)** | `.evtx` exports (`System.evtx`, `*FailoverClustering*.evtx`) **OR** text/CSV exports (`*_evt_System.txt`, `*_evt_FailoverClustering-Operational.txt`, `*_evt_*.csv`) | Event IDs `1135`/`1177`/`1564`/`1069`/`5985`/`1129` etc. with precise timestamps; cross-checks cluster.log. |
| 4 | **ERRORLOG (both replicas)** | SQL Server LOG folder | Correlate the SQL-side AG offline with the WSFC quorum-loss timestamp. |
| 5 | **Incident time + UTC offset** | User / case metadata | cluster.log is **UTC**; ERRORLOG/XEvent are **server local**. Needed to align. |
| 6 | **Node → site/datacenter mapping** | User | Confirms whether fault-domain config matches physical reality. |

> If you only have the hive (no cluster.log), you can still do **Phase 2**
> (config audit) and reach a config root cause. If you only have cluster.log
> (no hive), you can do **Phase 1** but vote weights must be inferred from
> `weights=(...)` lines and confirmed later.

---

## Background Reference — WSFC Quorum Model

Read this before interpreting evidence.

### Vote weights & quorum

- Each node has a **NodeWeight** (1 = has a vote, 0 = no vote). A witness adds 1 vote.
- **Quorum** = a strict majority of the *configured* votes must stay online.
- **Dynamic Quorum** (default ON, 2012+): WSFC may automatically adjust
  `DynamicWeight` (0/1) to keep the cluster running as nodes drop, but it
  **cannot give a vote to a node whose static `NodeWeight` is 0**. A
  statically zero-weighted node is *permanently* a non-voter.
- **Consequence:** a node with `NodeWeight = 0` and no witness on its side will
  **always be the minority** when the inter-site link breaks → it loses quorum,
  the Cluster Service stops (error `5925`), and every AG it hosts goes offline.
  The partner (holding the only vote) always survives. This single-handedly
  explains an "only node X ever fails" pattern.

### Witness types (and how to detect "no witness")

| Witness | Hive marker (under `Quorum`) |
|---------|------------------------------|
| Node Majority (NO witness) | `Resource` value **empty** AND no `SharePath` |
| File Share Witness (FSW) | a witness `Resource` GUID **and** a `SharePath` value (UNC) |
| Cloud Witness | a witness `Resource` GUID with `AccountName`/`StorageAccount` |
| Disk Witness | a witness `Resource` GUID of type `Physical Disk` |

> ⚠️ **Do NOT conclude "FSW exists" just because a UNC string appears in the
> hive.** A UNC can be embedded in a *Network Name* resource's AD blob (a Domain
> Controller, e.g. `\\xx-ads-007`, is NOT a witness). A real FSW **requires a
> `SharePath` value** under the witness resource. Absence of `SharePath` = no FSW.

### Fault Domain type codes

`FaultDomains\<id>\Type` (decimal / hex):

| Value | Hex | Meaning |
|-------|-----|---------|
| 1000 | 0x3e8 | **Site** |
| 2000 | 0x7d0 | Rack |
| 3000 | 0xbb8 | Chassis |
| 4000 | 0xfa0 | **Node** |

`PreferredSite` (a Site fault-domain GUID) only works if **two real Site fault
domains exist with nodes correctly parented**. If both nodes share one Site (or
a node is mis-tagged into the partner's site), site-aware quorum / PreferredSite
is effectively disabled.

### Quarantine (default tunables)

`QuarantineThreshold = 3` (consecutive failures), `QuarantineDuration = 7200s`
(2 h). Event `5985` = node quarantined; it is then refused rejoin for the
duration. Persisted overrides live under the cluster root; **absence = OS default**.

---

## Workflow

### Phase 0 — Input Gate (STOP & check first)

**The moment this skill is invoked, STOP and verify the cluster-side inputs exist
before doing any analysis.** The AG-failover entry only guarantees ERRORLOG was
seen — the two artifacts this skill actually depends on (Windows **event logs**
and the **cluster registry hive**) are often NOT in the initial collection and
must be requested explicitly.

Scan the case directory for each required artifact:

| Artifact | Glob to scan for |
|----------|------------------|
| cluster.log (both nodes) | `**/*[Cc]luster*.log`, `**/Cluster.log` |
| Cluster registry hive | `**/*_reg_Cluster.hiv`, `**/CLUSDB`, `**/Cluster\CLUSDB` |
| Windows event logs (both nodes) | `**/System.evtx`, `**/*FailoverClustering*.evtx`, **or** text/CSV exports `**/*_evt_System.txt`, `**/*_evt_*FailoverClustering*.txt`, `**/*_evt_*.csv` |
| ERRORLOG (both replicas) | `**/ERRORLOG*` |

```powershell
# Example scan (adjust $case)
$case = "<case_dir>"
"--- cluster.log ---";        Get-ChildItem $case -Recurse -Filter *.log    -EA SilentlyContinue | Where-Object Name -match 'cluster' | Select-Object FullName
"--- cluster hive ---";       Get-ChildItem $case -Recurse -EA SilentlyContinue | Where-Object { $_.Name -match '(_reg_Cluster\.hiv|^CLUSDB$)' } | Select-Object FullName
"--- event logs (.evtx / evt text exports) ---"; Get-ChildItem $case -Recurse -EA SilentlyContinue | Where-Object { $_.Name -match '\.evtx$' -or $_.Name -match '_evt_.*(System|FailoverClustering)' } | Select-Object FullName
```

### ⚠️ Validate every cluster.log belongs to THIS cluster (do NOT skip)

A case directory often contains **more than one** `*cluster*.log`, and some are
**stray files from a completely different cluster** (collected by mistake, left
over from another case, or a generic `node1_Cluster.log` / `node2_Cluster.log`
export). Using the wrong log silently corrupts the entire timeline. Before you
use any cluster.log, **read its header** and confirm it matches this case's
cluster:

```powershell
Get-ChildItem $case -Recurse -Filter *.log -EA SilentlyContinue |
  Where-Object Name -match 'cluster' | ForEach-Object {
    $h = Get-Content $_.FullName -TotalCount 12
    [pscustomobject]@{
      File   = $_.FullName
      Node   = ($h | Select-String 'Current node: name \((.+?)\)').Matches.Groups[1].Value
      Build  = ($h | Select-String 'Build Number (\d+)').Matches.Groups[1].Value
      TzMin  = ($h | Select-String 'offset of this machine is (-?\d+) minutes').Matches.Groups[1].Value
    }
  } | Format-Table -AutoSize
```

Keep a cluster.log **only if** all three match this case:

| Check | Must match |
|-------|-----------|
| `Current node: name (X)` | One of the **actual AG node names** for this case (e.g. `SHSDCWSDBA001` / `HKHDCWSDBA001`), NOT a generic `SQL1`/`NODE1`. |
| `Build Number` | The cluster OS build from the hive / ERRORLOG (e.g. WS2022 = `20348`; a `17763` = WS2019 log is a foreign cluster). |
| time-zone offset | The case's server offset (e.g. `480` min = UTC+8; `420` = UTC+7 is a different site/cluster). |

**Red flags that a log is foreign → discard it:**
- File named `node1_Cluster.log` / `node2_Cluster.log` while the real logs live
  in per-node folders named after the AG replicas
  (`<NODE>\<NODE>_cluster.log`).
- `Current node: name (...)` is a hostname that is **not** an AG replica.
- Build Number or time-zone offset disagrees with the case's OS/site.
- Drastically different file size for the same incident window (a few MB vs the
  expected hundreds of MB of a full `Get-ClusterLog`).

Use the per-node `<NODE>_cluster.log` whose header node name equals the AG
replica. If two candidates both pass, prefer the larger / full export covering
the incident window. If NO cluster.log passes validation, treat cluster.log as
missing and ask the user to re-collect with `Get-ClusterLog` on the real nodes.

**Decision:**

- **All present** → proceed to Phase 1 (read the hive config FIRST).
- **Hive missing** (even if cluster.log is present) → **STOP and ask the user for
  the hive before Phase 1.** The whole method reads the authoritative config
  first; you cannot classify a config root cause from cluster.log alone. You may
  preview the cluster.log timeline, but do not state a verdict without the hive.
- **Both hive and cluster.log missing** → **STOP and ask the user to provide them.**
  Do NOT guess vote weights or witness state from ERRORLOG alone.

**If anything is missing, ask the user with the exact collection commands:**

```powershell
# On EACH cluster node, as administrator:

# 1. cluster.log (UTC) — both nodes
Get-ClusterLog -Destination C:\Temp -UseLocalTime:$false

# 2. Cluster registry hive (authoritative config) — either node
#    a) live export:
reg save "HKLM\Cluster" C:\Temp\$(hostname)_reg_Cluster.hiv
#    b) or copy the on-disk DB:  %SystemRoot%\Cluster\CLUSDB

# 3. Windows event logs — both nodes
wevtutil epl System C:\Temp\$(hostname)_System.evtx
wevtutil epl "Microsoft-Windows-FailoverClustering/Operational" C:\Temp\$(hostname)_FailoverClustering_Operational.evtx
wevtutil epl "Microsoft-Windows-FailoverClustering/Diagnostic"   C:\Temp\$(hostname)_FailoverClustering_Diagnostic.evtx
```

Also confirm the **incident time + UTC offset** and **node→site mapping** if not
already known. Only continue once the required inputs are in hand.

### Phase 1 — Authoritative Config Audit (registry hive) — DO THIS FIRST

**This is the first analysis step.** Before touching cluster.log, load the hive
and read the cluster's overall configuration — it is the ground truth for vote
weights, witness, fault domains, networks and tunables. cluster.log (Phase 2)
only gives *hints*; the hive *proves* the config, so reading it first frames the
entire investigation.

**Step 1 — pop the import command for the user.** Show the exact `reg load` /
enumerate / `reg unload` sequence and have the user run it (or confirm the hive
path so you can run it). `reg load` requires elevation (SeRestorePrivilege) and
you MUST `reg unload` when finished. **`reg query` (read) does NOT need
elevation** — once the hive is loaded (by the user, elevated), do all the
enumeration yourself; do NOT ask the user to run queries. In this terminal,
multi-line PowerShell output is unreliable — **write every query's output to a
temp file and `read_file` it back; you will quote these raw blocks verbatim in
the report.**

```powershell
# 1. Load the collected hive under a temp key (example path shown — adjust to the case)
reg load "HKLM\TmpClus" "C:\Temp\2606230030003998\SHSDCWSDBA001\SHSDCWSDBA001_reg_Cluster.hiv"
#   generic form:
#   reg load "HKLM\TmpClus" "<path>\<host>_reg_Cluster.hiv"

# --- capture EVERY query's RAW output to a temp file, then read_file it back ---
$o = "C:\Temp\<case>\_cluster_hive.txt"; "" | Out-File $o

# 2. Cluster IDENTITY (root values) — ClusterName, OS / OSVersion,
#    ClusterInstanceID, AdminAccessPoint (1 = CNO / ADNameOnly), ClusterNameResource
"===== ROOT ====="      | Out-File $o -Append; reg query "HKLM\TmpClus"                | Out-File $o -Append

# 3. Quorum — is there a witness?  (Resource & Path empty = Node Majority, NO witness)
"===== QUORUM ====="    | Out-File $o -Append; reg query "HKLM\TmpClus\Quorum"         | Out-File $o -Append

# 4. Per-node vote weights (NodeWeight 0x0 = NON-voter) + per-node FaultDomain (site)
"===== NODES ====="     | Out-File $o -Append; reg query "HKLM\TmpClus\Nodes" /s        | Out-File $o -Append

# 5. Networks (Role 1=none,3=cluster+client; Address/AddressMask → which site/subnet)
"===== NETWORKS ====="  | Out-File $o -Append; reg query "HKLM\TmpClus\Networks" /s     | Out-File $o -Append

# 6. Fault domains (Type 0x3e8=Site / 0xfa0=Node; FaultDomainParent = site layout)
"===== FD ====="        | Out-File $o -Append; reg query "HKLM\TmpClus\FaultDomains" /s | Out-File $o -Append

# 7. Resource INVENTORY — enumerate ALL resources (Name + Type).
#    Confirms NO witness instance AND lists the AG / listener / IP resources.
"===== RESOURCES =====" | Out-File $o -Append
reg query "HKLM\TmpClus\Resources" /s 2>&1 | Select-String -Pattern '\\Resources\\|    Name |    Type ' | Out-File $o -Append

# 8. Tunables (absence of a value = OS default — say so explicitly in the report)
"===== TUNABLES ====="  | Out-File $o -Append
reg query "HKLM\TmpClus" /v QuarantineThreshold 2>&1 | Out-File $o -Append
reg query "HKLM\TmpClus" /v QuarantineDuration  2>&1 | Out-File $o -Append

# 9. ALWAYS unload when finished (also needs elevation)
reg unload "HKLM\TmpClus"
```

**Step 2 — extract the RAW data the report requires.** For each item below,
keep the *verbatim* `reg query` lines (you will paste them as code blocks in the
report's "Cluster config from hive" section) AND apply the decision rule:

| # | Raw data to extract (verbatim) | Hive key | Decision rule |
|---|--------------------------------|----------|---------------|
| 1 | `ClusterName`, `OS`/`OSVersion`, `ClusterInstanceID`, `AdminAccessPoint`, `ClusterNameResource` | `HKLM\TmpClus` (root) | Cluster identity block (report §"identity") |
| 2 | `Resource`, `Path`, `MaxQuorumLogSize` | `Quorum` | `Resource`/`Path` empty + no `SharePath` → **No witness** (Node Majority) |
| 3 | per node: `NodeName`, **`NodeWeight`**, `FaultDomain` | `Nodes\*` | `NodeWeight = 0x0` → **permanent non-voter**; sum weights = total votes |
| 4 | each `FaultDomainName` + `FaultDomainType` + `FaultDomainParent` | `FaultDomains\*` | Only one Site, or both nodes parented to one Site / a node mis-parented → **site misconfig** (PreferredSite ineffective) |
| 5 | per network: `Name`, `Address`, `AddressMask`, `Role` | `Networks\*` | One heartbeat subnet per site / single path → **no heartbeat redundancy** |
| 6 | full resource list: `Name` + `Type` | `Resources\*` | No witness instance → confirms "no witness" from a 2nd angle; also names the AG / listener / IP resources |
| 7 | `QuarantineThreshold`, `QuarantineDuration` (+ note any absent `*Threshold`/`*Delay`/`DynamicQuorum`) | root | Value absent = **OS default** (Threshold 3, Duration 7200s); state defaults explicitly |

**Output of Phase 1:** the raw-dump-backed "cluster overall config" snapshot —
cluster identity, per-node NodeWeight + total votes, witness type (or none),
fault-domain/site tree, heartbeat networks, resource inventory, and tunables
(default vs overridden). Keep the verbatim `reg query` blocks; the report's
cluster-config section quotes them. Carry these facts into Phase 2 so the
cluster.log timeline is read against the *known* configuration.

### Phase 2 — cluster.log Checkpoint Scan (both nodes)

With the config snapshot from Phase 1 in hand, now walk the logs. cluster.log is
UTC — convert the incident window to UTC first
(e.g. local `11:12–11:22` at UTC+8 → `03:12–03:22` UTC).

For tooling: `grep_search` returns **empty on out-of-workspace paths** — use
`Select-String` in PowerShell instead.

Scan **each** node's cluster.log for the checkpoint categories. The full regex
catalog is in [reference/cluster_log_signatures.md](reference/cluster_log_signatures.md).
For every checkpoint you MUST keep the **verbatim raw log line(s)** (with the
original `pid.tid::UTC` prefix) — the report pairs one raw line with each
timeline step ("时间线逐步证据 / verbatim evidence"). Summary:

| # | Checkpoint | Signature (regex) | What it tells you |
|---|-----------|-------------------|-------------------|
| 0 | **Last good heartbeat** (baseline) | `Route history.*Heartbeats counter/threshold: \d+/\d+.*Error: Success` | The last healthy cross-site heartbeat before the break — the "health baseline" timestamp |
| 1 | NetFT route flap | `Route (Deleted\|Added)` near `:3343` | Heartbeat path instability — count flaps, build a timeline |
| 2 | Heartbeat loss → unreachable | `NetftTwoFifthMissedHeartbeats` / `Missed \d+% .* heart ?beats` / `NetftRemoteUnreachable` / `All routes .* are down` | Early 40% warning → full 20/20 loss. Compare both nodes → mid-link (bidirectional) vs one-sided |
| 3 | Network interface / network down | `Cluster network interface .* failed` / `Cluster network .* is down` | The heartbeat NIC/network the engine marked down |
| 4 | Membership / regroup | `node .* (was )?removed` / `\[RGP\].*straggler` / `won't have quorum without stragglers` | Who got removed, who survived |
| 5 | **Quorum loss** | `\[QUORUM\].*Lost quorum` + `status = 5925` + `OnStop` | The node that printed this is the one whose Cluster Service stopped |
| 6 | Quarantine | `quarantined` + `status = 5985` + `set netft heartbeat interval` | Apply QuarantineThreshold/Duration to compute the lockout window |
| 7 | **AG group placement** (why the survivor never onlined the AG) | `Group '.*' transitioned from '(Online\|Orphaned)' to '(Orphaned\|Offline)'` / `RunPlacementFilter.*PossibleOwnerFilter` / `IsPossibleOwner:false` / `BanCode: PossibleOwnerFilter \(5016\)` / `DoFailback` | On the SURVIVOR: the AG group goes Online→Orphaned→Offline and the loser is filtered out of placement — proves WSFC never auto-onlined the AG on the survivor (and whether it was static MANUAL-mode exclusion or dynamic) |
| 7b | **Healthy failover baseline** (positive control for #7) | `Clustered role .* is moving from .* to .*` / `NodeIsPossibleOwner.*IsPossibleOwner:true` / `RcmApi::AddPossibleOwner` / `RcmGum::(Add\|Remove)PossibleOwner` / `Refreshing PossibleOwners` / `cannot be hosted on node` | A CORRECT failover: Phase 1 placement lookup picks the target (`IsPossibleOwner:true`) → Online; Phase 2 the new primary's hadr DLL refreshes the set (add new primary, remove down old primary, re-add it when ready). Presence of this full sequence = failover succeeded; its ABSENCE alongside #7 = stuck/no auto-failover. See reference §6c |
| 8 | Config hints | `QuorumConfig.*set=.*weights=` / `NodeWeights` | Vote-weight clue — **cross-check against the Phase 1 hive read** |
| 9 | Side-by-side | (synthesize) | Put both nodes' events on ONE shared UTC timeline; the node that loses quorum every time is the candidate victim |

**Output of Phase 2:** two artifacts —
1. a **numbered timeline table** (序号 ｜ 本地时间(UTC+8) ｜ 节点 ｜ 事件 ｜ 含义 ｜
   来源) spanning trigger → each flap → quarantine → recovery, both nodes merged,
   interpreted against the Phase 1 config; and
2. a **verbatim evidence section** — one raw cluster.log/ERRORLOG line per
   timeline step (证据 1..N), each labelled with step #, time, node, and source
   (cluster.log = UTC / ERRORLOG = local). The causal chain (last good HB → 40%
   missed → NetftRemoteUnreachable → interface failed → network down → Lost quorum
   5925 → OnStop → quarantine 5985 → group Orphaned→Offline) must appear verbatim.

### Phase 3 — Root-Cause Classification (decision tree)

```
Did BOTH nodes lose quorum?
├─ YES → witness + all network paths down, OR no witness at all → whole cluster stopped
└─ NO (only one side lost) → VOTE ASYMMETRY. Inspect the hive:
        ├─ losing node has NodeWeight = 0            → ZERO-WEIGHT NODE (static non-voter)
        ├─ witness exists but co-located with winner → WITNESS PLACEMENT anti-pattern
        ├─ no witness + 2 voting nodes, link broke   → MISSING WITNESS (no tie-breaker)
        └─ fault domains collapsed to one site       → SITE MISCONFIG (no PreferredSite)
   ⇒ Remediation = witness in a 3rd fault domain + symmetric NodeWeight
                    + correct site fault domains + redundant heartbeat path
```

State the classification explicitly and back it with the exact hive value
(e.g. `Nodes\1\NodeWeight = 0x0`) AND the Phase-2 cluster.log evidence
(e.g. node 1 printed `Lost quorum ... status = 5925` in all 3 flaps).

### Phase 4 — Remediation Template

Generate concrete, parameterized admin steps (run as cluster admin). Replace the
`<...>` placeholders from Phase 1 findings. **Recommend, do not auto-apply** —
these change live cluster behavior.

```powershell
# (a) Create the missing site fault domain and parent the mis-tagged node into it
New-ClusterFaultDomain -Name "<SiteA>" -Type Site
New-ClusterFaultDomain -Name "<SiteB>" -Type Site            # if also missing
Set-ClusterFaultDomain -Name "<NodeA>" -Parent "<SiteA>"
Set-ClusterFaultDomain -Name "<NodeB>" -Parent "<SiteB>"

# (b) Add a witness in a THIRD fault domain (cloud witness preferred for 2-site)
Set-ClusterQuorum -CloudWitness -AccountName "<storageacct>" -AccessKey "<key>"
#   or:  Set-ClusterQuorum -FileShareWitness "\\<server-in-3rd-site>\<share>"

# (c) Restore symmetric vote weight (give the zero-weight node its vote back)
(Get-ClusterNode "<NodeA>").NodeWeight = 1
(Get-ClusterNode "<NodeB>").NodeWeight = 1

# (d) Set PreferredSite so the intended primary site wins a 50/50 split
(Get-Cluster).PreferredSite = "<SiteA>"

# Verify
Get-ClusterNode | Format-Table Name, NodeWeight, DynamicWeight, State
Get-ClusterQuorum
Get-ClusterFaultDomain
```

After remediation the losing node has a vote AND a witness exists in an
independent fault domain, so a single inter-site link failure can no longer take
down only one side.

---

## Gotchas (hard-won)

- **Time zones:** cluster.log = **UTC**; ERRORLOG / `.xel` = **server local**.
  Convert before correlating. State the offset used in the report.
- **NULL bytes in event-log text exports:** UTF-16 / exported `.txt` may contain
  `\x00`; strip with `-replace "`0",""` before matching.
- **`grep_search` is empty on out-of-workspace paths** → use `Select-String`.
- **Multi-line PowerShell output gets swallowed in this terminal** → write to a
  temp file, then `read_file`.
- **`reg load` needs elevation and a matching `reg unload`** — leaving
  `HKLM\TmpClus` mounted is messy; always unload.
- **Never trust a raw strings-scan of the hive for config conclusions.** A UNC or
  GUID embedded in a resource blob can be mistaken for a witness/setting. Load the
  hive and read the *specific keys* (`Quorum`, `Nodes\*\NodeWeight`, `FaultDomains`).
  (A real FSW requires `SharePath`; its absence = no FSW.)
- **A case dir can contain a FOREIGN cluster.log.** Multiple `*cluster*.log`
  files — especially generic `node1_Cluster.log` / `node2_Cluster.log` — may come
  from a *different* cluster (wrong node name, wrong Build Number, wrong TZ
  offset). Always read the header (`Current node: name (X)` / `Build Number` /
  `time zone offset ... minutes`) and confirm it matches this case's AG node /
  OS build / site before using. Prefer the per-node `<NODE>_cluster.log` named
  after the real AG replica. (Seen in case 2606230030003998: stray
  `node1/node2_Cluster.log` were `SQL1`, WS2019 build 17763, UTC+7 — a totally
  different cluster than the case's `SHSDCWSDBA001`/`HKHDCWSDBA001`, WS2022
  build 20348, UTC+8.)

## Report Output

Write findings into the case report (or a `cluster-review` section). Use the
Catppuccin Mocha theme for any HTML (per repo instructions). The cluster section
must be **raw-evidence-backed**, not just summary tables — match the depth below
(modelled on the reference report `2606230030003998_ag_failover_report.md` §§3, 5, 11).

### A. 执行摘要 (executive summary table)

One table: **Trigger** (the WSFC heartbeat/quorum event) vs **enabling root cause**
(the config asymmetry — zero-weight node / no witness / site misconfig; or, if it
belongs to the SQL layer such as `FAILOVER_MODE=MANUAL`, hand that to
`ag-failover-analysis` and label it "enabling root cause, separate layer"),
flap count, why it stuck, why no auto-failover, data loss, recovery time.

> **Keep the distinction explicit:** cluster-review owns the **trigger / WSFC**
> layer; the *enabling* root cause may live in the AG/DDL layer. Never collapse
> the two.

### B. 环境与拓扑 (environment & topology)

Node / IP / site / designed-role table; WSFC quorum model (votes, witness);
AG replica IDs + DB; commit mode.

### C. 根本原因（含权威证据） — verbatim cluster.log causal chain

Quote the FO causal chain **verbatim** as a code block (last good HB → 40% missed
→ NetftRemoteUnreachable → All routes down → interface failed → network down →
`[QUORUM] Lost quorum` → `FatalError status=5925` → `OnStop`), then a one-paragraph
解读. Add the survivor-side block (regroup, `weights=`, `won't have quorum
without stragglers`).

### D. 完整时间线 (numbered timeline table)

Columns: **序号 ｜ 本地时间(UTC+8) ｜ 节点 ｜ 事件 ｜ 含义 ｜ 来源**. Cover trigger →
each flap → CRC/config offline → quarantine → the ~2h gap → recovery. cluster.log
rows are UTC-converted to local; mark the source (cluster.log / ERRORLOG).

### E. 时间线逐步证据 (verbatim — one raw line per step)

For **each** numbered step in §D, a `证据 N` code block with the actual raw log
line(s) — cluster.log (UTC) or ERRORLOG (local), labelled with step #, time,
node, source. This is the section that made the difference between "too brief"
and audit-grade; do NOT skip it.

### F. Cluster 配置总结（来自注册表 hive 权威枚举） — raw `reg query` dumps

The authoritative config section. Lead with the reproduce commands
(`reg load` → enumerate → `reg unload`), then these subsections, **each backed by
the verbatim `reg query` output captured in Phase 1** (paste the raw key/value
lines as code blocks, not just an interpreted table):

1. **集群本体 / identity** — ClusterName, OS/build, ClusterInstanceID, AdminAccessPoint, ClusterNameResource.
2. **仲裁 Quorum** — raw `Quorum` dump (`Resource`/`Path` empty → **no witness**); state the quorum model (Node Majority + Dynamic Quorum).
3. **节点与投票权** — raw `Nodes\*` dump showing each `NodeWeight`; table of NodeId / name / site / NodeWeight; total effective votes.
4. **站点 Fault Domain** — the FaultDomains tree (Site vs Node, Parent), call out any single-site / mis-parent misconfig.
5. **网络** — per-network subnet / Role / heartbeat endpoint; note single vs redundant heartbeat path.
6. **心跳 / 仲裁阈值** — list tunables; explicitly note `absent = OS default` and give the defaults (Quarantine 3 / 7200s, dynamic quorum on).
7. **资源清单** — the full resource inventory (Name + Type): AG, listener, IPs, cluster name/IP — confirming **no witness resource instance**.
8. **配置层根因结论** — tie the raw values together (e.g. "SH NodeWeight=0 + no witness → SH is always the minority → every flap takes down SH, HK always survives").

### G. 隔离 (Quarantine) 分析 — if `5985` seen

Quote the `status = 5985` line verbatim; compute lockout window
(start + QuarantineDuration); explain why it stretched the outage.

### H. 为什么没有自动 failover (WSFC placement view) — if relevant

Run the **PossibleOwner lifecycle audit** (reference §6d) — the 4-point check for
"did WSFC try to online the AG on another node, and if not, why?" PossibleOwner
membership is **stateful across failovers**, so run it per-failover in
chronological order and carry the set forward:

1. **上次有没有成功加回 possible owner** — after the PREVIOUS failover, was the
   formerly-down node re-added (`AddPossibleOwner`) once its replica was ready? If
   not, it was disqualified as a target before THIS incident even began.
2. **这次有没有成功找到 `IsPossibleOwner:true`** — did placement lookup find a legal
   target this time (`NodeIsPossibleOwner ... IsPossibleOwner:true` +
   `Clustered role ... is moving from ... to ...`)?
3. **这次 failover 时有没有把 down 的 node remove 掉** — was the down/old primary
   removed (`RemovePossibleOwner`)?
4. **failover 完成后有没有把原始 node add 回来** — was the original node re-added
   (`AddPossibleOwner` / `Refreshing PossibleOwners`) once it recovered? A missing
   re-add cascades into check #1 of the NEXT failover.

Compare against the **healthy baseline** (§6c). If a target was found and onlined,
quote the §6c success sequence; if NOT, quote the survivor-side placement block
verbatim (`RunPlacementFilter` / `PossibleOwnerFilter` / `IsPossibleOwner:false` /
`BanCode 5016` / `Group ... Orphaned→Offline` / `DoFailback`). State whether the
exclusion was a static config state (e.g. MANUAL mode — defer to
`ag-failover-analysis`) or a dynamic sync-state removal. Do not assert the
SQL-layer cause from cluster.log alone — cross-reference.

### I. 根本原因 + 建议 (remediation)

The Phase-3 classification (exact hive value + cluster.log line that prove it) +
the Phase-4 parameterized commands.

Reports save under the Report root (`C:\Users\lduan\sqlcsi-archive\reports\<case_id>_<brief>\`),
NOT the workspace `reports/`.
