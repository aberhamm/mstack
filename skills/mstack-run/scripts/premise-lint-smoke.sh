#!/usr/bin/env bash
# premise-lint-smoke.sh — the four-class citation lint (plan 088, Rule 1).
#
# THE INVARIANT UNDER TEST: an acceptance criterion that depends on a fact about
# existing code must cite it, and a citation that resolves nowhere is a blocking
# finding. Two failure directions are asserted, not one:
#
#   OVER-BLOCK — a forward reference the plan declares it will create, or a
#     premise-signal word, must NOT set the exit code. This repo shipped that
#     mistake once: verify-lint.sh conflated PENDING with BROKEN and flagged six
#     well-formed plans as dead. A check that cries wolf gets bypassed.
#   UNDER-BLOCK — a symbol that exists nowhere must set exit 37, and it must
#     still do so when the symbol appears inside the plan file that cites it.
#
# CASE 2 IS THE LOAD-BEARING ONE and it is written as an invariant test, not a
# feature test. The symbol it cites appears in exactly one place in the fixture:
# the plan under lint. If premise-lint.sh ever searched plan content, that symbol
# would resolve, CITED-UNRESOLVED would become unreachable by construction, and
# the suite would still be green — the plan-045 failure mode where a check that
# cannot fail is indistinguishable from a check that passes. So case 2 asserts
# the exclusion AND proves the exclusion is load-bearing by checking the symbol
# really is present in the plan file.
#
# Usage: bash skills/mstack-run/scripts/premise-lint-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PL="$SCRIPT_DIR/premise-lint.sh"
# shellcheck source=skills/mstack-run/scripts/lib.sh
# shellcheck disable=SC1091  # resolved at runtime; lib.sh ships alongside
. "$SCRIPT_DIR/lib.sh"

CLEAN=()
cleanup() { [ "${#CLEAN[@]}" -gt 0 ] && rm -rf "${CLEAN[@]}"; }
trap cleanup EXIT
PASSED=0
fail() { echo "[premise-lint-smoke] FAIL: $*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); echo "[premise-lint-smoke] ok: $*"; }

[ -f "$PL" ] || fail "premise-lint.sh does not exist yet — implement it (this is the expected pre-implementation failure)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/premise-lint-smoke-XXXXXX")"
CLEAN+=("$TMP")

# --- Fixture repo -----------------------------------------------------------
mkdir -p "$TMP/docs/plans" "$TMP/src" "$TMP/.mstack"
( cd "$TMP" && git init -q && git config user.email s@e.com && git config user.name s )
printf '.mstack/\n' > "$TMP/.gitignore"

# The ONLY non-plan source file. `existing_helper` lives here and nowhere else;
# `never_defined_symbol` lives nowhere at all.
cat > "$TMP/src/app.py" <<'PY'
def existing_helper(session):
    return session.state
PY

# 010: the four classes that do not block, in one plan. Must exit 0.
cat > "$TMP/docs/plans/010-baseline.md" <<'PLAN'
---
id: 010
title: baseline classes
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] The state reader calls `existing_helper` and returns its value.
- [ ] The migration note in `docs/plans/011-orphan.md` is linked from the index.
- [ ] The picker is a modal, so the session state reader should report a
      blocked dialog rather than an idle one.
- [ ] Add a button to the settings page.

## Design

**Files expected to change:**

- `src/app.py`: read the state

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN

# 011: THE BLOCKING CASE. `never_defined_symbol` appears in this plan file and
# nowhere else in the fixture — see case 2's exclusion proof.
cat > "$TMP/docs/plans/011-orphan.md" <<'PLAN'
---
id: 011
title: orphan citation
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] The reader delegates to `never_defined_symbol` for the dialog case.

## Design

**Files expected to change:**

- `src/app.py`: delegate

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN

# 012: SELF exemption — the plan declares it will create the symbol it cites.
cat > "$TMP/docs/plans/012-forward.md" <<'PLAN'
---
id: 012
title: forward reference
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] The new entry point `brand_new_helper` normalizes the pane text.

## Design

**Files expected to change:**

- `src/new_module.py`: NEW. adds `brand_new_helper`

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN

# 013: ANCESTOR exemption — a not-yet-done blocked-by ancestor declares it.
cat > "$TMP/docs/plans/013-descendant.md" <<'PLAN'
---
id: 013
title: descendant of a forward reference
status: pending
blocked-by: [012]
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] The dispatcher routes through `brand_new_helper`.

## Design

**Files expected to change:**

- `src/dispatch.py`: route

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN

( cd "$TMP" && git add -A && git commit -q -m init )

run_pl() { ( cd "$TMP" && bash "$PL" lint "$1" 2>&1 ); }
rc_pl()  { ( cd "$TMP" && bash "$PL" lint "$1" >/dev/null 2>&1; echo $? ); }
has()    { grep -q -- "$1" <<< "$2"; }
has_re() { grep -qE -- "$1" <<< "$2"; }

# --- 1. A symbol that exists resolves; the mode line is printed -------------
out="$(run_pl 010)"; rc="$(rc_pl 010)"
has 'rule citation_or_finding: enabled' "$out" \
  || fail "an enabled run must print its mode line: $out"
has_re 'CITED-OK +AC1' "$out" \
  || fail "an AC citing existing_helper (present in src/app.py) must be CITED-OK: $out"
[ "$rc" -eq 0 ] || fail "expected exit 0 for a plan with no unresolved citation, got $rc"
ok "an AC citing a symbol that exists is CITED-OK, exit 0, mode line printed"

# --- 1b. A PATH citation uses the FULL surface, plan files included ---------
# The asymmetry between path and symbol resolution is deliberate; without this
# case, dropping the path/symbol split would go unnoticed.
has_re 'CITED-OK +AC2' "$out" \
  || fail "an AC citing an existing PLAN file by path must be CITED-OK: $out"
ok "a path citation resolves against plan files too (full surface)"

# --- 1c. UNCITED: a premise signal with no citation -------------------------
has_re 'UNCITED +AC3' "$out" \
  || fail "an AC with a premise signal and no citation must be UNCITED: $out"
has 'premise signal "should"' "$out" \
  || fail "the UNCITED finding must name the signal that fired: $out"
ok "an AC with a premise signal and no citation is UNCITED and names the signal"

# --- 1d. UNCITED does NOT block --------------------------------------------
# The calibration that keeps this check usable. UNCITED is a word-list match
# over prose; blocking on it in the deterministic layer rebuilds verify-lint's
# original over-block. plan-doctor Step 4b is where it becomes blocking.
[ "$rc" -eq 0 ] \
  || fail "UNCITED must not set the exit code (that over-block is what gets a check bypassed), got $rc"
has 'UNCITED is reported, not blocking here' "$out" \
  || fail "the report must say plainly that UNCITED does not block here: $out"
ok "an UNCITED finding is reported without blocking"

# --- 1e. NO-PREMISE: a plain AC --------------------------------------------
has_re 'NO-PREMISE +AC4' "$out" \
  || fail "a plain AC asserting nothing about existing code must be NO-PREMISE: $out"
ok "a plain AC is NO-PREMISE"

# --- 2. THE BLOCKING CASE, and the exclusion that makes it reachable -------
# Exclusion proof FIRST: the symbol really is present in the plan file that
# cites it. If premise-lint searched plan content, this case would resolve and
# the whole blocking class would be dead while the suite stayed green.
grep -q 'never_defined_symbol' "$TMP/docs/plans/011-orphan.md" \
  || fail "fixture broken: the symbol must appear in the plan file for the exclusion to be under test"
grep -rq 'never_defined_symbol' "$TMP/src" 2>/dev/null \
  && fail "fixture broken: the symbol must NOT exist in non-plan content"

out="$(run_pl 011)"; rc="$(rc_pl 011)"
has 'CITED-UNRESOLVED' "$out" \
  || fail "a symbol present ONLY in the citing plan file must be CITED-UNRESOLVED — the plans dir must be excluded from the symbol content search: $out"
has 'never_defined_symbol' "$out" \
  || fail "the finding must NAME the unresolved identifier: $out"
[ "$rc" -eq "$EXIT_PREMISE_UNCITED" ] \
  || fail "expected exit $EXIT_PREMISE_UNCITED for CITED-UNRESOLVED, got $rc"
ok "a symbol that exists nowhere is CITED-UNRESOLVED and blocking (exit $rc)"

# --- 3. SELF exemption: a declared forward reference is not a defect --------
out="$(run_pl 012)"; rc="$(rc_pl 012)"
has_re 'CITED-OK +AC1' "$out" \
  || fail "a symbol the plan declares it will create must be CITED-OK: $out"
has 'CITED-UNRESOLVED' "$out" \
  && fail "a declared forward reference must not be reported unresolved: $out"
[ "$rc" -eq 0 ] || fail "expected exit 0 for a declared forward reference, got $rc"
ok "a symbol the plan itself declares it will create is CITED-OK, exit 0"

# --- 3b. ANCESTOR exemption: an unfinished blocked-by ancestor's output ----
out="$(run_pl 013)"; rc="$(rc_pl 013)"
has_re 'CITED-OK +AC1' "$out" \
  || fail "a symbol a not-yet-done ancestor declares must be CITED-OK: $out"
[ "$rc" -eq 0 ] || fail "expected exit 0 for an ancestor forward reference, got $rc"
ok "a symbol an unfinished blocked-by ancestor declares is CITED-OK, exit 0"

# --- 3c. NEGATIVE CONTROL for the exemptions -------------------------------
# Without this, cases 3/3b could pass because the exemption fires for
# EVERYTHING (which is exactly the bug found during implementation: a loose
# `Files expected to change` anchor swallowed the acceptance criteria and
# exempted every identifier in the plan). Plan 012's declared block does NOT
# name never_defined_symbol, so 011 must still block after 012 exists.
[ "$(rc_pl 011)" -eq "$EXIT_PREMISE_UNCITED" ] \
  || fail "the forward-reference exemption must not exempt identifiers no plan declares"
ok "the exemption is scoped to declared identifiers, not to every citation"

# --- 4. The disabled path --------------------------------------------------
# Run against 011, the plan that otherwise exits 37, so a disable that did
# nothing would be caught rather than hidden behind an already-clean plan.
printf '{"rules":{"citation_or_finding":false}}\n' > "$TMP/.mstack/config.json"
out="$(run_pl 011)"; rc="$(rc_pl 011)"
has 'rule citation_or_finding: disabled (config)' "$out" \
  || fail "a disabled run must print the disabled mode line: $out"
has 'CITED-UNRESOLVED' "$out" \
  && fail "a disabled rule must emit no findings: $out"
[ "$rc" -eq 0 ] || fail "a disabled rule must exit 0 even on an otherwise-blocking plan, got $rc"
ok "rules.citation_or_finding=false prints the disabled line, emits no findings, exits 0"

# --- 4b. Re-enabling restores the finding (positive control) ---------------
printf '{"rules":{"citation_or_finding":true}}\n' > "$TMP/.mstack/config.json"
[ "$(rc_pl 011)" -eq "$EXIT_PREMISE_UNCITED" ] \
  || fail "re-enabling the rule must restore the blocking finding"
ok "re-enabling the rule restores the finding"

# --- 4c. Disabling a DIFFERENT rule leaves this one running ----------------
printf '{"rules":{"tui_fixture":false}}\n' > "$TMP/.mstack/config.json"
[ "$(rc_pl 011)" -eq "$EXIT_PREMISE_UNCITED" ] \
  || fail "disabling an unrelated rule must not disable citation_or_finding"
ok "one key disables exactly one rule"
rm -f "$TMP/.mstack/config.json"

# --- 5. ALL-CAPS prose is not a citation -----------------------------------
# Regression guard. Under the en_US.UTF-8 collation `[a-z]*` matches
# `UNDETERMINED`, so every ALL-CAPS word in every plan was classified as a
# camelCase symbol and reported unresolved. Found on the real backlog.
cat > "$TMP/docs/plans/014-caps.md" <<'PLAN'
---
id: 014
title: all caps prose
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] A check that cannot be probed makes the plan `UNDETERMINED`, never
      `SATISFIED`.

## Design

**Files expected to change:**

- `src/app.py`: report

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN
out="$(run_pl 014)"
has 'CITED-UNRESOLVED' "$out" \
  && fail "an ALL-CAPS prose token is not a snake_case/camelCase symbol: $out"
[ "$(rc_pl 014)" -eq 0 ] || fail "ALL-CAPS prose must not block"
ok "an ALL-CAPS prose token is not treated as a symbol citation"

# --- 6. Templates, globs, and skill names are not citations ----------------
# Each cannot resolve BY CONSTRUCTION, so flagging them yields a false-positive
# rate of 1 for every plan that describes a naming scheme or names a skill.
cat > "$TMP/docs/plans/015-shapes.md" <<'PLAN'
---
id: 015
title: templates and skill names
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] Records live in `.mstack/amendments/plan-<id>.jsonl`, one per capture.
- [ ] The derived cache under `.mstack/reviews/*.json` stays non-authoritative.
- [ ] The doctor invokes `/plan-eng-review` with the plan file as context.
- [ ] The classifier rule is stated in `docs/plans/011-orphan.md` line 1.

## Design

**Files expected to change:**

- `src/app.py`: record

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN
out="$(run_pl 015)"
has 'CITED-UNRESOLVED' "$out" \
  && fail "templates, globs and skill invocations are not resolvable citations: $out"
[ "$(rc_pl 015)" -eq 0 ] || fail "templates/globs/skill names must not block"
ok "templates, globs, and slash-prefixed skill names are not citations"

# --- 7. A line-anchored path citation still resolves -----------------------
# The most precise citation form a plan can write must not be the one that
# fails: `path/file.md:160-163` resolves to `path/file.md`.
cat > "$TMP/docs/plans/016-anchor.md" <<'PLAN'
---
id: 016
title: line anchored citation
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] The rule is stated at `src/app.py:1-2` and must not be restated.

## Design

**Files expected to change:**

- `src/app.py`: state it once

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN
out="$(run_pl 016)"
has_re 'CITED-OK +AC1' "$out" \
  || fail "a line-anchored path citation must resolve: $out"
[ "$(rc_pl 016)" -eq 0 ] || fail "a line-anchored path citation must not block"
ok "a line-anchored path citation resolves to its file"

# --- 8. Not every backticked token is a citation ---------------------------
# THE FOUR STRINGS BELOW ARE VERBATIM from the only four times the blocking
# class ever fired on this repo's live backlog (plans 068 and 055, 14 pending
# plans swept). All four were false positives — a 100% false-positive rate,
# found by sweeping, not by design. They are copied rather than paraphrased so
# this exact regression cannot return through a reworded approximation.

# The identifiers these ACs cite for real must resolve, so the case isolates
# the four non-citation tokens instead of passing for the wrong reason.
# Untracked on purpose: the surface is tracked UNION untracked-not-ignored.
cat > "$TMP/src/checkpoint.sh" <<'SH'
cmd_prune() { return 0; }
SH
cat > "$TMP/src/health-reach.sh" <<'SH'
plan_label() { printf '%s' "$1"; }
SH

cat > "$TMP/docs/plans/017-noncitations.md" <<'PLAN'
---
id: 017
title: shell syntax and invented paths are not citations
status: pending
blocked-by: []
needs-review: none
created: 2026-08-06
---

## Requirements

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
- [ ] Injection repro: a temp-repo plan with
      `blocked-by: [$(touch "$d/marker")]` makes the picker die loudly (naming
      the plan via `plan_label` and the offending token) and `$d/marker` is
      NOT created.

## Design

**Files expected to change:**

- `src/app.py`: sweep

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN

# EXCLUSION PROOF FIRST, in the shape case 2 established. Each of these tokens
# genuinely resolves nowhere in the fixture, so if the eligibility filters were
# removed every one of them would block again — the assertions below are not
# passing because the strings happen to exist somewhere.
for phantom in tests/test_x.py other/tests/test_x.py 'if/fi'; do
  [ -e "$TMP/$phantom" ] \
    && fail "fixture broken: $phantom must NOT exist, or the exclusion is not what is under test"
done
grep -rq 'test_x' "$TMP/src" 2>/dev/null \
  && fail "fixture broken: the illustrative paths must not exist in fixture content"

out="$(run_pl 017)"; rc="$(rc_pl 017)"
has 'CITED-UNRESOLVED' "$out" \
  && fail "shell keywords, shell expressions, injection payloads and invented example paths are not citations: $out"
[ "$rc" -eq 0 ] \
  || fail "expected exit 0 for an AC set whose only unresolvable tokens are non-citations, got $rc"
ok "shell keyword pairs (if/fi) are not path citations"
ok "shell expressions (\${var#\"\$root\"/}) are not citations"
ok "an injection payload (\$(touch \"\$d/marker\")) is not a citation"
ok "invented illustrative paths (tests/test_x.py) are not citations"

# --- 8b. THE BLOCKING CLASS IS STILL LIVE ----------------------------------
# The failure mode case 8 could introduce is strictly worse than the one it
# fixes: a filter broad enough to silence those four could silence everything,
# and a blocking class that cannot fire is indistinguishable from one that
# passes (plan 045). This case is the positive control, and it is deliberately
# adjacent: a path under a REAL top-level entry that does not exist, plus a
# snake_case symbol that exists nowhere.
cat > "$TMP/docs/plans/018-real-miss.md" <<'PLAN'
---
id: 018
title: a genuine unresolvable citation
status: pending
blocked-by: []
needs-review: none
created: 2026-08-06
---

## Requirements

- [ ] The dispatcher already lives in `src/nope.py` and needs no change.
- [ ] It delegates to `never_defined_probe_symbol` for the blocked case.

## Design

**Files expected to change:**

- `src/app.py`: nothing

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN
[ -e "$TMP/src/nope.py" ] && fail "fixture broken: src/nope.py must not exist"
[ -d "$TMP/src" ] || fail "fixture broken: src/ must be a real top-level entry, or the path is rejected as implausible instead of unresolved"

out="$(run_pl 018)"; rc="$(rc_pl 018)"
has 'src/nope.py' "$out" \
  || fail "a nonexistent file under a REAL top-level directory must still be CITED-UNRESOLVED — the plausibility filter must not swallow it: $out"
has 'never_defined_probe_symbol' "$out" \
  || fail "a snake_case symbol that exists nowhere must still be CITED-UNRESOLVED: $out"
[ "$rc" -eq "$EXIT_PREMISE_UNCITED" ] \
  || fail "the blocking class must not be dead code: expected exit $EXIT_PREMISE_UNCITED, got $rc"
ok "a nonexistent path under a real top-level entry still blocks (exit $rc)"
ok "a snake_case symbol that exists nowhere still blocks"

# --- 8c. A tail-form path citation is still a citation ---------------------
# The plausibility filter is asked ONLY of paths that failed to resolve. Plans
# here routinely cite a real file by its tail (`scripts/lib.sh`), whose first
# segment is not top-level; filtering before resolution would demote all of
# them from CITED-OK for no gain.
cat > "$TMP/docs/plans/019-tail-path.md" <<'PLAN'
---
id: 019
title: tail form path citation
status: pending
blocked-by: []
needs-review: none
created: 2026-08-06
---

## Requirements

- [ ] The reader is defined in `plans/010-baseline.md` and stays there.

## Design

**Files expected to change:**

- `src/app.py`: read

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN
[ -e "$TMP/plans" ] && fail "fixture broken: 'plans' must not be a top-level entry for this case to mean anything"
out="$(run_pl 019)"
has_re 'CITED-OK +AC1' "$out" \
  || fail "a path cited by its tail must still resolve and count as a citation: $out"
ok "a tail-form path citation resolves and is not filtered as implausible"

echo "[premise-lint-smoke] all $PASSED checks passed"
