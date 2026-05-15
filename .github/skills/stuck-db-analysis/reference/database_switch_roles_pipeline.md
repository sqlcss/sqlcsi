# DatabaseSwitchRoles Pipeline — Complete Source Code Reference

**Source**: SQL Server 2022 RTM QFE CU (`rel/box/sql2022/sql2022_rtm_qfe-cu`)
**Note**: SQL 2019 code is similar but may differ in cloud-specific guards (e.g. `IsXDBInstance()`)

---

## 1. `HaDrDbMgr::DatabaseSwitchRoles` — Main Orchestrator

**File**: `HadrDbMgrApi.cpp`, Lines 1391–2103

### Complete Step-by-Step (PRIMARY → RESOLVING path)

```
L1419  Step 1:  WaitForDbRestart()
L1422  Step 2:  XEvent: ledger_synchronization_xevent (state=7)
L1436  Step 3:  m_fIsInDatabaseSwitchRoles = true
L1474  Step 4:  Determine currentDbRole from PRU state
L1504  Step 6:  ★ scierrlog Error 1480 "changing roles PRIMARY → RESOLVING"
L1511  Step 7:  scierrlog Error 1483 State info (Hardened LSN, Commit LSN)
L1524  Step 8:  HkHostDbSwitchToResolving() — stop Hekaton OfflineCkptTimerTask
L1563  Step 9:  SetTargetStateForAllMgrs(HDbMState_Stopped)
L1565  Step 10: ChangeState(HDbMState_Stopping)
L1567  Step 11: m_userMgr.Stop(Immediate)      ← CAN BLOCK
L1568  Step 12: m_scanMgr.Stop(Immediate)      ← CAN BLOCK
L1569  Step 13: m_redoMgr.Stop(Clean)          ← CAN BLOCK
L1570  Step 14: m_fullTextMgr.Stop(Immediate)
L1571  Step 15: m_filestreamMgr.Stop(Immediate)
L1574  Step 16: m_undoPendingEvent.Signal()
L1577  Step 17: m_quorumEvent.Reset()
L1611  Step 18: StopDtcForDb(CDTC_MSDTC)
               → ERRORLOG: "MS DTC resource manager [db] has been released"
L1616  Step 19: ★★★ AcquireXDbLockWithKill(INFINITE) ★★★  ← CAN BLOCK FOREVER
L1623  Step 20: ReleaseAllInactiveDTCStates
L1630  Step 21: m_transportRegistration.DeRegister()
L1634  Step 22: SetRole(HADR_ROLE_RESOLVING) — role actually changes here
L1679  Step 23: UpdateCommitHardenPolicy()
L1685  Step 24: CleanupPartners() + ResetReadonlyRoutingInfo()
L2062  Step 25: DTC cleanup (PRIMARY→RESOLVING specific)
```

### Locks Held by DatabaseSwitchRoles

| Lock | Type | Acquired at | Released at | Scope |
|------|------|------------|-------------|-------|
| `HaDrDbMgrDbLock` | LCK_M_U on HADR DB resource | Function entry (L1393) | Function exit | Per-DB |
| `AutoDbLock` (X-lock) | LCK_M_X on database | Step 19 (L1616) | Function exit | Per-DB |
| `m_lockPartners` | RWLOCK_WRITE | Step 23 (L1679) | Step 24 end | Per-DB |

**Does NOT hold**: AG-level `m_lock`, `m_agConfigMutex`, or per-DB `m_DBRLock`

### ERRORLOG Messages Generated

| Step | Error | Message |
|------|-------|---------|
| 6 (L1504) | 1480 | `"database 'X' is changing roles from 'PRIMARY' to 'RESOLVING'"` |
| 7 (L1511) | 1483 | `"State information for database 'X' - Hardened Lsn: ... Commit LSN: ..."` |
| 19 (loop) | 35299 | `"Nonqualified transactions are being rolled back...N%"` (on timeout) |
| 19 (loop) | 1217 | `"Process ID N was killed by ABORT_AFTER_WAIT = BLOCKERS"` (on kill) |
| 18 (L1611) | — | `"MS DTC resource manager [X] has been released"` |

---

## 2. `HaDrDbMgr::AcquireXDbLockWithKill` — The Infinite Loop

**File**: `HadrDbMgrControl.cpp`, Lines 232–376

```cpp
LCK_RESULT HaDrDbMgr::AcquireXDbLockWithKill(
    AutoDbLock& autoDbLock, DWORD timeout, bool assertOnLockFail)
{
    do {
        // 1. Kill all sessions holding DB lock
        lck_KillSpecificOwners(lockResource, IsAnyOne, FALSE,
                               ekrMirroringStateChange, FALSE);
        
        // 2. Cleanup DTC transactions
        CleanupDTCXact(GetDbId());
        
        // 3. Try to acquire exclusive DB lock with SHORT timeout
        lckResult = autoDbLock.Acquire(GetDbId(), LCK_M_X,
                                       DB_LOCK_TIMEOUT_SHORT, killBlockers);

        if (LCK_TIMEDOUT == lckResult) {
            printRollbackProgress = true;
            retry = true;
        }

        // 4. Print rollback progress
        if (printRollbackProgress) {
            int percent = lck_GetRollBackProgress(lockResource, IsAnyOne);
            scierrlogwithstate(Error 35299, percent);
        }
    } while (retry && (timeout == INFINITE || elapsed < timeout));
    //                  ^^^^^^^^ INFINITE = never exits
}
```

### Why "100%" But Never Completes

`lck_GetRollBackProgress()` (lckmgr.cpp L20343-20474):
```cpp
INT lck_GetRollBackProgress(...) {
    INT min_percent = 100;   // DEFAULT = 100%
    for (each lock owner in grant queue) {
        if (taskProxy->FKill()) {     // ★ only checks FKill-marked tasks
            percent = taskProxy->GetPercentComplete();
            min_percent = MIN(min_percent, percent);
        }
        // System threads (Ghost/QDS/Checkpoint) NOT FKill-marked → SKIPPED
    }
    return min_percent;  // returns 100 because no FKill tasks found
}
```

---

## 3. `HadrDbMgrUsers::Stop` — m_userMgr.Stop() Internals

**File**: `HadrDbMgrControl.cpp`, Lines 2616–2720

```cpp
void HadrDbMgrUsers::Stop(HadrDbMgrShutdownType immediate, STOPAT stopAt)
{
    // XEvent: hadr_db_manager_user_control (Disable)
    ChangeState(HDbMState_Stopping);
    
    // Set database access to RESOLVING (blocks new users)
    GetDbMgr()->SetDatabaseReadOnlyAccessOptionsInternal(HADR_ACCESS_RESOLVING);
    
    if (immediate == HadrDbMgr_ST_Immediate) {
        // Kill user sessions holding DB locks
        lck_KillSpecificOwners(lockResource, IsAnyOne, FALSE,
                               ekrMirroringStateChange, TRUE);  // onlyKillUserSessions=TRUE
    }
    
    ChangeState(HDbMState_Stopped);
}
```

### MarkPartnerNotSynchronized — KillAll XEvent Source

Called during sub-manager stop phase:

```cpp
void DbMgrPartnerCommitPolicy::MarkPartnerNotSynchronized(AutoRWLock& autoRWLock, ...)
{
    AutoRWLock a_agLock(GetAgLockPointer());  // per-DB-partner m_agUpdateLock
    a_agLock.GetLock(RWLOCK_WRITE, INFINITE);
    
    EX_HADR_TRYBACKOUT {
        UpdateReplicaInfoInAg(HADR_SYNCHRONIZED_NOT);  // write to WSFC
        SetSyncState(HADR_SYNCHRONIZED_NOT);
        // ★ XEvent: hadr_db_partner_set_sync_state fires HERE
        //   commit_policy = current m_hardenPolicy value
        SetHardenPolicy(DoNothing);
    }
    EX_CATCHSE {
        SetHardenPolicy(KillAll);  // WSFC write failed → set KillAll, NO XEvent
    }
}
```

**XEvent KillAll interpretation**:
- KillAll in event = stale value from a previous FAILED `UpdateReplicaInfoInAg` call
- SQL 2019 on-prem: `SetPolicyWithLock(KillAll)` may be unconditional
- SQL 2022: guarded by `IsXDBInstance()` (cloud-only)
- **Not all DBs emit this event** — even recovered ones may not (conditional on sync state change)

---

## 4. Thread Pool Dispatch — How DBs Are Parallelized

### `CHadrPublisher::Publish` (hadrarproxypublisher.cpp L732)

```cpp
void CHadrPublisher::Publish(eventId, notificationInfo)
{
    // Iterates all subscribers → calls each subscriber's Publish()
    pSubscriberInfo = GetSubscriberListHead();
    while (pSubscriberInfo) {
        pSubscriberInfo->m_pSubscriber->Publish(eventId, notificationInfo);
        pSubscriberInfo = GetNextSubscriber(pSubscriberInfo);
    }
    // ★ NO AG-level lock held during iteration
}
```

### `CDbrSubscriberFilter::PublishEventToAllSubscribers` (hadrdbrsubscription.cpp L1139)

```cpp
void CDbrSubscriberFilter::PublishEventToAllSubscribers(eventId, notificationInfo)
{
    // Step 1: Dispatch to ALL DB subscribers sequentially
    apSubscriberInfo = GetSubscriberListHead();
    while (apSubscriberInfo) {
        pDbrSubscriber->Publish(eventId, notificationInfo);  // per-DB
        apSubscriberInfo = GetNextSubscriber();
    }

    // Step 2: Wait for ALL DBs to complete
    apSubscriberInfo = GetSubscriberListHead();
    while (apSubscriberInfo) {
        WaitForDbOperationCompletion(dbrSubscriber, eventId);  // BLOCKS
    }
}
```

### `CHadrDbrSubscriber::Publish` (hadrdbrsubscriber.cpp L1809)

```cpp
void CHadrDbrSubscriber::Publish(eventId, notificationInfo)
{
    AutoRWLock autoRWLock(GetDBRRWLockPointer());  // per-DB m_DBRLock
    autoRWLock.GetLock(RWLOCK_WRITE, INFINITE);    // ★ INFINITE wait!
    
    // For EVT_AR_ROLE_CHANGE (default path):
    ScheduleDatabaseOperation(eEvent, notificationInfo);  // enqueue to thread pool
    // autoRWLock released on return
}
```

### `HadrDbrSubscriberDbOpRoutine` (hadrdbrsubscribertaskcontext.cpp L153)

```cpp
void HadrDbrSubscriberDbOpRoutine(pTaskContext, pWorkerContext)
{
    AutoRWLock autoRWLock(pContext->m_apDbrSubscriber->GetDBRRWLockPointer());
    autoRWLock.GetLock(RWLOCK_WRITE, INFINITE);
    //                 ★ m_DBRLock held for ENTIRE DatabaseSwitchRoles execution!
    
    pContext->m_apDbrSubscriber->InvokeDBOperation(eventId, notificationInfo);
    //  → ArRoleChangeDatabaseOperation → DatabaseSwitchRoles
    //  → AcquireXDbLockWithKill (can block for minutes!)
    
    // m_DBRLock released HERE when autoRWLock destructor runs
}
```

**Key implication**: A DB stuck at `AcquireXDbLockWithKill` holds `m_DBRLock` (WRITE).
If another event (e.g. RESOLVING→SECONDARY role change) needs to `Publish()` for this same DB,
it will block at `GetLock(RWLOCK_WRITE, INFINITE)` in `CHadrDbrSubscriber::Publish()`.

---

## 5. AG-Level Lock — `CHadrArProxy::m_lock`

**File**: `hadrarproxy.h`, Lines 3550–3556

```cpp
// m_apAgConfig is the in-memory cache of the AG configuration from WSFC
// m_agConfigMutex serializes access to the in-memory cache
CAutoP<HadrAvailabilityGroup>  m_apAgConfig;
mutable SOS_RecursiveMutex     m_agConfigMutex;     // ONE per AG

// m_lock is used by Signal/ProcessStateChangeNotification
SOS_RWLock  m_lock;                                  // ONE per AG
```

### Where m_lock is acquired

- `CHadrArProxy::Signal()` → `PublishRoleChangeEvent()` — acquires `m_lock` (WRITE)
  then calls `CHadrPublisher::Publish()` which iterates DB subscribers
- `CHadrArProxy::ProcessStateChangeNotification()` — acquires `m_lock` via
  `CHadrAutoArCriticalSection` (`MyEnterCriticalSection`)

**If `PublishRoleChangeEvent` is blocked while iterating DB subscribers
(because a per-DB m_DBRLock is held by a stuck DatabaseSwitchRoles worker),
it holds `m_lock` → blocks ALL subsequent AG operations.**

---

## 6. Error Code Reference

| Error | Constant | Source File | Description |
|-------|----------|-------------|-------------|
| 1480 | DBM_SWITCHROLES | `sqlerrorcodes.h` | "database 'X' is changing roles from 'Y' to 'Z'" |
| 1483 | HADRON_DATABASE_REPLICA_STATE_INFO | `sqlerrorcodes.h` | State info (Hardened/Commit LSN) |
| 35299 | HADR_ROLLBACK_PROGRESS | `SqlErrorCodes__352xx__HADR_ERROR.h` | "Nonqualified rollback...N%" |
| 1217 | LCK_KILL_BLOCKING_SESSION | `sqlerrorcodes.h` | "Process ID N killed by ABORT_AFTER_WAIT" |
| 5060 | ALT_INPROGRESS | `sqlerrorcodes.h` | Non-HADR rollback progress (ALTER DATABASE path) |
| 3303 | — | — | "Remote harden of transaction...failed" |
| 22006 | — | — | "ADR VersionCleaner aborted (database exclusive waiter)" |
