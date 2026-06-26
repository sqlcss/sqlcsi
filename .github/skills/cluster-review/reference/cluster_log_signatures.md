# cluster.log Signature Catalog (KB)

Pure reference for the `cluster-review` skill Phase 1. cluster.log timestamps are
**UTC**. Patterns are case-insensitive regex; tune node names per case.

> Tooling: `grep_search` returns empty on out-of-workspace paths — use
> `Select-String -Path <cluster.log> -Pattern '<regex>'`. Strip NULL bytes from
> exported text first: `(Get-Content $f -Raw) -replace "`0",""`.

---

## 0. Last good heartbeat (baseline before the break)

```
Route history .*Heartbeats counter/threshold: \d+/\d+.*Error: Success
```

- The most recent `Error: Success` route-history line before the flap = the last
  healthy cross-site heartbeat. Its embedded `Timestamp:` is the "health
  baseline" — step 1 of the verbatim timeline.

## 1. NetFT heartbeat route flap

```
Route (Deleted|Added)
:3343                                  # NetFT heartbeat UDP port
NetftRouteChange
```

- Each `Route Deleted` immediately followed by `Route Added` for the same
  remote = a flap. Count flaps and timestamp them.
- Clustered around the incident = the **trigger** (transient inter-site link loss).

## 2. Heartbeat loss / unreachable

```
NetftTwoFifthMissedHeartbeats             # early 40% warning (~8/20)
Missed \d+% of the heart ?beats
Missed .* (consecutive )?heartbeats
NetftRemoteUnreachable.*(true|set|event)
All routes .* are down                    # full 20/20 loss → route dead
unreachable
heartbeat.*(lost|failed)
```

- Progression: `NetftTwoFifthMissedHeartbeats` (early warning, link still up) →
  `NetftRemoteUnreachable` + `All routes ... are down` (route confirmed dead).
- Compare **both** nodes:
  - Node A sees B unreachable AND Node B sees A unreachable → **bidirectional** →
    break is in the middle (WAN/inter-site link).
  - Only one side reports unreachable → asymmetric (NIC/firewall on one node).

## 2b. Cluster network interface / network down

```
Cluster network interface '.*' .* failed
Cluster network '.*' is down
Cluster network '.*' is (operational \(up\)|up)     # recovery
```

- The heartbeat route dying makes the engine mark the NIC and the whole network
  down; the matching `operational (up)` line later = recovery (transient self-heal
  vs persistent — compare durations across flaps).

## 3. Membership change / regroup (RGP)

```
\[RGP\]
node\s*\(?\d+\)?\s*(was )?removed
removing node
\[NODE\].*(down|removed)
straggler
regroup
```

- Identify which node id was removed and which survived.
- `straggler` = a node late to the regroup; the late node is at risk of eviction.

## 4. Quorum loss (the decisive event)

```
\[QUORUM\].*Lost quorum
status\s*=\s*5925
FatalError
OnStop
ClusterService.*stop
```

- The node whose log prints `Lost quorum` + `5925` + `OnStop` is the one whose
  **Cluster Service stopped** → all its hosted AGs went offline at that instant.
- Match this UTC time to the SQL ERRORLOG "AG offline" (after UTC→local offset).

## 5. Node quarantine

```
quarantined
status\s*=\s*5985
QuarantineThreshold
QuarantineDuration
```

- `5985` = node placed in quarantine. With defaults (Threshold=3, Duration=7200s)
  a node hitting 3 failures is locked out of rejoin for 2 hours.

## 6. Vote / quorum config hints

```
QuorumConfig.*set=.*weights=\(([\d, ]+)\)
NodeWeights?
DynamicWeight
PreferredSite
Witness
```

- `weights=(2)` style lines hint at the live vote vector — but **confirm against
  the registry hive** (`Nodes\<id>\NodeWeight`); cluster.log hints can lag config.

## 6b. AG group placement — why the survivor never onlined the AG

```
Group '.*' transitioned from '(Online|Orphaned)' to '(Orphaned|Offline)'
RunPlacementFilter: group .*, after filter PossibleOwnerFilter candidate list has \d+ node
.* cannot be hosted on node \d+
NodeIsPossibleOwner: Group .*: Node:\d+ IsPossibleOwner:false
\[Filter\] Removing candidate: NodeCandidate\(\d+\) BanCode: PossibleOwnerFilter \(5016\)
Placement manager picked node 0 for group        # node 0 = no available node
\[RCM-plcmt\] Group .* allowed to move to node \d+       # ONLY the down/old node listed, survivor absent
moving from .* reason: 'DoFailback'
```

- On the **survivor** node, after the primary loses quorum the AG group goes
  `Online → Orphaned → Offline`; the loser is filtered out of placement by
  `PossibleOwnerFilter` (ban code 5016) so WSFC **never tries to online the AG**
  on the survivor — this is the WSFC-layer fingerprint of "no auto-failover".
- **Two distinct shapes of "no auto-failover"** — catalog BOTH:
  1. **Explicit ban** — `IsPossibleOwner:false` / `BanCode: PossibleOwnerFilter
     (5016)` names the survivor and rejects it.
  2. **Survivor simply absent from the candidate list** — there is NO
     `IsPossibleOwner:false` line for the survivor at all; instead
     `[RCM-plcmt] Group <AG> allowed to move to node <N>` lists **only the
     down/old owner** (or no live node), because the survivor was already removed
     from PossibleOwners earlier (often a static config state — see §6d #1). This
     is the quieter fingerprint and is easy to miss: the absence of the survivor
     from placement candidates IS the evidence. Confirm with the §6d audit.
- `DoFailback` after the loser returns = the group moved back to its preferred
  owner (transient flap self-heal).
- ⚠️ The *cause* of `IsPossibleOwner:false` may be a **static** config state
  (e.g. AG `FAILOVER_MODE = MANUAL` statically removes the replica from
  PossibleOwners) OR a **dynamic** sync-state removal. cluster.log alone cannot
  tell which — hand this to `ag-failover-analysis` (DDL / `alwayson_ddl_executed`)
  to confirm. Compare steady-state (both `IsPossibleOwner:true`) vs incident to
  decide static-vs-dynamic.

## 6c. AG group placement — the HEALTHY failover fingerprint (baseline)

Use this as the **positive control** when judging §6b. A *correct* automatic
failover shows TWO distinct phases in the RCM log. If you see this complete
sequence, the AG **did** fail over normally and PossibleOwners were managed as
designed — the absence of these lines (and presence of §6b's `IsPossibleOwner:false`
/ ban 5016) is what marks a stuck/blocked failover.

**Phase 1 — placement lookup (RCM picks the target by probing PossibleOwners):**

```
Clustered role '.*' is moving from cluster node '.*' to cluster node '.*'
\[RCM\] rcm::RcmGroup::NodeIsPossibleOwner: Group .*: Node:\d+ IsPossibleOwner:true
\[RCM\] rcm::RcmResource::Online: bringing .*'s provider resource '.*' online
```

- `NodeIsPossibleOwner ... Node:<n> IsPossibleOwner:true` is the exact moment the
  target replica node **passes** the possible-owner check and is selected as the
  failover destination. Nodes with no replica stay `IsPossibleOwner:false`
  forever (expected — not a fault); the old primary is skipped because it is down.

**Phase 2 — dynamic management (the new primary's hadr resource DLL refreshes the
PossibleOwner set via the RCM/GUM API once it is Online):**

```
Group '.*' .* OnlinePending
Group '.*' .* Online
\[RCM\] rcm::RcmApi::AddPossibleOwner: \(.*, \d+\)
\[RCM\] rcm::RcmGum::AddPossibleOwner\(.*,\d+\)            # add the new primary itself
\[RCM\] .* cannot be hosted on node \d+                  # node with no replica — expected
\[RCM\] rcm::RcmApi::RemovePossibleOwner: \(.*, \d+\)
\[RCM\] rcm::RcmGum::RemovePossibleOwner\(.*,\d+\)        # drop the old/down primary
\[RCM\] Refreshing PossibleOwners for resource '.*'
\[RCM\] rcm::RcmApi::AddPossibleOwner: \(.*, \d+\)         # re-add old primary once its replica is ready again
```

- The `Add`/`Remove` pair is the resource DLL keeping the WSFC PossibleOwner list
  in sync with live AG replica health: **add** the new primary, **remove** the
  down/old primary, then **re-add** it once its replica rejoins and is ready.
  This add→remove→re-add churn is NORMAL and self-corrects.
- Worked example (node3 = SQL2 becomes new primary; node1 = SQL1 old primary down;
  node2 = SQL3 has no replica):

```
03:11:49.111 Clustered role 'AG2022' is moving from 'SQL1' to 'SQL2'.
03:11:49.111 [RCM] NodeIsPossibleOwner: Group AG2022: Node:3 IsPossibleOwner:true   ← target found
03:11:49.112 [RCM] RcmResource::Online: bringing AG2022's provider 'AG2022_AG2022L' online
03:11:52.988→53.623  AG2022  OnlinePending → Online                                  ← new primary up
03:11:53.640 [RCM] RcmApi::AddPossibleOwner: (AG2022, 3)  / RcmGum::AddPossibleOwner ← add SQL2 (self)
03:11:53.641 [RCM] AG2022 cannot be hosted on node 2                                 ← SQL3 no replica
03:11:53.642 [RCM] RcmApi::RemovePossibleOwner: (AG2022, 1) / RcmGum::RemovePossibleOwner ← drop down SQL1
03:11:53.642 [RCM] Refreshing PossibleOwners for resource 'AG2022'
03:11:53.651 [RCM] RcmApi::AddPossibleOwner: (AG2022, 1)                             ← re-add SQL1 when ready
```

- ⚠️ **Provenance / time-zone caveat:** when you cite such an example, confirm the
  cluster.log header (`Current node` / `Build Number` / TZ offset) belongs to the
  case's cluster — do not mix a baseline-cluster log (different node names / OS /
  TZ) into the case timeline (see the foreign-cluster.log gotcha in SKILL.md).

- ⚠️ **No in-window automatic healthy failover? Use a fallback positive control.**
  Many incident captures contain NO clean automatic failover (every event is
  self-heal on the same node, a stuck transition, or a manual `ALTER…FAILOVER`).
  Do NOT leave §6c blank. In order of preference: (1) the most recent **automatic**
  failover earlier in the same cluster.log; (2) the last healthy **Add/Remove
  PossibleOwner pair** from the RCM history (`_*possown*.txt`) showing the set
  returning to the symmetric "both nodes in list" steady state; (3) if neither
  exists, state explicitly **"no positive control available in this capture"** and
  rely on §6d alone. Label whichever you use so the reader knows it is a fallback,
  not an in-incident control.

**Decision rule:** §6c sequence present → failover succeeded, PossibleOwners OK.
§6c absent + §6b (`IsPossibleOwner:false` / ban 5016 / group `Orphaned→Offline`)
present → WSFC never onlined the AG on the survivor → "no auto-failover" → escalate
the static-vs-dynamic question to `ag-failover-analysis`.

## 6d. PossibleOwner lifecycle audit — the 4-point "why online (or not) on another node" check

This is the **primary check procedure** for "did WSFC try to online the AG on
another node, and if not, why?" PossibleOwner membership is **stateful and carries
across failovers** — a failure to re-add a node after the *previous* failover can
silently disqualify it as a target for the *next* one. Run all four checks in
order, each backed by the verbatim RCM line and its timestamp.

| # | Question (Chinese) | What it verifies | Look for (grep) | If MISSING → meaning |
|---|--------------------|------------------|-----------------|----------------------|
| 1 | **上次有没有成功加回 possible owner** | After the PREVIOUS failover, the formerly-down node was re-added to PossibleOwners once its replica was ready | `RcmApi::AddPossibleOwner: \(.*, <oldNode>\)` / `RcmGum::AddPossibleOwner(.*,<oldNode>)` AFTER the prior recovery | The node is NOT a possible owner going into THIS incident → it can never be chosen now (root cause is one failover earlier) |
| 2 | **这次有没有成功找到 IsPossibleOwner:true** | In THIS failover, RCM's placement lookup found a legal target | `NodeIsPossibleOwner: Group .*: Node:\d+ IsPossibleOwner:true` + `Clustered role .* is moving from .* to .*` | No node passed the check → WSFC has **no legal target** → AG stays Offline/Orphaned (correlate with §6b ban 5016) |
| 3 | **这次 failover 时有没有把 down 的 node remove 掉** | During THIS failover, the down/old primary was removed from PossibleOwners | `RcmApi::RemovePossibleOwner: \(.*, <downNode>\)` / `RcmGum::RemovePossibleOwner(.*,<downNode>)` | Stale membership: the down node is still a possible owner → WSFC may try to fail back onto a dead node (`DoFailback` to a down owner) |
| 4 | **failover 完成后有没有把原始 node add 回来** | After THIS failover completed, the original node was re-added once its replica rejoined and is ready | `RcmApi::AddPossibleOwner: \(.*, <origNode>\)` / `Refreshing PossibleOwners` AFTER online completes | The original node will be **disqualified for the NEXT failover** → feeds check #1 of the following incident (cascading) |

**How to read the result:**
- All four present → healthy, self-correcting PossibleOwner lifecycle (matches §6c).
- #1 missing (prior re-add failed) → **the current incident's target was eliminated
  by the previous failover** — the real root cause is in the earlier transition,
  not this one. This is the key cross-failover trap.
- #2 missing → no legal owner this time; pivot to §6b to see whether the exclusion
  is static (`FAILOVER_MODE = MANUAL`) or dynamic (sync-state) — hand to
  `ag-failover-analysis`.
- #3 missing → down node never removed → stale/incorrect owner set.
- #4 missing → sets up a failure for the *next* failover (cascade) — flag it even
  if THIS failover succeeded.

> ⚠️ **Check #1 is NOT limited to the immediately-preceding flap — scan back to the
> last successful `AddPossibleOwner(<survivor>)`.** The disqualifying
> `RemovePossibleOwner(<survivor>)` that has no matching re-add can be **days or
> months earlier** — frequently a **static config change** (e.g. someone set
> `FAILOVER_MODE = MANUAL`), not a recent transient flap. When the last re-add is
> far in the past, report the **gap duration** (e.g. "HK removed 2026-03-05, never
> re-added for 109 days until the manual failover") and treat that static change as
> the **root-cause cascade origin** — the recent heartbeat flap is only the
> trigger that exposed the long-standing stale PossibleOwner set. Correlate the
> removal timestamp with `alwayson_ddl_executed` to attribute it.

> Because checks #1 and #4 link consecutive incidents, run this audit **per
> failover in chronological order** and carry the PossibleOwner set forward — the
> answer to "why no target this time" is frequently "the re-add at the end of last
> time never happened."

## 7. Cross-node side-by-side synthesis (not a single regex)

Build ONE timeline merging both nodes' events (all in UTC):

```
UTC time | Node A event              | Node B event
---------+---------------------------+---------------------------
03:12:0x | Route Deleted :3343       | Route Deleted :3343
03:12:1x | Missed heartbeats         | Missed heartbeats
03:12:2x | [RGP] node 1 removed      | [RGP] survived
03:12:2x | [QUORUM] Lost quorum 5925 | (holds the only vote)
03:12:3x | OnStop / Cluster stopped  | online
```

The node that loses quorum **in every flap** is the structural victim → carry
that node id into Phase 2 and verify its `NodeWeight`.

---

## Quick scan one-liner (run per node)

```powershell
$log = "<path>\Cluster.log"
$pat = 'Route (Deleted|Added)|Heartbeats counter/threshold.*Error: Success|NetftTwoFifthMissedHeartbeats|Missed .*heart ?beats|NetftRemoteUnreachable|All routes .* are down|Cluster network .*(failed|is down|operational)|\[RGP\]|node .*removed|straggler|\[QUORUM\].*Lost quorum|status = 5925|status = 5985|quarantined|OnStop|weights=|transitioned from .*(Orphaned|Offline)|Clustered role .* is moving from|NodeIsPossibleOwner.*IsPossibleOwner:(true|false)|RcmApi::(Add|Remove)PossibleOwner|RcmGum::(Add|Remove)PossibleOwner|Refreshing PossibleOwners|cannot be hosted on node|PossibleOwnerFilter|BanCode: PossibleOwnerFilter|DoFailback'
((Get-Content $log -Raw) -replace "`0","") -split "`n" |
  Select-String -Pattern $pat |
  Set-Content "<tmp>\cluster_signatures_<node>.txt"
```

Then `read_file` the output and assemble the Phase-1 unified timeline.
