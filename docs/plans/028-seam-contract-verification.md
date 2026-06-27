---
id: 028
title: Seam-contract verification across plan dependency edges
status: pending
blocked-by: [026, 027]
priority:
goal: doctor-autonomy-hardening
allows-migrations: false
needs-review: none
created: 2026-06-26
---

## Requirements

plan-doctor's cross-plan consistency agent checks dependency ORDERING (does B
run after A) and file overlap, but not interface CONSISTENCY: whether plan B's
assumptions about the artifacts plan A produces (function signatures, schemas,
endpoint path/verb, CLI flags) actually match what A's spec says it produces.
This is the dominant source of cascade drift in long dependency chains — B
builds on a contract A never promised, and the divergence is only discovered
when the worker reaches B. (Observed: downstream plans assumed a gate
signature, a record shape, and endpoint behaviors that upstream plans defined
differently.)

Add a seam-contract check: for each `blocked-by` edge A→B, diff A's produced
contract against B's assumed contract and flag mismatches.

**Acceptance criteria:**

- [ ] The doctor builds, per plan, a PRODUCED set (symbols / endpoints /
      schemas / flags / files the plan's Design + "Files expected to change"
      declare it creates) and an ASSUMED set (artifacts it references from its
      blocked-by ancestors), by heuristic extraction from plan prose.
- [ ] The doctor EMITS a normalized, MACHINE-READABLE seam block into each plan
      file (an HTML-comment-delimited `<!-- mstack:seam ... -->` block with the
      schema defined in `seam-contracts.md`: per entry a `kind`, `name`,
      optional `shape` signature/field-list/verb, optional `file`, and `from:`
      plan id for assumed entries). This block — not the freeform prose — is the
      canonical contract that plan 029's shell parses at pickup. Emission is
      IDEMPOTENT: re-emitting an unchanged contract produces a byte-identical
      block (no hash change, no spurious "modified" churn in plan 026's loop).
- [ ] For each edge A→B, the check diffs B.ASSUMED-from-A against A.PRODUCED and
      reports mismatches: MISSING (B assumes X, A produces nothing named X) or
      SHAPE-DIVERGENT (name matches, but signature / field list / verb differs).
- [ ] BOTH MISSING and SHAPE-DIVERGENT are BLOCKING: a SEAM finding gates the
      `ready` verdict (it is a blocking finding per plan 026's definition). The
      report states the finding is heuristic and names the edge + symbol so the
      architect can confirm or override, but the default is to block.
- [ ] The seam check runs in BOTH all-plans and single-plan doctor scope. The
      existing cross-plan consistency agent only runs for all-plans; the seam
      check must NOT be confined to it — in single-plan scope (`/mstack-plan-doctor NNN`)
      it loads NNN's blocked-by ancestors and checks the edges incident to NNN.
      (Plan 029's recovery path directs users to single-plan doctor; the seam
      check must actually run there.)
- [ ] Verifiability is anchored on `file:` and defined IDENTICALLY here and in
      plan 029 (single source of truth in `seam-contracts.md`): an assumed entry
      is VERIFIABLE iff it carries a `file:` path — then existence is checked and,
      if `shape:` is present, the shape token is checked WITHIN that file. An
      assumed entry with NO `file:` (even though `name:` is always present) is
      UNVERIFIABLE → noted, non-blocking, never MISSING. A bare `name:` is never
      grepped repo-wide (too noisy to be a reliable stale signal). To maximize
      verifiable coverage, 028's emitter SHOULD populate an assumed entry's
      `file:` from the name-matched PRODUCED entry of the upstream plan when the
      edge resolves.
- [ ] Seam-triggered edits mark the plan MODIFIED so plan 026's loop re-runs the
      seam diff on that plan's incident edges (coordinated with 026's loop scope).

## Design

The design splits cleanly into a HEURISTIC authoring step and a DETERMINISTIC
artifact. Extraction is heuristic from plan prose (an LLM/agent task): PRODUCED =
the symbols/paths in "Files expected to change" + Design declarations ("adds
`gate(...)`", "`POST /dispatch/confirm`", "`RankerOutput` with `confidence`");
ASSUMED = references to those same kinds of names attributed to an upstream plan.
But the OUTPUT is deterministic: the doctor normalizes the extraction into a
machine-readable `<!-- mstack:seam ... -->` block written into each plan file.
That block is the contract — plan 029's shell script parses the block, never the
prose. This resolves the prose-vs-shell seam between 028 and 029: prose is the
input to authoring; the structured block is the interface.

**Seam block schema** (defined canonically in `seam-contracts.md`): an
HTML-comment block (invisible in rendered markdown, greppable, line-oriented so
`awk`/`grep` can parse it). Sketch:

```
<!-- mstack:seam
produced:
- kind: symbol; name: gate; shape: "gate(plan, ctx)"; file: skills/mstack-run/scripts/x.sh
- kind: endpoint; name: POST /dispatch/confirm
assumed:
- from: 028; kind: symbol; name: gate; shape: "gate(plan)"
-->
```

`kind` ∈ {symbol, endpoint, schema, flag, file}. `name` is always present.
`shape` and `file` are optional, BUT verifiability is anchored on `file:`: an
assumed entry with a `file:` is VERIFIABLE (existence + in-file shape token);
an assumed entry without `file:` is UNVERIFIABLE and never blocks (a bare name
is not grepped repo-wide). This rule is the single source of truth that plan
029's parser obeys. The exact grammar (delimiters, field separators, escaping)
is fixed in `seam-contracts.md` so 029's parser and 028's emitter agree
byte-for-byte.

The diff is name-first, then a shallow shape comparison where BOTH sides state a
`shape`. The extraction is NOT a deterministic AST parser (prose is too
freeform); only the emitted block is deterministic.

**Files expected to change:**

- `skills/mstack-plan-doctor/SKILL.md`: add seam-contract verification that runs
  in BOTH all-plans and single-plan scope (do not bury it inside the all-plans-only
  cross-plan consistency agent); build PRODUCED/ASSUMED per plan, emit the
  normalized seam block into each plan idempotently, diff each `blocked-by` edge,
  and add the BLOCKING "SEAM" finding category to the Step 4 report format.
- `skills/mstack-plan-doctor/references/seam-contracts.md` (new): the canonical
  machine-readable block grammar (so 029 can parse it), extraction heuristics,
  attribution/normalization rules, per-edge diff rules, the mismatch taxonomy
  (MISSING / SHAPE-DIVERGENT / UNVERIFIABLE), the report block format, the
  blocking-verdict rule, and the prose-only caveat. Shared with plan 029.

**Out of scope:** enforcing seams at execution time (plan 029 consumes this
definition); the adversarial audit (plan 027); a deterministic AST-level prose
extractor (note as future work, do not build here). Pre-populating seam blocks
in `mstack-plan-multi` at authoring time is also future work — here the doctor
generates them.

## Tasks

1. Write `references/seam-contracts.md`: define (a) the canonical
   `<!-- mstack:seam ... -->` block grammar — exact delimiters, field
   separators, `kind`/`name`/`shape`/`file`/`from` fields, escaping — precise
   enough that a POSIX shell (`awk`/`grep`) can parse it unambiguously (029
   depends on this); (b) the heuristic PRODUCED/ASSUMED extraction rules,
   including attribution (how an ASSUMED entry is tied to a specific blocked-by
   ancestor) and normalization (casing, stripping arg names, endpoint
   verb+path); (c) the name-first + shallow-shape diff; (d) the MISSING /
   SHAPE-DIVERGENT / UNVERIFIABLE taxonomy and which are BLOCKING; (e) the report
   block format. Include a worked end-to-end example (plan A "adds
   `gate(plan, ctx)`" → produced block; plan B "calls `gate()` from plan A with
   the plan id" → assumed block → SHAPE-DIVERGENT on arg count → blocking).
2. Add seam-contract verification to SKILL.md as a step that runs in BOTH
   all-plans and single-plan scope (NOT confined to the all-plans-only cross-plan
   consistency agent). For each plan, extract PRODUCED/ASSUMED and EMIT the
   normalized seam block into the plan file idempotently (byte-identical on
   re-emit). Then diff each `blocked-by` edge per `seam-contracts.md`. In
   single-plan scope, load the target's blocked-by ancestors and check incident
   edges only. Keep the existing ordering/overlap checks unchanged.
3. Add a BLOCKING "SEAM" findings section to the Step 4 report (cite both plan
   ids + the symbol/endpoint + mismatch type); ensure SEAM MISSING and
   SHAPE-DIVERGENT count as blocking findings in the Step 6 `ready` gate (the
   blocking-findings set plan 026 defines), while UNVERIFIABLE is noted only.
4. Wire the loop feed: a seam-triggered plan edit marks the plan MODIFIED (its
   content hash changes), and per plan 026's loop scope the seam diff on that
   plan's incident edges re-runs in Step 4b. Confirm the emitted block's
   idempotency so a no-op re-emit does NOT mark a plan modified.

## Verification

Checks:
- [cmd] test -f skills/mstack-plan-doctor/references/seam-contracts.md
- [cmd] grep -qiE "produced" skills/mstack-plan-doctor/references/seam-contracts.md
- [cmd] grep -qiE "assumed" skills/mstack-plan-doctor/references/seam-contracts.md
- [cmd] grep -qiE "shape.divergent|missing" skills/mstack-plan-doctor/references/seam-contracts.md
- [cmd] grep -qiE "mstack:seam" skills/mstack-plan-doctor/references/seam-contracts.md
- [cmd] grep -qiE "single.plan|both .* scope|all.plans and single" skills/mstack-plan-doctor/references/seam-contracts.md skills/mstack-plan-doctor/SKILL.md
- [cmd] grep -qiE "block(ing|s)? .*(ready|verdict)|SEAM .*block" skills/mstack-plan-doctor/SKILL.md skills/mstack-plan-doctor/references/seam-contracts.md
- [assert] grep -ni "seam" skills/mstack-plan-doctor/SKILL.md | grep -iE "contract|edge|produced|assumed|report"
- [manual] run plan-doctor on a chain where B assumes a function signature A defines differently; confirm a blocking SEAM SHAPE-DIVERGENT is reported and gates `ready`
- [manual] run `/mstack-plan-doctor NNN` (single-plan scope) on a plan with a stale upstream seam; confirm the seam check actually runs and reports
- [manual] run plan-doctor twice with no contract change; confirm the emitted seam block is byte-identical the second time (idempotent, no spurious modified-plan churn)
