---
id: 032
title: Never emit a bare plan ID — cite every plan as "ID: Title"
status: done
blocked-by: [031]
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

In real fleet use, mstack skills and agents cite plans by bare number ("plan
029", "running 067-073", SKIPPED lines, blocked messages). The user then has to
open the repo to find out what that plan *is*. Every agent-facing citation of a
plan should carry its title so no lookup is ever required.

Most display paths already pair ID + title (`status.sh`, backlog table,
plan-doctor report rows). The gaps — bare-ID-only surfaces — are the target:

- `references/progress-format.md`: the `Plan N/M: <title> (plan <id>)` and
  `SKIPPED: blocked by failed plan <id>` lines and the final tally.
- `mstack-run/SKILL.md` prose: crash-resume message (`:142`), blocked messages
  citing `${PLAN_ID}` + doctor command (`:452`, `:495`), completion line
  (`:884`).
- `mstack-checkpoint/SKILL.md` crash message (`:138`).
- `mstack-learned-patterns/SKILL.md` header (`:118`) and `mstack-run` mirror
  (`:523`).
- `mstack-backlog` table and any prose that cites `blocked-by` dependency IDs.

**Acceptance criteria:**

- [ ] A documented convention exists (in `AGENTS.md`): *no agent-facing output
      emits a bare plan ID; render `ID: Title` via `plan_label`.* Machine-only
      identifiers are explicitly exempted (see Out of scope).
- [ ] `status.sh` renders its "Next ready", recent-completions, and plan-detail
      lines through `plan_label` (or its title lookup), replacing hand-rolled
      `${id} ... ${title}` formatting.
- [ ] `references/progress-format.md` line specs include the title on the
      SKIPPED line and anywhere only `(plan <id>)` appeared; the worker is
      instructed to build them via `plan_label`.
- [ ] The prose citations listed above render `NNN: Title`, not a bare number.
- [ ] Where a message lists dependency IDs (e.g. "blocked by 026"), it renders
      `026: Title` for each.
- [ ] Skills that already pair ID + title are left correct (no regressions); the
      pass just fills the gaps.

## Design

Scripts call the `plan_label`/`plan_title` helpers from plan 031. Prose skills
get an explicit rule plus a worked example so an agent writing a status line
knows to resolve the title. The convention paragraph in `AGENTS.md` is the
canonical statement; individual skills reference it.

**Performance:** `plan_label` scans plans+archive per call; `status.sh` and
`mstack-backlog` render in loops, so calling it per row is O(n²) over the
backlog. Build the id→label map once per invocation (single pass) and look up
from it, rather than resolving each row independently.

**Files expected to change:**

- `skills/mstack-run/scripts/status.sh`: route display lines through
  `plan_label`.
- `skills/mstack-run/references/progress-format.md`: update line specs.
- `skills/mstack-run/SKILL.md`: crash-resume, blocked, completion prose.
- `skills/mstack-checkpoint/SKILL.md`, `skills/mstack-learned-patterns/SKILL.md`,
  `skills/mstack-backlog/SKILL.md`, `skills/mstack-plan-doctor/SKILL.md` (SEAM
  and blocked citations).
- `AGENTS.md`: add the "always cite ID: Title" convention.

**Out of scope (stay bare — these are machine identifiers, not prose):**

- Git commit messages and the `mstack/plan-${PLAN_ID}-done` tag.
- Machine-readable JSON fields (`plan_id` in checkpoint and
  `.mstack/reviews/plan-*.json`, evidence path names). Changing these would
  break parsers; they are not user-facing prose.

State this exemption explicitly so a later agent does not "helpfully" rewrite
tag/commit/JSON identifiers.

## Tasks

1. Add the convention paragraph to `AGENTS.md`.
2. Update `status.sh` display lines to use `plan_label`.
3. Update `progress-format.md` line specs (SKIPPED + any `(plan <id>)`).
4. Update the prose citations in `mstack-run`, `mstack-checkpoint`,
   `mstack-learned-patterns`, `mstack-backlog`, `mstack-plan-doctor`.
5. Render dependency-ID lists as `ID: Title`.

## Verification

- `[cmd]` `bash -n skills/mstack-run/scripts/status.sh`
- `[cmd]` `shellcheck skills/mstack-run/scripts/status.sh`
- `[assert]` `bash skills/mstack-run/scripts/status.sh` output contains a
  `NNN: <title>` pairing for the next-ready plan (assert the colon-title form,
  not a bare number).
- `[cmd]` grep guard, scoped to be falsifiable: over **only the specific edited
  prose lines** (the enumerated citation surfaces — SKIPPED line, blocked/crash
  messages, learned-patterns header), assert each now matches the `NNN: <title>`
  form. This is an allowlist of known lines, not a repo-wide "no bare number"
  scan — bare numbers legitimately appear in exit codes, line refs, commit
  examples, and the exempt `mstack/plan-*` tags / `plan_id` JSON, which must NOT
  be flagged.

## Implementation Notes

Added the plan-citation convention to `AGENTS.md` (render `NNN: Title`, with
explicit machine-identifier exemptions: git commit subjects/bodies, the
`mstack/plan-*-done` tag, JSON `plan_id` fields, evidence path names). Added a
`format_plan_label()` helper in `status.sh` that builds the label from the
id/title already fetched in the single backlog pass — avoiding the O(n²) trap
of calling `lib.sh`'s `plan_label` (which rescans plans+archive) per row —
and routed Next-ready, recent-completions, plan-detail, blocked-by, and the
REVIEWS line through it. Filled the bare-ID prose surfaces across
`progress-format.md` and the `mstack-run`, `mstack-checkpoint`,
`mstack-learned-patterns`, `mstack-backlog`, `mstack-plan-doctor` SKILL.md
files, leaving exempt machine identifiers bare.

Review caught two gaps beyond the plan's enumerated list (both fixed):
`status.sh`'s REVIEWS section still printed a bare `plan-$plan_id`, and
`mstack-status/SKILL.md`'s documented example output had gone stale against
the new format. Verification note: `shellcheck status.sh` in isolation emits
info-level SC1091 (can't follow the sourced `lib.sh`); the canonical
AGENTS.md check runs the whole script glob (lib.sh in the input set) and
passes clean — this is pre-existing, not a regression.

**Files changed:**

- `AGENTS.md` (modified)
- `skills/mstack-run/scripts/status.sh` (modified)
- `skills/mstack-run/references/progress-format.md` (modified)
- `skills/mstack-run/SKILL.md` (modified)
- `skills/mstack-checkpoint/SKILL.md` (modified)
- `skills/mstack-learned-patterns/SKILL.md` (modified)
- `skills/mstack-backlog/SKILL.md` (modified)
- `skills/mstack-plan-doctor/SKILL.md` (modified)
- `skills/mstack-status/SKILL.md` (modified)

**Commit:** `b225b89` — `feat(mstack): cite every plan as "ID: Title", never a bare number`
