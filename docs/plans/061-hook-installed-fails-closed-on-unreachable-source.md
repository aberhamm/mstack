---
id: 061
title: make assert-hook-installed fail closed on an unreachable source and diagnose a foreign hooksPath
status: pending
blocked-by: [060]
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

Confirmed: in `cmd_assert_hook_installed` (review-gate.sh lines 725-755), line
728 builds `src="$(_hooks_src_dir 2>/dev/null || true)/hooks"` — when
`_hooks_src_dir` fails, `src` is the nonsense path `/hooks`, the
`[ -f "$src/$hook" ]` guard on the staleness `cmp` (lines 748-751) is false,
and the compare is SILENTLY SKIPPED. A gutted `exit 0` hook is then certified
"current" (exit 0) exactly when the shipped source is unreadable. This is the
plan-045 "a fail-safe default hides a dead feature" pattern inside the
enforcement guard itself — the degraded run is indistinguishable from a
verified one.

Separately: when `core.hooksPath` points at a FOREIGN hooks dir (e.g. a
user-global `~/.config/git/hooks` containing its own pre-commit), today's
message says the hook "is stale (differs from the shipped source)". That is a
misdiagnosis — the operator's problem is that mstack's hooks are not installed
at all, and the remediation is different (run mstack-init, which also captures
`mstack.priorHooksPath` for chaining) from refreshing a stale copy.

**Acceptance criteria**

- [ ] The check ANNOUNCES its mode on every run: the resolved shipped-source
      path, or an explicit `source unreachable` line (plan-045 rule: a
      degraded run must be legible as degraded).
- [ ] When the source is unreachable, the installed hooks are verified to
      contain the mstack delegation markers — the exec-form strings
      `hook-pre-commit "$@"` / `hook-pre-push "$@"`, which occur only on the
      shims' delegation lines (pre-commit:86 / pre-push:34), never in
      comments; absent or unverifiable marker exits
      `EXIT_GATE_HOOK_MISSING` (26). A gutted hook can no longer be certified.
- [ ] When `core.hooksPath` resolves to something other than the repo's
      `.githooks`, the failure is diagnosed as "hooksPath is not mstack's
      .githooks" with mstack-init remediation text, distinct from the stale
      message.
- [ ] Smoke covers: missing hooksPath, foreign hooksPath, stale hook,
      unreachable source + marker present (pass, announced degraded),
      unreachable source + marker absent (exit 26).

## Design

Resolution: capture `_hooks_src_dir` output into its own variable and branch —
never string-concatenate a possibly-empty result into a path. Reachability
test uses `-r` on the two source files, not `-x`/`-f` alone (the plan-045
lesson: a resolution test must not depend on a bit nothing verifies; the mode
bit is script-mode-smoke's job). Print one line always:
`hook source: <abs path>` or `hook source: unreachable — falling back to
delegation-marker check`.

Degraded verification: the marker must match the FUNCTIONAL delegation, not a
comment. The literal `review-gate.sh hook-pre-commit` appears ONLY in the
shims' header comments (pre-commit line 4, pre-push line 3) — the actual
delegation lines are `exec bash "$RG" hook-pre-commit "$@"` (pre-commit line
86) and `exec bash "$RG" hook-pre-push "$@"` (pre-push line 34), which do NOT
contain that literal; a comment-matching grep would certify a hook gutted
below its intact header. So the marker is the exec-form delegation
itself: `grep -Fq 'hook-pre-commit "$@"'` on the installed pre-commit and
`grep -Fq 'hook-pre-push "$@"'` on the installed pre-push — each string
occurs ONLY on the delegation line, never in a comment, so a gutted `exit 0`
stub (with or without the original header comments) fails it. Marker present
=> exit 0 with the degraded-mode announcement; absent, or the grep itself
failing (unreadable file), => `_hook_install_hint` + exit 26.
This is weaker than a byte compare and the output says so — legible degraded,
never silent.

Foreign-path diagnosis: mstack-init always installs at `.githooks`
(init.sh line 126 sets `core.hooksPath .githooks`), so after making `hp`
absolute, `abs_hp != "$root/.githooks"` means a foreign hooksPath. Emit a
dedicated hint ("core.hooksPath points at <path>, not this repo's .githooks —
mstack's enforcement hooks are not installed; run mstack-init, which also
preserves your existing hooks via mstack.priorHooksPath chaining") and exit
26. Ordering: foreign-path check first, then per-hook existence/executable
checks, then staleness/marker.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/review-gate.sh`: `cmd_assert_hook_installed`
  (and `_hook_install_hint` if a second hint variant is cleaner).
- `skills/mstack-run/scripts/review-gate-smoke.sh`: the five smoke cases
  (throwaway repos; unreachable source via a copied scripts tree with no
  `hooks/` sibling, the same isolation trick review-gate-smoke already uses
  for the missing-template case).

**Out of scope:** the hook shims themselves (no change to
`skills/mstack-run/hooks/*` or `.githooks/*`), init.sh, audit (plan 060),
changing exit code 26's meaning or adding new codes.

## Tasks

1. Rework source resolution in `cmd_assert_hook_installed`: explicit variable,
   `-r` reachability on both files, always-printed mode line.
2. Add the delegation-marker fallback for the unreachable-source path, failing
   closed on absent/unverifiable markers.
3. Add the foreign-hooksPath branch with its distinct diagnostic, ordered
   before the per-hook checks.
4. Smoke: build a throwaway repo with the real shipped hooks installed and
   assert (i) hooksPath unset → 26; (ii) hooksPath pointed at a foreign dir →
   26 with the foreign-path text, not "stale"; (iii) an edited .githooks hook →
   26 "stale"; (iv) scripts copied to a tree with no hooks/ sibling, installed
   hooks intact → 0 and output contains "unreachable"; (v) same tree, installed
   pre-commit replaced by `exit 0` stub → 26.
5. Run the full smoke set and shell lint.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/review-gate.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/review-gate.sh skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [assert] `grep -c "hook source" skills/mstack-run/scripts/review-gate.sh` — mode announcement implemented
- [assert] `bash skills/mstack-run/scripts/review-gate.sh assert-hook-installed` — passes in this repo and prints the resolved source path
