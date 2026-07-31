---
id: 062
title: add a sanctioned verdict demotion path so re-review does not require --no-verify
status: pending
blocked-by: []
priority: 25
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
qa: automated
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-plan-doctor
---

## Requirements

Confirmed deadlock in the honest path. After a committed
`type=eng verdict=approved`, the sanctioned actor (plan-doctor Step 5 via the
named review skill) recording `changes-requested` on re-review has no legal
way to persist it: `cmd_record` replaces the type's entry in place (the
replace loop at review-gate.sh lines 590-607), which drops the rank from 2 to
1 per `verdict_rank` (lib.sh lines 526-532), so `assert-no-downgrade`
(section 2, review-gate.sh lines 243-259) exits `EXIT_GATE_DOWNGRADE` AND the
pre-commit hook rejects the commit. But plan 037 REQUIRES every recorded
verdict committed immediately. The only path through is
`git commit --no-verify` — the enforcement model trains its honest users to
bypass it.

**Acceptance criteria**

- [ ] `record`, when the new verdict is weaker (lower `verdict_rank`) than the
      newest existing entry for the same type, APPENDS a fresh entry carrying
      a `supersedes=<date-of-superseded>` token and PRESERVES all prior
      entries verbatim; once a type carries >=2 entries, ALL further records
      for it append (chains are append-only); same-or-stronger verdicts keep
      today's replace-in-place ONLY in the single-entry case.
- [ ] The downgrade check (`_no_downgrade_between` + pre-commit hook) accepts
      a rank decrease IFF it arrives as an appended record with a `supersedes=`
      token, a date >= the superseded entry's date, and every HEAD entry for
      that type still present verbatim. Removal or in-place weakening still
      fails with `EXIT_GATE_DOWNGRADE`.
- [ ] Gate semantics are newest-record-per-type: `_type_cleared` (and thus
      `assert-completable`) honors the LAST entry per type in file order, so a
      superseding `changes-requested` RE-OPENS the gate, and a later appended
      re-approval closes it again.
- [ ] AGENTS.md documents this as the single sanctioned demotion path.
- [ ] Smoke: sanctioned demotion passes hook + `assert-no-downgrade`;
      in-place edit still rejected; gate re-opens and re-closes correctly.

## Design

Record format stays compact one-line key=value (values never contain spaces):
`type=eng verdict=changes-requested date=2026-07-30 by=agent
supersedes=2026-07-04`. `kv_get` already parses arbitrary keys, so no parser
change. "Newest" = last entry for the type in the `reviews:` block (append
order); `date` corroborates but file order decides, since two records can
share a date.

`_type_cleared` changes from "every entry for the type passes" to "the last
entry for the type passes". This is what makes supersession meaningful in both
directions: demotion re-opens, re-approval re-closes even though a
`changes-requested` entry remains in history. `_max_rank_for_type` is replaced
at its call site by a last-entry-rank helper (`_last_rank_for_type`) so the
downgrade comparison is newest-vs-newest.

Chain rule — resolves an otherwise-inconsistent trio (replace-in-place vs
"append a fresh approved" vs smoke case (v) below): once a type has TWO OR
MORE entries (a demotion chain exists), ALL further records for that type
APPEND — replace-in-place survives only for the single-entry case with a
same-or-stronger verdict (today's idempotent re-record). Two reasons this is
forced: (1) the current replace loop (lines 590-607) emits the new entry once
PER matching line, so replacing into a 2-entry chain would duplicate the
record and destroy the chain 060's audit expects preserved; (2) newest-vs-
newest rank comparison alone cannot see the deletion of a superseded
(weaker-ranked) history entry, so the downgrade check needs a chain-
preservation clause, and that clause in turn forbids replace-into-chain.

Downgrade acceptance rule, checked structurally, two clauses per type:
(A) newest rank decreased vs HEAD => allowed only if every HEAD entry for
that type appears verbatim in the new file AND the newest entry carries
`supersedes=` with a date >= the newest HEAD entry's date; (B) independent of
rank direction, when HEAD has >=2 entries for a type, every one of them must
appear verbatim in the new file (append-only chains) — clause (B) is what
makes deleting a superseded entry fail even though the newest rank is
unchanged (smoke case (v)). Single-entry HEAD keeps today's replace
semantics when rank is not lowered. Honesty note for the plan text and AGENTS.md:
a shell script cannot verify WHO appended the record — actor restriction
("only named review skills demote") remains plan-035 prose enforced by skill
instructions plus the audit trail; what the mechanism guarantees is that
demotion is append-only and evidence-preserving, never destructive.

`cmd_record` gains the branch: compute the existing entry count and newest
rank for the type; append when the type already has >=2 entries (chain
exists, any rank — `supersedes=` added only when the rank decreases) or when
the new verdict's rank is lower than the sole entry's; otherwise (single
entry, same-or-stronger) keep replace-in-place. This is purely file-local —
no git read inside `record` — and stays consistent with clause (B) because a
chain only ever grows. The 058 read-back check applies unchanged to the
appended entry.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/review-gate.sh`: `cmd_record` append branch,
  `_type_cleared` newest-per-type, `_last_rank_for_type`,
  `_no_downgrade_between` sanctioned-demotion acceptance.
- `skills/mstack-run/scripts/review-gate-smoke.sh`: demotion cases.
- `AGENTS.md`: document the sanctioned demotion path in the review-gate
  section.

**Out of scope:** audit history recovery (plan 060 consumes these semantics),
hook shim files, any change to who may invoke `record` (plan 035 prose),
`review-required` handling (059 owns effective-set comparison).

## Tasks

1. Add `_last_rank_for_type` and switch `_type_cleared` to
   newest-record-per-type; keep fail-closed on unknown verdicts.
2. Add the append branch to `cmd_record`: rank-decreasing records append with
   `supersedes=`; any record on a type that already has >=2 entries appends
   (never replaces into a chain — the replace loop would duplicate the new
   entry once per matching line and destroy the chain).
3. Teach `_no_downgrade_between` both clauses: (A) rank-decrease acceptance
   (HEAD entries preserved verbatim + newest entry has `supersedes=` + date
   not older) and (B) chain preservation (>=2 HEAD entries for a type must
   all appear verbatim, regardless of rank direction); everything else that
   lowers a newest rank still fails.
4. Smoke: (i) record approved, commit, record changes-requested — file gains a
   second eng entry, `assert-no-downgrade` exits 0, a commit passes the hook;
   (ii) `assert-completable` now fails (gate re-opened); (iii) append a fresh
   approved — gate closes again, no downgrade; (iv) in-place sed of
   approved→changes-requested still exits 24 and the hook rejects; (v) removing
   the superseded entry still exits 24.
5. Document the path in AGENTS.md (one paragraph in "Review Records and the
   Completion Gate": what qualifies, what stays forbidden).
6. Run the full smoke set and shell lint.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/review-gate.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/review-gate.sh skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [assert] `grep -c "supersedes" skills/mstack-run/scripts/review-gate.sh` — the marker is implemented
- [assert] `grep -c "supersedes" AGENTS.md` — the sanctioned path is documented

## Triage amendment (2026-07-31)

ABSORBS the `by=` injection-guard regression case from plan 063,
which is dropped. Add it to `review-gate-smoke.sh` alongside this plan own
demotion cases rather than to a new suite.

Scoping note for the reviewer: the design as written (append-only chains,
`supersedes=`, clauses A/B, re-defining `_type_cleared` from "all entries pass"
to "last entry passes") is heavier than one user needs. The deadlock is real and
reproduced — record `approved`, commit, then record `changes-requested`, and the
pre-commit hook rejects (exit 24) while `assert-committed` simultaneously
demands the commit (exit 25), leaving `--no-verify` as the only exit. Narrow the
mechanism at execution time if a simpler one closes it.
