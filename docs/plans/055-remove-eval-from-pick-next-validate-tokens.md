---
id: 055
title: Remove eval from pick-next; validate dep and priority tokens
status: pending
blocked-by: [054]
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

Three related defects in `skills/mstack-run/scripts/pick-next.sh`, all in how
frontmatter tokens flow into shell evaluation:

(a) The cycle-detection storage uses
`eval "DEPS_${_skey}=\"$_deps\""` (line 292), where `$_deps` derives from the
plan's `blocked-by:` frontmatter via `parse_blocked_qualified`. Reproduced in
the audit: `blocked-by: [$(id>/tmp/marker)]` executes the command
substitution. Plan files are LLM-authored, so this is a live self-injection
surface, not a theoretical one. The paired lookup
`eval "deps=\"\${DEPS_${_snode}:-}\""` (line 303, inside `cycle_dfs`) is the
same mechanism's read side.

(b) A YAML-quoted dep — `blocked-by: ["002"]` — yields the literal token
`"002"`, which never matches a `DONE_IDS` entry, so the plan is silently and
permanently blocked with no diagnostic.

(c) A non-numeric `priority: high` reaches `$((10#$pri))` (lines 378-380);
under `set -e` the arithmetic error kills comparison silently mid-loop, so
ordering breaks with no message naming the offending plan.

**Acceptance criteria**

- [ ] No `eval` remains anywhere in `pick-next.sh`.
- [ ] Injection repro: a temp-repo plan with
      `blocked-by: [$(touch "$d/marker")]` makes the picker die loudly (naming
      the plan via `plan_label` and the offending token) and `$d/marker` is
      NOT created.
- [ ] Quoted dep `blocked-by: ["002"]` dies loudly naming the plan and the
      token `"002"` with a hint to write bare numeric ids — the silent
      permanent block is gone. (Decision, documented in a comment: REJECT
      quotes rather than accept-and-strip; loud failure beats silent
      tolerance of a second dep syntax.)
- [ ] Valid dep forms still work: bare numeric (`3`), zero-padded (`003`),
      and cross-goal `slug:id` (id part validated `[0-9]+`, slug part
      validated `[a-zA-Z0-9_-]+`). Anything else dies with `plan_label` +
      token.
- [ ] Non-numeric `priority:` dies loudly with `plan_label` and the value;
      empty/absent priority still defaults to id.
- [ ] The dead `parse_blocked()` (lines 159-166, already
      `shellcheck disable=SC2329` as unreachable) is deleted.
- [ ] Cycle detection still catches a 2-node and a self-referential cycle
      (exit 13) — behavior preserved through the storage rewrite.

## Design

Replace the eval-based per-key storage with the flat string-list +
scan-function technique the SAME file already uses for `DONE_IDS` (lines
203-212) and `ALL_ID_MAP` (lines 218-225) — bash-3.2 compatible, no
associative arrays, no eval. Concretely: build
`DEPS_MAP` as newline-separated records `goal|id<TAB>dep1 dep2 ...` (tab
delimiter is safe because dep tokens are validated `[0-9]+`/`slug:id` before
insertion), plus a `deps_for <goal|id>` lookup function doing a `case`/`awk`
scan. The DFS in `cycle_dfs` (lines 295-333) is the ONLY consumer of
`DEPS_*` — port it to call `deps_for`; `_sanitize_key` (line 273) loses its
last caller and is deleted too.

Validation happens once, inside (or immediately after)
`parse_blocked_qualified` (lines 173-197): each raw token must match
`^[0-9]+$` or `^[a-zA-Z0-9_-]+:[0-9]+$`; on violation, `die` (from lib.sh)
with `plan_label` and the literal token. Priority validation sits at the read
site (line 374): non-empty and not `^[0-9]+$` → same loud die. Because
validation runs before any token reaches an arithmetic or storage context,
the injection surface is closed even if a future edit reintroduces dynamic
evaluation elsewhere.

`die` propagation caveat (do not get this wrong): `parse_blocked_qualified`
is only ever called in command substitution, so `die` exits the subshell,
not the script. The abort reaches the top level because the collection-pass
call site is a simple-command assignment (`_deps="$(...)"`, line 288) whose
failure trips `set -e`. The `for dep in $(parse_blocked_qualified ...)`
sites (candidate loop line 363, scoped diagnosis line 437) do NOT trip
`set -e` on substitution failure — bash ignores it in a for-word-list. This
is safe ONLY because the collection pass scans every non-done plan before
either later site runs, so every invalid token dies at line 288 first. Keep
the validation inside `parse_blocked_qualified` AND keep the collection
pass parsing all non-done plans; verify the repro exits nonzero via that
path, and add a one-line comment at the line-288 call site stating it is
the propagation point.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/pick-next.sh`: eval removal, `deps_for` lookup,
  token/priority validation, dead-code deletion.

**Out of scope:** the unscoped all-blocked fix (plan 054, a dependency); the
`fm_get` awk parser; `normalize_id` duplication across scripts (noted in
lib.sh line ~253 as pre-existing); status.sh/manifest.sh copies of anything.

## Tasks

1. Add token validation to `parse_blocked_qualified`: accept `[0-9]+` and
   `slug:[0-9]+`, `die` with `plan_label` + token otherwise; document the
   reject-quotes decision in a comment.
2. Replace lines 267-293's eval storage with the flat `DEPS_MAP` build +
   `deps_for` lookup function; delete `_sanitize_key`.
3. Port `cycle_dfs` (lines 295-333) to `deps_for`; verify 2-node and
   self-cycle still exit 13.
4. Validate `priority` as `[0-9]+` at line 374 before the `$((10#...))`
   comparisons; `die` with `plan_label` + value on violation.
5. Delete dead `parse_blocked()` (lines 159-166) and its SC2329 disable.
6. Run `bash -n`, `shellcheck`, all smoke suites, and the two temp-repo
   repros (injection, quoted dep).

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/pick-next.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/pick-next.sh`
- [cmd] `! grep -n "eval" skills/mstack-run/scripts/pick-next.sh`
- [cmd] `d=$(mktemp -d) && cd "$d" && git init -q . && mkdir -p docs/plans && printf -- '---\nid: 001\ntitle: a\nstatus: pending\nblocked-by: [$(touch %s/marker)]\nneeds-review: none\n---\n' "$d" > docs/plans/001-a.md && rc=0; bash /Users/matthew/dev/mstack/skills/mstack-run/scripts/pick-next.sh 2>err.txt || rc=$?; test "$rc" -ne 0 && test ! -e "$d/marker"`
- [assert] the injection repro's `err.txt` names the offending token
- [cmd] `d=$(mktemp -d) && cd "$d" && git init -q . && mkdir -p docs/plans && printf -- '---\nid: 002\ntitle: b\nstatus: pending\nblocked-by: ["001"]\nneeds-review: none\n---\n' > docs/plans/002-b.md && rc=0; bash /Users/matthew/dev/mstack/skills/mstack-run/scripts/pick-next.sh 2>err.txt || rc=$?; test "$rc" -ne 0 && grep -q '"001"' err.txt`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh && bash skills/mstack-run/scripts/review-gate-smoke.sh && bash skills/mstack-run/scripts/verify-lint-smoke.sh && bash skills/mstack-run/scripts/health-reach-smoke.sh && bash skills/mstack-run/scripts/wrapup-scan-smoke.sh && bash skills/mstack-run/scripts/plan-ref-smoke.sh && bash skills/mstack-run/scripts/hook-chain-smoke.sh`
