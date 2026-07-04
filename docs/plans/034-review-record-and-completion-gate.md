---
id: 034
title: Review-record format + fail-closed completion-gate script
status: done
blocked-by: []
priority:
goal: plan-ref-and-review-gates
allows-migrations: false
needs-review: none
created: 2026-07-04
completed: 2026-07-04
reviewed: false
qa: automated
---

## Requirements

A plan flagged for review (`needs-review: eng|design|ceo`, or an open
code-review gate) must not be markable as done, cleared, or
`mstack/plan-NNN-done`-tagged until that review has actually been performed and
recorded by the review process. The anti-pattern observed today: an implementing
agent offers to "clear its `needs-review: eng`, or say go and I'll proceed
outside the picker" — routing around the gate entirely.

Today `needs-review: none` is a single mutable frontmatter scalar that *any*
agent can hand-edit. `pick-next.sh` skips plans whose `needs-review != none`
(so it won't *pick* them), but nothing stops an agent from flipping the flag to
`none` itself, or from running the plan "outside the picker" and then marking it
done. The clearing authority and the completion authority are the same actor.

**Threat model (be honest).** Every actor here is the same class of LLM agent
editing markdown in a git repo. There is no cryptographic barrier, and there are
no active git hooks today (`.git/hooks` holds only the default `*.sample` files;
`core.hooksPath` is unset). So a script the
agent *chooses* to call is anti-forgetfulness, not anti-adversary. This plan
delivers the deterministic mechanism (script + record format); plan 036 wires it
into the completion path; **plan 038 makes it non-optional** (a git hook that
rejects bad transitions regardless of whether the agent runs the script, plus a
retroactive audit that catches `--no-verify` / out-of-band completions). The
three together are the enforcement; this plan alone is not.

**Decisions locked in this plan (the eng review flagged these as must-decide,
not defer):**

- **Record store = frontmatter `reviews:` list** on the plan file — the single
  source of truth. It travels with the plan through git history and archive, and
  `assert-no-downgrade` can diff it against `HEAD`. The existing
  `.mstack/reviews/plan-<id>.json` becomes a derived, non-authoritative cache
  only; the gate never trusts it.
- **Required-review source = an immutable `review-required:` frontmatter field**
  stamped once at authoring, listing the review types that must be recorded
  before completion. It is *declarative and never cleared* (distinct from
  `needs-review:`, which the picker/reviewers mutate to track *remaining* work).
- **Legacy / missing `review-required` fails closed, not open.** When a plan has
  no `review-required` field, the gate derives the required set from the current
  `needs-review:` tags (treating any non-`none` tag as required) — it must never
  treat "field absent" as "nothing required." A doctor backfill (plan 035/status
  audit) stamps `review-required` onto legacy plans from their `needs-review`.
- **`review-required` is itself guarded against tampering:** `assert-no-downgrade`
  fails if `review-required` shrinks or empties versus `HEAD`. An in-repo scalar
  is only tamper-*evident* (via the downgrade check + the 038 hook), never
  tamper-proof — say so.

**Acceptance criteria:**

- [ ] The `reviews:` record format is documented in `plan-template.md` and
      `AGENTS.md`: each entry is `{type, verdict, date, by}`. `verdict` ∈
      `approved | changes-requested | pass | fail`.
- [ ] `review-required:` is documented in the template as the immutable declared
      gate list; `needs-review:` documented as the mutable remaining-work tracker.
- [ ] `review-gate.sh required <plan>` prints the required review types:
      `review-required` when present, else derived from `needs-review` (fail
      closed — absent field ≠ empty set).
- [ ] `review-gate.sh cleared <plan> <type>` exits 0 iff a `reviews:` entry for
      that type has a passing verdict (`approved` for eng/design/ceo, `pass` for
      `code`).
- [ ] The **code** verdict has a defined fail condition: a `code` review records
      `fail` when any critical/high finding remains unfixed after the review
      (mapped from the existing `findings_*` counts), else `pass`. An absent
      `code` record = open gate. (Producer wiring is plan 035; the mapping is
      defined here so an executor cannot default it to `pass`.)
- [ ] `review-gate.sh assert-completable <plan>` exits 0 **only if** every
      required review has a passing record; otherwise nonzero with a
      human-readable reason. Missing/garbled records = not completable.
- [ ] `review-gate.sh assert-no-downgrade <plan>` compares against committed
      `HEAD` and fails if any of: `reviewed: true→false`; a `reviews:` entry
      removed or its verdict weakened; `review-required` shrunk or emptied.
- [ ] `review-gate.sh record <plan> <type> <verdict>` appends/updates a `reviews:`
      entry (used by producers in plan 035; defined here).
- [ ] `bash -n` clean, `shellcheck` clean, `bash 3.2`-compatible.

## Design

**Fail closed, always.** Any ambiguity — no record, malformed record, unreadable
plan, unknown verdict, absent `review-required` — resolves to "not completable"
or "required". The gate never fails open.

**Why this is only tamper-evident.** `review-required`, `reviews`, and `reviewed`
all live in the same markdown any agent can edit. The defenses are layered:
`assert-no-downgrade` catches weakening *versus HEAD* (so a bypass has to also
rewrite history), the 038 hook rejects the bad commit/tag at write time, and the
038 audit retroactively flags any completed plan missing its records. This plan
provides the primitive all three call.

**Files expected to change:**

- New `skills/mstack-run/scripts/review-gate.sh`.
- `skills/mstack-run/scripts/lib.sh`: shared helpers (record parsing, verdict
  mapping) + new exit-code constants. (Note: 031 also edits the exit-code block;
  sequential on `main`, so re-read before editing.)
- `skills/mstack-run/plan-template.md`: document `review-required:` and `reviews:`.
- Fixtures for the smoke test.

**Out of scope:** wiring the gate into completion (036), producing records /
forbidding self-clear (035), the git hook + audit (038).

## Tasks

1. Lock the record + required-review format into the template and `AGENTS.md`.
2. Implement `review-gate.sh`: `required`, `cleared`, `assert-completable`,
   `assert-no-downgrade`, `record`, with the fail-closed and legacy-fallback
   rules above.
3. Define the `code` fail-condition mapping from `findings_*` counts.
4. Add exit-code constants + helpers to `lib.sh`.
5. Add a `review-gate.sh backfill` (or doctor/init step) that stamps
   `review-required` onto existing plans that carry a non-`none` `needs-review`
   but no `review-required` (derives the required set from `needs-review`). This
   covers every legacy plan and any still-pending plan in the current backlog so
   they get an explicit, immutable declaration rather than relying on the
   fail-closed fallback forever.
6. Add fixtures + smoke test, including the legacy fixture (`needs-review: eng`,
   no `review-required`) that must be non-completable.

## Verification

- `[cmd]` `bash -n skills/mstack-run/scripts/review-gate.sh skills/mstack-run/scripts/lib.sh`
- `[cmd]` `shellcheck skills/mstack-run/scripts/review-gate.sh`
- `[cmd]` `assert-completable` on a fixture with a required-but-unrecorded review
  exits nonzero; on a fixture with all required reviews recorded passing exits 0.
- `[cmd]` `assert-completable` on a legacy fixture with `needs-review: eng` and
  **no** `review-required` exits nonzero (fails closed, does not treat absent as
  empty).
- `[cmd]` `assert-no-downgrade` fails on each of: `reviewed: true→false`; a
  removed `reviews:` entry; a shrunk `review-required` — versus the committed
  version.

## Implementation Notes

Implemented the fail-closed review-record + completion-gate primitive.
**Record encoding:** the frontmatter `reviews:` block is one compact line per
entry (`  - type=eng verdict=approved date=2026-07-04 by=agent`), chosen over
a YAML list-of-maps because it round-trips deterministically through pure bash
3.2; `review-required:` is a comma-scalar read directly by `fm_get`. New
`review-gate.sh` provides `required`, `cleared`, `assert-completable`,
`assert-no-downgrade`, `record`, and `backfill`. Shared parsers
(`review_entries`, `kv_get`, `verdict_rank`, `verdict_passing`,
`code_verdict_from_findings`) and exit codes 23/24 live in `lib.sh` (no
collision with the 10–22 range owned by pick-next/seam-check/resolve_plan_ref).

**Fail-closed confirmed:** absent `review-required` derives the required set
from `needs-review` and is only empty when nothing was ever flagged — the
legacy fixture (`needs-review: eng`, no `review-required`, no records) is
non-completable (exit 23). The `code` verdict maps `fail` when any
critical/high finding remains unfixed (`findings_above_threshold >
findings_fixed`), else `pass`; a missing/undeterminable findings file yields
`fail`. `assert-no-downgrade` compares token sets and per-type verdict ranks
versus `git show HEAD:<path>`, so whitespace/reordering can't fool it; a plan
absent from HEAD has no baseline → pass. Adversarial self-review fixed three
issues (a `by`-field injection vector, an awk-newline record bug, and a
`json_get` single-line fail-open). Post-agent fix: added the repo-standard
`# shellcheck source=skills/mstack-run/scripts/lib.sh` directive to
`review-gate.sh`/`review-gate-smoke.sh` (they shipped with a relative
`source=lib.sh` that broke the canonical `shellcheck scripts/*.sh` gate).

**Files changed:**

- `AGENTS.md` (modified)
- `skills/mstack-run/plan-template.md` (modified)
- `skills/mstack-run/scripts/lib.sh` (modified)
- `skills/mstack-run/scripts/review-gate.sh` (created)
- `skills/mstack-run/scripts/review-gate-smoke.sh` (created)
- `skills/mstack-run/scripts/fixtures/review-gate/*.md` (created)

**Commit:** `ad99a33` — `feat(mstack-run): fail-closed review-record format + completion-gate script`
