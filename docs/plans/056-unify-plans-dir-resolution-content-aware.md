---
id: 056
title: Unify plans-dir resolution content-aware with PLANS_DIR env
status: pending
blocked-by: [055]
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

Three scripts each resolve the plans directory independently, and they
disagree:

- `lib.sh` `plans_dir()` (lines 232-241) prefers `docs/plans` purely on
  directory EXISTENCE and ignores the `PLANS_DIR` env var entirely.
- `pick-next.sh` (lines 27-28) honors `PLANS_DIR` env, then falls back on
  existence.
- `init.sh` `cmd_bootstrap` (lines 21-31) carries a third private copy of the
  existence check.

Reproduced in the audit: an EMPTY `docs/plans/` shadows a populated `plans/`,
so the picker exits 10 "all plans done" and `status.sh` shows 0 pending while
real plans sit unread. Separately, because only `pick-next.sh` reads the env
var, `PLANS_DIR=x pick-next.sh` picks a plan that `review-gate.sh` (which
resolves through lib.sh `plans_dir()`, e.g. `resolve_plan_ref` at lib.sh line
388) cannot see — the picker and the completion gate silently operate on
different directories.

**Acceptance criteria**

- [ ] `lib.sh` `plans_dir()` is the single resolver: it (1) honors a
      `PLANS_DIR` env override first, (2) otherwise prefers the directory
      that actually CONTAINS plan files (a `*.md` with a frontmatter
      `status:` line), (3) warns loudly on stderr when BOTH `docs/plans` and
      `plans` contain plan files (and picks `docs/plans`).
- [ ] Repro fixed: temp repo with empty `docs/plans/` and a pending plan in
      `plans/` — `pick-next.sh` picks the plan (exit 0), `status.sh` counts
      it.
- [ ] `PLANS_DIR=<dir>` produces the SAME resolution in `pick-next.sh` and in
      every lib.sh consumer (`resolve_plan_ref`, `archive_dir`,
      `review-gate.sh`): one temp-repo check demonstrates picker and
      `review-gate.sh` agree under the override.
- [ ] `init.sh` delegates detection to `plans_dir()` and only keeps its
      create-`docs/plans`-when-neither-exists behavior.
- [ ] Existing behavior preserved when only one populated dir exists, and
      when both exist but only `docs/plans` has plan files (this repo's own
      layout): `docs/plans` wins with no warning.

## Design

Rewrite `plans_dir()` in `lib.sh`:

1. If `PLANS_DIR` is set: echo it if it is a directory; else print
   `mstack: PLANS_DIR='<value>' is not a directory` to stderr and return 2
   (an explicit override pointing nowhere is an error, not a silent
   fallback — fail closed, consistent with repo doctrine). Return 1 stays
   reserved for "nothing resolvable" in step 3, so callers can tell a bad
   override (2, hard error) apart from a repo with no plans dir (1,
   legitimate all-done).
2. Define a tiny predicate `has_plan_files <dir>`: any `-maxdepth 1` `*.md`
   (excluding `README.md`) whose first frontmatter block contains `^status:`
   (reuse the same lenient awk shape as `fm_get`; a `head -c` bounded grep is
   acceptable). Cheap enough for a helper called several times per run.
3. Prefer `docs/plans` if it has plan files; else `plans` if it has plan
   files; if both have plan files, warn on stderr
   (`mstack: both docs/plans and plans contain plan files; using docs/plans`)
   and use `docs/plans`; if neither has plan files, fall back to today's pure
   existence order (`docs/plans` then `plans`) so freshly-bootstrapped empty
   repos keep working; else return 1.

`pick-next.sh` lines 27-33 collapse to a resolution that distinguishes the
two failure codes (do NOT fold rc=2 into exit 10 — a bad explicit override
must never read as "all plans done" success):

```bash
PLANS_DIR="$(plans_dir)" && _pd_rc=0 || _pd_rc=$?
if [ "$_pd_rc" -eq 2 ]; then exit 1; fi   # bad PLANS_DIR override; stderr already printed
if [ "$_pd_rc" -ne 0 ]; then echo "all plans done" >&2; exit "$EXIT_ALL_DONE"; fi
```

(Capture rc via `&& _pd_rc=0 || _pd_rc=$?`, not `if ! VAR=$(...)` — after a
negated test `$?` is the inverted status. lib.sh is already sourced at line
21; the env override now flows through `plans_dir()` itself.) `init.sh` replaces its lines 21-31 detection branch
with a `plans_dir` call guarded so that when resolution fails it creates
`$ROOT/docs/plans` exactly as today. The stderr warning must never go to
stdout — pick-next.sh's stdout is a machine-read plan path.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/lib.sh`: rewritten `plans_dir()` +
  `has_plan_files` predicate.
- `skills/mstack-run/scripts/pick-next.sh`: delegate to `plans_dir()`.
- `skills/mstack-run/scripts/init.sh`: delegate detection, keep creation.

**Out of scope:** the `normalize_id` duplication noted at lib.sh ~253;
teaching `status.sh`/`manifest.sh` anything new (they already source lib.sh
or will inherit via `plans_dir()`); adding a config-file plans-dir setting
(`.mstack/` is gitignored — per the plan-043 doctrine, invisible per-checkout
state must not steer resolution).

## Tasks

1. Add `has_plan_files` and rewrite `plans_dir()` in `lib.sh` per the Design
   ordering (env → content → existence → fail).
2. Collapse `pick-next.sh` lines 27-33 to delegate to `plans_dir()`.
3. Replace `init.sh` cmd_bootstrap detection (lines 21-31) with a
   `plans_dir()` call plus the existing create-on-absence branch.
4. Grep the scripts dir for any other private `docs/plans` resolution
   (`grep -rn 'docs/plans' skills/mstack-run/scripts/`) and delegate any
   found stragglers.
5. Run `bash -n`, `shellcheck`, all smoke suites, and the temp-repo repros.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/lib.sh skills/mstack-run/scripts/pick-next.sh skills/mstack-run/scripts/init.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/lib.sh skills/mstack-run/scripts/pick-next.sh skills/mstack-run/scripts/init.sh`
- [cmd] `d=$(mktemp -d) && cd "$d" && git init -q . && mkdir -p docs/plans plans && printf -- '---\nid: 001\ntitle: a\nstatus: pending\nblocked-by: []\nneeds-review: none\n---\n' > plans/001-a.md && out=$(bash /Users/matthew/dev/mstack/skills/mstack-run/scripts/pick-next.sh) && printf '%s' "$out" | grep -q 'plans/001-a.md'`
- [cmd] `d=$(mktemp -d) && mkdir -p "$d/mydir" && printf -- '---\nid: 001\ntitle: a\nstatus: pending\nblocked-by: []\nneeds-review: none\n---\n' > "$d/mydir/001-a.md" && cd "$d" && git init -q . && PLANS_DIR="$d/mydir" bash /Users/matthew/dev/mstack/skills/mstack-run/scripts/pick-next.sh | grep -q 'mydir/001-a.md'`
- [assert] with both dirs populated in a temp repo, stderr contains `both docs/plans and plans`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh && bash skills/mstack-run/scripts/review-gate-smoke.sh && bash skills/mstack-run/scripts/verify-lint-smoke.sh && bash skills/mstack-run/scripts/health-reach-smoke.sh && bash skills/mstack-run/scripts/wrapup-scan-smoke.sh && bash skills/mstack-run/scripts/plan-ref-smoke.sh && bash skills/mstack-run/scripts/hook-chain-smoke.sh`
