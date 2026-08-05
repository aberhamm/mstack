#!/usr/bin/env bash
# amendment-repass-smoke.sh — a review's own fix gets one adversarial re-check
# (plan 091, Rule 2).
#
# THE INVARIANT UNDER TEST: an amendment the doctor made to a plan — a fix
# folded in during an auto-fix round, or a plan edit a review skill applied —
# cannot reach `ready` un-re-checked when its severity is P2 or above. Three
# directions are asserted and each covers a distinct way the rule dies:
#
#   THE ASSERTION CAN ACTUALLY FAIL (cases 2, 5). A gate that never fires is
#     indistinguishable from a gate that passes — plan 045's fail-safe-default
#     problem — so a P2 capture with no re-check MUST exit 39. Case 3 is its
#     pair: recording the re-check must actually clear it, or the gate is a
#     brick rather than a gate.
#   THE CLASSIFICATION SIGNAL CANNOT ROT BACK TO ABSENT (cases 5, 6). The
#     severity is produced by the caller and stored by the script; nothing else
#     in the pipeline knows it. So an UNRECOGNIZED severity token stores `p2`
#     (unknown means "needs the re-check"), while a capture with FEWER THAN
#     FOUR arguments is a usage error that exits nonzero and writes NOTHING. If
#     a missing argument silently defaulted, every caller that forgot the
#     severity would look like a caller that supplied one, and the whole signal
#     would be absent again while the records looked complete.
#   IT DOES NOT OVER-BLOCK (cases 4, 7, 8). A P3 amendment, a plan with no
#     amendments at all, and a disabled rule all exit 0. A check that cries
#     wolf gets bypassed, and a bypassed check covers nothing.
#
# CASE 1 IS THE PAYLOAD CONTRACT. `diff` output is the ONLY text the re-pass
# reviewer is given, so it must round-trip the exact edited text: pre-image in,
# unified diff of pre→current out. A re-pass briefed on a diff that lost the
# amendment is a re-pass of nothing.
#
# CASE 9 IS THE TYPO GUARD. `record` refuses a round with no matching capture.
# Without it, `record <plan> 3 ...` against a round-2 amendment would look
# recorded, exit 0, and leave the real amendment un-re-checked — a false
# clearance produced by an off-by-one.
#
# Usage: bash skills/mstack-run/scripts/amendment-repass-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AR="$SCRIPT_DIR/amendment-repass.sh"

CLEAN=()
cleanup() { [ "${#CLEAN[@]}" -gt 0 ] && rm -rf "${CLEAN[@]}"; }
trap cleanup EXIT
PASSED=0
fail() { echo "[amendment-repass-smoke] FAIL: $*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); echo "[amendment-repass-smoke] ok: $*"; }

[ -f "$AR" ] || fail "amendment-repass.sh does not exist yet — implement it (this is the expected pre-implementation failure)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/amendment-repass-smoke-XXXXXX")"
CLEAN+=("$TMP")

# --- Fixture repo -----------------------------------------------------------
mkdir -p "$TMP/docs/plans" "$TMP/.mstack"
( cd "$TMP" && git init -q && git config user.email s@e.com && git config user.name s )
printf '.mstack/\n' > "$TMP/.gitignore"

CFG="$TMP/.mstack/config.json"
AMEND_DIR="$TMP/.mstack/amendments"

_plan() {
  # _plan <id> <title> <criterion-line>
  cat > "$TMP/docs/plans/$1-fixture.md" <<PLAN
---
id: $1
title: $2
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] $3

## Design

**Files expected to change:**

- \`src/app.py\`: the handler

## Tasks

1. Do the thing.

## Verification

Checks:
- [cmd] \`test -f src/app.py\`
PLAN
}

_plan 010 "amended plan" "The handler returns 200."
_plan 011 "second amended plan" "The handler returns 201."
_plan 012 "never amended plan" "The handler returns 202."

# Every probe runs from inside the fixture repo so lib.sh's repo root and
# config.sh's CONFIG_FILE both resolve to the fixture, never to the real mstack
# checkout.
run()    { ( cd "$TMP" && bash "$AR" "$@" 2>&1 ); }
# CONTENT, not just filenames: a "writes nothing" assertion that compared only
# names would pass a capture that APPENDED to an existing record file, which is
# precisely the write a usage error must not perform.
snapshot() { ( cd "$AMEND_DIR" 2>/dev/null && find . -type f -exec cksum {} \; | sort ); }
run_rc() { ( cd "$TMP" && bash "$AR" "$@" >/dev/null 2>&1; echo $? ); }

# --- 1. capture → edit → diff round-trips the exact edited text -------------
out="$(run capture 010 1 p2 audit-genuine)" || fail "capture must exit 0: $out"
[ -f "$AMEND_DIR/plan-010-r1.pre" ] || fail "capture must persist a pre-image, missing plan-010-r1.pre"
[ -f "$AMEND_DIR/plan-010.jsonl" ] || fail "capture must append a record to plan-010.jsonl"

# The amendment: the doctor rewrites the acceptance criterion.
sed -i.bak 's/The handler returns 200./The handler returns 200 and sets a Location header./' \
  "$TMP/docs/plans/010-fixture.md"
rm -f "$TMP/docs/plans/010-fixture.md.bak"

d="$(run diff 010 1)"
printf '%s' "$d" | grep -q '^+.*Location header' \
  || fail "diff must carry the added text, got: $d"
printf '%s' "$d" | grep -q '^-.*returns 200\.' \
  || fail "diff must carry the removed text, got: $d"
printf '%s' "$d" | grep -q 'Do the thing' \
  && fail "diff must be scoped to the amendment, not the whole plan"
ok "capture then diff round-trips the exact edited text and nothing else"

# --- 2. a P2 capture with no re-check is NOT completable (exit 39) ----------
# The case that proves the assertion can fail. Without it every other case
# below would pass against a gate hardwired to exit 0.
rc="$(run_rc assert-rechecked 010)"
[ "$rc" -eq 39 ] || fail "a P2 amendment with no re-check must exit 39, got $rc"
# Captured, never piped: `assert-rechecked` exits 39 here by design, and under
# `set -o pipefail` a `... | grep -q` would fail on the FUNCTION's status rather
# than the grep's — producing a failure whose message prints the very string it
# claims is missing. rule-toggle-smoke.sh carries the same note.
a="$(run assert-rechecked 010)"
printf '%s' "$a" | grep -q 'OPEN' \
  || fail "an open amendment must be named in the output, got: $a"
printf '%s' "$a" | grep -q '010: amended plan' \
  || fail "the plan must be cited as 'NNN: Title' per the plan citation convention, got: $a"
ok "a P2 capture with no re-check exits 39 and names the open amendment"

# --- 3. recording the re-check clears it -----------------------------------
out="$(run record 010 1 p2 audit-genuine codex 0)" || fail "record must exit 0: $out"
rc="$(run_rc assert-rechecked 010)"
[ "$rc" -eq 0 ] || fail "a re-checked P2 amendment must exit 0, got $rc"
ok "recording the re-check clears the gate"

# --- 4. a P3 capture with no re-check does not block ------------------------
out="$(run capture 011 1 p3 autofix-mechanical)" || fail "capture must exit 0: $out"
rc="$(run_rc assert-rechecked 011)"
[ "$rc" -eq 0 ] || fail "a P3 amendment with no re-check must exit 0, got $rc"
ok "a P3 amendment needs no re-check"

# --- 5. an UNRECOGNIZED severity token is stored as p2 ---------------------
# Unknown means "needs the re-check", never "skip it". The whole cost asymmetry
# of this rule is here: a needless re-pass costs one bounded call.
out="$(run capture 011 2 unknown review-edit)" || fail "an unrecognized severity must still capture: $out"
grep -q '"severity":"p2"' "$AMEND_DIR/plan-011.jsonl" \
  || fail "an unrecognized severity token must be stored as p2, got: $(cat "$AMEND_DIR/plan-011.jsonl")"
rc="$(run_rc assert-rechecked 011)"
[ "$rc" -eq 39 ] || fail "an unrecognized-severity amendment must behave as P2 and exit 39, got $rc"
ok "an unrecognized severity token stores p2 and blocks until re-checked"

# --- 6. fewer than four arguments is a usage error that writes NOTHING ------
# There is no short form. A silently-defaulted missing argument is how the
# classification signal rots back to absent while the records look complete.
before="$(snapshot)"
rc="$(run_rc capture 012 1)"
[ "$rc" -ne 0 ] || fail "capture with 2 arguments must exit nonzero"
rc="$(run_rc capture 012 1 p2)"
[ "$rc" -ne 0 ] || fail "capture with 3 arguments must exit nonzero"
after="$(snapshot)"
[ "$before" = "$after" ] || fail "a usage error must write nothing, but the amendments dir changed"
[ ! -f "$AMEND_DIR/plan-012.jsonl" ] || fail "a usage error must not create a record file"
ok "capture with fewer than four arguments exits nonzero and writes nothing"

# --- 7. a plan with no amendments at all is clean ---------------------------
rc="$(run_rc assert-rechecked 012)"
[ "$rc" -eq 0 ] || fail "a plan with no amendment records must exit 0, got $rc"
ok "a plan with no amendments exits 0 (the honest residual: no record, no assertion)"

# --- 8. the disabled path exits 0 and writes no records --------------------
printf '{"rules":{"amendment_repass":false}}\n' > "$CFG"
before="$(snapshot)"
rc="$(run_rc capture 012 1 p2 audit-genuine)"
[ "$rc" -eq 0 ] || fail "a disabled capture must exit 0, got $rc"
after="$(snapshot)"
[ "$before" = "$after" ] || fail "a disabled capture must write nothing, but the amendments dir changed"
# Captured, never piped, for the second pipefail reason: `grep -q` exits at the
# first match and SIGPIPEs the writer, so the pipeline reports 141 even though
# the string was found.
a="$(run capture 012 1 p2 audit-genuine)"
printf '%s' "$a" | grep -q 'rule amendment_repass: disabled (config)' \
  || fail "a disabled run must be legible as disabled (plan 045's mode line), got: $a"
# And the assertion itself stands down: the un-re-checked P2 on 010's sibling
# 011 (case 5) is still open, so this is a real test of the toggle and not a
# vacuous one.
rc="$(run_rc assert-rechecked 011)"
[ "$rc" -eq 0 ] || fail "a disabled assert-rechecked must exit 0 even with an open P2, got $rc"
rm -f "$CFG"
rc="$(run_rc assert-rechecked 011)"
[ "$rc" -eq 39 ] || fail "re-enabling must restore the block, got $rc"
ok "the disabled path exits 0, writes nothing, and says which mode it is in"

# --- 9. record refuses a round with no matching capture --------------------
# The typo guard. `record <plan> 3` against a round-2 amendment would otherwise
# look recorded while leaving the real amendment un-re-checked.
rc="$(run_rc record 011 9 p2 review-edit codex 0)"
[ "$rc" -ne 0 ] || fail "record for a round with no capture must exit nonzero"
rc="$(run_rc assert-rechecked 011)"
[ "$rc" -eq 39 ] || fail "a mis-numbered record must not clear the real amendment, got $rc"
ok "record refuses a round with no matching capture"

echo "[amendment-repass-smoke] all $PASSED checks passed"
