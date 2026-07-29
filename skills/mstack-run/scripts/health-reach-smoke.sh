#!/usr/bin/env bash
# Smoke test for health-reach.sh (plan 047).
#
# THE INVARIANT UNDER TEST: if a plan declares it adds a test file, the
# configured health-gate command must actually execute that file. A gate that
# runs over the wrong files is not a gate that passed.
#
# This is written as an INVARIANT test, not a feature test, deliberately. The
# lesson it is modelled on: `review-gate.sh` shipped mode 100644 while consumers
# resolved it with `[ -x ]`, so plan-authored never ran once and nothing looked
# broken — the fail-safe branch was indistinguishable from the working one. What
# caught it was asserting the invariant ("every shipped script is 100755") and
# then PROVING the assertion could fail by deleting the fix. Same discipline
# here: case 1 reproduces the real escape and must fail before the fix exists.
#
# Central fixture: the observed live defect — a `.mstack/config.json` test
# command whose `-k` filter excludes `test_curl_cffi_impersonation_guard.py`
# entirely. The gate ran, went green, and covered none of the new code.
#
# pytest is frequently absent from PATH, so collection is driven through a stub
# that models `-k` selection. HONEST SCOPE: the stub exercises this script's
# parsing and diffing, NOT real pytest `-k` semantics. Real-runner behavior is
# the [manual] check in plan 047.
#
# Usage: bash skills/mstack-run/scripts/health-reach-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HR="$SCRIPT_DIR/health-reach.sh"
# shellcheck source=skills/mstack-run/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

CLEAN=()
cleanup() { [ "${#CLEAN[@]}" -gt 0 ] && rm -rf "${CLEAN[@]}"; }
trap cleanup EXIT
PASSED=0
fail() { echo "[health-reach-smoke] FAIL: $*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); echo "[health-reach-smoke] ok: $*"; }

[ -f "$HR" ] || fail "health-reach.sh does not exist yet — implement it (this is the expected pre-implementation failure)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/health-reach-smoke-XXXXXX")"
CLEAN+=("$TMP")

# --- Fixture repo -----------------------------------------------------------
mkdir -p "$TMP/docs/plans" "$TMP/tests" "$TMP/.mstack" "$TMP/stub"
( cd "$TMP" && git init -q && git config user.email s@e.com && git config user.name s )

# The test the plan adds, plus an unrelated one that the filter keeps.
cat > "$TMP/tests/test_curl_cffi_impersonation_guard.py" <<'PY'
def test_impersonation_guard():
    assert True
PY
cat > "$TMP/tests/test_unrelated.py" <<'PY'
def test_unrelated():
    assert True
PY

# A plan that DECLARES it adds the guard test.
cat > "$TMP/docs/plans/070-encrypt.md" <<'PLAN'
---
id: 070
title: guard curl_cffi impersonation
status: pending
blocked-by: []
needs-review: none
created: 2026-07-30
---

## Design

**Files expected to change:**

- `scraper/impersonation.py`: add the guard
- `tests/test_curl_cffi_impersonation_guard.py`: cover the guard

## Verification

Checks:
- [cmd] `pytest tests/test_curl_cffi_impersonation_guard.py`
PLAN

( cd "$TMP" && git add -A && git commit -q -m init )

# Stub pytest: models `-k` selection over tests/*.py for --collect-only.
cat > "$TMP/stub/pytest" <<'STUBEOF'
#!/usr/bin/env bash
# --collect-only -q: print one id per test file, honoring a simple -k filter.
kexpr=""
prev=""
for a in "$@"; do
  [ "$prev" = "-k" ] && kexpr="$a"
  prev="$a"
done
case " $* " in *" --collect-only "*) ;; *) exit 0 ;; esac
for f in tests/test_*.py; do
  [ -e "$f" ] || continue
  base="$(basename "$f" .py)"
  if [ -n "$kexpr" ]; then
    # Support exactly `not <substr>` and `<substr>`, which is all the fixture needs.
    case "$kexpr" in
      "not "*) sub="${kexpr#not }"; case "$base" in *"$sub"*) continue ;; esac ;;
      *)       case "$base" in *"$kexpr"*) ;; *) continue ;; esac ;;
    esac
  fi
  echo "${f}::${base}"
done
exit 0
STUBEOF
chmod +x "$TMP/stub/pytest"

# Build the config with jq, never string interpolation. The commands under test
# CONTAIN double quotes (`-k "not impersonation"`); interpolating them produced
# invalid JSON, config.sh silently fell back to defaults, and the auto-detected
# `python -m pytest` was assessed instead of the fixture's command. Case 1 still
# "passed" — for entirely the wrong reason. Escaping is load-bearing here.
set_test_cmd() {
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg c "$1" '{health:{commands:{test:$c}}}' > "$TMP/.mstack/config.json"
  else
    local esc="${1//\\/\\\\}"; esc="${esc//\"/\\\"}"
    printf '{"health":{"commands":{"test":"%s"}}}\n' "$esc" > "$TMP/.mstack/config.json"
  fi
  # Guard the fixture itself: an unreadable command here means the test is
  # measuring the wrong thing, which is worse than failing.
  local back
  back="$( cd "$TMP" && bash "$SCRIPT_DIR/config.sh" get health.commands.test 2>/dev/null )"
  [ "$back" = "$1" ] || fail "fixture config did not round-trip: wrote '$1', read back '$back'"
}
run_hr() { ( cd "$TMP" && PATH="$TMP/stub:$PATH" bash "$HR" reach 070 2>&1 ); }
rc_hr()  { ( cd "$TMP" && PATH="$TMP/stub:$PATH" bash "$HR" reach 070 >/dev/null 2>&1; echo $? ); }

# --- 1. THE REAL ESCAPE: -k filter excludes the declared test ---------------
# This is the case that shipped green in production. It must be caught, named,
# and blocking.
set_test_cmd 'pytest -k "not impersonation"'
out="$(run_hr)"; rc="$(rc_hr)"
printf '%s' "$out" | grep -q 'UNREACHABLE' \
  || fail "the -k-excluded test must be UNREACHABLE: $out"
printf '%s' "$out" | grep -q 'test_curl_cffi_impersonation_guard.py' \
  || fail "the finding must NAME the excluded file: $out"
[ "$rc" -eq "$EXIT_HEALTH_UNREACHABLE" ] \
  || fail "expected exit $EXIT_HEALTH_UNREACHABLE for an unreachable test, got $rc"
ok "a -k filter excluding a declared test is UNREACHABLE and blocking (exit $rc)"

# The report must show the selector responsible, or the finding is unactionable.
printf '%s' "$out" | grep -q 'not impersonation' \
  || fail "the finding must show the excluding command/selector: $out"
ok "the finding names the selector that excludes it"

# --- 2. Positive control: no filter, same plan, same files ------------------
# Without this, case 1 could pass for the wrong reason (e.g. always UNREACHABLE).
set_test_cmd 'pytest'
out="$(run_hr)"; rc="$(rc_hr)"
printf '%s' "$out" | grep -q 'REACHABLE' || fail "unfiltered command should be REACHABLE: $out"
printf '%s' "$out" | grep -q 'UNREACHABLE' && fail "unfiltered command must not report UNREACHABLE: $out"
[ "$rc" -eq 0 ] || fail "expected exit 0 when every declared test is reachable, got $rc"
ok "the same plan under an unfiltered command is REACHABLE (exit 0)"

# --- 3. A filter that excludes an UNRELATED test is not a finding -----------
# Only the files the plan DECLARES matter; a gate may legitimately skip others.
set_test_cmd 'pytest -k "not unrelated"'
[ "$(rc_hr)" -eq 0 ] || fail "excluding a test the plan does not declare must not block"
ok "excluding an undeclared test is not a finding"

# --- 4. UNKNOWN runner: never silently 'covered' ---------------------------
# Fail closed on knowledge, but do NOT block: blocking every non-pytest repo is
# how a check earns itself a permanent bypass (the verify-lint over-block
# lesson). Report loudly, exit 0.
set_test_cmd 'make test'
out="$(run_hr)"
printf '%s' "$out" | grep -q 'UNKNOWN' || fail "unrecognized runner must report UNKNOWN: $out"
printf '%s' "$out" | grep -qi 'not verified' \
  || fail "UNKNOWN must say it is NOT verified, never imply coverage: $out"
# NEGATIVE assertion, and it is the one with teeth. The positive check above was
# satisfiable by a SECOND 'not verified' line further down the same output, so
# rewording the primary UNKNOWN message to claim coverage passed the suite —
# verified by negative control. A test that cannot fail for the regression it
# targets is decoration. Assert the claim is ABSENT, not merely that a denial
# appears somewhere.
printf '%s' "$out" | grep -qiE '(are|is) covered' \
  && fail "UNKNOWN must never claim coverage: $out"
[ "$(rc_hr)" -eq 0 ] || fail "UNKNOWN should report, not block"
ok "an unrecognized runner reports UNKNOWN and not-verified, without blocking"

# --- 5. A plan declaring no test files is not a finding --------------------
cat > "$TMP/docs/plans/071-notests.md" <<'PLAN'
---
id: 071
title: docs only
status: pending
blocked-by: []
needs-review: none
created: 2026-07-30
---

## Design

**Files expected to change:**

- `README.md`: reword the intro
PLAN
set_test_cmd 'pytest'
rc="$( cd "$TMP" && PATH="$TMP/stub:$PATH" bash "$HR" reach 071 >/dev/null 2>&1; echo $? )"
[ "$rc" -eq 0 ] || fail "a plan declaring no test files must not block, got $rc"
ok "a plan that adds no tests is not a finding"

# --- 6. PENDING: declared but not yet created must NOT block ---------------
# This is the calibration that keeps the check usable. Yesterday's verify-lint
# shipped without it and reported all six freshly-written plans as BROKEN,
# because their checks assert on files the plans had not created yet. A check
# that fails every unimplemented plan gets bypassed, and a bypassed check
# covers nothing — the exact failure this file exists to prevent.
cat > "$TMP/docs/plans/072-future.md" <<'PLAN'
---
id: 072
title: adds a test that does not exist yet
status: pending
blocked-by: []
needs-review: none
created: 2026-07-30
---

## Design

**Files expected to change:**

- `tests/test_not_written_yet.py`: will cover the new path
PLAN
set_test_cmd 'pytest'
out="$( cd "$TMP" && PATH="$TMP/stub:$PATH" bash "$HR" reach 072 2>&1 )"
rc="$( cd "$TMP" && PATH="$TMP/stub:$PATH" bash "$HR" reach 072 >/dev/null 2>&1; echo $? )"
printf '%s' "$out" | grep -q 'PENDING' \
  || fail "a declared-but-uncreated test must be PENDING, not UNREACHABLE: $out"
printf '%s' "$out" | grep -q 'UNREACHABLE' \
  && fail "a file that does not exist yet must NOT be reported UNREACHABLE: $out"
[ "$rc" -eq 0 ] || fail "PENDING must not block (that over-block is what gets a check bypassed), got $rc"
ok "a declared-but-uncreated test is PENDING and does not block"

echo "[health-reach-smoke] all $PASSED checks passed"
