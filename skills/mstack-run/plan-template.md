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
goal:                     # optional; groups plans from the same planning session. Kebab-case slug.
allows-migrations: false  # true ONLY for plans that intentionally edit db/migrations/**
needs-review: none        # MUTABLE remaining-work tracker: none | eng | design | ceo | eng,design | ceo,eng | ceo,design | ceo,eng,design. Run the corresponding /plan-*-review skill(s) before mstack-run picks it up. The picker/reviewers flip this as work is completed.
# review-required:         # IMMUTABLE declared review-gate list (subset of eng,design,ceo,code). Stamped ONCE at authoring; never cleared or shrunk. Distinct from needs-review. The completion gate (scripts/review-gate.sh) requires a passing `reviews:` record for every type here before the plan may be marked done. If ABSENT, the gate fails closed and derives the required set from needs-review (absent field is NEVER "nothing required"). Backfill legacy plans with `review-gate.sh backfill`.
# verification: health-only  # uncomment ONLY if no executable checks are possible (purely visual plans)
# review: thorough           # uncomment for 3-blind-reviewer pipeline (default: 1 unified reviewer)
created: 2026-04-30
# Filled in by mstack-run on completion:
# completed: <YYYY-MM-DD>
# reviewed: false         # false | true. Has the human personally reviewed the shipped code
# reviews:                # Review records — the SINGLE SOURCE OF TRUTH the completion gate trusts.
#   - type=eng verdict=approved date=2026-07-04 by=agent
#   - type=code verdict=pass date=2026-07-04 by=mstack-code-review
#                         #   One compact line per performed review (values never contain spaces).
#                         #   type ∈ eng|design|ceo|code. verdict ∈ approved|changes-requested|pass|fail
#                         #   (code passes with `pass`; eng/design/ceo pass with `approved`). Written by
#                         #   the review skills via `review-gate.sh record`. The derived
#                         #   .mstack/reviews/plan-<id>.json cache is NON-authoritative.
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

<!--
## Implementation Notes

Appended automatically by mstack-run on completion. Do not write this
section manually — it is generated from the subagent's result block.

Contains: summary of what was implemented, files changed (modified vs
created), and the implementation commit hash with message.
-->
