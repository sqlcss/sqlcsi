# WinDbg / TTD Command Cheat-Sheet (reusable for AV analysis)

Tested, validated commands from the `CDisjointSet::FindNoCompression` AV case
(`sp_describe_undeclared_parameters`). Copy and adapt.

## Recommended MCP usage

For interactive TTD/dump analysis, configure WinDbg MCP Server first:
https://www.osgwiki.com/wiki/WinDbg_MCP_Server

Recommended flow:

1. Open the `.run`/dump in WinDbg and wait until symbols/source are usable.
2. Start/connect the WinDbg MCP Server.
3. Use the agent to run the commands below and collect raw output.
4. Keep every important command output paired with the source snippet it proves.

If MCP is unavailable, run the commands manually in WinDbg and paste exact output into the report.

## Common traps: radix / truncation / registers / layout / hash

- **Default hex.** Always prefix decimal shift/count constants with `0n`: `@$t0<0n100`, `<<0n13`.
- **`(UINT32)` cast in source → `& 0xFFFFFFFF` in WinDbg**, or high bits pollute the next xorshift.
- **Temp registers are numeric only:** `$t0`–`$t9`. Names like `$tB` are invalid (raises
  "invalid register").
- **`.for` / `.while` must be on a single line** — multi-line forms raise syntax errors.
- **Do not hard-code wrapper layout.** Use `dx` field paths for `CAutoP`/`CTMap`/`CTHashTable`
  before treating a raw qword as a table or contained pointer.
- **Do not hard-code hash formulas.** If a guessed formula does not match live `m_hashVal` values,
  stop and step the actual hash call or use full bucket enumeration.

## Exception scene

```
.exr -1                 ; exception record: ExceptionCode / Parameter[0] read|write / Parameter[1] target addr
r                       ; registers; inspect the pointer being dereferenced (rcx/rax/...)
u rip L3                ; faulting instruction; the [reg+off] off -> infer the field offset
k                       ; call stack, incl. (Inline Function) rows -> locate the source layer
!ttdext.position        ; current TTD position (e.g. 7F2FB:0); label every report node with it
```

## Full bucket dump for a hash table / disjoint set (with bucketAddr column)

First get the CTHashTable `m_buckets` (bucket-array base) and `m_cBuckets` (here `0n100`):

```
dx -r1 (*((sqllang!CTHashTable<...>*)<table_addr>))
```

Prefer field paths from the owning object when possible; this avoids wrapper-layout mistakes:

```
dx -r3 ((sqllang!CEncryptionTypeDeductionContext*)<ctx>)->m_apExprDisjointSet->m_Elements.m_table
dx ((sqllang!CEncryptionTypeDeductionContext*)<ctx>)->m_apExprDisjointSet->m_Elements.m_table.m_cBuckets
dx ((sqllang!CEncryptionTypeDeductionContext*)<ctx>)->m_apExprDisjointSet->m_Elements.m_table.m_cEntries
dx ((sqllang!CEncryptionTypeDeductionContext*)<ctx>)->m_apExprDisjointSet->m_Elements.m_table.m_buckets
```

One line to dump every entry in every bucket (linked list per bucket):

```
.for (r $t0=0; @$t0<0n100; r $t0=@$t0+1) { r $t2 = <m_buckets> + @$t0*8; r $t1 = poi(@$t2); .while (@$t1 != 0) { .printf "bucket=%3d bucketAddr=%p entry=%p first=%p hashVal=%08x\n", @$t0, @$t2, @$t1, poi(@$t1+8), dwo(@$t1+0x18); r $t1 = poi(@$t1) } }
```

- `$t0` = bucket index, `$t2` = bucket slot address (bucketAddr), `$t1` = current entry,
  `poi(@$t1)` = next pointer.
- Adjust entry offsets to the real layout: `+8` = first/value, `+0x18` = `m_hashVal`
  (confirm with `dx -r1` first).
- The number of live entries should equal `m_cEntries`; if not, the traversal missed a chain.

Confirm the entry layout before trusting offsets:

```
dx -r2 (*((sqllang!CTHashTableBase<...>::CHashEl*)<entry>))
dq <entry> L5
```

## Algebrizer tree dump

```
dx -r3 (*((sqllang!COptExpr*)<root_addr>))     ; expand the operator tree 3 levels
```

Save output, then grep/filter the RelOp/AncOp/ScaOp rows and addresses into an
"address → operator → parent/child" map. **Note:** the disjoint-set key is `COptExpr*`, not
`m_poparg` (`COpArg*`); if the filtered tree's first column shows OpArg addresses they won't line
up with the buckets.

## Hash key derivation (ScaOp_Identifier special case)

The functor `CFnHashCOptExpr::operator()` has 3 branches:

- identifier over an algorithm variable → hash of the variable name string;
- other `ScaOp_Identifier` → pointer hash of `pexpr->Identifier()->Pvr()` = a `CValRef*`
  (`m_pval` @ +0x48);
- other operators → `Hash64bits(COptExpr*)` (the pointer itself).

Pick the key field:

```
dx -r1 ((sqllang!COptExpr*)<addr>)->m_poparg     ; check ClassNo -> which branch
dx ((sqllang!CScaOp_Identifier*)<addr>)->m_pval   ; for ScaOp_Identifier, this is the key
```

The functor identifies the key, not necessarily a portable closed-form hash formula. If
`Hash64bits` is not inline in the current build, get the exact `hashVal` by stepping over the
actual call in TTD and reading `eax`, or skip arithmetic and prove absence by dumping all buckets.
Only use a reconstructed formula after at least 3 live entries match `m_hashVal`.

```
; If stopped before/inside the hash path:
p              ; step over the Hash64bits call
r eax          ; eax = hashVal
? eax % 0n100  ; bucket for a 100-bucket table
```

After computing, you **must** validate against the entry's `m_hashVal`. If it does not match,
discard the formula.

## Reverse: find "who corrupted it"

```
ba w8 <addr> ; g-          ; reverse write breakpoint -> the last write to that memory
```

## Arity / registration-path confirmation

```
dx -r1 pSelf                       ; m_cpexprInput (arity); ==0 means no recursion -> never registered
; source COpArg::DeduceEncryptionTypes: for (j=0; j<GetArity(); j++) recurses into children
```

For `SELECT IDENTITY(...) INTO #t`, confirm the projection path without expanding the whole tree:

```
dx ((sqllang!COptExpr*)<project>)->m_rgpexpr[1]        ; AncOp_PrjList
dx ((sqllang!COptExpr*)<prjlist>)->m_rgpexpr[0]        ; first AncOp_PrjEl
dx ((sqllang!COptExpr*)<prjel>)->m_rgpexpr[0]          ; ScaOp_IdentityFunc
dx ((sqllang!COptExpr*)<identity>)->m_cpexprInput      ; 0
```

Then compare with sibling projection elements. Identifiers may also have arity 0, but
`CScaOp_Identifier::DeduceEncryptionTypes` explicitly registers them; absence of an
`IdentityFunc` override is the differentiator.

## Key artifacts produced (case study)

- `dump_buckets_with_bucketaddr.txt` — the bucket-dump script
- `alge_tree.txt` / `tree.filtered.txt` — tree dump and filtered tree
- `h64.ps1` — Hash64bits verification (use C# `unchecked` / `[bigint]` to avoid overflow)
- `sp_describe_undeclared_parameters_AV_analysis.cpp` — dump analysis notes
