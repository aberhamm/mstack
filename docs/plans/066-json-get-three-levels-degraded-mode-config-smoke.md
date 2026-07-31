---
id: 066
title: json_get supports 3 levels and announces degraded mode; config smoke
status: skipped
blocked-by: []
priority: 43
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
skipped: 2026-07-31
skipped-reason: "jq is Apple-shipped at /usr/bin/jq on both machines; blast radius is config.sh get alone; the 5-line dead-awk deletion rides along in 068"
---

## Requirements

`json_get` in `skills/mstack-run/scripts/lib.sh` (lines 136-158) has three
audit-reproduced defects. (a) Its docstring claims 1-3 levels of nesting, but
the jq-less awk fallback's `case $#` handles only 1 and 2 — a 3-level path
like `health.commands.test` hits `*) return 1` (line 155). Both real
3-level consumers — `configured_cmd` in `health-check.sh` (line 113,
`config.sh get "health.commands.$cat"`) and `_configured_test_cmd` in
`health-reach.sh` (line 74) — therefore silently ignore configured health
commands whenever jq is absent. (b) The 2-level awk fallback (lines 147-154)
uses GNU-only 3-arg `match($0, /re/, a)` — a hard syntax error on macOS/BSD
awk, i.e. dead code on the primary platform. (c) Every failure is swallowed
by callers' `2>/dev/null || true` / `|| echo <default>` (e.g. `config.sh`
`cmd_get` line 48, `health-check.sh` lines 244-248) — verbatim the AGENTS.md
"a fail-safe default is a place where dead code hides" class.

**Acceptance criteria**

- [ ] With jq, `json_get` resolves 1-, 2-, and 3-level dot paths (already
      true via the jq branch; now pinned by a smoke test).
- [ ] Without jq, the broken GNU-awk 2-level fallback is gone; degraded-mode
      behavior is explicit, not a silent wrong answer or silent empty.
- [ ] Without jq, any `json_get` invocation for a path deeper than 1 level
      prints `CONFIG_MODE=degraded-no-jq` exactly once per invocation on
      stderr (the "say which mode it is in" rule; level-1 reads resolve via
      the supported awk path and stay silent), and stdout stays clean for
      callers.
- [ ] Missing file, missing key, and unsupported depth return nonzero without
      emitting a fabricated value.
- [ ] A new `config-smoke.sh` suite covers 1/2/3-level reads, missing keys,
      and the degraded announcement, and is registered in AGENTS.md and the
      pre-commit hook source (plus the `.githooks/` copy).

## Design

Decision: **delete the awk fallbacks and make jq a hard requirement for
multi-level config reads**, keeping only the portable 1-level awk read
(line 146 — plain `-F'"'`, POSIX-safe) because `code_verdict_from_findings`
(lib.sh lines 569-570) depends on jq-less 1-level reads for its own
fail-closed path. Without jq: level 1 works via the existing awk; levels 2-3
print `CONFIG_MODE=degraded-no-jq` to stderr and return 1. With jq: all
levels resolve via the existing `jq -r ".$path // empty"` branch (which
already supports arbitrary depth — only the fallback lied). The stderr
announcement means the swallowing callers (`2>/dev/null`) still function,
but any operator or smoke harness that looks sees the mode; callers are NOT
rewritten here (065 and 073 own their call sites).

New suite `skills/mstack-run/scripts/config-smoke.sh`, self-contained temp
fixture (a JSON file written to `mktemp -d`), asserting: 1/2/3-level hits,
missing key returns nonzero/empty, and — by invoking a bash with a PATH that
hides jq — the `CONFIG_MODE=degraded-no-jq` stderr line appears exactly once
and level-1 still resolves. Committed executable (`chmod +x` +
`git update-index --chmod=+x`). Registered in AGENTS.md's smoke list and
added to the suite loop in `skills/mstack-run/hooks/pre-commit` (line 62),
then the hook copied to `.githooks/pre-commit` (edit the shipped source
first; never only `.githooks/`). If `config-smoke.sh` already exists at
implementation time (existing plan 051, goal pipeline-hardening, may create
it first), EXTEND it and keep its cases rather than creating fresh;
registration in AGENTS.md and the pre-commit hook is this plan's
responsibility either way (skip if already registered).

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/lib.sh`: `json_get` rewrite (jq all-depth; awk
  1-level only; degraded-mode announcement).
- `skills/mstack-run/scripts/config-smoke.sh`: new suite.
- `skills/mstack-run/hooks/pre-commit`: add `config-smoke` to the suite loop.
- `.githooks/pre-commit`: refreshed copy of the hook source.
- `AGENTS.md`: register the new suite in the smoke-suite list.

**Out of scope:** changing any `json_get` caller's fallback/default behavior
(`config.sh`, `health-check.sh`, `health-reach.sh` call sites are 065/073
territory); adding jq as a dependency for anything outside config reads;
`config.sh set` (already hard-requires jq, line 97).

## Tasks

1. Rewrite `json_get`: keep the jq branch for all depths; keep the 1-level
   awk; delete the 2-level GNU-awk block and the `*) return 1` dead end in
   favor of an explicit depth check with the degraded announcement.
2. Emit `CONFIG_MODE=degraded-no-jq` once per invocation on stderr when jq
   is absent and the path depth is > 1; return 1.
3. Write `config-smoke.sh` covering the acceptance-criteria matrix; make it
   executable and stage the mode bit.
4. Register the suite in AGENTS.md and in `hooks/pre-commit`'s suite loop;
   copy the hook to `.githooks/pre-commit`.
5. Run syntax, shellcheck, and all smoke suites including the new one.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/lib.sh skills/mstack-run/scripts/config-smoke.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/lib.sh skills/mstack-run/scripts/config-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/config-smoke.sh`
- [assert] `grep -c "CONFIG_MODE=degraded-no-jq" skills/mstack-run/scripts/lib.sh` output is >= 1
- [cmd] `grep -q "config-smoke" skills/mstack-run/hooks/pre-commit && grep -q "config-smoke" .githooks/pre-commit && grep -q "config-smoke" AGENTS.md`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
- [assert] `bash skills/mstack-run/scripts/config.sh get health.weights.test` prints a number
