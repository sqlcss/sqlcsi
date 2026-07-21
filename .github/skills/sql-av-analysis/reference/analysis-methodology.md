# Analysis Methodology — TTD / Crash Root-Causing for SQL Server

The conclusion goes **straight to the product group to change code**. No guessing. One wrong
step misleads the fix.

## Iron rules

- **Never infer call arguments from local variable names.** Callee-saved registers
  (rsi/rdi/rbx/r12–r15) only hold leftover values from the caller frame; they have nothing to do
  with the current call's arguments. To read real arguments, read the stack home/spill slots
  `[rsp+offset]`.
- **Every reasoning step needs disassembly + source double-confirmation.** When source is inlined
  several layers deep, use the disassembly to lock down the real control flow.
- **WinDbg MASM expressions default to hex radix.** `<<13` is parsed as `<<0x13`. Prefix every
  decimal shift/count constant with `0n`.
- **A `(UINT32)cast` in C source must be `& 0xFFFFFFFF` in a WinDbg expression.** Otherwise stray
  high bits from the previous step pollute the next xorshift.
- **PowerShell big-number math overflows to double.** Validate bit operations with C# `unchecked`
  or `[bigint]`.
- **Hash implementation is source/version-specific.** The hash functor source tells you which key
  is hashed; it does not prove your arithmetic formula is correct. If a guessed `Hash64bits`
  formula fails to match live `m_hashVal` values for multiple entries, abandon the formula and use
  full bucket enumeration or TTD stepping over the actual hash call.
- **Validate wrapper/container layout before raw offsets.** For `CAutoP`, `CTMap`, `CTHashTable`,
  and list nodes, first use `dx` field paths to get `m_table`, `m_buckets`, `m_cEntries`, and entry
  layout. Do not treat the first qword of a wrapper as the contained pointer unless the type view
  proves it.
- **Reverse-validate before writing a conclusion.** Any intermediate value you compute (hash,
  bucket index, offset, field value, size, branch decision) must match the actual field in memory
  (e.g. `m_hashVal`). If it doesn't match, your reasoning drifted — restart, don't force-fit.

## Standard 7-step flow

1. **Pin the AV location** — exception address, exception code, parameter 0/1 (read vs write,
   target address).
2. **Disassembly ↔ source** — which source line is the faulting instruction? Which C++ object's
   which field does it dereference? Confirm the field offset matches the object type.
3. **Identify the bad C++ object** — the pointer dereferenced as NULL/garbage is which member of
   which object? (The runtime arg/field, not the source-level name.)
4. **Explain why it's corrupt** — walk back: how was it constructed? Who should have
   initialized/inserted it? Which path skipped it?
5. **Sibling comparison** — other objects of the same type/lifetime in the same container: why
   didn't they AV? Find the differing point; map it to a source branch.
6. **Code location** — which commit/branch/version introduced the differing branch? Is it fixed
   in newer builds? Search msdata / GitHub history.
7. **Fix recommendation** — what call/check to add on which line; why that suffices; side effects.

## Report presentation rules

**Each key analysis node must simultaneously provide:**

1. **`!ttdext.position`** (or a TTD position like `7F2F5:1BDA`) — pins the point in time.
2. **`k` callstack** (≥5 frames, incl. inline frames) — pins the calling context.
3. **The node's source snippet** (file name + line number) — pins the location in space.
4. When needed, `r` registers, `dx` of key objects, 1–3 lines of relevant disassembly.

Suggested format:

```
═══ Node N: <one-line description> ═══
TTD pos : 7F2F5:1BDA
Callstack:
  00 (Inline) sqllang!CTHashTable::TFind+0x18 [stdhash.inl @ 414]
  01 (Inline) sqllang!CTMap::ValLookup+0x1f  [stdmap.inl  @ 170]
  02 sqllang!CDisjointSet::Find+0x23          [tce.inl     @ 60]
  03 sqllang!CEncryptionTypeDeductionContext::Unify+0x41 [tcetypededuct.cpp @ 1573]
  04 sqllang!CRelOp_Project::DeduceEncryptionTypes+0xa2  [tcetypededuct.cpp @ 4536]
Key state: rax=0 (PtFind miss)
Source   : tcetypededuct.cpp@1573  prightSet = m_apExprDisjointSet->Find(pexprRight)
Analysis : ...
```

The reader should map at a glance: which point in time / which call chain / which source line /
what state.

### Computed values must be cross-validated against memory

Whenever you compute a value from source (hash, bucket index, offset, field, size, decision),
**immediately follow it with a WinDbg command that prints the actual value from memory**, and
state explicitly "computed = X, dump = X ✓ match" or "computed = X, dump = Y ✗ reasoning drifted,
re-check". Never compute without validating. If it fails, stop and go back a step — never
force-fit. Example:

```
Compute: hashVal = 0x88cf18e5, bucket = hashVal % 0n100 = 1
Verify : dx (CHashEl*)0x2ad9bcbee70 -> m_hashVal = 0x88cf18e5  ✓
         bucket head @ m_buckets+1*8 = 0x2ad9bcbee70           ✓
```

If the exact hash implementation is not available or your formula does not validate, a full bucket
dump whose live entry count equals `m_cEntries` is still a valid proof of absence. State it as:
"all `m_cEntries` entries were enumerated; target key X is absent", rather than inventing a bucket.

## Find the hash functor — don't guess from symbol names

- Container hierarchy example: `CDisjointSet → CTMap → CTHashTable`. CTHashTable's 3rd template
  parameter is `HashFn` (the functor type). **Do not assume hash key == the template KeyType.**
- In the case study the functor `CFnHashCOptExpr::operator()(COptExpr const* pexpr)` has 3 branches:
  - identifier over an algorithm variable → hash of the variable name string;
  - other `ScaOp_Identifier` → pointer hash of `pexpr->Identifier()->Pvr()` (a `CValRef*`, i.e.
    `m_pval` at +0x48) — **not** the `COptExpr*`;
  - everything else → `Hash64bits(COptExpr*)` (the pointer itself).
- Lesson: computing `Hash64bits(COptExpr*)` matched only 3/10 entries — that was the signal the
  functor was transforming the key. **Correct approach:** read the `CFn*Hash*` functor source
  first, then decide which field is the key.
- Validation: breakpoint the functor, inspect rcx (pexpr) and rax (return), and
  `dx pexpr->m_poparg` to see which ClassNo branch is taken.
- `bucket = hashVal % m_cBuckets` (here `m_cBuckets = 0n100`).
- If `Hash64bits` is an imported/non-inline helper in the build, do not reconstruct it from memory
  or prior notes. Either step over the actual call in TTD and read `eax`, or rely on full bucket
  enumeration.

## The "all N data points match" hard rule

- For hash/serialization formulas, **at least 3 independent data points must all match** before
  concluding "the algorithm is correct". One match may be coincidence (especially with low-byte
  alignment).
- Any mismatch > 0 → stop and suspect immediately: wrong key field? missing preprocessing
  (truncation/normalization)? multiple paths using different algorithms?

## Case study lessons (AV in CDisjointSet::FindNoCompression)

- First mistakenly treated `pleftSet=0x2ad9bcbe550` as the `PtFind` arg → computed a bucket-1 hit
  → contradicted the AV (rcx=0). The real situation: `PtFind` returned NULL (rax=0 @ TFind+0x18),
  so `me.second=0` took the `CInvalidFn()` default 0 → `FindNoCompression(0)` → AV. Fully
  self-consistent.
- The real argument was `pexprRight=0x2ad9c707220` (the 2nd `Find`), which was **never Inserted**
  into the disjoint set → PtFind miss → NULL → AV.
- Root cause: `CRelOp_Project::DeduceEncryptionTypes` (tcetypededuct.cpp@4536 master / @4452 in the
  dump build) calls `Unify(pexprSet, pexprEl)` where `pexprEl` is a `ScaOp_IdentityFunc` (from
  `IDENTITY(int,1,1)`) that was never Registered by any lower Deduce path, because its arity
  (`m_cpexprInput`) is 0 so the bottom-up walk never recurses into it.
- The decisive storage proof was full bucket enumeration: `m_cBuckets=0x64`, `m_cEntries=0xa`, and
  all 10 live entries were printed. `RelOp_Project` and the sibling `ScaOp_Identifier` nodes were
  present, but `ScaOp_IdentityFunc` was absent. This proof does not require a trusted hash formula.
- Sibling comparison matters: `CScaOp_Identifier::DeduceEncryptionTypes` explicitly calls
  `Register(pSelf, md)`, so arity-0 identifiers can still be registered. No
  `CScaOp_IdentityFunc::DeduceEncryptionTypes` override was found, so the arity-0 identity node
  only follows the default child walk and is skipped.
- Only ~10 of ~30 tree nodes get Registered: structural/predicate nodes (RelOp_Select/Join/Get,
  AncOp_PrjList/PrjEl) never participate; identifiers and comparisons do.
- The disjoint-set key is `COptExpr*`, **not** `m_poparg` (`COpArg*`). Mixing them up makes bucket
  lookups not line up.
