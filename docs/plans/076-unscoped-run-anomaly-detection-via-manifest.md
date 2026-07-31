---
id: 076
title: Unscoped-run anomaly detection via manifest
status: pending
blocked-by: []
priority: 47
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

`skills/mstack-run/SKILL.md` wraps the ENTIRE execution-manifest lifecycle in
`if [ -n "$SCOPE_IDS" ]`: creation (lines 352-364), the per-iteration update +
`manifest.sh check` anomaly pass (Step 7c2, lines 1124-1150), and goal-
completion cleanup (lines 1044-1053). `manifest.sh cmd_check` (lines 265-318)
implements four anomaly detectors — `iteration_bound`, `repeat_pick`,
`no_progress`, `path_divergence` — but the flagship UNSCOPED mode
(`/goal all pending mstack plans are done or failed`) never creates a
manifest, so it runs with zero livelock/anomaly detection: a plan picked
forever, iterations that never terminate anything, or a mid-run file rename
all go unnoticed exactly where runs are longest. Separately, `manifest.sh`
itself (328 lines) has no smoke coverage.

**Acceptance criteria**

- [ ] Unscoped runs create an execution manifest too: scope = snapshot of all
      pending plan ids at loop start (same CSV shape `cmd_create` already
      accepts, manifest.sh line 24), created at the same lifecycle point as
      the scoped branch.
- [ ] All four `manifest.sh check` anomaly conditions apply per iteration in
      unscoped mode with the SAME bail semantics as scoped: on anomaly, run
      `handoff.sh write-anomaly "$REASON"`, preserve the manifest, emit the
      `[mstack] ANOMALY:` terminal signal, stop the loop.
- [ ] Manifest cleanup on completion works unscoped (all snapshot ids
      terminal → delete), and a plan authored MID-run (not in the snapshot)
      neither trips `iteration_bound` incorrectly for prior iterations nor
      crashes `update` — the documented rule is: the snapshot is fixed at
      loop start; newly-appeared plans are outside this manifest's scope.
- [ ] Scoped behavior is byte-for-byte unchanged apart from shared prose.
- [ ] New `skills/mstack-run/scripts/manifest-smoke.sh` deterministically
      exercises all four anomaly conditions (plus create/update/delete/
      validate happy path) against temp-repo fixtures, in the style of
      `review-gate-smoke.sh`.
- [ ] Suite registered in AGENTS.md's smoke list AND the pre-commit suite
      loop — edit shipped source `skills/mstack-run/hooks/pre-commit` (suite
      list, line 62), then `cp` to `.githooks/pre-commit`.
- [ ] `manifest-smoke.sh` committed executable (`100755`);
      `script-mode-smoke.sh` covers the bit.

## Design

SKILL.md changes are prose/snippet edits, not script logic: in the "Execution
manifest" section (lines 349-365), replace the `if [ -n "$SCOPE_IDS" ]` guard
with an unconditional block that computes `MANIFEST_SCOPE` — `$SCOPE_IDS`
when set, otherwise a CSV of pending plan ids derived by scanning the plans
dir with the same awk frontmatter idiom Step 7c2 already uses (line 1132) —
and passes it to `manifest.sh create`. Step 7c2 (lines 1124-1150): drop the
outer guard, iterate `${MANIFEST_SCOPE//,/ }`, keep the existing terminal-id
derivation, `manifest.sh update`, `manifest.sh check`, and
`handoff.sh write-anomaly` flow verbatim — with ONE new pre-step that makes
the mid-run-authored-plan acceptance bullet actually hold: before the
update+check pair, compare the just-picked plan's normalized id (strip
leading zeros, same as pick-next) against the ids in `MANIFEST_SCOPE`. If
the picked id is NOT in the snapshot (a plan authored mid-run in unscoped
mode), SKIP both `manifest.sh update` and `manifest.sh check` for that
iteration and print a one-line note
(`[mstack] manifest: plan <id> outside run snapshot; not tracked`). Without
this, an out-of-snapshot iteration bumps `iteration_count` while snapshot
`terminal_ids` cannot change, so `no_progress` (manifest.sh line 301) fires
a false anomaly on a healthy run, and `iteration_bound` inflates. Skipping
keeps every detector measured strictly against snapshot-scoped iterations.
In scoped mode this pre-step is inert (the picker only picks in-scope ids),
preserving byte-for-byte scoped behavior. Cleanup block (lines 1044-1053):
drop the guard. `manifest.sh` itself likely needs NO behavior change —
`cmd_create <scope_ids_csv>` is scope-agnostic; if the implementer finds a
scoped assumption inside it, that is in scope to fix, minimally.

`manifest-smoke.sh` drives detectors without a real run: temp git repo,
`manifest.sh create 1,2`, then hand-edit the manifest JSON with `jq` (the
script already requires jq, line 267) to stage each condition —
`iteration_count > scope+1` (iteration_bound); `picked_history` ending
`["1","1"]` with `1` non-terminal (repeat_pick); bumped `iteration_count`
with `terminal_ids` unchanged (no_progress); a `path_diverged` entry for a
non-terminal id (path_divergence) — asserting `check` exits 1 with the right
reason substring, and exits 0 on a clean manifest.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/SKILL.md`: manifest create/update/check/cleanup blocks
  made scope-agnostic via `MANIFEST_SCOPE`.
- `skills/mstack-run/scripts/manifest-smoke.sh`: new suite.
- `AGENTS.md`: smoke-list registration.
- `skills/mstack-run/hooks/pre-commit` and `.githooks/pre-commit`: suite loop.
- `README.md`: only if it states manifests are scoped-only (check the
  "execution manifest" section around line 368).

**Out of scope:** changing the four anomaly thresholds or adding new anomaly
types; picker changes (054-057); making `manifest.sh` work without jq.

## Tasks

1. Edit SKILL.md: introduce `MANIFEST_SCOPE`, make creation (352-364), Step
   7c2 (1124-1150), and cleanup (1044-1053) unconditional; state the
   fixed-snapshot rule for mid-run plans.
2. Verify `manifest.sh create/update/check/delete` behave scope-agnostically;
   apply minimal fixes only if a scoped assumption surfaces.
3. Write `manifest-smoke.sh` per the Design; `chmod +x` and
   `git update-index --chmod=+x skills/mstack-run/scripts/manifest-smoke.sh`.
4. Register the suite in AGENTS.md; add to the loop in
   `skills/mstack-run/hooks/pre-commit`; `cp` to `.githooks/pre-commit`.
5. Update README's execution-manifest section if it claims scoped-only.
6. Run the new suite, all existing suites, `bash -n`, `shellcheck`.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/manifest-smoke.sh skills/mstack-run/scripts/manifest.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/manifest-smoke.sh skills/mstack-run/scripts/manifest.sh`
- [cmd] `bash skills/mstack-run/scripts/manifest-smoke.sh`
- [cmd] `git ls-files -s skills/mstack-run/scripts/manifest-smoke.sh | grep -q '^100755'`
- [assert] `grep -c "MANIFEST_SCOPE" skills/mstack-run/SKILL.md` output is >= 3
- [cmd] `grep -q "manifest-smoke" AGENTS.md && grep -q "manifest-smoke" skills/mstack-run/hooks/pre-commit && grep -q "manifest-smoke" .githooks/pre-commit`
- [cmd] `diff skills/mstack-run/hooks/pre-commit .githooks/pre-commit`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh && bash skills/mstack-run/scripts/review-gate-smoke.sh && bash skills/mstack-run/scripts/verify-lint-smoke.sh && bash skills/mstack-run/scripts/health-reach-smoke.sh && bash skills/mstack-run/scripts/wrapup-scan-smoke.sh && bash skills/mstack-run/scripts/plan-ref-smoke.sh && bash skills/mstack-run/scripts/hook-chain-smoke.sh`

## Backlog amendment (2026-07-31)

SPLIT. Ship the `manifest-smoke.sh` half ONLY: `manifest.sh` has
328 lines of anomaly-detection logic with zero test coverage, and pinning it
is a pure addition with no behavior change.

The unscoped-manifest extension is DROPPED. As specified it would make the
flagship command LESS reliable, not more: the `no_progress` detector fires
when `terminal_count == prev_terminal_count`, and terminal means only
`done`/`failed`. A plan that ends an iteration `blocked` — exactly what Step
7a does on a review-gate abort, and what plan 054 makes more visible — is not
terminal. So the first blocked plan in an unscoped run would write an anomaly
handoff and halt the whole backlog, where today the loop simply moves on.

If this is ever revived it needs an acceptance criterion that a non-terminal
`blocked` outcome does not trip `no_progress`.
