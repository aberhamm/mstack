# mstack Agent Guide

This repository is the source for MStack, a plan-driven autonomous workflow
framework distributed as agent skills.

## Canonical Instructions

- Keep shared project instructions in `AGENTS.md`.
- Keep `CLAUDE.md` as a thin compatibility shim that imports this file with
  `@AGENTS.md`.
- Do not duplicate long-lived workflow rules across both files.
- When adding agent-specific notes, keep the shared rule here and put only the
  agent-specific exception in that agent's file.

## Repository Shape

- `skills/mstack-*` contains the skill source directories.
- `skills/mstack-run/scripts/` contains deterministic shell helpers used by
  multiple skills.
- `skills/mstack-run/references/` contains long-form references loaded on
  demand by `mstack-run`.
- `.codex/agents/` contains Codex custom agent adapters for MStack worker and
  reviewer subagents.
- `docs/plans/` contains this repo's implementation plans; archived completed
  plans live under `docs/plans/archive/`.
- `setup` links MStack skills into the parent skill directory for legacy
  Claude/Skillshare installs.

## Skill Routing

When a user request matches an MStack workflow, use the matching skill:

- "create a plan for...", "plan out...", "break this down" ->
  `mstack-plan-multi`
- "validate plans", "check the backlog", "are plans ready" ->
  `mstack-plan-doctor`
- "review the backlog", "reprioritize", "reorder plans", "groom",
  "triage" -> `mstack-backlog`
- "run the plans", "execute the backlog", "start the loop" -> `mstack-run`
- "where are we", "what's next", "backlog status" -> `mstack-status`
- "configure mstack", "change health weights" -> `mstack-config`
- "show learnings", "what patterns" -> `mstack-learned-patterns`
- "stash this", "save for later", "come back to this", "not ready to plan" ->
  `mstack-stash`
- "handoff", "save session state" -> `mstack-handoff`
- "resume from handoff", "load handoff", "pick up where I left off" ->
  `mstack-handoff` in resume mode

## Review Records and the Completion Gate

A plan flagged for review must not be markable done/cleared until that review
has actually been performed and RECORDED. The deterministic mechanism lives in
`skills/mstack-run/scripts/review-gate.sh` (plan 034). It is fail-closed: any
ambiguity resolves to "required" / "not completable", never open.

**End-to-end invariant:** authoring declares required reviews
(`review-required`, stamped once and never shrunk) → only the named review
skills record verdicts (`review-gate.sh record`, plan 035) → completion
refuses to proceed until every required verdict is recorded passing
(`assert-completable`, plan 036) → a recorded `reviewed`/`reviews`/
`review-required` state can never be silently downgraded
(`assert-no-downgrade`, plans 034/036). Each link is enforced by a distinct
mechanism; breaking any one link breaks the invariant.

`mstack-run` Step 7a runs `assert-completable "$NEXT"` as the very first
action of its success path — before the `status: done` write, the archive,
and the `mstack/plan-${PLAN_ID}-done` tag — and aborts the whole sequence on
a nonzero exit: it sets `status: blocked` and `needs-review:` to the
still-open type(s) (re-using `pick-next.sh`'s existing skip-on-non-`none`
mechanism, not a new one, so the picker doesn't loop on the same plan) and
commits only the plan file. `needs-review` can carry `code` here — an
unresolved code-review finding has no automated remediation path the way
eng/design/ceo do via `mstack-plan-doctor` Step 5, so it needs a human to
re-run `mstack-code-review` or fix and re-record. It also runs
`assert-no-downgrade "$NEXT"` before writing `reviewed`/`review-required`/
`reviews`; at Step 7a this is normally inert (`reviewed: false` is a fresh
add on a plan's first completion, not a downgrade) but the same call is what
refuses a later out-of-band `reviewed: true → false` edit. Fixture/smoke
plans (e.g. `bin/mstack-codex-smoke`'s `001-create-hello`) are authored with
`needs-review: none` and no `review-required`, so they have an empty
required set and the gate is naturally a no-op for them — no path-based
exemption exists or is needed. `mstack-status` and `mstack-plan-doctor`
independently re-check `review-gate.sh` per pending/blocked plan with a
declared requirement and surface an open gate as a blocked/gate-open state,
so it's visible before a completion attempt, not just at completion time.

**This is anti-forgetfulness, not anti-adversary.** Step 7a only stops an
agent that runs the honest completion path. An agent that skips Step 7a and
hand-writes `status: done` plus `git tag` bypasses all of the above
entirely — wiring the assertion into Step 7a does not, by itself, make
completion unbypassable. Plan 038 (a git hook that rejects such a
commit/tag regardless of how it was produced, plus a retroactive audit) is
the non-optional barrier that actually closes the "proceed outside the
picker" hole; treat 034/035/036 as the honest-path layer and 038 as the
enforcement layer.

Three distinct frontmatter fields, do not conflate them:

- `needs-review:` — MUTABLE remaining-work tracker (`none | eng | design | ceo`
  and comma combinations). The picker skips plans whose value is non-`none`;
  reviewers flip it as work completes.
- `review-required:` — IMMUTABLE declared gate list (subset of
  `eng,design,ceo,code`), stamped once at authoring and NEVER cleared or shrunk.
  It lists the review types that must be recorded passing before completion.
- `reviews:` — the SINGLE SOURCE OF TRUTH the gate trusts, a block of compact
  one-line records (values never contain spaces):

  ```
  reviews:
    - type=eng verdict=approved date=2026-07-04 by=agent
    - type=code verdict=pass date=2026-07-04 by=mstack-code-review
  ```

  `type ∈ eng|design|ceo|code`; `verdict ∈ approved|changes-requested|pass|fail`.
  eng/design/ceo clear the gate with `approved`; `code` clears with `pass`. A
  `code` review records `fail` when any critical/high finding remains unfixed
  after review (mapped from the `findings_*` counts by
  `code_verdict_from_findings` in `lib.sh`), else `pass`. An absent `code`
  record is an OPEN gate. The `.mstack/reviews/plan-<id>.json` file is a derived,
  NON-authoritative cache; the gate never trusts it.

Fail-closed rules that must not be softened:

- ABSENT `review-required` ≠ empty required set. When the field is absent the
  gate derives the required set from `needs-review` (any non-`none` tag). Legacy
  plans without the field are non-completable until backfilled
  (`review-gate.sh backfill <plan> | --all`).
- `assert-completable <plan>` exits 0 only if every required review has a passing
  record; missing/garbled records are non-completable.
- `assert-no-downgrade <plan>` diffs the working tree against committed `HEAD`
  and fails on `reviewed: true→false`, a removed/weakened `reviews:` entry, or a
  shrunk/emptied `review-required`. A plan not yet in `HEAD` has no baseline, so
  it passes (nothing to downgrade from).

`review-gate.sh` exit codes: `23` = not completable, `24` = downgrade detected
(defined in `lib.sh`; do not collide with pick-next 10-19, seam-check 20,
resolve_plan_ref 21-22).

**Only the named review skills write review records or clear gates** (plan
035). `plan-eng-review` / `plan-design-review` / `plan-ceo-review`
(orchestrated by `mstack-plan-doctor`'s Step 5) record `eng`/`design`/`ceo`
verdicts; `mstack-code-review` records the `code` verdict. No other actor —
not a worker/implementing agent, not `mstack-run` itself — may invoke
`review-gate.sh record`, edit `review-required` or `reviews` to clear or
weaken a gate, mark a needs-review plan `done`, or run a needs-review plan
outside the picker. The observed anti-pattern this forbids explicitly: an
agent offering to self-clear `needs-review: eng`, or to "say go and I'll
proceed outside the picker" — both are forbidden; the remediation is always
to run the named review skill. Adding or raising a gate (setting
`needs-review: eng` on an incomplete spec or stale seam) stays allowed for
any actor; only clearing/weakening one is restricted.

## Plan Citation Convention

No agent-facing output emits a bare plan ID. Every citation of a plan —
in a printed progress line, a status dashboard, a blocked/crash message,
a learnings header, or a table row — renders `NNN: Title` (the plan's
zero-padded id, a colon, its frontmatter title). Use the `plan_label`
helper in `skills/mstack-run/scripts/lib.sh` (or an equivalent
already-known id/title pair) to build the string; never print a plan id
on its own and make the reader open the repo to learn what it is. When a
message lists several dependency ids (e.g. "blocked by 026"), render each
one as `026: Title`.

Machine identifiers are exempt and MUST stay bare — do not "helpfully"
rewrite them: git commit message subjects and bodies, the
`mstack/plan-${PLAN_ID}-done` git tag, machine-readable JSON fields
(e.g. `plan_id` in checkpoint or `.mstack/reviews/plan-*.json`), and
evidence path names (e.g. `.mstack/evidence/plan-032/`). These are parsed
by scripts or `git`, not read as prose; adding a title would break the
parser or the identifier's shape.

## Compatibility Rules

- Treat `AGENTS.md` as the primary project guidance file for Codex.
- Treat `CLAUDE.md` as a compatibility import file for Claude Code.
- When skills need to read project guidance, support both `AGENTS.md` and
  `CLAUDE.md`.
- When skills need to locate installed MStack assets, prefer path resolution
  that works across Skillshare, Codex, and Claude:
  `~/.config/skillshare/skills`, `~/.agents/skills`, `~/.codex/skills`, then
  `~/.claude/skills`.
- Prefer agent-neutral wording in shared MStack instructions. Call out
  Claude-only or Codex-only behavior explicitly when the behavior differs.

## Development Commands

Run focused checks after changing shell helpers:

```bash
bash -n skills/mstack-run/scripts/*.sh bin/mstack-update-check setup
shellcheck skills/mstack-run/scripts/*.sh bin/mstack-update-check setup
```

Useful smoke checks:

```bash
bash skills/mstack-run/scripts/config.sh show
bash skills/mstack-run/scripts/status.sh
bash skills/mstack-run/scripts/pick-next.sh
bin/mstack-codex-smoke
```

`pick-next.sh` exits with code `10` when all plans are done; that is expected
for an empty backlog.

## Editing Expectations

- Keep changes scoped to the relevant skill, script, or reference.
- Do not rewrite archived plans unless the task is explicitly archival cleanup.
- Do not revert unrelated local changes. This repo is often dirty during
  active MStack work.
- Use deterministic shell scripts for behavior that should survive across
  agents; use skill prose for workflow judgment.
