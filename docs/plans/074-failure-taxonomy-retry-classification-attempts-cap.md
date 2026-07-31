---
id: 074
title: classify failures as retryable vs permanent with a capped attempts counter
status: pending
blocked-by: [057]
priority: 32
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

`status: failed` is uniformly terminal today. "Recovery from a failed
iteration's commit" (`skills/mstack-run/SKILL.md:1263-1268`) tells the USER to
hand-edit frontmatter back to `status: pending` — a human step in an autonomous
loop. Yet `failed-reason` values span wildly different classes treated
identically: `agent-error` (SKILL.md:762 — agent crashed or returned no result
block, often transient), `health-gate-unavailable` (SKILL.md:839-842 — a
missing environment binary), and investigation exhaustion after 9 strikes
(`skills/mstack-investigate/SKILL.md:139-167`, verdict FAILED at line 167 — a
genuinely hard bug). A transient rate-limit permanently kills a plan AND, via
the dependency-skip path (SKILL.md:747-758), its whole downstream chain. Worst:
`health-gate-unavailable` — an environment problem, not a plan defect — FAILS
the plan and REVERTS working code (SKILL.md:838-843).

**Acceptance criteria**

- [ ] A failure taxonomy classifies every known `failed-reason` value as
      `retryable`, `permanent`, or `environment`. Closed set: an UNKNOWN
      reason classifies as `permanent` (fail closed, mirroring the
      review-gate doctrine in `AGENTS.md`).
- [ ] Retryable failures below the cap set `status: pending` and increment a
      new `attempts: N` frontmatter counter instead of terminal `failed`;
      `failed-reason`/`failed-at` are retained as last-attempt history. An
      increment that reaches the cap writes terminal `status: failed` (see
      Design) — a plan never sits permanently-pending at the cap.
- [ ] `pick-next.sh` reads `attempts:` and treats `attempts >= cap` as
      ineligible-permanent (skipped like `failed`). Cap default 3,
      overridable via config key `retry.max_attempts`.
- [ ] `health-gate-unavailable` becomes `status: blocked` with a
      `blocked-reason:` naming the missing tool and the saved patch path;
      the work is preserved to `.mstack/evidence/plan-<id>/env-blocked.patch`
      and the tree is then reverted per the standard rollback recipe (no
      plan-attributable dirt survives the iteration).
- [ ] `plan-template.md` and plan-doctor's field vocabulary gain `attempts`.
- [ ] The retry loop is bounded deterministically in the picker, not by prose.

## Design

Classification lives in one place: a `failure_class <reason>` helper in
`skills/mstack-run/scripts/lib.sh` (beside `code_verdict_from_findings`,
lib.sh:559) echoing `retryable|permanent|environment`; unknown → `permanent`.
Initial mapping — retryable: `agent-error`, `context-exhausted`; environment:
`health-gate-unavailable`; permanent: everything else (including
investigation exhaustion). The other known values are still named in the
table as permanent rather than left to the catch-all:
`missing-verification-checks` and `verification: <check description>`
(`skills/mstack-run/references/verification-spec.md:22,131`), plus
`investigation-exhausted` (the value plan 079 introduces). `failure_class`
matches on the **first whitespace-delimited token** of `failed-reason`, so a
composite value like `investigation-exhausted (see <path>)` classifies by
its leading token instead of falling through as unknown. The taxonomy is
documented in a new `AGENTS.md` section so authors and reviewers share the
same table the helper implements.

The increment happens in the orchestrator at Step 7b ("7b. On failure",
SKILL.md:1076-1089), which already owns the failure frontmatter write: it
calls `failure_class`, and on `retryable` writes `status: pending` +
incremented `attempts:` instead of `status: failed`. **Cap-terminal rule:**
when the incremented `attempts:` reaches the cap, Step 7b writes terminal
`status: failed` (retaining `failed-reason`/`failed-at`) instead of
`pending` — so dependents get the existing dependency-skip handling
(SKILL.md:747-758, which keys on the dependency's `status: failed`) and
pick-next's all-blocked/all-done accounting never sees a permanently-pending
zombie; the picker's `attempts >= cap` check remains as a backstop for
hand-edited counters. On `environment` it
writes `status: blocked` + `blocked-reason:` — but the working tree must NOT
be left dirty: before setting `status: blocked`, save the plan's full diff to
`.mstack/evidence/plan-<id>/env-blocked.patch` (the evidence dir is the
established sink), then revert per the standard rollback recipe, and
reference the patch path in `blocked-reason:` so resume/re-run can recover
the work — this preserves the plan-039 rollback doctrine (no
plan-attributable dirt survives an iteration) while losing nothing. The
health-gate-unavailable path (Step 7a item 0, the plan-043 health-result
check, SKILL.md:838-843 — not a Step 5 site) is rewritten to match.

The cap is enforced where infinite loops are actually prevented: in
`pick-next.sh`'s frontmatter filter (selection rules, pick-next.sh:5-10),
which parses `attempts:` alongside `status:` and excludes plans at/over the
cap. Cap read from `retry.max_attempts` via `config.sh get` (dispatch at
config.sh:124-126), defaulting to 3 when unset or non-numeric.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/lib.sh`: add `failure_class`.
- `skills/mstack-run/scripts/pick-next.sh`: parse `attempts:`, enforce cap.
- `skills/mstack-run/scripts/config.sh`: default for `retry.max_attempts`.
- `skills/mstack-run/SKILL.md`: Step 7b classification branch (incl.
  cap-terminal rule); the health-gate-unavailable path (Step 7a item 0, the
  plan-043 health-result check, SKILL.md:838-843) → blocked with
  patch-preservation then revert; recovery section note.
- `skills/mstack-run/plan-template.md`: `# attempts:` comment line.
- `skills/mstack-plan-doctor/SKILL.md`: field vocabulary gains `attempts`.
- `skills/mstack-run/scripts/failure-class-smoke.sh`: new smoke suite.
- `skills/mstack-run/scripts/pick-next-smoke.sh`: extend with the
  attempts-cap skip case.
- `AGENTS.md`: taxonomy table + fail-closed rule.

**Out of scope:** auto-unblocking environment-blocked plans when the tool
reappears (plan 075); changing the 9-strike investigate discipline; any retry
that re-runs within the same iteration (retry means re-eligibility for a
FUTURE pick, never an in-iteration loop).

## Tasks

1. Add `failure_class` to `lib.sh` with the closed-set mapping;
   unknown → `permanent`.
2. Write `failure-class-smoke.sh`: each known reason maps correctly
   (including first-token matching on a composite value), an unknown reason
   maps to `permanent`, and a fixture plan with `attempts: 3` is skipped by
   `pick-next.sh` while `attempts: 2` is not.
3. Wire the cap into `pick-next.sh` (config-read with default 3);
   `chmod +x` + `git update-index --chmod=+x` the new smoke script.
4. Rewrite Step 7b in `mstack-run/SKILL.md` to branch on `failure_class`
   with the cap-terminal rule; change the health-gate-unavailable path to
   blocked-with-patch-preservation (save the diff to
   `.mstack/evidence/plan-<id>/env-blocked.patch`, then revert per the
   standard rollback recipe).
5. Extend `pick-next-smoke.sh` (created by plan 057) with the attempts-cap
   skip case.
6. Update `plan-template.md`, plan-doctor vocabulary, and `AGENTS.md`.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/lib.sh skills/mstack-run/scripts/pick-next.sh skills/mstack-run/scripts/failure-class-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/failure-class-smoke.sh`
- [assert] `grep -c "failure_class" skills/mstack-run/scripts/lib.sh`
- [cmd] `grep -q "retry.max_attempts" skills/mstack-run/scripts/config.sh`
- [cmd] `grep -q "attempts" skills/mstack-run/plan-template.md`
- [cmd] `grep -q "failure_class" skills/mstack-run/SKILL.md`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/plan-ref-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
