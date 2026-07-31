---
id: 054
title: Picker distinguishes all-blocked from all-done in unscoped mode
status: pending
blocked-by: []
priority: 21
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

`skills/mstack-run/scripts/pick-next.sh` gates its all-blocked detection (exit
12, `EXIT_ALL_BLOCKED`) on `[ -n "$SCOPE_FILTER" ]` (line 417); the unscoped
else-branch (lines 465-468) unconditionally prints "all plans done" and exits
10 (`EXIT_ALL_DONE`). So the flagship unscoped invocation — `/goal all pending
mstack plans are done or failed` — reads a fully-blocked or fully-review-gated
backlog as terminal success: `mstack-run` SKILL.md's exit-10 row (table row at
line 394, case arm at line 409) then prints "Backlog clear." and runs the
success notification over a backlog where nothing is done. Compounding it, the
`needs-review != none` skip (line 346) emits no stderr, so a review-gated plan
vanishes from the picker's output with zero trace.

**Acceptance criteria**

- [ ] Temp-repo repro from the audit: two pending plans, one dep-blocked on a
      non-done id, one `needs-review: eng` — unscoped `pick-next.sh` exits 12
      (not 10) with a stderr diagnosis.
- [ ] The exit-12 stderr diagnosis reports distinct counts: N
      dependency-blocked, M review-gated (`needs-review != none`), K
      status-blocked (`status: blocked`), and names blocking/blocked plans via
      `plan_label` (per the Plan Citation Convention in AGENTS.md).
- [ ] A genuinely all-done unscoped backlog (and an empty one) still exits 10
      with "all plans done" — no regression.
- [ ] Scoped mode keeps its existing exit-12 semantics (out-of-scope-dep
      message, lines 458-462) — purely-scoped behavior is unchanged.
- [ ] The `needs-review != none` skip at line 346 emits a one-line stderr note
      (`plan_label`: skipped, needs-review=<value>) so gated plans are visible.
- [ ] `skills/mstack-run/SKILL.md` exit-code table and case statement direct
      the unscoped exit-12 path to a truthful NOT-done terminal state: no
      "Backlog clear.", no success notification, prints the picker diagnosis.
- [ ] SKILL.md table gains the missing exit-15 row (`EXIT_GOAL_NOT_FOUND`,
      lib.sh line 14) and a matching case arm; README's picker exit table
      (lines 353-362) gains rows for 15 and the name-resolution codes it
      omits, or at minimum 15.

## Design

Hoist blocked-detection out of the scope conditional. After the candidate loop
(line 385) finds no `best_path`, run ONE shared classification pass over all
plan files regardless of `SCOPE_FILTER` (scoped mode additionally filters to
in-scope ids and keeps its out-of-scope-dep wording): for every plan whose
`status` is not `done`/`failed`, classify as (a) dependency-blocked — has an
unmet `blocked-by` dep per `parse_blocked_qualified` + `DONE_IDS`; (b)
review-gated — `needs-review` present and != `none`; (c) status-blocked —
`status: blocked` (or `in-progress`). A plan matching several buckets counts
once, in the first matching bucket, documented in a comment. If the total is
zero → exit 10 as today; otherwise print the counts + `plan_label` lines to
stderr and exit 12. `plan_label` is already sourced from `lib.sh` (line 21).

SKILL.md edits: exit-code table (lines 390-400) — reword row 12 so it covers
both scoped and unscoped ("remaining plans blocked / review-gated — backlog is
NOT done"), add row 15; case statement (lines 403-437) — exit-12 arm must echo
the stderr diagnosis and terminate the loop WITHOUT Step 8's success
notification or "Backlog clear."; add a 15 arm. README table (lines 353-362):
add 15, correct row-12 wording to include the unscoped case.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/pick-next.sh`: hoisted classification, stderr
  diagnosis, needs-review skip note.
- `skills/mstack-run/SKILL.md`: exit table rows 12/15, case arms 12/15.
- `README.md`: picker exit-code table.

**Out of scope:** removing the `eval` in the same file (plan 055); plans-dir
resolution (plan 056); a smoke suite for the picker (plan 057 owns it); any
change to scoped exit-11/13/14 behavior.

## Tasks

1. In `pick-next.sh`, extract the no-candidate classification into a function
   run for BOTH branches; keep scoped mode's extra out-of-scope-dep wording.
2. Build the three-bucket diagnosis (dep-blocked / review-gated /
   status-blocked) with counts and `plan_label` names; exit 12 when non-empty,
   else exit 10.
3. Add the stderr skip note at the `needs-review` continue (line 346).
4. Update SKILL.md exit table + case statement (rows/arms 12 and 15) so
   unscoped exit 12 never reaches "Backlog clear." or the success
   notification.
5. Update README's picker exit table.
6. Run `bash -n`, `shellcheck`, and all smoke suites.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/pick-next.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/pick-next.sh`
- [cmd] `d=$(mktemp -d) && cd "$d" && git init -q . && mkdir -p docs/plans && printf -- '---\nid: 001\ntitle: a\nstatus: pending\nblocked-by: [3]\nneeds-review: none\n---\n' > docs/plans/001-a.md && printf -- '---\nid: 002\ntitle: b\nstatus: pending\nblocked-by: []\nneeds-review: eng\n---\n' > docs/plans/002-b.md && bash /Users/matthew/dev/mstack/skills/mstack-run/scripts/pick-next.sh; test $? -eq 12`
- [assert] the repro above prints a stderr line containing `review-gated` and one containing `dependency-blocked`
- [cmd] `grep -n "15" skills/mstack-run/SKILL.md | grep -qi "goal"`
- [cmd] `grep -q "EXIT_GOAL_NOT_FOUND" README.md`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh && bash skills/mstack-run/scripts/review-gate-smoke.sh && bash skills/mstack-run/scripts/verify-lint-smoke.sh && bash skills/mstack-run/scripts/health-reach-smoke.sh && bash skills/mstack-run/scripts/wrapup-scan-smoke.sh && bash skills/mstack-run/scripts/plan-ref-smoke.sh && bash skills/mstack-run/scripts/hook-chain-smoke.sh`

## Backlog amendment (2026-07-31)

This plan now also OWNS the picker exit-code documentation rows
that plan 072 would have added; 072 is skipped. `README.md:353-362` and
`skills/mstack-run/SKILL.md:390-400` both stop at exit 14 while `lib.sh`
defines 15 (`EXIT_GOAL_NOT_FOUND`), 21/22 (`EXIT_REF_NOT_FOUND`), and codes
through 34. Add the missing rows to both tables as part of this plan rather
than leaving a second plan to edit the same table.

Do NOT add a README "Enforcement" section summarizing the four-layer model —
that was 072 acceptance criterion 4 and it duplicates doctrine that plan 085
exists to delete.
