---
id: 068
title: Small-script correctness sweep with smoke coverage
status: pending
blocked-by: []
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

An audit of the small helpers under `skills/mstack-run/scripts/` reproduced a
cluster of latent bugs: crashes under `set -euo pipefail` on ordinary inputs,
a false-green substring match in the very script whose job is preventing false
greens, a hardcoded exit-code constant outside `lib.sh`'s central table, a
gate self-block hazard, an unsafe word-split, and triplicated helper
definitions. None currently has smoke coverage, so each could regress
silently. This plan fixes them and adds a smoke suite that pins the fixed
behaviors, wired into the same CI surface as the existing suites.

**Acceptance criteria**

- [ ] `status.sh` line 172: `grep -o '[0-9]\{4\}-...' | head -1` over
      `$recent_done` no longer aborts the whole dashboard (exit 1, zero
      output) when a `done` plan lacks a `completed:` date — guarded with
      `|| true` so pipefail cannot kill the script.
- [ ] `status.sh` line 166: `git branch --show-current 2>/dev/null || echo unknown`
      prints a blank Branch on detached HEAD because the command exits 0 with
      empty output, so `|| echo unknown` never fires — replaced with an
      explicit emptiness check that substitutes `unknown`.
- [ ] `checkpoint.sh` line 98: `[ "$rcount" -gt 0 ] && echo ...` as the last
      statement of `cmd_prune`'s review-dir branch makes `prune` exit 1 on the
      normal zero-pruned path — converted to `if/fi` with an explicit
      `return 0`.
- [ ] `health-reach.sh` line 155: `grep -qF -- "$f"` substring-matches, so a
      declared `tests/test_x.py` matches a collected `other/tests/test_x.py`
      and reports a false REACHABLE — replaced with `grep -qxF` (whole-line).
- [ ] `health-reach.sh` line 97: `sed -E "s|^$root/||"` treats `$root` as a
      regex; a repo path containing sed/regex metacharacters breaks the strip —
      replaced with a literal-prefix strip (shell `${var#"$root"/}` per line
      or equivalent non-regex mechanism).
- [ ] `seam-check.sh` line 24 hardcodes `EXIT_STALE_SEAM=20` outside `lib.sh`'s
      central exit-code table (which today jumps 15 → 21) — the constant moves
      to `lib.sh` and `seam-check.sh` uses the sourced value.
- [ ] `review-gate.sh` `cmd_assert_work_committed` (~line 363): if `.mstack/`
      is ever not gitignored, its own `.mstack/pre-dirty-<id>.txt` baseline
      file reads as stray dirt and permanently blocks every completion —
      ONLY the gate's own baseline artifacts (`.mstack/pre-dirty-*.txt`) are
      excluded from the stray set: plan 039's invariant is all
      plan-attributable dirt minus baseline, and a consumer repo that
      deliberately tracks other `.mstack` paths must still have
      plan-attributable changes there flagged.
- [ ] `lib.sh` `kv_get` (lines 513-521): `for tok in $kv` word-splits with
      globbing on, so a token like `verdict=a*` pathname-expands — guarded
      with a local `set -f` / restore.
- [ ] Dedup: `normalize_id` exists at `lib.sh:255`, `pick-next.sh:48`, and
      `status.sh:11`; `fm_get` at `lib.sh:218` and `pick-next.sh:146` (which
      shadows it despite sourcing lib.sh). The lib.sh copies stay; the
      `status.sh` shadows are deleted. See Out of scope for pick-next.sh.
- [ ] New `misc-scripts-smoke.sh` covers: status.sh no-completed-date crash
      case, checkpoint prune zero-pruned exit code, seam-check constant
      sourced from lib.sh, health-reach exact-match (declared file vs
      same-suffix sibling).
- [ ] `misc-scripts-smoke.sh` AND the existing `handoff.sh self-test` (which
      passes today but is invisible to CI) are registered in AGENTS.md's smoke
      list (~lines 491-497) and in the pre-commit hook loop
      (`skills/mstack-run/hooks/pre-commit:62` + the `.githooks/pre-commit`
      copy).

## Design

Each fix is a minimal, local edit; no behavior changes beyond the bug. One
structural note: `seam-check.sh` does NOT currently source `lib.sh` (it only
"mirrors lib.sh fallback behavior", line 38) — the constant move therefore
requires adding the standard `SCRIPT_DIR` + `source "$SCRIPT_DIR/lib.sh"`
preamble used by checkpoint.sh/status.sh; lib.sh is side-effect-free to
source. The new smoke suite follows the existing pattern (self-contained, deterministic,
seconds to run, exits nonzero on first failure) using temp fixtures under
`mktemp -d`. The hook edit goes to the SHIPPED SOURCE
`skills/mstack-run/hooks/pre-commit` first, then is copied to
`.githooks/pre-commit` (per AGENTS.md — an edit made only in `.githooks/` is
clobbered by `mstack-init`/`setup`). The new script must be committed
executable: `chmod +x` + `git update-index --chmod=+x`.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/status.sh`: pipefail guard, branch check, dedup
- `skills/mstack-run/scripts/checkpoint.sh`: prune return code
- `skills/mstack-run/scripts/health-reach.sh`: exact match + literal strip
- `skills/mstack-run/scripts/seam-check.sh`: use lib.sh constant
- `skills/mstack-run/scripts/lib.sh`: add `EXIT_STALE_SEAM=20`, `kv_get` set -f
- `skills/mstack-run/scripts/review-gate.sh`: exclude `.mstack/pre-dirty-*.txt`
  from stray set
- `skills/mstack-run/scripts/misc-scripts-smoke.sh`: NEW smoke suite
- `skills/mstack-run/hooks/pre-commit` + `.githooks/pre-commit`: register suites
- `AGENTS.md`: smoke list additions

**Out of scope:** `learnings.sh` — existing plan 044 deletes that whole file;
fixing its bugs first is wasted work. The `pick-next.sh` copies of
`normalize_id`/`fm_get` — plans 054-056 also touch pick-next.sh; this plan's
dedup is scoped to status.sh only, noting the pick-next dedup may already be
done by the time this runs (if not, leave a TODO comment, don't edit).

## Tasks

1. Apply the six single-file fixes (status.sh x2, checkpoint.sh,
   health-reach.sh x2, seam-check.sh + lib.sh constant move).
2. Add the `kv_get` glob guard in lib.sh and the `.mstack/pre-dirty-*.txt`
   baseline exclusion in review-gate.sh `cmd_assert_work_committed`.
3. Delete `status.sh`'s local `normalize_id` (and any other lib.sh shadow in
   status.sh), relying on the sourced lib.sh copy.
4. Write `misc-scripts-smoke.sh` pinning the four fixed behaviors; chmod +x
   and `git update-index --chmod=+x`.
5. Register `misc-scripts-smoke` and `handoff.sh self-test` in the hook source
   loop, copy to `.githooks/pre-commit`, and update AGENTS.md's smoke list.
6. Run all smoke suites plus `bash -n` and `shellcheck` over changed scripts.

## Verification

Checks:

- [cmd] `bash skills/mstack-run/scripts/misc-scripts-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/handoff.sh self-test`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/health-reach-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/plan-ref-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
- [cmd] `grep -q 'EXIT_STALE_SEAM=20' skills/mstack-run/scripts/lib.sh`
- [cmd] `bash skills/mstack-run/scripts/verify-lint-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/wrapup-scan-smoke.sh`
- [cmd] `grep -q 'misc-scripts-smoke' skills/mstack-run/hooks/pre-commit && grep -q 'misc-scripts-smoke' .githooks/pre-commit && grep -q 'misc-scripts-smoke' AGENTS.md`
- [cmd] `! grep -n 'normalize_id()' skills/mstack-run/scripts/status.sh`
- [cmd] `bash -n skills/mstack-run/scripts/*.sh`
