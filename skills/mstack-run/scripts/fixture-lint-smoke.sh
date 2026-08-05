#!/usr/bin/env bash
# fixture-lint-smoke.sh — a pane-dependent plan must attach a real capture
# (plan 089, Rule 3).
#
# THE INVARIANT UNDER TEST: a plan whose prose keys on terminal screen content
# may not proceed with zero captured evidence. Two directions are asserted, and
# both matter:
#
#   UNDER-BLOCK — a pane-scraping plan that declares no fixture, and one that
#     declares a fixture that is not on disk, must BOTH set exit 38. The second
#     is the calibration departure from plans 046/047 and is easy to "simplify"
#     into a PENDING-style report; case 3 is what notices if someone does.
#   OVER-BLOCK — a plan with no pane vocabulary, a plan carrying the declared
#     `tui-fixture: n/a  # <reason>` exemption, and a plan whose capture exists
#     but carries no provenance must all exit 0. A check that cries wolf gets
#     bypassed, and a bypassed check covers nothing.
#
# CASE 7b IS THE TIERING PAIR, and it is written as two halves of one invariant.
# Keywords are two tiers: STRONG ones name the MECHANISM of reading a screen
# (`tmux`, `capture-pane`) and fire alone; WEAK ones name a screen ARTIFACT
# (`modal`, `picker`) and fire only alongside a strong one. 017 and 018 are the
# same plan differing by one strong keyword, so the pair pins BOTH failure
# directions at once: weak-alone must not fire (the 9-of-41 false positive this
# repo measured, where "picker" means `pick-next.sh`), and weak-with-strong must
# fire (otherwise the weak tier is dead code that looks exactly like a working
# one from outside — plan 045).
#
# CASE 7 IS THE NEGATIVE CONTROL FOR THE EXEMPTION. Case 6 proves a declared
# `n/a` silences the lint; on its own that would also pass if the frontmatter
# key were honored with no reason at all, or honored for any value whatsoever —
# i.e. if the escape hatch were a heuristic rather than a declaration. Case 7
# uses the same plan with the reason stripped and requires it to block again.
#
# CASE 9 pins the OUTPUT CONTRACT: exactly one line per run whose first
# whitespace-delimited token is a verdict, and that token drawn from a closed
# set of four. Detail text is free-form precisely because nothing parses it, so
# a fifth verdict can only enter through the token position.
#
# Usage: bash skills/mstack-run/scripts/fixture-lint-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FL="$SCRIPT_DIR/fixture-lint.sh"
# shellcheck source=skills/mstack-run/scripts/lib.sh
# shellcheck disable=SC1091  # resolved at runtime; lib.sh ships alongside
. "$SCRIPT_DIR/lib.sh"

CLEAN=()
cleanup() { [ "${#CLEAN[@]}" -gt 0 ] && rm -rf "${CLEAN[@]}"; }
trap cleanup EXIT
PASSED=0
fail() { echo "[fixture-lint-smoke] FAIL: $*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); echo "[fixture-lint-smoke] ok: $*"; }

[ -f "$FL" ] || fail "fixture-lint.sh does not exist yet — implement it (this is the expected pre-implementation failure)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fixture-lint-smoke-XXXXXX")"
CLEAN+=("$TMP")

# --- Fixture repo -----------------------------------------------------------
mkdir -p "$TMP/docs/plans" "$TMP/src" "$TMP/tests/fixtures" "$TMP/.mstack"
( cd "$TMP" && git init -q && git config user.email s@e.com && git config user.name s )
printf '.mstack/\n' > "$TMP/.gitignore"

# A capture WITH provenance, and a capture WITHOUT one. Contents are irrelevant
# to the lint (it cannot verify a capture against reality and does not pretend
# to); only presence and the sidecar are read.
printf '  1. resume session\n> 2. start new\n' > "$TMP/tests/fixtures/pane-picker.txt"
cat > "$TMP/tests/fixtures/pane-picker.txt.meta" <<'META'
capture-date: 2026-08-05
agent-cli-version: claude-code 2.1.4
META
printf 'Allow command?\n' > "$TMP/tests/fixtures/pane-modal.txt"

# 010: no pane vocabulary anywhere. The overwhelmingly common case.
cat > "$TMP/docs/plans/010-plain.md" <<'PLAN'
---
id: 010
title: plain feature plan
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] The settings page gains a save button.

## Design

**Files expected to change:**

- `src/app.py`: add the handler

## Tasks

1. Add the handler.

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN

# 011: pane-scraping, declares no fixture at all. BLOCKING.
cat > "$TMP/docs/plans/011-scrape-nofixture.md" <<'PLAN'
---
id: 011
title: detect the session picker
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] When the picker is on screen, the state reader reports a blocked dialog.

## Design

Read the pane with tmux and match the selected row.

**Files expected to change:**

- `src/app.py`: add the detector

## Tasks

1. Add the detector.

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN

# 012: pane-scraping, declares a fixture that is NOT on disk. BLOCKING, and the
# case that must not drift into a PENDING-style report.
cat > "$TMP/docs/plans/012-scrape-absent.md" <<'PLAN'
---
id: 012
title: detect the approval modal
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] When the modal is on screen, the runner pauses.

## Design

The detector matches against a `tmux capture-pane -p` dump of the modal.

**Files expected to change:**

- `src/app.py`: add the detector
- `tests/fixtures/pane-approval.txt`: NEW. captured pane for the modal state

## Tasks

1. Capture the pane, then add the detector.

## Verification

Checks:
- [cmd] `grep -q "Allow" tests/fixtures/pane-approval.txt`
PLAN

# 013: pane-scraping, fixture exists AND carries a .meta sidecar.
cat > "$TMP/docs/plans/013-scrape-ok.md" <<'PLAN'
---
id: 013
title: detect the picker against a capture
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] When the picker is on screen, the state reader reports a blocked dialog.

## Design

The detector matches against a `tmux capture-pane -p` dump of the picker.

**Files expected to change:**

- `src/app.py`: add the detector
- `tests/fixtures/pane-picker.txt`: the captured picker pane

## Tasks

1. Add the detector.

## Verification

Checks:
- [cmd] `grep -q "resume session" tests/fixtures/pane-picker.txt`
PLAN

# 014: pane-scraping, fixture exists, NO sidecar. Reported, never blocking.
cat > "$TMP/docs/plans/014-scrape-undated.md" <<'PLAN'
---
id: 014
title: detect the approval modal against a capture
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] When the modal is on screen, the runner pauses.

## Design

The detector matches against a `tmux capture-pane -p` dump of the modal.

**Files expected to change:**

- `src/app.py`: add the detector
- `tests/fixtures/pane-modal.txt`: the captured modal pane

## Tasks

1. Add the detector.

## Verification

Checks:
- [cmd] `grep -q "Allow" tests/fixtures/pane-modal.txt`
PLAN

# 017 / 018: THE TIERING PAIR. Byte-identical but for one added strong keyword.
# 017 is phrased exactly like mstack's own pick-next.sh plans — "picker" meaning
# a plan picker, no screen anywhere.
cat > "$TMP/docs/plans/017-weak-only.md" <<'PLAN'
---
id: 017
title: the picker distinguishes all-blocked from all-done
status: pending
blocked-by: []
needs-review: none
created: 2026-08-05
---

## Requirements

- [ ] The picker exits 12 when every remaining plan is blocked, not 10.

## Design

A plan vanishes from the picker's output with zero trace. The modal case is the
one where every plan is blocked.

**Files expected to change:**

- `src/app.py`: fix the exit code

## Tasks

1. Fix the exit code.

## Verification

Checks:
- [cmd] `test -f src/app.py`
PLAN

# Same plan, one strong keyword added. MUST block — without this the tiering
# could silently degrade into "weak keywords never match at all", which is the
# dead-check failure mode plan 045 documents.
sed -e 's/^id: 017$/id: 018/' \
    -e 's/^title: the picker.*$/title: the picker state is read off the pane/' \
    -e 's|^A plan vanishes from the picker.*$|The state is read with tmux. A plan vanishes from the picker output with zero|' \
    "$TMP/docs/plans/017-weak-only.md" > "$TMP/docs/plans/018-weak-plus-strong.md"

# 015 / 016: the same keyword-matching plan with and without a reason on the
# `tui-fixture: n/a` declaration. Only the reasoned one is honored.
cat > "$TMP/docs/plans/015-declared.md" <<'PLAN'
---
id: 015
title: document the pane vocabulary
status: pending
blocked-by: []
needs-review: none
tui-fixture: n/a  # quotes the rule's own vocabulary; scrapes no pane
created: 2026-08-05
---

## Requirements

- [ ] The doc lists the picker and modal keywords the lint matches on.

## Design

Prose only; tmux is never invoked.

**Files expected to change:**

- `docs/vocab.md`: NEW. the keyword list

## Tasks

1. Write the doc.

## Verification

Checks:
- [cmd] `test -f docs/vocab.md`
PLAN

sed 's/^tui-fixture: n\/a.*$/tui-fixture: n\/a/' "$TMP/docs/plans/015-declared.md" \
  | sed 's/^id: 015$/id: 016/' > "$TMP/docs/plans/016-declared-noreason.md"

( cd "$TMP" && git add -A && git commit -q -m init )

run_fl() { ( cd "$TMP" && bash "$FL" lint "$1" 2>&1 ); }
rc_fl()  { ( cd "$TMP" && bash "$FL" lint "$1" >/dev/null 2>&1; echo $? ); }

# verdict_token <output>: the first whitespace-delimited token of the single
# verdict line. Deliberately re-derives the contract the consumer relies on
# rather than grepping for an expected string, so a run that emits two verdict
# lines (or none) is a failure rather than a coincidental pass.
verdict_token() {
  printf '%s\n' "$1" | awk '
    { t=$1 }
    t=="NOT-APPLICABLE" || t=="FIXTURE-OK" || t=="FIXTURE-UNDATED" || t=="FIXTURE-MISSING" {
      n++; tok=t
    }
    END { if (n==1) print tok; else print "VERDICT-LINES:" n+0 }
  '
}

# --- 1. A plan with no pane vocabulary is NOT-APPLICABLE, exit 0 ------------
out="$(run_fl 010)"; rc="$(rc_fl 010)"
printf '%s' "$out" | grep -q 'rule tui_fixture: enabled' \
  || fail "an enabled run must print its mode line: $out"
[ "$(verdict_token "$out")" = "NOT-APPLICABLE" ] \
  || fail "a plan with no pane vocabulary must be NOT-APPLICABLE, got '$(verdict_token "$out")': $out"
[ "$rc" -eq 0 ] || fail "expected exit 0 for a non-TUI plan, got $rc"
ok "a plan with no pane vocabulary is NOT-APPLICABLE, exit 0, mode line printed"

# --- 1b. NOT-APPLICABLE still emits its verdict line ------------------------
# The output contract is unconditional. A silent run is indistinguishable from a
# lint that never executed — plan 045's failure mode, exactly.
printf '%s' "$out" | grep -qE '^NOT-APPLICABLE' \
  || fail "the common case must still print one verdict line, not run silently: $out"
ok "the common case prints its verdict line rather than running silently"

# --- 2. Pane-scraping with no fixture declared: BLOCKING -------------------
out="$(run_fl 011)"; rc="$(rc_fl 011)"
[ "$(verdict_token "$out")" = "FIXTURE-MISSING" ] \
  || fail "a pane-scraping plan declaring no fixture must be FIXTURE-MISSING: $out"
[ "$rc" -eq "$EXIT_TUI_FIXTURE_MISSING" ] \
  || fail "expected exit $EXIT_TUI_FIXTURE_MISSING for FIXTURE-MISSING, got $rc"
printf '%s' "$out" | grep -q 'picker' \
  || fail "the finding must NAME the matched keyword so a false positive is dismissible: $out"
printf '%s' "$out" | grep -q 'When the picker is on screen' \
  || fail "the finding must QUOTE the matching line: $out"
ok "a pane-scraping plan with no fixture is FIXTURE-MISSING (exit $rc), names the keyword and quotes the line"

# --- 3. A declared fixture that is not on disk: BLOCKING -------------------
# THE CALIBRATION DEPARTURE. Plans 046/047 defer on a plan's output; a capture is
# an input the author must already hold. "I'll capture the pane later" is exactly
# the plan that writes its detector from memory first.
[ ! -e "$TMP/tests/fixtures/pane-approval.txt" ] \
  || fail "fixture broken: the absent-capture case needs the file to actually be absent"
out="$(run_fl 012)"; rc="$(rc_fl 012)"
[ "$(verdict_token "$out")" = "FIXTURE-MISSING" ] \
  || fail "a declared-but-absent capture must be FIXTURE-MISSING, not deferred: $out"
[ "$rc" -eq "$EXIT_TUI_FIXTURE_MISSING" ] \
  || fail "a declared-but-absent capture must block with exit $EXIT_TUI_FIXTURE_MISSING, got $rc"
printf '%s' "$out" | grep -q 'declared but absent' \
  || fail "the absent-capture finding needs its own message: $out"
printf '%s' "$out" | grep -q 'tests/fixtures/pane-approval.txt' \
  || fail "the absent-capture finding must name the path: $out"
ok "a declared-but-absent capture is FIXTURE-MISSING with its own message (exit $rc)"

# --- 4. Fixture present with a .meta sidecar: FIXTURE-OK -------------------
out="$(run_fl 013)"; rc="$(rc_fl 013)"
[ "$(verdict_token "$out")" = "FIXTURE-OK" ] \
  || fail "a declared capture that exists with provenance must be FIXTURE-OK: $out"
[ "$rc" -eq 0 ] || fail "expected exit 0 for FIXTURE-OK, got $rc"
ok "a declared capture that exists and carries a .meta sidecar is FIXTURE-OK, exit 0"

# --- 5. Fixture present, no sidecar: FIXTURE-UNDATED, reported not blocking --
out="$(run_fl 014)"; rc="$(rc_fl 014)"
[ "$(verdict_token "$out")" = "FIXTURE-UNDATED" ] \
  || fail "a capture with no provenance sidecar must be FIXTURE-UNDATED: $out"
[ "$rc" -eq 0 ] \
  || fail "missing provenance is REPORTED, never blocking — a strict parse earns a bypass, got $rc"
printf '%s' "$out" | grep -q 'pane-modal.txt.meta' \
  || fail "the undated finding must name the sidecar path the author should write: $out"
ok "a capture with no .meta sidecar is FIXTURE-UNDATED and does not block"

# --- 5b. An incomplete sidecar is also UNDATED, and still does not block ----
printf 'agent-cli-version: claude-code 2.1.4\n' > "$TMP/tests/fixtures/pane-modal.txt.meta"
out="$(run_fl 014)"
[ "$(verdict_token "$out")" = "FIXTURE-UNDATED" ] \
  || fail "a sidecar missing capture-date must still be FIXTURE-UNDATED: $out"
[ "$(rc_fl 014)" -eq 0 ] || fail "an incomplete sidecar must not block"
printf 'capture-date: not-a-date\nagent-cli-version: x\n' > "$TMP/tests/fixtures/pane-modal.txt.meta"
[ "$(verdict_token "$(run_fl 014)")" = "FIXTURE-UNDATED" ] \
  || fail "a capture-date that is not YYYY-MM-DD must be FIXTURE-UNDATED"
printf 'capture-date: 2026-08-05\nagent-cli-version: claude-code 2.1.4\n' > "$TMP/tests/fixtures/pane-modal.txt.meta"
[ "$(verdict_token "$(run_fl 014)")" = "FIXTURE-OK" ] \
  || fail "completing the sidecar must flip 014 to FIXTURE-OK (positive control)"
rm -f "$TMP/tests/fixtures/pane-modal.txt.meta"
ok "an incomplete or malformed sidecar is UNDATED; completing it flips to FIXTURE-OK"

# --- 6. The declared exemption, with a reason ------------------------------
out="$(run_fl 015)"; rc="$(rc_fl 015)"
[ "$(verdict_token "$out")" = "NOT-APPLICABLE" ] \
  || fail "a plan declaring 'tui-fixture: n/a  # <reason>' must be NOT-APPLICABLE: $out"
printf '%s' "$out" | grep -q 'declared' \
  || fail "the exemption verdict must say it came from a declaration: $out"
printf '%s' "$out" | grep -q 'scrapes no pane' \
  || fail "the exemption verdict must surface the stated reason for review: $out"
[ "$rc" -eq 0 ] || fail "expected exit 0 for a declared exemption, got $rc"
ok "'tui-fixture: n/a  # <reason>' is honored, prints the reason, exits 0"

# --- 7. NEGATIVE CONTROL: the same declaration with no reason -------------
# Without this, case 6 would also pass if the key were honored unconditionally —
# i.e. if the escape hatch were a bare keyword rather than a declaration that
# review can read. Block-unless-declared, same doctrine as the health gate's
# `- none:` entry.
grep -q '^tui-fixture: n/a$' "$TMP/docs/plans/016-declared-noreason.md" \
  || fail "fixture broken: 016 must carry the bare key with no reason"
out="$(run_fl 016)"; rc="$(rc_fl 016)"
[ "$(verdict_token "$out")" = "FIXTURE-MISSING" ] \
  || fail "'tui-fixture: n/a' with NO reason must not be honored: $out"
[ "$rc" -eq "$EXIT_TUI_FIXTURE_MISSING" ] \
  || fail "an unreasoned declaration must leave the plan blocking, got $rc"
ok "'tui-fixture: n/a' with no reason is not honored — the plan is linted normally"

# --- 7b. THE TIERING, both directions (the amendment to plan 089) ---------
# WEAK ALONE MUST NOT FIRE. 017 is phrased exactly like mstack's own
# pick-next.sh plans: "picker" meaning a plan picker, "modal" meaning the
# all-blocked case, no screen anywhere. The un-tiered list fired on 9 of 41 live
# plans in this repo and every one was a false positive — a check whose only
# observed firings are all wrong earns a permanent bypass.
out="$(run_fl 017)"; rc="$(rc_fl 017)"
[ "$(verdict_token "$out")" = "NOT-APPLICABLE" ] \
  || fail "weak keywords ALONE (picker/modal, no mechanism word) must not make a plan pane-dependent: $out"
[ "$rc" -eq 0 ] || fail "a weak-only plan must exit 0, got $rc"
ok "weak keywords alone (picker/modal) are NOT-APPLICABLE — the pick-next.sh false positive"

# AND THE OTHER DIRECTION, which is what stops the tiering from degrading into
# "weak keywords never match at all" — a dead branch that looks identical to a
# working one from outside (plan 045). 018 is 017 plus one strong keyword.
grep -q 'picker' "$TMP/docs/plans/018-weak-plus-strong.md" \
  || fail "fixture broken: 018 must still carry the weak keyword"
grep -q 'tmux' "$TMP/docs/plans/018-weak-plus-strong.md" \
  || fail "fixture broken: 018 must carry exactly one added strong keyword"
grep -q 'tmux' "$TMP/docs/plans/017-weak-only.md" \
  && fail "fixture broken: 017 must carry NO strong keyword, or the pair proves nothing"
out="$(run_fl 018)"; rc="$(rc_fl 018)"
[ "$(verdict_token "$out")" = "FIXTURE-MISSING" ] \
  || fail "the SAME plan plus one strong keyword must become pane-dependent: $out"
[ "$rc" -eq "$EXIT_TUI_FIXTURE_MISSING" ] \
  || fail "expected exit $EXIT_TUI_FIXTURE_MISSING once a strong keyword is present, got $rc"
ok "the same plan plus one strong keyword blocks — the weak tier is live, not dead"

# 7c. Once the strong gate opens, a WEAK keyword may be the quoted line. On a
# genuine pane plan "when the picker is on screen" is the sentence worth
# quoting, not an incidental tmux mention three sections later.
printf '%s' "$out" | grep -q 'picker' \
  || fail "with the gate open, the weak keyword must still be eligible to name/quote the finding: $out"
ok "with the strong gate open, weak keywords are eligible as the quoted finding"

# --- 8. The disabled path ---------------------------------------------------
# Run against 011, which otherwise exits 38, so a disable that did nothing would
# be caught rather than hidden behind an already-clean plan.
printf '{"rules":{"tui_fixture":false}}\n' > "$TMP/.mstack/config.json"
out="$(run_fl 011)"; rc="$(rc_fl 011)"
printf '%s' "$out" | grep -q 'rule tui_fixture: disabled (config)' \
  || fail "a disabled run must print the disabled mode line: $out"
printf '%s' "$out" | grep -q 'FIXTURE-MISSING' \
  && fail "a disabled rule must emit no findings: $out"
[ "$rc" -eq 0 ] || fail "a disabled rule must exit 0 even on an otherwise-blocking plan, got $rc"
ok "rules.tui_fixture=false prints the disabled line, emits no findings, exits 0"

# --- 8b. Re-enabling restores the finding (positive control) --------------
printf '{"rules":{"tui_fixture":true}}\n' > "$TMP/.mstack/config.json"
[ "$(rc_fl 011)" -eq "$EXIT_TUI_FIXTURE_MISSING" ] \
  || fail "re-enabling the rule must restore the blocking finding"
ok "re-enabling the rule restores the finding"

# --- 8c. Disabling a DIFFERENT rule leaves this one running ---------------
printf '{"rules":{"citation_or_finding":false}}\n' > "$TMP/.mstack/config.json"
[ "$(rc_fl 011)" -eq "$EXIT_TUI_FIXTURE_MISSING" ] \
  || fail "disabling an unrelated rule must not disable tui_fixture"
ok "one key disables exactly one rule"
rm -f "$TMP/.mstack/config.json"

# --- 9. THE OUTPUT CONTRACT: exactly one verdict line, from a closed set ---
# Every fixture above, re-run, asserting the shape a consumer parses. Detail
# text is free-form because nothing parses it; a fifth verdict could therefore
# only arrive in the token position, which is what this pins.
for p in 010 011 012 013 014 015 016 017 018; do
  t="$(verdict_token "$(run_fl "$p")")"
  case "$t" in
    NOT-APPLICABLE|FIXTURE-OK|FIXTURE-UNDATED|FIXTURE-MISSING) ;;
    *) fail "plan $p emitted '$t' — the contract is exactly one verdict line from the closed four-verdict set" ;;
  esac
done
ok "every run emits exactly one verdict line whose first token is one of the four verdicts"

# --- 10. An unresolvable plan reference fails loudly ----------------------
[ "$(rc_fl 999)" -ne 0 ] || fail "an unresolvable plan ref must not silently pass"
ok "an unresolvable plan reference is an error, not a silent NOT-APPLICABLE"

echo "[fixture-lint-smoke] all $PASSED checks passed"
