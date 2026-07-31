#!/usr/bin/env bash
# Smoke test for health-check.sh scoring (plan 065).
#
# THE INVARIANT UNDER TEST: every category the gate DETECTS and RUNS must reach
# the composite, and the weights it scores against must be the weights the
# config advertises. A category that runs but is not scored is worse than one
# that never ran: the gate reports a number, the number looks fine, and the
# failing suite is invisible.
#
# Central fixture: the audit-reproduced defect. `cmd_detect` emitted `e2e`,
# `cmd_run` executed it, and then the score-assignment `case` had no `e2e)`
# branch — so a failing Playwright suite next to one passing lint produced
# `VERDICT:PASS COMPOSITE:10.0`. Meanwhile `config.sh` DEFAULT_CONFIG shipped
# `"e2e": 20`, advertising a weight nothing consumed, and health-check.sh
# carried a SECOND, divergent weight set as `|| echo N` literals
# (25/20/30/15/10, no e2e) that would silently score a repo against different
# numbers than its own config declared.
#
# Case 1 is that exact escape and is the case that must fail before the fix
# exists. Case 3 is its mirror and the one that keeps the fix honest: a repo
# with NO e2e framework must not be dragged down by an e2e weight it never
# used. Fixing the first by always charging the weight would be a regression
# for every non-e2e repo, and nothing else in the suite would notice.
#
# jq is required: the fixture writes 3-level config paths, and the assertions
# read the persisted history JSON.
#
# Usage: bash skills/mstack-run/scripts/health-score-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HC="$SCRIPT_DIR/health-check.sh"
# shellcheck source=skills/mstack-run/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

CLEAN=()
cleanup() { [ "${#CLEAN[@]}" -gt 0 ] && rm -rf "${CLEAN[@]}"; }
trap cleanup EXIT
PASSED=0
fail() { echo "[health-score-smoke] FAIL: $*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); echo "[health-score-smoke] ok: $*"; }

[ -f "$HC" ] || fail "health-check.sh does not exist"

# jq is required to build the fixture config and read the persisted history.
# Report LOUDLY and exit 0 rather than failing: this suite runs inside the
# pre-commit hook, and a suite that bricks every commit on a machine missing an
# optional dependency is how a check earns a permanent --no-verify. Loud is the
# point — a silent skip would be the worse failure.
if ! command -v jq >/dev/null 2>&1; then
  echo "[health-score-smoke] SKIPPED: jq not found. NOTHING WAS VERIFIED." >&2
  echo "[health-score-smoke] Install jq to run e2e scoring and composite coverage." >&2
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/health-score-smoke-XXXXXX")"
CLEAN+=("$TMP")

# --- Fixture repo -----------------------------------------------------------
# Deliberately EMPTY of anything auto-detectable: no tsconfig.json, no
# package.json, no pyproject.toml, no `tests/`, no `*.sh`. Every category that
# runs in this fixture is one the config explicitly asked for, so a composite
# can be predicted exactly instead of depending on what happens to be installed
# on the machine running the suite.
mkdir -p "$TMP/.mstack"
( cd "$TMP" && git init -q && git config user.email s@e.com && git config user.name s )

# Build .mstack/config.json from a jq spec. Commands are author-written shell
# evaluated by the gate, which is exactly how a real repo configures them.
# jq, never string interpolation: the health-reach-smoke lesson is that an
# interpolated command containing quotes yields invalid JSON, config.sh
# silently falls back to DEFAULT_CONFIG, and the suite then measures the
# defaults while still reporting green.
DEFAULT_WEIGHTS='{"typecheck":20,"lint":15,"test":25,"e2e":20,"deadcode":10,"shell":10}'
WEIGHTS="$DEFAULT_WEIGHTS"

write_config() {
  # args: cat=command ... ; weights come from $WEIGHTS
  local cmds='{}' kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    cmds="$(jq -n --argjson c "$cmds" --arg k "$k" --arg v "$v" '$c + {($k): $v}')" \
      || fail "could not encode fixture command for $k"
  done
  jq -n --argjson c "$cmds" --argjson w "$WEIGHTS" '{health:{commands:$c, weights:$w}}' \
    > "$TMP/.mstack/config.json" || fail "could not write fixture config"
  # Guard the fixture: a command that does not round-trip means config.sh fell
  # back to DEFAULT_CONFIG and the suite is measuring the defaults.
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    local back
    back="$( cd "$TMP" && bash "$SCRIPT_DIR/config.sh" get "health.commands.$k" 2>/dev/null )"
    [ "$back" = "$v" ] || fail "fixture config did not round-trip for $k: wrote '$v', read back '$back'"
  done
}

# Commands, as literal shell. `true` scores lint 10 (exit 0, empty output).
PASS_CMD='true'
E2E_FAIL='sh -c "echo 0 pass 5 fail; exit 1"'      # score 0  (0% passing)
E2E_PART='sh -c "echo 9 pass 1 fail; exit 1"'      # score 4  (90% passing)

run_hc()  { ( cd "$TMP" && bash "$HC" run 2>/dev/null ); }
rc_hc()   { ( cd "$TMP" && bash "$HC" run >/dev/null 2>&1; echo $? ); }
field()   { printf '%s\n' "$1" | grep "^$2:" | head -1 | cut -d: -f2-; }
# COMPOSITE as a scaled integer (9.4 -> 94) so assertions can use ranges
# instead of pinning a value that integer-division rounding owns.
scaled()  { local c; c="$(field "$1" COMPOSITE)"; echo $(( ${c%.*} * 10 + ${c#*.} )); }

# Guard the fixture itself. If this machine has some tool that auto-detects
# into an extra category, every composite below is measuring something other
# than what it claims, and a wrong-for-the-right-reason pass is the failure
# mode this whole file exists to prevent.
assert_detected() {
  local want="$1" got
  got="$( cd "$TMP" && bash "$HC" detect | cut -d: -f1 | sort | tr '\n' ' ' )"
  got="${got% }"
  [ "$got" = "$want" ] || fail "fixture drift: expected detected categories '$want', got '$got'"
}

# --- 1. THE REAL ESCAPE: a failing e2e suite must not yield PASS -----------
# Pre-fix this printed VERDICT:PASS COMPOSITE:10.0 FAILURES:e2e — the failure
# was named in a field nothing read, and the verdict said ship it.
write_config "lint=$PASS_CMD" "e2e=$E2E_FAIL"
assert_detected "e2e lint"
out="$(run_hc)"
[ "$(field "$out" VERDICT)" = "FAIL" ] \
  || fail "a failing e2e suite must FAIL the gate, got: $out"
[ "$(field "$out" E2E)" = "0" ] \
  || fail "a 0%-passing e2e suite must score 0, got E2E:$(field "$out" E2E)"
printf '%s' "$out" | grep -q 'FAILURES:.*e2e' \
  || fail "e2e must appear in FAILURES: $out"
ok "a failing e2e suite scores 0 and forces VERDICT:FAIL (composite $(field "$out" COMPOSITE))"

# The composite must actually MOVE. Asserting only the verdict would pass on an
# implementation that hard-codes FAIL whenever e2e is present.
[ "$(scaled "$out")" -lt 70 ] \
  || fail "the failing e2e must drag the composite below 7.0, got $(field "$out" COMPOSITE)"
ok "the failing e2e is weighted into the composite, not just flagged"

# --- 2. Positive control: same repo, passing e2e ---------------------------
# Without this, case 1 is satisfiable by an implementation that fails any repo
# with an e2e category at all.
write_config "lint=$PASS_CMD" "e2e=$PASS_CMD"
out="$(run_hc)"
[ "$(field "$out" VERDICT)" = "PASS" ] || fail "a passing e2e suite must PASS: $out"
[ "$(field "$out" E2E)" = "10" ] || fail "a clean e2e run must score 10: $out"
[ "$(scaled "$out")" -ge 95 ] || fail "two perfect categories must score ~10.0, got $(field "$out" COMPOSITE)"
ok "a passing e2e scores 10 and the gate PASSes ($(field "$out" COMPOSITE))"

# --- 3. NO e2e detected must not skew the score ----------------------------
# The mirror of case 1, and the reason the fix is redistribution rather than
# "always charge the e2e weight". A repo with no Playwright and no Cypress
# must be scored over the categories it HAS. If a SKIPPED e2e were charged its
# 20 into active_weight while contributing 0 to the numerator, these two
# perfect categories would land at 6.6 instead of ~9.9 — a permanent, silent
# ceiling on every repo without browser tests.
write_config "lint=$PASS_CMD" "test=$PASS_CMD"
assert_detected "lint test"
out="$(run_hc)"
[ "$(field "$out" E2E)" = "SKIPPED" ] \
  || fail "with no e2e tool the category must be SKIPPED, got E2E:$(field "$out" E2E)"
[ "$(field "$out" VERDICT)" = "PASS" ] || fail "no-e2e repo with clean tools must PASS: $out"
[ "$(scaled "$out")" -ge 95 ] \
  || fail "an undetected e2e must not consume weight; expected ~10.0, got $(field "$out" COMPOSITE)"
ok "an undetected e2e is SKIPPED and its weight is redistributed ($(field "$out" COMPOSITE))"

# --- 4. An e2e-ONLY repo produces a normal structured result ---------------
# Pre-fix this repo detected a tool (so it cleared the NO-TOOLS gate), then
# reached active_weight=0 and died bare — no VERDICT line at all, which is
# precisely the crashed-gate state plan 043 forbids, because a worker facing it
# has nothing to parse and starts improvising.
write_config "e2e=$E2E_FAIL"
assert_detected "e2e"
out="$(run_hc)"
printf '%s' "$out" | grep -q '^VERDICT:' \
  || fail "an e2e-only repo must still emit a VERDICT line, got: $out"
[ "$(field "$out" VERDICT)" = "FAIL" ] || fail "e2e-only failing repo must FAIL: $out"
printf '%s' "$out" | grep -qi 'no tools ran successfully' \
  && fail "the bare die must be gone: $out"
ok "an e2e-only repo emits a structured VERDICT instead of dying bare"

write_config "e2e=$PASS_CMD"
out="$(run_hc)"
[ "$(field "$out" VERDICT)" = "PASS" ] || fail "e2e-only passing repo must PASS: $out"
[ "$(scaled "$out")" -eq 100 ] || fail "a single perfect category must be 10.0, got $(field "$out" COMPOSITE)"
ok "an e2e-only passing repo scores 10.0 over the one active category"

# --- 5. Weights come from config, and ONLY from config ---------------------
# The single-source-of-truth claim, tested behaviorally rather than by grep.
# Same commands, same scores, different declared weights: the composite must
# move by exactly the declared amount. A surviving literal fallback set would
# make this pair identical.
WEIGHTS='{"typecheck":20,"lint":50,"test":25,"e2e":50,"deadcode":10,"shell":10}'
write_config "lint=$PASS_CMD" "e2e=$E2E_PART"   # lint 10, e2e 4
out="$(run_hc)"
[ "$(field "$out" E2E)" = "4" ] || fail "a 90%-passing e2e suite must score 4: $out"
[ "$(scaled "$out")" -eq 70 ] \
  || fail "lint 10 @50 + e2e 4 @50 must be 7.0, got $(field "$out" COMPOSITE)"
ok "declared weights 50/50 produce the predicted composite 7.0"

WEIGHTS='{"typecheck":20,"lint":90,"test":25,"e2e":10,"deadcode":10,"shell":10}'
write_config "lint=$PASS_CMD" "e2e=$E2E_PART"
out="$(run_hc)"
[ "$(scaled "$out")" -eq 94 ] \
  || fail "reweighting to 90/10 must yield 9.4, got $(field "$out" COMPOSITE)"
ok "reweighting the SAME scores to 90/10 moves the composite to 9.4"

# Static backstop for the behavioral pair above: no divergent literal set may
# reappear as a `|| echo N` fallback next to a weight read.
grep -nE 'health\.weights\.[a-z]+.*\|\|[[:space:]]*echo[[:space:]]*[0-9]' "$HC" \
  && fail "health-check.sh grew a hardcoded weight fallback again — config.sh owns the defaults"
ok "health-check.sh carries no literal weight fallbacks"

# --- 6. Config that cannot be read fails CLOSED ----------------------------
# Fail closed, not fail different: scoring against an improvised weight set
# yields a number that looks exactly like a real one.
WEIGHTS='{"typecheck":20,"lint":"not-a-number","test":25,"e2e":20,"deadcode":10,"shell":10}'
write_config "lint=$PASS_CMD"
out="$(run_hc)"; rc="$(rc_hc)"
[ "$(field "$out" VERDICT)" = "FAIL" ] || fail "an unreadable weight must FAIL, not score: $out"
printf '%s' "$out" | grep -q 'FAILURES:config-unreadable' \
  || fail "the failure must be NAMED config-unreadable: $out"
[ "$rc" -eq "$EXIT_HEALTH_INTERNAL" ] \
  || fail "expected exit $EXIT_HEALTH_INTERNAL for an unreadable config, got $rc"
ok "a non-numeric weight fails closed with FAILURES:config-unreadable (exit $rc)"

# --- 7. The persisted history carries e2e ----------------------------------
# The history is what trend and regression detection read. An e2e score that
# reaches the verdict but not the history means REGRESSED can never see an e2e
# regression.
rm -f "$TMP/.mstack/health-history.jsonl"
WEIGHTS="$DEFAULT_WEIGHTS"
write_config "lint=$PASS_CMD" "e2e=$E2E_PART"
run_hc >/dev/null
last="$(tail -1 "$TMP/.mstack/health-history.jsonl")"
printf '%s' "$last" | jq -e 'has("e2e")' >/dev/null \
  || fail "history entry must carry an e2e field: $last"
[ "$(printf '%s' "$last" | jq -r '.e2e')" = "4" ] \
  || fail "history e2e must record the score, got: $last"
ok "a scored e2e is persisted to health-history.jsonl"

write_config "lint=$PASS_CMD"
run_hc >/dev/null
last="$(tail -1 "$TMP/.mstack/health-history.jsonl")"
[ "$(printf '%s' "$last" | jq -r '.e2e')" = "null" ] \
  || fail "an unrun e2e must persist as null, not 0 (0 is a real failing score): $last"
ok "an undetected e2e persists as null, never as a passing-looking 0"

echo "[health-score-smoke] all $PASSED checks passed"
