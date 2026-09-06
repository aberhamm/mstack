#!/usr/bin/env bash
# Smoke test for review-gate.sh (mstack plan 034). Self-contained and
# deterministic:
#   - completability checks run against the static fixtures in
#     fixtures/review-gate/ (no git needed).
#   - assert-no-downgrade checks run against a throwaway git repo created in a
#     temp dir, so a committed HEAD baseline exists to diff against without
#     touching this repo's history.
#
# Usage: bash skills/mstack-run/scripts/review-gate-smoke.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RG="$SCRIPT_DIR/review-gate.sh"
FIX="$SCRIPT_DIR/fixtures/review-gate"

# shellcheck source=skills/mstack-run/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# Some checks run in subshells (cwd must be the temp repo), so track the pass
# count through a file rather than a shell variable that a subshell would drop.
CLEAN=()
cleanup() { [ "${#CLEAN[@]}" -gt 0 ] && rm -rf "${CLEAN[@]}"; }
trap cleanup EXIT
COUNTER="$(mktemp "${TMPDIR:-/tmp}/review-gate-smoke-cnt-XXXXXX")"
CLEAN+=("$COUNTER")

fail() { echo "[review-gate-smoke] FAIL: $*" >&2; exit 1; }
ok()   { echo x >> "$COUNTER"; echo "[review-gate-smoke] ok: $*"; }

# run_rc <expected-rc> <label> <args...>: run review-gate.sh, assert exit code.
run_rc() {
  local want="$1" label="$2"; shift 2
  local rc=0
  set +e
  bash "$RG" "$@" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq "$want" ] || fail "$label: exit $rc, expected $want (args: $*)"
  ok "$label (exit $rc)"
}

# --- Completability (static fixtures) --------------------------------------

# Legacy plan: needs-review: eng, NO review-required => fail closed.
run_rc "$EXIT_GATE_NOT_COMPLETABLE" "legacy (needs-review, no review-required) not completable" \
  assert-completable "$FIX/legacy-no-required.md"

# required-required check: `required` on the legacy fixture derives `eng`.
req="$(bash "$RG" required "$FIX/legacy-no-required.md")"
[ "$req" = "eng" ] || fail "legacy required set = '$req', expected 'eng'"
ok "legacy required derives 'eng' from needs-review"

# review-required declared but no passing record => not completable.
run_rc "$EXIT_GATE_NOT_COMPLETABLE" "required-but-unrecorded not completable" \
  assert-completable "$FIX/required-unrecorded.md"

# all required reviews recorded passing => completable.
run_rc 0 "all-recorded completable" \
  assert-completable "$FIX/all-recorded.md"

# --- Hook self-refresh -----------------------------------------------------

HOOK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-gate-hook-refresh-XXXXXX")"
CLEAN+=("$HOOK_TMP")
(
  cd "$HOOK_TMP"
  git init -q
  git config user.email smoke@example.com
  git config user.name smoke
  mkdir -p docs/plans
  bash "$RG" ensure-hook-installed >/dev/null 2>&1
)
[ "$(git -C "$HOOK_TMP" config --get core.hooksPath)" = ".githooks" ] \
  || fail "ensure-hook-installed did not configure core.hooksPath"
cmp -s "$HOOK_TMP/.githooks/pre-commit" "$SCRIPT_DIR/../hooks/pre-commit" \
  || fail "ensure-hook-installed did not install current pre-commit"
cmp -s "$HOOK_TMP/.githooks/pre-push" "$SCRIPT_DIR/../hooks/pre-push" \
  || fail "ensure-hook-installed did not install current pre-push"
ok "missing hooks are installed and rechecked"

printf '%s\n' '# stale hook' > "$HOOK_TMP/.githooks/pre-commit"
HOOK_OUT="$(cd "$HOOK_TMP" && bash "$RG" ensure-hook-installed 2>&1)" \
  || fail "ensure-hook-installed did not repair a stale hook"
printf '%s\n' "$HOOK_OUT" | grep -q 'hook refresh diff: pre-commit' \
  || fail "stale-hook repair did not print the old/new diff"
printf '%s\n' "$HOOK_OUT" | grep -q 'repaired and rechecked' \
  || fail "stale-hook repair did not report the successful recheck"
cmp -s "$HOOK_TMP/.githooks/pre-commit" "$SCRIPT_DIR/../hooks/pre-commit" \
  || fail "stale pre-commit does not match shipped source after repair"
ok "stale hook is refreshed with a visible diff and strict recheck"

BROKEN_SKILL="$HOOK_TMP/broken-skill"
mkdir -p "$BROKEN_SKILL/scripts"
cp "$RG" "$SCRIPT_DIR/lib.sh" "$BROKEN_SKILL/scripts/"
BROKEN_REPO="$(mktemp -d "${TMPDIR:-/tmp}/review-gate-hook-broken-XXXXXX")"
CLEAN+=("$BROKEN_REPO")
(
  cd "$BROKEN_REPO"
  git init -q
  git config core.hooksPath .githooks
  mkdir -p docs/plans
)
rc=0
set +e
( cd "$BROKEN_REPO" && bash "$BROKEN_SKILL/scripts/review-gate.sh" ensure-hook-installed >/dev/null 2>&1 )
rc=$?
set -e
[ "$rc" -eq "$EXIT_GATE_HOOK_MISSING" ] \
  || fail "failed reinstall: exit $rc, expected $EXIT_GATE_HOOK_MISSING"
ok "failed reinstall remains fatal after one attempt"

# cleared: eng approved on all-recorded => 0; missing type => nonzero.
run_rc 0 "cleared eng on all-recorded" cleared "$FIX/all-recorded.md" eng
run_rc "$EXIT_GATE_NOT_COMPLETABLE" "cleared design (unrecorded) on all-recorded" \
  cleared "$FIX/all-recorded.md" design

# --- assert-no-downgrade (throwaway git repo) ------------------------------

TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-gate-smoke-XXXXXX")"
CLEAN+=("$TMP")

(
  cd "$TMP"
  git init -q
  git config user.email smoke@example.com
  git config user.name smoke
  mkdir -p docs/plans
)

PLAN="$TMP/docs/plans/950-downgrade-baseline.md"

write_baseline() {
  cat > "$PLAN" <<'PLAN'
---
id: 950
title: Downgrade baseline
status: pending
blocked-by: []
needs-review: none
review-required: eng,code
reviewed: true
reviews:
  - type=eng verdict=approved date=2026-07-04 by=agent
  - type=code verdict=pass date=2026-07-04 by=mstack-code-review
created: 2026-07-04
---

## Requirements

Baseline for assert-no-downgrade tests.
PLAN
}

write_baseline
( cd "$TMP" && git add -A && git commit -q -m "baseline" )

# Positive control: unchanged working copy => no downgrade.
( cd "$TMP" && run_rc 0 "unchanged baseline: no downgrade" assert-no-downgrade 950 )

# Case A: reviewed true -> false.
write_baseline
sed 's/^reviewed: true$/reviewed: false/' "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
( cd "$TMP" && run_rc "$EXIT_GATE_DOWNGRADE" "reviewed true->false caught" assert-no-downgrade 950 )

# Case B: removed reviews entry (drop the eng approval line).
write_baseline
grep -v 'type=eng' "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
( cd "$TMP" && run_rc "$EXIT_GATE_DOWNGRADE" "removed reviews entry caught" assert-no-downgrade 950 )

# Case C: shrunk review-required (eng,code -> eng).
write_baseline
sed 's/^review-required: eng,code$/review-required: eng/' "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
( cd "$TMP" && run_rc "$EXIT_GATE_DOWNGRADE" "shrunk review-required caught" assert-no-downgrade 950 )

# Case D: verdict weakened (approved -> changes-requested).
write_baseline
sed 's/type=eng verdict=approved/type=eng verdict=changes-requested/' "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
( cd "$TMP" && run_rc "$EXIT_GATE_DOWNGRADE" "weakened verdict caught" assert-no-downgrade 950 )

# --- record round-trip -----------------------------------------------------

write_baseline
( cd "$TMP" && git add -A && git commit -q -m "reset baseline" --allow-empty )
# Strip records, then re-record via the script; assert it reads back cleared.
grep -v -e 'type=eng' -e 'type=code' -e '^reviews:' "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
( cd "$TMP" && bash "$RG" record 950 eng approved smoke >/dev/null )
( cd "$TMP" && run_rc 0 "recorded eng reads back cleared" cleared 950 eng )
# Idempotent update: record code pass, eng still cleared, code cleared.
( cd "$TMP" && bash "$RG" record 950 code pass smoke >/dev/null )
( cd "$TMP" && run_rc 0 "code recorded reads back cleared" cleared 950 code )
( cd "$TMP" && run_rc 0 "eng still cleared after second record" cleared 950 eng )
# Overwrite eng with a failing verdict => no longer cleared (fail closed).
( cd "$TMP" && bash "$RG" record 950 eng changes-requested smoke >/dev/null )
( cd "$TMP" && run_rc "$EXIT_GATE_NOT_COMPLETABLE" "eng downgraded record no longer cleared" cleared 950 eng )

# --- backfill --------------------------------------------------------------

cat > "$TMP/docs/plans/951-legacy.md" <<'PLAN'
---
id: 951
title: Legacy needing backfill
status: pending
blocked-by: []
needs-review: eng,design
created: 2026-07-04
---

body
PLAN
( cd "$TMP" && bash "$RG" backfill 951 >/dev/null )
got="$(fm_get "$TMP/docs/plans/951-legacy.md" review-required || true)"
[ "$got" = "eng,design" ] || fail "backfill stamped review-required='$got', expected 'eng,design'"
ok "backfill stamps review-required from needs-review"
# Idempotent: second backfill leaves it unchanged.
( cd "$TMP" && bash "$RG" backfill 951 >/dev/null )
got2="$(fm_get "$TMP/docs/plans/951-legacy.md" review-required || true)"
[ "$got2" = "eng,design" ] || fail "backfill not idempotent: '$got2'"
ok "backfill idempotent"

# --- plan-authored: scaffold vs authored (plan 045) ------------------------
#
# INVERTED POLARITY, on purpose: exit 0 = authored (a consumer must surface it),
# exit EXIT_PLAN_SCAFFOLD = pristine scaffold (a consumer may stay silent). Every
# ambiguity resolves to authored, so the fail-open cases below assert 0.

TPL="$SCRIPT_DIR/../plan-template.md"
[ -r "$TPL" ] || fail "plan-template.md not found at $TPL"

# The summary is part of the authored-plan contract, not presentation sugar.
# Keep the assertion here, beside the live-template scaffold test, so removing
# either the reader-facing explanation or its code-change explanation cannot
# silently turn newly scaffolded plans into opaque implementation specs.
grep -qx '## Plain-English Summary' "$TPL" \
  || fail "plan template is missing the Plain-English Summary section"
grep -q '^\*\*What changes in the code:\*\*' "$TPL" \
  || fail "plan template is missing the plain-English code-change explanation"
ok "plan template includes the plain-English summary contract"

# The pristine-scaffold case is built from the LIVE template rather than
# checked in as a fixture: a static copy would drift from the template silently,
# and this copy is exactly what mstack-plan-new produces.
SCAF="$TMP/docs/plans/953-fresh-scaffold.md"
sed -e 's/^id: 001$/id: 953/' -e 's/^title: .*/title: Fresh scaffold/' "$TPL" > "$SCAF"
run_rc "$EXIT_PLAN_SCAFFOLD" "pristine scaffold is scaffold (silent)" plan-authored "$SCAF"

# One instructional line replaced => somebody wrote something => ask.
PARTIAL="$TMP/docs/plans/954-partially-authored.md"
# shellcheck disable=SC2016  # the backticks are literal template text, not a subshell
sed 's|^- `path/to/file.ts`: what changes$|- `accounts/fields.py`: new encrypted field|' "$SCAF" > "$PARTIAL"
run_rc 0 "one placeholder replaced is authored (ask)" plan-authored "$PARTIAL"

# A real, fully-written plan with no `reviews:` entry — the incident case.
run_rc 0 "fully authored plan is authored (ask)" plan-authored "$FIX/authored-plan.md"

# APPEND-ONLY AUTHORING — every placeholder left intact, real work written
# AROUND them. `miss` stays 0, so a miss-only rule would call this a scaffold
# and stay silent about a fully authored plan. Found by the plan-045
# adversarial audit; this is the exact false-silence the mechanism exists to
# prevent, so it is a permanent regression test, not an edge case.
APPEND="$TMP/docs/plans/955-append-only.md"
cp "$SCAF" "$APPEND"
cat >> "$APPEND" <<'PLAN'

## Implementation research

The credential store writes plaintext to accounts_socialaccount.password, and
the worker reads it on every session start, so a database dump exposes every
login. Fernet with a key from SOCIAL_CRED_KEY is the smallest change that
closes it. Batch the backfill so the table does not lock for the rewrite.
PLAN
run_rc 0 "append-only authoring is authored (ask), not scaffold" plan-authored "$APPEND"

# Fail-open-to-ask paths: each must be 0, never the scaffold code.
run_rc 0 "unresolvable plan ref falls open to authored" plan-authored "no-such-plan-ref-xyz"
run_rc 0 "missing plan file falls open to authored" plan-authored "$TMP/docs/plans/999-absent.md"

# Template unreachable => authored. Copy the script tree WITHOUT the template so
# the co-located lookup misses; asserting 0 here is asserting "cannot tell means
# ask", the plan-045 fail direction.
NOTPL="$TMP/no-template"
mkdir -p "$NOTPL/scripts"
cp "$SCRIPT_DIR"/*.sh "$NOTPL/scripts/"
rc=0
set +e
bash "$NOTPL/scripts/review-gate.sh" plan-authored "$SCAF" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "missing template: exit $rc, expected 0 (must fall open to authored)"
ok "missing template falls open to authored (exit 0)"

# VACUOUS-TRUTH GUARD. If the template yields fewer than 3 sentinels, "none
# missing" is trivially true and EVERY plan would read as scaffold — the
# original silence bug, at full backlog scale.
#
# This case ISOLATES the n<3 guard, and the isolation is the whole point. The
# probe plan is body-identical to the thin template, so miss==0 AND extra==0:
# `extra` cannot rescue this one, leaving the guard as the only thing standing
# between here and exit 32. Verified by deleting the guard — this assertion
# then fails, which is what makes it a real test. An earlier draft probed with
# a full scaffold instead; `extra` caught that on its own, so the test passed
# without ever exercising the guard.
THIN="$TMP/thin-template"
mkdir -p "$THIN/scripts"
cp "$SCRIPT_DIR"/*.sh "$THIN/scripts/"
cat > "$THIN/plan-template.md" <<'TPL'
---
id: 001
title: stub
---

## Requirements

- [ ] ...
TPL
THIN_PLAN="$TMP/docs/plans/956-thin-probe.md"
cp "$THIN/plan-template.md" "$THIN_PLAN"
rc=0
set +e
bash "$THIN/scripts/review-gate.sh" plan-authored "$THIN_PLAN" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "thin template: exit $rc, expected 0 (n<3 guard must force authored, never scaffold)"
ok "too-few-sentinels template falls open to authored (exit 0)"

echo "[review-gate-smoke] all $(wc -l < "$COUNTER" | tr -d ' ') checks passed"
