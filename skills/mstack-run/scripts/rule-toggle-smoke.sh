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

# --- 6b. tui_fixture independence, against EVERY other key (plan 089) ------
# Case 6 pairs tui_fixture with one neighbour. That would still pass if the two
# shared a switch with the other keys, so this asserts the full set: disabling
# Rule 3 leaves Rules 1, 4 and 2 running. Reverting one rule must cost one key.
printf '{"rules":{"tui_fixture":false}}\n' > "$CFG"
[ "$(rule_rc tui_fixture)" -ne 0 ] || fail "rules.tui_fixture false must disable tui_fixture"
for k in citation_or_finding premise_brief amendment_repass; do
  [ "$(rule_rc "$k")" -eq 0 ] || fail "disabling tui_fixture must not disable $k"
done
mode_line tui_fixture | grep -q 'rule tui_fixture: disabled (config)' \
  || fail "a disabled tui_fixture must be legible as disabled, got: $(mode_line tui_fixture)"
# And the converse: every other key off, tui_fixture still on. Without this the
# assertions above would pass under a switch that only ever disables.
printf '{"rules":{"citation_or_finding":false,"premise_brief":false,"amendment_repass":false}}\n' > "$CFG"
[ "$(rule_rc tui_fixture)" -eq 0 ] \
  || fail "disabling every other rule must leave tui_fixture enabled"
mode_line tui_fixture | grep -q 'rule tui_fixture: enabled' \
  || fail "tui_fixture must announce itself enabled, got: $(mode_line tui_fixture)"
ok "rules.tui_fixture toggles Rule 3 and only Rule 3, in both directions"

# --- 6c. premise_brief independence, against EVERY other key (plan 090) ----
# Rule 4 is the odd one out: it gates PROSE in four skill files rather than a
# script, so nothing errors when its toggle misbehaves — the briefs just quietly
# revert to the pre-090 mandate. That makes the independence assertion the only
# thing standing between "disable Rule 4" and "disable whichever rule shares its
# switch", in both directions.
printf '{"rules":{"premise_brief":false}}\n' > "$CFG"
[ "$(rule_rc premise_brief)" -ne 0 ] || fail "rules.premise_brief false must disable premise_brief"
for k in citation_or_finding tui_fixture amendment_repass; do
  [ "$(rule_rc "$k")" -eq 0 ] || fail "disabling premise_brief must not disable $k"
done
mode_line premise_brief | grep -q 'rule premise_brief: disabled (config)' \
  || fail "a disabled premise_brief must be legible as disabled, got: $(mode_line premise_brief)"
# The converse: every other key off, premise_brief still on. Without this the
# assertions above would pass under a switch that only ever disables.
printf '{"rules":{"citation_or_finding":false,"tui_fixture":false,"amendment_repass":false}}\n' > "$CFG"
[ "$(rule_rc premise_brief)" -eq 0 ] \
  || fail "disabling every other rule must leave premise_brief enabled"
mode_line premise_brief | grep -q 'rule premise_brief: enabled' \
  || fail "premise_brief must announce itself enabled, got: $(mode_line premise_brief)"
ok "rules.premise_brief toggles Rule 4 and only Rule 4, in both directions"

# --- 6d. amendment_repass independence, against EVERY other key (plan 091) --
# Rule 2 is the most expensive of the four (it captures a pre-image per edit and
# spends a bounded adversarial pass per P2+ amendment), so it is the one an
# operator is likeliest to actually turn off. That makes independence the whole
# point: disabling the costly rule must not silently take the three cheap ones
# with it, and disabling any of them must not take Rule 2's completion-side
# `assert-rechecked` gate with it either.
printf '{"rules":{"amendment_repass":false}}\n' > "$CFG"
[ "$(rule_rc amendment_repass)" -ne 0 ] || fail "rules.amendment_repass false must disable amendment_repass"
for k in citation_or_finding tui_fixture premise_brief; do
  [ "$(rule_rc "$k")" -eq 0 ] || fail "disabling amendment_repass must not disable $k"
done
mode_line amendment_repass | grep -q 'rule amendment_repass: disabled (config)' \
  || fail "a disabled amendment_repass must be legible as disabled, got: $(mode_line amendment_repass)"
# The converse: every other key off, amendment_repass still on. Without this the
# assertions above would pass under a switch that only ever disables.
printf '{"rules":{"citation_or_finding":false,"tui_fixture":false,"premise_brief":false}}\n' > "$CFG"
[ "$(rule_rc amendment_repass)" -eq 0 ] \
  || fail "disabling every other rule must leave amendment_repass enabled"
mode_line amendment_repass | grep -q 'rule amendment_repass: enabled' \
  || fail "amendment_repass must announce itself enabled, got: $(mode_line amendment_repass)"
ok "rules.amendment_repass toggles Rule 2 and only Rule 2, in both directions"

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

# --- 10. Review decision batches are configurable and bounded ----------------
# Review pacing is deliberately not a rules.* toggle: it is a user preference
# with a closed numeric domain, so a typo must fail instead of silently falling
# back to the slow one-question cadence.
rm -f "$CFG"
get_review_batch() { ( cd "$TMP" && bash "$CONFIG" get review.question_batch_size 2>/dev/null ); }
[ "$(get_review_batch)" = "3" ] || fail "review.question_batch_size must default to 3"
[ "$(set_rc review.question_batch_size 1)" -eq 0 ] || fail "batch size 1 must be accepted"
[ "$(get_review_batch)" = "1" ] || fail "batch size 1 must round-trip"
[ "$(set_rc review.question_batch_size 2)" -eq 0 ] || fail "batch size 2 must be accepted"
[ "$(set_rc review.question_batch_size 3)" -eq 0 ] || fail "batch size 3 must be accepted"
[ "$(set_rc review.question_batch_size 4)" -ne 0 ] || fail "batch size 4 must be rejected"
[ "$(set_rc review.question_batch_size many)" -ne 0 ] || fail "non-numeric batch size must be rejected"
ok "review question batch size defaults to 3 and accepts only 1, 2, or 3"

echo "[rule-toggle-smoke] all $PASSED checks passed"
