# Writing the Product-Group AV ICM

Audience = SQL Server product-group engineers who must change code directly. Every conclusion
needs **raw WinDbg output immediately followed by the matching source**. Delete any sentence with
no evidence.

## Fixed ICM structure (use this order)

1. **Title = full faulting function signature** (with template params), e.g.
   `sqllang!CDisjointSet<COptExpr *,CFnHashCOptExpr,CFnCompCOptExpr,CMemObjAlloc<0> >::FindNoCompression`
2. **One bucket label line:** `[SQL Box] - <CSS case #> - <AV code + faulting function signature>`
3. **Problem** — 1–2 sentences: what operation triggers the crash + whether it's deterministic.
4. **Current Status** — which versions/CUs reproduce; one sentence on root-cause nature (code
   defect, and whether it's *not* gated by some feature switch).
5. **Environment Details** — whether OS/build/hardware are material; stress "reproduces with no
   special configuration".
6. **Customer Impact and Sentiment** — real business impact (e.g. repeated AG failover); stress
   it's not cosmetic.
7. **Questions and Request from CSS** — numbered yes/no questions for engineering + "can it be
   scheduled for a fix". Compress your inferred root cause into one line for them to confirm
   ("Is this a confirmed product defect?").
8. **Detailed Summary and Troubleshooting** — the numbered evidence chain (the core; see below).
9. **Root Cause / Proposed Fix** — one root-cause paragraph + 2–3 fix directions for the PG to choose.
10. **Steps to reproduce** — a fully self-contained T-SQL script (create db/tables + trigger),
    runnable verbatim.

## How to write the evidence chain (most important)

Each numbered item = one claim + **raw WinDbg output** + **the matching source snippet
(file@line)**. Typical 7-item order (from the case study):

1. **Faulting instruction** — `.exr -1` + key registers + the faulting disassembly line + the
   `FindNoCompression` source; point out it dereferences `[rcx+8]` while rcx=0 → reads 0x8 → AV.
2. **Which element is being searched** — paste `Unify`/`Find`/`ValLookup` source; explain the
   argument `pexprRight` is not in the set → ValLookup returns NULL → `FindNoCompression(NULL)`.
   Stress that RETAIL compiles out `Assert(FContains)`.
3. **Container contents prove it was never stored** — first paste the **full bucket dump** and show
   the number of printed entries equals `m_cEntries`; point out `pexprRight` is absent while
   `pexprLeft`/siblings are present. Compute hash/bucket only if the hash formula has already been
   validated against live `m_hashVal` values; otherwise do not invent a bucket.
4. **Algebrizer tree + registration table** — paste the relevant subtree + a table
   `| # | bucket | first | position in tree | operator | who registers it |`, and point out the
   faulting node is the **only** projection element with no row.
5. **Trace-flag counter-proof** — disabling the feature (e.g. TF 106) avoids the crash but the
   statement then fails to analyze (e.g. Msg 208 / 11501), proving the path is the culprit *and*
   the TF is not a usable workaround.
6. **Why the node was never registered** — paste `COpArg::DeduceEncryptionTypes`'s
   `for j<GetArity()` loop + `dx -r1 pSelf` showing `m_cpexprInput = 0`. Then include the sibling
   counter-example: `CScaOp_Identifier::DeduceEncryptionTypes` explicitly calls `Register`, while
   no `CScaOp_IdentityFunc::DeduceEncryptionTypes` override exists in the analyzed source.
7. **Full sequence** — give the TTD position, stringing together "walk reaches the node → arity 0
   skips registration → Project still calls Unify on it → AV".

## Style iron rules

- Paste every register / stack / `dx` / bucket dump **verbatim** (don't edit addresses, don't
  truncate), immediately followed by the matching source.
- Source must carry the real path + line number (`tcetypededuct.cpp @ 4452`). The dump build's
  line numbers may differ from master — give both ("@4452 in dump / @4536 in master").
- The root-cause paragraph must state "who should have registered but didn't + who still goes on
  to Unify + RETAIL has no Assert to catch it".
- For hash-table cases, prefer "full `m_cEntries` enumeration proves absence" over an unvalidated
  hash formula. If a formula was tried and mismatched, say it was discarded and do not use it as
  evidence.
- Give 2–3 fix directions and mark which is most targeted vs most hardening; let the PG decide.
- The repro script must be self-contained and reproduce in one run.

## Reference template & products

- Template: a real product-group bug-report `.docx` (docx = zip; extract `word/document.xml` text
  with PowerShell unzip).
- Finished ICM example: `sp_describe_AV_ICM.md`.
- Companion detailed RCA: `sp_describe_undeclared_parameters_AV_RCA_report.md`.
