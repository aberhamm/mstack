---
id: 099
title: Add a human-approved health-gate waiver with baseline-delta mode
status: blocked
blocked-by: []
priority:
goal: health-gate-waiver-baseline-delta
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-10-26
qa: automated
reviews:
  - type=eng verdict=changes-requested date=2026-10-27 by=mstack-review
---

## Plain-English Summary

The health gate can only say pass, fail, or skipped. When a repo is already
failing for reasons the plan did not cause, a correctly scoped plan can never
finish, and the only way out is hand-editing status, which the completion gate
and git hooks (plan 038) exist to stop. This plan adds a sanctioned,
human-approved waiver per plan and per gate category. The preferred form is
"no regression versus the base commit": the gate is run on the base and on the
plan head, and passes if the plan adds no new failures. A blanket waiver is the
fallback. Waivers always show as "waived", never "pass".

**What changes in the code:** the health script gains a baseline-delta run and a
`WAIVED` category state; `review-gate.sh` gains a `waivers:` record store with
parse, validate, and `waive` subcommands; `assert-completable` and the hooks
accept a valid waiver and reject missing, expired, or self-approved ones; the
changelog and Paperclip report render waived categories distinctly.

## Requirements

Real case: next-chat-umbrella-app plan 039 (eval-only harness). Baseline has 124
typecheck errors, integration tests needing local Supabase, failing e2e, and
shellcheck failing on `dev.sh`. The plan's own scoped checks all pass. There is
no sanctioned override. Matthew approved this plan on 2026-10-26; once it ships,
plan 039 is completed using the recorded waiver note carrying that approval.

**Acceptance criteria:**

- [ ] A `waivers:` frontmatter block (same one-line `key=value` style as
      `reviews:`, no spaces in values) records, per entry: `category` (one of
      typecheck, lint, test, e2e, deadcode, shell), `mode` (`baseline-delta` or
      `blanket`), `reason`, `approver`, `date`, `scope` (`this-plan` or an
      `expires=YYYY-MM-DD` date), and `evidence` (the scoped checks that passed).
- [ ] Baseline-delta mode runs the category on the base commit and on the plan
      head commit (isolated worktree, never the dirty tree) and passes only if
      the head introduces no new failures. Comparison is by failure identity
      (error code plus file, failing test name), not raw count, so swapping one
      failure for another is a regression. Unreadable or non-comparable output
      fails closed.
- [ ] Blanket mode is accepted only when baseline-delta is infeasible, and the
      waiver must say why (`fallback-reason`). It is reported as less strong.
- [ ] `review-gate.sh assert-completable` and `hook-pre-commit` / `hook-pre-push`
      accept a valid waiver and reject a missing, expired, malformed,
      wrong-category, or self-approved one. Fail closed on any ambiguity.
- [ ] Approver must be a human owner: listed in committed
      `.mstack/config.json` `waiver-approvers`, and never an agent identity
      (`agent`, `mstack-*`, session ids). A waiver added in the same commit that
      flips the plan to `done` is rejected unless the approver differs from the
      commit author identity the agent runs as. `waive` requires an interactive
      TTY confirmation; non-interactive callers cannot create one.
- [ ] Removing or weakening a waiver after approval is caught by
      `assert-no-downgrade`, as for `reviews:`.
- [ ] Health output reports `WAIVED` per category (never `PASS`); the verdict is
      `PASS-WAIVED` when waivers were the only reason for passing. Waived
      categories are excluded from the composite weight, not scored 10.
- [ ] The mstack-changelog entry and the Paperclip report list waived
      categories, mode, approver, and date as "waived".
- [ ] Unit tests cover waiver parsing and validation; a hook test shows a commit
      to `status: done` is accepted with a valid waiver and rejected without one.
- [ ] mstack-run SKILL and `references/health-gate-spec.md` document the waiver.

## Design

**Record format** (in plan frontmatter, read by the same awk parser family as
`reviews:`):

```
waivers:
  - category=typecheck mode=baseline-delta approver=matthew date=2026-10-26 scope=this-plan reason=pre-existing_124_ts_errors evidence=eval_harness_tests_pass
```

**Validation** lives in `review-gate.sh` as `waiver-valid <plan> <category>`,
used by `assert-completable` as an additional path: a failing health category is
acceptable only if a valid waiver covers it. Reviews are unaffected.

**Baseline-delta** is a new `health-check.sh run --baseline <sha>` mode: create
a throwaway worktree at the base commit, run the category there, run it at the
plan head, diff failure sets. Persist both results under `.mstack/` as evidence.

**Approver trust.** Anti-forgetfulness, not anti-adversary (same stance as plan
034): owner allowlist in committed config, TTY-gated `waive`, agent-identity
denylist, and the same-commit rule. A determined agent editing config is out of
scope but is caught by the existing no-downgrade audit on config.

**Files expected to change:**

- `skills/mstack-run/scripts/review-gate.sh`: `waivers:` parse, `waive`,
  `waiver-valid`, completable and hook integration, no-downgrade
- `skills/mstack-run/scripts/health-check.sh`: `WAIVED` state, `--baseline`
- `skills/mstack-run/scripts/lib.sh`: shared waiver parsing helper if needed
- `skills/mstack-run/scripts/paperclip_lifecycle.py` and
  `skills/mstack-changelog/SKILL.md`: render "waived"
- `skills/mstack-run/scripts/waiver-smoke.sh` (new) and a hook test alongside
  `review-gate-smoke.sh`
- `skills/mstack-run/SKILL.md`, `references/health-gate-spec.md`,
  `plan-template.md`: docs and commented `waivers:` example

**Out of scope:** editing installed skills; changing scoring thresholds;
auto-creating waivers; waiving review gates (eng/design/ceo/code); implementing
anything in next-chat-umbrella-app; completing plan 039.

## Tasks

1. Specify the `waivers:` format and validation rules in `review-gate.sh` header.
2. Implement waiver parsing and `waiver-valid` with fail-closed semantics.
3. Add `waive` (TTY-gated, owner-allowlist checked) and no-downgrade coverage.
4. Add baseline-delta runner and `WAIVED` / `PASS-WAIVED` to `health-check.sh`.
5. Wire waivers into `assert-completable`, `hook-pre-commit`, `hook-pre-push`.
6. Render "waived" in changelog and Paperclip report.
7. Write unit and hook smoke tests.
8. Update SKILL, health-gate-spec, plan-template docs.

## Verification

Checks:

- [cmd] bash skills/mstack-run/scripts/waiver-smoke.sh
- [cmd] bash skills/mstack-run/scripts/review-gate-smoke.sh
- [assert] grep -c "WAIVED" skills/mstack-run/references/health-gate-spec.md returns a nonzero count
- [cmd] bash skills/mstack-run/scripts/health-score-smoke.sh
- [manual] Dry-run the waiver against a copy of next-chat-umbrella-app plan 039 baseline
