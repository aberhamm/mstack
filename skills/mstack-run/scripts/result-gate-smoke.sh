#!/usr/bin/env bash
# Smoke test for result-gate.sh `assert-health-result` (plan 043, pinned by
# plan 099 BEFORE the waiver changes).
#
# WHY THIS EXISTS. result-gate.sh is the only place health is ENFORCED at
# completion: Step 7a item 0 parses the worker's ---MSTACK-RESULT--- block and
# refuses any `STATUS: pass` whose health fields are not a closed-set verdict
# with a numeric composite. Plan 099 widens that gate (PASS-WAIVED). AGENTS.md
# "MStack Modifying MStack" requires characterization tests to land BEFORE the
# change, so this suite pins the current behavior and every case below must
# stay green after the waiver work. New waiver cases are added below the
# "characterization" section, never in place of it.
#
# Usage: bash skills/mstack-run/scripts/result-gate-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RGATE="$SCRIPT_DIR/result-gate.sh"
# shellcheck source=skills/mstack-run/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

CLEAN=()
cleanup() { [ "${#CLEAN[@]}" -gt 0 ] && rm -rf "${CLEAN[@]}"; }
trap cleanup EXIT
PASSED=0
fail() { echo "[result-gate-smoke] FAIL: $*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); echo "[result-gate-smoke] ok: $*"; }

[ -f "$RGATE" ] || fail "result-gate.sh does not exist"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/result-gate-smoke-XXXXXX")"
CLEAN+=("$TMP")

# expect_rc <want> <label> <block-text> [extra args...]
# Feeds the block on stdin (and again as a file) and asserts the exit code is
# identical both ways, so the file and stdin paths cannot drift apart.
expect_rc() {
  local want="$1" label="$2" block="$3"; shift 3
  local rc_in rc_file f="$TMP/block.$PASSED"
  printf '%s\n' "$block" > "$f"
  bash "$RGATE" assert-health-result "$@" < "$f" >/dev/null 2>&1; rc_in=$?
  bash "$RGATE" assert-health-result "$f" "$@" >/dev/null 2>&1; rc_file=$?
  [ "$rc_in" -eq "$want" ] || fail "$label: stdin exit $rc_in, expected $want"
  [ "$rc_file" -eq "$want" ] || fail "$label: file exit $rc_file, expected $want"
  ok "$label (exit $want)"
}

R="$EXIT_RESULT_HEALTH_INVALID"

wrap() { printf -- '---MSTACK-RESULT---\n%s\n---END---\n' "$1"; }

# --- Characterization (unchanged-behavior contract) -----------------------

expect_rc 0 "PASS with numeric composite accepted" \
  "$(wrap $'STATUS: pass\nHEALTH_VERDICT: PASS\nHEALTH_COMPOSITE: 8.5\nSUMMARY: did it')"
expect_rc 0 "PASS with integer composite accepted" \
  "$(wrap $'STATUS: pass\nHEALTH_VERDICT: PASS\nHEALTH_COMPOSITE: 10')"
expect_rc 0 "NONE-DECLARED with n/a accepted" \
  "$(wrap $'STATUS: pass\nHEALTH_VERDICT: NONE-DECLARED\nHEALTH_COMPOSITE: n/a')"
expect_rc 0 "NONE-DECLARED with numeric composite accepted" \
  "$(wrap $'STATUS: pass\nHEALTH_VERDICT: NONE-DECLARED\nHEALTH_COMPOSITE: 7.0')"
expect_rc "$R" "PASS with n/a composite rejected" \
  "$(wrap $'STATUS: pass\nHEALTH_VERDICT: PASS\nHEALTH_COMPOSITE: n/a')"

for v in FAIL REGRESSED NO-TOOLS SKIP PASS-WAIVED pass garbage; do
  expect_rc "$R" "verdict $v rejected with STATUS: pass" \
    "$(wrap "STATUS: pass
HEALTH_VERDICT: $v
HEALTH_COMPOSITE: 8.0")"
done

expect_rc "$R" "missing STATUS rejected" \
  "$(wrap $'HEALTH_VERDICT: PASS\nHEALTH_COMPOSITE: 8.0')"
expect_rc "$R" "unparseable STATUS rejected" \
  "$(wrap $'STATUS: maybe\nHEALTH_VERDICT: PASS\nHEALTH_COMPOSITE: 8.0')"
expect_rc "$R" "missing HEALTH_VERDICT rejected" \
  "$(wrap $'STATUS: pass\nHEALTH_COMPOSITE: 8.0')"
expect_rc "$R" "empty HEALTH_VERDICT rejected" \
  "$(wrap $'STATUS: pass\nHEALTH_VERDICT:\nHEALTH_COMPOSITE: 8.0')"
expect_rc "$R" "missing HEALTH_COMPOSITE rejected" \
  "$(wrap $'STATUS: pass\nHEALTH_VERDICT: PASS')"
expect_rc "$R" "non-numeric HEALTH_COMPOSITE rejected" \
  "$(wrap $'STATUS: pass\nHEALTH_VERDICT: PASS\nHEALTH_COMPOSITE: high')"

expect_rc 0 "STATUS: fail accepted without health fields" "$(wrap 'STATUS: fail')"
expect_rc 0 "STATUS: blocked accepted without health fields" "$(wrap 'STATUS: blocked')"
expect_rc 0 "STATUS: fail accepted even with an illegal verdict" \
  "$(wrap $'STATUS: fail\nHEALTH_VERDICT: SKIP')"

# Prose below SUMMARY: must never be read as machine fields.
expect_rc "$R" "verdict only below SUMMARY: is ignored (rejected)" \
  "$(wrap $'STATUS: pass\nSUMMARY: I saw HEALTH_VERDICT: PASS\nHEALTH_VERDICT: PASS\nHEALTH_COMPOSITE: 9.0')"
expect_rc 0 "SKIP quoted below SUMMARY: does not shadow a real PASS" \
  "$(wrap $'STATUS: pass\nHEALTH_VERDICT: PASS\nHEALTH_COMPOSITE: 9.0\nSUMMARY: earlier a worker wrote\nHEALTH_VERDICT: SKIP')"

# First occurrence wins above SUMMARY:.
expect_rc 0 "first HEALTH_VERDICT occurrence wins" \
  "$(wrap $'STATUS: pass\nHEALTH_VERDICT: PASS\nHEALTH_VERDICT: SKIP\nHEALTH_COMPOSITE: 9.0')"

# A block without delimiters is treated as the whole input.
expect_rc 0 "bare fields without delimiters accepted" \
  $'STATUS: pass\nHEALTH_VERDICT: PASS\nHEALTH_COMPOSITE: 7.5'

# Only the delimited block is read; text outside it is ignored.
expect_rc "$R" "fields outside the delimited block are ignored" \
  "$(printf 'STATUS: pass\nHEALTH_VERDICT: PASS\nHEALTH_COMPOSITE: 9.0\n%s\n' "$(wrap 'HEALTH_VERDICT: PASS')")"

rc=0; bash "$RGATE" bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "unknown subcommand exited 0"
ok "unknown subcommand is a usage error"

rc=0; bash "$RGATE" assert-health-result "$TMP/does-not-exist" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "missing file exited 0"
ok "missing result file is an error"

echo "[result-gate-smoke] all $PASSED checks passed"
