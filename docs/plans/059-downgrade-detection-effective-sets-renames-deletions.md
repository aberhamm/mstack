---
id: 059
title: compare effective required sets in downgrade detection and handle renames and deletions in the hook
status: pending
blocked-by: [058]
priority: 45
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-30
qa: automated
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-plan-doctor
---

## Requirements

Three confirmed bypasses of the plan-038 write-time barrier, reproduced live.

(a) LAUNDERING. A legacy plan with no `review-required` field and
`needs-review: eng` has derived required set `{eng}` (fail-closed doctrine,
AGENTS.md). Adding the single line `review-required: none` in the working tree
passes `assert-no-downgrade`, `assert-completable`, AND the pre-commit hook —
because `_no_downgrade_between` section 3 (review-gate.sh lines 261-280)
iterates HEAD's RAW tokens via `_raw_required`, which is EMPTY for an absent
field, so no shrink is ever detected.

(b) RENAME+WEAKEN. `cmd_hook_pre_commit` (line 855) uses
`git diff --cached --name-only --diff-filter=ACMR`; a `git mv` lists only the
NEW path, which has no HEAD baseline (`has_head=0` at lines 873-877, downgrade
check skipped at line 888) — so a rename plus stripping the approval line,
staged in one commit, is ACCEPTED.

(c) DELETION. `D` entries are excluded by the diff-filter entirely: `git rm`
of a plan carrying recorded verdicts is accepted, destroying the record
plan 037 protects.

**Acceptance criteria**

- [ ] `_no_downgrade_between` compares EFFECTIVE required sets (with
      `cmd_required` derivation) on both sides and fails on any shrink —
      the laundering probe from (a) now exits `EXIT_GATE_DOWNGRADE` and the
      hook rejects the commit.
- [ ] The hook parses `git diff --cached --name-status -z -M`; for `R` entries
      the OLD path supplies the HEAD baseline, so rename+weaken is rejected.
- [ ] A staged `D` of a plan whose HEAD content has `reviews:` entries is
      rejected unless the same commit stages a plan file with the same
      frontmatter id (rename/archive fallback).
- [ ] The Step 8 archive flow (`git mv "$NEXT" archive/` with identical
      content, per SKILL.md line 797) still passes — regression case included.
- [ ] The per-path fail-open `git show ":$path" > ... || continue` (line 870)
      fails closed: unreadable staged content rejects the commit.
- [ ] Paths with spaces/special chars survive intact (`-z` parsing).

## Design

For (a): in `_no_downgrade_between`, replace the two `_raw_required` calls with
a small `_effective_required <file>` wrapper around `cmd_required` semantics
(explicit field wins; absent field derives from `needs-review`). Fail on any
member of HEAD's effective set missing from the new file's effective set.
Consequence, stated on purpose: flipping `needs-review: eng -> none` on a
legacy plan WITHOUT a stamped `review-required` now trips the check — that is
correct per the fail-closed doctrine, and the remediation is
`review-gate.sh backfill <plan>` first (stamp `review-required: eng`), then
flip the tracker. `_raw_required` stays for any caller that genuinely needs
the declared-only view.

That consequence is not hypothetical — it hits mstack's OWN honest path:
`mstack-plan-doctor` Step 5's approve flow (SKILL.md ~lines 1277-1295) records
the verdict, flips `needs-review: eng -> none`, and commits, WITHOUT ever
stamping `review-required` — on a legacy plan the effective set shrinks
`{eng} -> {}` and the new hook rejects the doctor's own approval commit. So
this plan MUST also edit `skills/mstack-plan-doctor/SKILL.md` Step 5: on the
approve path, run `review-gate.sh backfill <plan>` BEFORE removing the tag
from `needs-review` (order matters — `_backfill_one` derives the stamp from
`needs-review`, which must still carry the tag; the call is idempotent and
skips plans whose `review-required` is already present). With the stamp in
place the staged effective set stays `{eng}` (explicit) and the approval
commit passes.

Fail-closed propagation (inherits plan 058's verified caveat):
`_no_downgrade_between` runs inside `if`-conditions, where `set -e` is
suspended — so `head_req="$(_effective_required "$head_file")"` must check the
substitution status explicitly and turn a failure into `fail=1` with a
"cannot derive required set" message, never fall through with an empty set.

For (b)+(c): rewrite the staged-file loop in `cmd_hook_pre_commit` on
`git diff --cached --name-status -z -M`. NUL-parse: status token, then path
(R/C entries carry old-path then new-path). For `R*`: baseline =
`git show "HEAD:$old"`, staged = `git show ":$new"`, run
`_no_downgrade_between` and the done-transition check against that pair. For
`D`: read HEAD content; if `review_entries` is non-empty, collect the plan id
and reject unless another staged A/R-target plan file in the same commit
carries the same id (compare via `fm_get id` + `normalize_id`). Plan identity
here is (goal, id), not the bare numeric id — the deletion rename-fallback
must match the re-added plan by the same goal-qualified identity (or an
identical archive-relative path), so a same-numeric-id plan in a different
goal can never mask deletion of a reviewed plan. Note the
`case` glob `docs/plans/*.md|plans/*.md` matches `docs/plans/archive/*.md`
too (shell `case` `*` crosses `/`), so archive moves are inspected: identical
content means no downgrade and HEAD status is already `done`, so they pass —
pin that with a test, do not special-case archive paths. Any `git show`
failure for a path under inspection sets `rejected=1` with a
"cannot verify staged content" message instead of `continue`.

Edit the hook logic only in `review-gate.sh` (`cmd_hook_pre_commit`); the thin
shims delegate and should need no change — if shim text must change, edit the
SHIPPED SOURCE `skills/mstack-run/hooks/pre-commit` then copy to
`.githooks/pre-commit` (never `.githooks/` only). Update AGENTS.md sentences
these bypasses falsify only where the implemented wording now differs.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/review-gate.sh`: `_effective_required`,
  `_no_downgrade_between` section 3, `cmd_hook_pre_commit` loop.
- `skills/mstack-plan-doctor/SKILL.md`: Step 5 approve path — `backfill`
  before the `needs-review` flip (see Design; without it this plan breaks the
  doctor's own approval commits on legacy plans).
- `skills/mstack-run/scripts/review-gate-smoke.sh`: laundering case.
- `skills/mstack-run/scripts/hook-chain-smoke.sh`: rename/deletion/archive
  cases.
- `skills/mstack-run/hooks/pre-commit` + `.githooks/pre-commit`: only if shim
  text changes (expected: no change).

**Out of scope:** sanctioned demotion (plan 062), audit history recovery
(plan 060), `record` internals (plan 058), pre-push changes.

## Tasks

1. Add `_effective_required` and switch `_no_downgrade_between` section 3 to
   effective-set comparison; keep the failure message naming the vanished type.
2. Rewrite the `cmd_hook_pre_commit` staged loop on `--name-status -z -M`
   with R old-path baselines and D rejection (same-id fallback).
3. Convert the line-870 `|| continue` to a fail-closed rejection.
4. Update `mstack-plan-doctor` SKILL.md Step 5 approve path: insert the
   idempotent `review-gate.sh backfill <plan>` call before the `needs-review`
   tag removal, with one sentence explaining why (effective-set downgrade
   protection).
5. Smoke: (i) laundering — legacy plan committed without `review-required`,
   working tree adds `review-required: none`, `assert-no-downgrade` exits 24
   and a commit is rejected; (ii) `git mv` + strip approval rejected;
   (iii) `git rm` of a reviewed plan rejected; (iv) archive-style `git mv`
   with identical content passes; (v) rename with unchanged content passes;
   (vi) a plan path with a space survives; (vii) doctor-flow regression —
   legacy plan committed, then backfill + record approved + flip
   `needs-review: none` staged together is ACCEPTED by the hook.
6. Re-check the four AGENTS.md enforcement sections against the new behavior;
   adjust wording only where now false.
7. Run the full smoke set and shell lint.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/review-gate.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/review-gate.sh skills/mstack-run/scripts/review-gate-smoke.sh skills/mstack-run/scripts/hook-chain-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [assert] `grep -c "name-status" skills/mstack-run/scripts/review-gate.sh` — the hook loop no longer uses name-only
- [cmd] `cmp skills/mstack-run/hooks/pre-commit .githooks/pre-commit` — shipped source and installed copy identical

## Backlog amendment (2026-07-31)

SCOPE NARROWED to one case: reject a staged deletion (`git rm`) of
a plan file that carries recorded `reviews:` entries. That is a cheap
accident-guard worth roughly twenty lines.

The other two cases are DROPPED:
- The absent-`review-required` laundering path applies to ZERO of the plans
  currently in this repo, and plan 070 closes the pipe that would create more
  by making authoring stamp the field. Defending a surface that is empty
  today and permanently empty after 070 is not worth the risk.
- The `git mv` + strip case requires a deliberate multi-step evasion by the
  sole user of a gate that exists to protect that same user.

Specifically DO NOT rewrite the live pre-commit loop to NUL-parsed
`--name-status -z -M`. That was the highest-blast-radius change in the
backlog — a bug there rejects or accepts every commit in every consumer
repo — and it was serving the two cases just dropped.
