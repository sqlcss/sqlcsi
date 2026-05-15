# Lock Dependency Reference — AG Failover Role Transition

## Lock Hierarchy During DatabaseSwitchRoles

```
AG-Level:
  CHadrArProxy::m_lock (SOS_RWLock)          — ONE per AG
  CHadrArProxy::m_agConfigMutex (SOS_RecursiveMutex) — ONE per AG

Per-DB:
  CHadrDbrSubscriber::m_DBRLock (SOS_RWLock) — ONE per joined DB
  HaDrDbMgrDbLock (LCK_M_U on HADR DB resource) — per-DB command lock
  AutoDbLock (LCK_M_X on database) — database exclusive lock
  m_lockPartners (SOS_RWLock) — per-DB partner list lock
  m_agUpdateLock (SOS_RWLock) — per-DB-partner AG update lock
```

## Who Holds What During Stuck Scenarios

### Thread stuck at AcquireXDbLockWithKill (Cat B)

```
Worker thread (e.g. spid21s, aidcconfig):
  HOLDS:
    ✅ m_DBRLock (WRITE) — acquired by HadrDbrSubscriberDbOpRoutine at function entry
    ✅ HaDrDbMgrDbLock (U) — acquired by DatabaseSwitchRoles at function entry
  WAITS:
    ❌ LCK_M_X on database — cannot acquire (system threads hold shared lock)
  DOES NOT HOLD:
    ❌ m_lock (AG-level) — never acquired by DatabaseSwitchRoles
    ❌ m_agConfigMutex — only acquired AFTER X-lock obtained
    ❌ m_lockPartners — only acquired AFTER X-lock obtained
```

### Thread dispatching new role change (e.g. RESOLVING→SECONDARY)

```
PublishEventToAllSubscribers → CHadrDbrSubscriber::Publish:
  WAITS:
    ❌ m_DBRLock (WRITE) on stuck DB — held by Cat B worker above
  HOLDS (if called from CHadrArProxy::Signal):
    ✅ m_lock (AG-level WRITE) — acquired before PublishRoleChangeEvent
  RESULT:
    → Blocks on per-DB m_DBRLock → holds AG m_lock → blocks ALL AG operations
```

### System threads (Ghost/QDS/Checkpoint)

```
  HOLDS:
    ✅ Shared DB lock (LCK_M_S or IS) on the stuck database
  NOT FKill-marked → lck_KillSpecificOwners cannot kill them
  NOT in lck_GetRollBackProgress check → progress reports 100%
```

## Deadlock Chain (Confirmed by Dump — Old Case CU15)

```
PID 112 (linked server)
  HOLDS: shared DB lock on CDR_ODS
  STATUS: rolling back (0%), uninterruptible
      ↑ blocks

Thread 304 (DatabaseSwitchRoles RESOLVING for CDR_ODS)
  HOLDS: m_DBRLock (WRITE) + HaDrDbMgrDbLock (U)
  WAITS: LCK_M_X via AcquireXDbLockWithKill
      ↑ blocks

Thread 370 (PublishRoleChangeEvent → PublishEventToAllSubscribers)
  HOLDS: ★ AG-level m_lock (WRITE) ★
  WAITS: m_DBRLock on CDR_ODS
      ↑ blocks ALL AG operations

Thread 81 (ProcessStateChangeNotification)
  WAITS: AG-level m_lock
```

## Wait Types in AG Failover

| Wait Type | Resource | Scope |
|-----------|----------|-------|
| `PWAIT_HADR_DBR_SUBSCRIBER` | `m_DBRLock` | Per-DB subscriber |
| `PWAIT_HADR_AR_CRITICAL_SECTION_ENTRY` | `CHadrArProxy::m_lock` | Per-AG |
| `PWAIT_HADR_PARTNER_SYNC` | `m_lockPartners` | Per-DB |
| `PWAIT_HADR_REPLICAINFO_SYNC` | `m_agUpdateLock` | Per-DB-partner |
| `LCK_M_X` | Database exclusive lock | Per-DB |
