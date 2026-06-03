<!--
Plan file template for the `mstack-run` skill.
Copy this into `plans/NNN-slug.md` (NNN = zero-padded sequential id).

The skill picks the lowest-numbered plan with `status: pending` whose
`blocked-by` ids are all `status: done`. Frontmatter is the source of truth
for state; do not track plan status anywhere else.
-->

---
id: 001
title: Short imperative title (becomes branch name and PR title)
status: pending           # pending | in-progress | done | failed | blocked
blocked-by: []            # list of plan ids that must be `done` first, e.g. [042, 043]
priority:                 # optional; lower runs first, defaults to id when absent
allows-migrations: false  # true ONLY for plans that intentionally edit db/migrations/**
needs-review: none        # none | eng | design | ceo | eng,design | ceo,eng | ceo,design | ceo,eng,design. Run the corresponding /plan-*-review skill(s) before mstack-run picks it up
# verification: health-only  # uncomment ONLY if no executable checks are possible (purely visual plans)
# review: thorough           # uncomment for 3-blind-reviewer pipeline (default: 1 unified reviewer)
created: 2026-04-30
# Filled in by mstack-run on completion:
# completed: <YYYY-MM-DD>
# reviewed: false         # false | true. Has the human personally reviewed the shipped code
# qa: automated           # comma-separated: none | automated | e2e | browser
#                         #   automated = verification gate (typecheck/lint/unit tests)
#                         #   e2e = end-to-end integration tests
#                         #   browser = browser-based QA (scripted or manual)
# Filled in by mstack-run on failure:
# failed-reason: <short>
# failed-at: <YYYY-MM-DD>
---

## Requirements

What user-visible problem does this solve? One paragraph. Be concrete: which
endpoint, which screen, which user. If you can't name a user, the plan is too
abstract to run unattended. Break it down further.

**Acceptance criteria** (the autonomous worker treats these as the test
oracle, so be specific):

- [ ] ...
- [ ] ...
- [ ] ...

## Design

How will it work? Files expected to change. Schemas, types, contracts. Edge
cases the agent must handle. Anything that requires judgment goes here, not
in Tasks. Tasks is for execution; Design is for decisions.

**Files expected to change:**

- `path/to/file.ts`: what changes
- `path/to/other.ts`: what changes

**Out of scope:** name anything a sloppy agent might be tempted to also fix
but shouldn't.

## Tasks

Concrete, ordered execution steps. Each should be small enough to verify.

1. ...
2. ...
3. ...

## Verification

**Mandatory.** Every plan must have at least one executable check (`[cmd]`,
`[assert]`, or `[status]`). If you can't describe how to verify this plan
programmatically, it's not ready for autonomous execution. For purely visual
plans with no testable endpoints or commands, add `verification: health-only`
to the frontmatter.

Use the format `[type] description` where type is one of:
- `[cmd]`: run a shell command, assert exit code 0
- `[assert]`: run a command, assert output contains a string
- `[status]`: hit a URL, assert HTTP status code
- `[browse]`: browser-based check via gstack's /browse skill (requires gstack).
  Format: `[browse] <url-or-path> <assertion>`. The assertion is a natural
  language description of what to verify in the browser.
  Examples:
    - `[browse] /settings/billing verify 'Current Plan' heading is visible and shows a plan name`
    - `[browse] /dashboard verify the chart renders with at least one data point`
    - `[browse] /login verify the login form has email and password fields`
  If gstack is not installed, `[browse]` checks are skipped with a warning
  (they do not cause failures). Use `[browse]` for web-facing plans that
  need browser-level verification beyond API or file-existence checks.
- `[manual]`: note for human review (skipped in automation, does not count
  toward the mandatory executable check requirement)

Checks:
- ...
