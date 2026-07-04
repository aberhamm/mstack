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

echo "[review-gate-smoke] all $(wc -l < "$COUNTER" | tr -d ' ') checks passed"
