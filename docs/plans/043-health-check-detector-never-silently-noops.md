---
id: 043
title: fix health-check.sh shell detector so it finds nested scripts and never silently no-ops
status: blocked
blocked-by: []
priority:
goal:
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-14
---

## Requirements

The health gate has never run in this repository. `health-check.sh`'s `shell`
auto-detector globs `find "$ROOT" -maxdepth 3 -name '*.sh'`
(`skills/mstack-run/scripts/health-check.sh:129`), but mstack keeps its scripts
at depth 4 (`skills/mstack-run/scripts/*.sh`). The glob matches nothing, no tool
is detected, and `cmd_run` dies with `error: no health check tools detected` —
which `mstack-run` treats as a skipped gate rather than a failure. There was no
`.mstack/health-history.jsonl` in this repo at all, confirming the gate had never
produced a single score. **Every plan through 039 completed against a gate that
did nothing.**

Two distinct defects, and the second is the dangerous one:

1. **The depth bug.** `-maxdepth 3` is simply too shallow for the repo that ships
   the tool. Discovered in plan 040 and worked around by writing explicit
   `health.commands` into this repo's gitignored `.mstack/config.json` — a local
   fix that does not travel to any other consumer repo.
2. **The silent no-op.** A gate that detects zero tools reports the same outcome
   as a gate that ran and passed. That is the real hazard: it fails open and
   quiet, so an agent completing a plan cannot tell "verified" from "verified
   nothing". Any consumer repo whose scripts sit deeper than three levels
   inherits this silently.

Fixing only (1) leaves the class of bug alive for the next layout that doesn't
match a detector's assumptions. Fixing (2) is what makes the failure legible.

**Acceptance criteria:**

- [ ] The `shell` detector finds this repo's own scripts. Concretely: with no
      `health.commands` configured, `health-check.sh detect` (or the internal
      detection path) reports a `shell:` command covering
      `skills/mstack-run/scripts/*.sh` when run from this repo root.
- [ ] The no-op case is LOUD. When zero tools are detected, `health-check.sh run`
      must not present as an ordinary skip: it emits an explicit, greppable
      signal (e.g. `VERDICT:NO-TOOLS` plus a human line naming what it looked for
      and where), distinct from both PASS and FAIL.
- [ ] `mstack-run` surfaces that signal instead of swallowing it. A plan must not
      be able to complete while reporting a health gate that never ran — at
      minimum the no-tools condition is printed prominently in the iteration's
      output and recorded in the checkpoint, so "the gate is dead" is visible on
      the first run rather than after nine plans.
- [ ] Decide and document the policy for zero-detected-tools: does it BLOCK
      completion (fail closed, consistent with the 034-039 enforcement family) or
      WARN loudly (fail open, but legible)? This is the plan's central judgment
      call and belongs to eng review, not to the implementing worker. Whichever
      is chosen, the rationale is written into AGENTS.md.
- [ ] The fix is general, not a magic number. Raising `-maxdepth 3` to `4` makes
      THIS repo work and leaves the next repo broken. Prefer a detector that does
      not depend on a hardcoded depth (e.g. `git ls-files '*.sh'` when in a git
      repo, which is both layout-independent and automatically respects
      gitignore), with a bounded-depth `find` only as the non-git fallback.
- [ ] No regression for repos that legitimately have no shell scripts: a JS/TS
      repo with zero `.sh` files must still detect its own tools and must not
      start reporting a scary no-tools state because of this change.
- [ ] `bash -n` and `shellcheck` pass on the canonical
      `shellcheck skills/mstack-run/scripts/*.sh` gate.

## Design

**Files expected to change:**

- `skills/mstack-run/scripts/health-check.sh`: replace the depth-limited `shell`
  detector with a layout-independent one; add the explicit no-tools verdict path
  in `cmd_run`.
- `skills/mstack-run/SKILL.md`: Step 5 (health gate) handles the no-tools signal
  per the policy chosen at eng review.
- `AGENTS.md`: document the zero-tools policy and why.

Notes and edge cases:

- The `head -20` cap on the detected file list is a separate latent papercut: a
  repo with more than 20 shell scripts silently lints only the first 20. Worth
  addressing in the same pass, or explicitly declaring out of scope.
- `git ls-files` returns paths relative to the repo root; `find` returns them
  relative to `$ROOT`. Do not mix the two conventions when building the command
  string.
- This repo currently MASKS the bug via explicit `health.commands` in its
  gitignored `.mstack/config.json`. Any verification of the detector must
  therefore bypass or temporarily neutralize that config — otherwise the
  detector path is never exercised and the fix cannot be proven. This is the
  single most likely way for a worker to produce a false pass on this plan.
- Do not "fix" this by writing a `health.commands` block into a committed config
  or into AGENTS.md. That papers over the detector for one repo and leaves the
  silent-no-op class intact everywhere else, which is the whole point of the plan.

Testing approach: unit-only

**Out of scope:** the health WEIGHTS and scoring math; adding new tool categories;
the `-maxdepth 1` globs in the other detectors (typecheck/lint/e2e legitimately
expect root-level config files); retrofitting health scores onto the already-
archived plans 031-039.

## Tasks

1. Reproduce the no-op deterministically: in a scratch fixture (or with this
   repo's `.mstack/config.json` health.commands temporarily neutralized), confirm
   `health-check.sh run` reports `no health check tools detected`.
2. Replace the `shell` detector with a layout-independent discovery (`git ls-files
   '*.sh'` in a git repo; bounded `find` as the non-git fallback), preserving the
   existing `.mstack/` and `node_modules/` exclusions.
3. Add the explicit no-tools verdict to `cmd_run` (distinct from PASS and FAIL,
   greppable, and naming what was searched).
4. Wire `mstack-run` Step 5 to surface that verdict per the eng-review policy
   (block vs loud warn), and record it in the checkpoint.
5. Document the policy and rationale in AGENTS.md.
6. Verify against BOTH a shell-script repo (this one, detector path exercised with
   the local config bypassed) and a no-shell-script fixture (no false no-tools
   alarm).

## Verification

Checks:
- [cmd] bash -n skills/mstack-run/scripts/health-check.sh
- [cmd] shellcheck skills/mstack-run/scripts/*.sh
- [assert] cd "$(mktemp -d)" && git init -q . && mkdir -p a/b/c/d && printf '#!/bin/bash\necho hi\n' > a/b/c/d/deep.sh && git add -A && bash "$OLDPWD/skills/mstack-run/scripts/health-check.sh" detect 2>&1 | grep -q 'shell:' — a script nested 4+ levels deep IS detected (the exact case that was broken)
- [assert] cd "$(mktemp -d)" && git init -q . && bash "$OLDPWD/skills/mstack-run/scripts/health-check.sh" run 2>&1 | grep -qE 'NO-TOOLS|no health check tools' — a repo with zero tools produces the LOUD distinct signal, not a silent skip
- [assert] bash skills/mstack-run/scripts/health-check.sh run 2>&1 | grep -q 'VERDICT:PASS' — this repo still scores PASS after the change
- [manual] Confirm the zero-tools policy (block vs warn) recorded in AGENTS.md matches what eng review decided.
