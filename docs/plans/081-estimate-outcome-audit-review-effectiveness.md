---
id: 081
title: add estimate field, outcome audit, and review-effectiveness harvest
status: skipped
blocked-by: []
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
skipped: 2026-07-31
skipped-reason: "backlog optimization: largest plan in its cluster; by its own AC changes nothing about whether the loop progresses"
---

## Requirements

The pipeline never measures its own decisions (audit F8). Concretely, against
the working tree: `skills/mstack-run/plan-template.md` has no effort field, so
predicted-vs-actual is impossible even retroactively; nothing checks whether a
done plan's diff survived or was reverted after its `mstack/plan-<id>-done`
tag; `.mstack/reviews/plan-*.json` records per-plan findings counts + fixed
(17 files exist, e.g. `plan-043.json`: `findings_high: 1, fixed: 2`) but is
never aggregated anywhere; and `reviewed: false` is stamped on nearly every
archived plan (42 of 43; the remaining one predates the field, and NO archived
plan carries `reviewed: true` in frontmatter — the two grep hits for that
string are prose mentions in 034/036 bodies) and the flag has literally never
been flipped. This plan adds the smallest load-bearing measurement slice — all
read-only reporting, no scorer or dashboard machinery.

**Acceptance criteria**

- [ ] `plan-template.md` frontmatter gains `estimate:` (S|M|L);
      `mstack-plan-new` and `mstack-plan-multi` stamp it at authoring.
- [ ] `mstack-run` Step 7a is untouched except that `created:`/`completed:`
      are documented as the actuals pair for estimate comparison (both fields
      already exist; no new completion-time write).
- [ ] A read-only `outcome-audit.sh` reports, for each archived plan with an
      `## Implementation Notes` files list, whether its diff is intact /
      partially reverted / fully reverted since its `mstack/plan-<id>-done`
      tag. Missing tag or missing files list → reported as `unverifiable`,
      never silently skipped.
- [ ] `mstack-status` surfaces the outcome-audit summary next to the plan-038
      review-audit section (`skills/mstack-status/SKILL.md:169-176`).
- [ ] `mstack-wrap-up`'s harvest adds a review-effectiveness aggregate (N
      plans, M findings by severity, K fixed, hit rate by review mode) from
      `.mstack/reviews/*.json`, plus estimate-vs-actual (created→completed
      span vs `estimate:`) for plans completed this session.
- [ ] Nothing in this plan writes to any plan file, review record, or gate.

## Design

New small script `skills/mstack-run/scripts/outcome-audit.sh` rather than
extending `review-gate.sh` — review-gate stays single-purpose (gate
enforcement); this is reporting. Mechanism: for each `docs/plans/archive/*.md`,
parse the `**Files changed:**` list from `## Implementation Notes` (written by
Step 7a step 4) and the plan id; if the `mstack/plan-<id>-done` tag exists, run
`git log --oneline <tag>..HEAD -- <files>` and classify: no later commits
touching the files → `intact`; later commits touching some → `modified-after`
(reported, not judged); a later revert commit naming the plan's commit, or all
listed created files now absent → `reverted`/`partially-reverted`. Output is
one line per plan plus a summary count; exit 0 always (reporting, not a gate).

Estimate: template comment line documents `estimate: S|M|L` (S ≤ half a
session, M ≤ one session, L = should probably decompose). Authoring skills
stamp it; absent field on legacy plans is reported as `unestimated`, never an
error (contrast with `review-required`: this field is advisory, not a gate —
no fail-closed doctrine applies).

Wrap-up aggregate: computed at harvest time by reading `.mstack/reviews/*.json`
with `jq` (mode, findings_* fields, fixed) — mode-keyed hit rate is
`findings_fixed / findings_above_threshold` per mode. Session scope = plans
whose `completed:` equals the session's date range from the latest checkpoint.
**Missing-field policy (the 17 existing files span ~15 distinct ad-hoc
schemas; many lack `mode`, several lack `findings_above_threshold`/
`findings_fixed`, e.g. `plan-043.json` has `fixed` and no `mode`):** a file
with no `mode` buckets as `unknown`; a file missing either hit-rate operand is
counted and reported as `unparseable-N`, never guessed at and never a crash.
The cache is NON-authoritative (AGENTS.md), so schema chaos is expected input,
not an error.

Estimate-vs-actual honesty note: the `created:`→`completed:` span includes
queue time (a plan can sit authored for days before being picked), so it is a
noisy proxy for effort. Accepted: at S/M/L granularity the signal survives the
noise, and adding a start-time write is exactly the Step 7a change this plan's
acceptance criteria forbid.

Testing approach: unit-only.

**Files expected to change:**

- `skills/mstack-run/scripts/outcome-audit.sh`: NEW (100755 +
  `git update-index --chmod=+x`).
- `skills/mstack-run/plan-template.md`: `estimate:` line.
- `skills/mstack-plan-new/SKILL.md`, `skills/mstack-plan-multi/SKILL.md`:
  stamp `estimate:` at authoring.
- `skills/mstack-status/SKILL.md` + `skills/mstack-run/scripts/status.sh`:
  outcome-audit section next to the review audit.
- `skills/mstack-wrap-up/SKILL.md`: review-effectiveness + estimate-vs-actual
  aggregates in the harvest.

**Out of scope:** any gate/blocking behavior on estimates or outcomes; flipping
`reviewed:` (that stays a human act); a scorer, trend store, or dashboard;
backfilling `estimate:` onto existing plans; changing what Step 7a writes.

## Tasks

1. Add `estimate:` to `plan-template.md` and the two authoring skills.
2. Write `outcome-audit.sh` (tag lookup, Implementation Notes file-list parse,
   git-log classification, summary line); commit-mode 100755.
3. Surface its summary in `status.sh` and `mstack-status/SKILL.md` beside the
   plan-038 audit section.
4. Add the review-effectiveness and estimate-vs-actual aggregates to
   `mstack-wrap-up`'s harvest output.
5. Run shellcheck + the smoke suites.

## Verification

Checks:

- [cmd] `grep -q 'estimate:' skills/mstack-run/plan-template.md`
- [cmd] `grep -q 'estimate' skills/mstack-plan-multi/SKILL.md`
- [cmd] `test -x skills/mstack-run/scripts/outcome-audit.sh`
- [cmd] `bash skills/mstack-run/scripts/outcome-audit.sh` → exit 0
- [assert] `bash skills/mstack-run/scripts/outcome-audit.sh | grep -c 'intact\|modified-after\|reverted\|unverifiable'` → >= 1
- [cmd] `grep -q 'outcome-audit' skills/mstack-status/SKILL.md`
- [cmd] `shellcheck skills/mstack-run/scripts/outcome-audit.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/status.sh`
