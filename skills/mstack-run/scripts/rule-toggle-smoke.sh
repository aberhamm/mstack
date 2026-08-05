#!/usr/bin/env bash
# rule-toggle-smoke.sh — the `rules.<key>` toggle namespace fails OPEN (plan 088).
#
# THE INVARIANT UNDER TEST. `rule_enabled <key>` must return ENABLED for every
# state except one: the config value is exactly `false`. Absence, an empty
# `rules` object, an unreadable file, a garbled file, and a degraded `json_get`
# fallback all mean ENABLED.
#
# WHY THAT POLARITY. This is plan 045's lesson applied to configuration. A lint
# that silently turns itself off is indistinguishable from a lint that ran and
# found nothing — "no errors" is then evidence of nothing. The cost asymmetry
# points one way: running a rule the user disabled is noisy and obvious and
# costs one config edit; skipping one they wanted is invisible and costs the
# finding. So the ONLY thing that buys silence is an explicit `false`.
#
# The second half of plan 045's rule is the mode line: a component with a
# fail-safe default must SAY which mode it is in, or the degraded path and the
# working path look the same from outside. `rule_mode_line` is that statement,
# and it is asserted here in both directions.
#
# Independence is also under test: flipping one rule's key must disable exactly
# that rule. Plans 089/090/091 each add their own key to the same namespace, and
# a shared kill switch would make "revert one rule" impossible.
#
# Usage: bash skills/mstack-run/scripts/rule-toggle-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib.sh"
CONFIG="$SCRIPT_DIR/config.sh"

CLEAN=()
cleanup() { [ "${#CLEAN[@]}" -gt 0 ] && rm -rf "${CLEAN[@]}"; }
trap cleanup EXIT
PASSED=0
fail() { echo "[rule-toggle-smoke] FAIL: $*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); echo "[rule-toggle-smoke] ok: $*"; }

[ -r "$LIB" ] || fail "lib.sh is not readable at $LIB"

# The pre-implementation failure this suite is supposed to produce, named so the
# failure message says what to do rather than dying inside a subshell.
grep -q '^rule_enabled()' "$LIB" \
  || fail "lib.sh has no rule_enabled() — implement it (this is the expected pre-implementation failure)"
grep -q '^rule_mode_line()' "$LIB" \
  || fail "lib.sh has no rule_mode_line() — implement it (this is the expected pre-implementation failure)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rule-toggle-smoke-XXXXXX")"
CLEAN+=("$TMP")

mkdir -p "$TMP/.mstack"
( cd "$TMP" && git init -q && git config user.email s@e.com && git config user.name s )
printf '.mstack/\n' > "$TMP/.gitignore"
( cd "$TMP" && git add -A && git commit -q -m init )

CFG="$TMP/.mstack/config.json"

# Each probe runs in a FRESH bash from inside the fixture repo, so lib.sh's
# cached repo root and config.sh's CONFIG_FILE both resolve to the fixture and
# never to the real mstack checkout.
rule_rc() {
  ( cd "$TMP" && bash -c '. "$1/lib.sh"; rule_enabled "$2"' _ "$SCRIPT_DIR" "$1" >/dev/null 2>&1; echo $? )
}
# Captured, never piped: rule_mode_line mirrors rule_enabled's exit status, and
# `set -o pipefail` makes `mode_line ... | grep -q` fail on the DISABLED case
# because of the function's status rather than the grep's. That produced a
# failure whose message printed the very string it claimed was missing.
mode_line() {
  ( cd "$TMP" && bash -c '. "$1/lib.sh"; rule_mode_line "$2"' _ "$SCRIPT_DIR" "$1" 2>/dev/null ) || true
}

# --- 1. No config file at all -> ENABLED -----------------------------------
rm -f "$CFG"
[ "$(rule_rc citation_or_finding)" -eq 0 ] || fail "absent config must mean ENABLED"
mode_line citation_or_finding | grep -q 'rule citation_or_finding: enabled' \
  || fail "absent config must print the enabled mode line, got: $(mode_line citation_or_finding)"
ok "an absent config resolves to ENABLED and says so"

# --- 2. Config present, no rules object -> ENABLED -------------------------
printf '{"health":{"weights":{"test":25}}}\n' > "$CFG"
[ "$(rule_rc citation_or_finding)" -eq 0 ] || fail "config without a rules object must mean ENABLED"
ok "a config with no rules object resolves to ENABLED"

# --- 3. Empty rules object -> ENABLED --------------------------------------
printf '{"rules":{}}\n' > "$CFG"
[ "$(rule_rc citation_or_finding)" -eq 0 ] || fail "an empty rules object must mean ENABLED"
ok "an empty rules object resolves to ENABLED"

# --- 4. Explicit true -> ENABLED -------------------------------------------
printf '{"rules":{"citation_or_finding":true}}\n' > "$CFG"
[ "$(rule_rc citation_or_finding)" -eq 0 ] || fail "explicit true must mean ENABLED"
ok "an explicit true resolves to ENABLED"

# --- 5. Explicit false -> DISABLED, and the mode line says so --------------
# The ONLY state that buys silence.
printf '{"rules":{"citation_or_finding":false}}\n' > "$CFG"
[ "$(rule_rc citation_or_finding)" -ne 0 ] || fail "an explicit false must mean DISABLED"
mode_line citation_or_finding | grep -q 'rule citation_or_finding: disabled (config)' \
  || fail "a disabled rule must say so, got: $(mode_line citation_or_finding)"
ok "an explicit false resolves to DISABLED and is legible as disabled"

# --- 6. Independence: one key off does not disable its neighbours ----------
# NEGATIVE CONTROL for case 5: without this, a shared kill switch would pass
# every assertion above while making per-rule revert impossible.
[ "$(rule_rc tui_fixture)" -eq 0 ] \
  || fail "disabling citation_or_finding must not disable tui_fixture"
printf '{"rules":{"tui_fixture":false}}\n' > "$CFG"
[ "$(rule_rc citation_or_finding)" -eq 0 ] \
  || fail "disabling tui_fixture must not disable citation_or_finding"
[ "$(rule_rc tui_fixture)" -ne 0 ] || fail "tui_fixture false must disable tui_fixture"
ok "each rules.<key> disables exactly one rule"

# --- 7. Garbled config -> ENABLED (degraded read never buys silence) -------
printf '{"rules": {"citation_or_finding": fal' > "$CFG"
[ "$(rule_rc citation_or_finding)" -eq 0 ] || fail "an unparseable config must mean ENABLED"
ok "an unparseable config resolves to ENABLED"

# --- 8. Unreadable config -> ENABLED ---------------------------------------
printf '{"rules":{"citation_or_finding":false}}\n' > "$CFG"
chmod 000 "$CFG"
if [ -r "$CFG" ]; then
  # Running as root (or on a filesystem ignoring the mode): the case is not
  # exercisable. Say so rather than claiming a pass we did not observe.
  echo "[rule-toggle-smoke] SKIP: cannot make the config unreadable here (running as root?)"
else
  [ "$(rule_rc citation_or_finding)" -eq 0 ] || fail "an unreadable config must mean ENABLED"
  ok "an unreadable config resolves to ENABLED"
fi
chmod 644 "$CFG"

# --- 9. config.sh set validates the rule keys ------------------------------
# A typo must be REJECTED, not silently written: a misspelled key is a rule the
# user believes they configured and did not.
rm -f "$CFG"
set_rc() { ( cd "$TMP" && bash "$CONFIG" set "$1" "$2" >/dev/null 2>&1; echo $? ); }
[ "$(set_rc rules.citation_or_finding false)" -eq 0 ] || fail "a known rule key with a boolean must be accepted"
[ "$(rule_rc citation_or_finding)" -ne 0 ] || fail "config.sh set must actually persist the disable"
ok "config.sh set writes a known rule key and the toggle takes effect"

[ "$(set_rc rules.citation_or_finding maybe)" -ne 0 ] || fail "a non-boolean rule value must be rejected"
[ "$(set_rc rules.citation_or_findings true)" -ne 0 ] || fail "a misspelled rule key must be rejected"
ok "config.sh set rejects a non-boolean value and an unknown rule key"

for k in tui_fixture premise_brief amendment_repass; do
  [ "$(set_rc "rules.$k" false)" -eq 0 ] || fail "rules.$k must be a known key"
done
ok "all four rule keys are known to config.sh set"

echo "[rule-toggle-smoke] all $PASSED checks passed"
