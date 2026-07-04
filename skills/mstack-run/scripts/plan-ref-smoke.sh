#!/usr/bin/env bash
# Smoke test for the plan-reference resolver library in lib.sh (mstack plan
# 031). Exercises plan_title, plan_label, and resolve_plan_ref against this
# repo's own plans (docs/plans/ + docs/plans/archive/) — no fixture repo
# needed since the assertions are about known, stable plan IDs/titles.
#
# Usage: bash skills/mstack-run/scripts/plan-ref-smoke.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

fail() {
  echo "[plan-ref-smoke] FAIL: $*" >&2
  exit 1
}

err_file="$(mktemp "${TMPDIR:-/tmp}/plan-ref-smoke-XXXXXX")"
trap 'rm -f "$err_file"' EXIT

# 1. plan_label for a known archived ID (001) contains the real title.
label="$(plan_label 1)" || fail "plan_label 1 errored"
case "$label" in
  "001: "*"cognitive"*) ;;
  *) fail "plan_label 1 = '$label' does not match ^001: ...cognitive..." ;;
esac
echo "[plan-ref-smoke] plan_label 1 -> $label"

# 2. resolve_plan_ref by a unique slug/title fragment returns that plan's
# bare ID (first stdout field — see resolve_plan_ref's stdout contract).
out="$(resolve_plan_ref cognitive)" || fail "resolve_plan_ref cognitive errored"
id_field="${out%% *}"
[ "$id_field" = "1" ] || fail "resolve_plan_ref cognitive -> '$out' (id field '$id_field', expected 1)"
echo "[plan-ref-smoke] resolve_plan_ref cognitive -> $out"

# 3. An ambiguous fragment exits EXIT_REF_AMBIGUOUS. "review" whole-token
# matches multiple plan slugs/titles in this repo's backlog (034, 035, 036,
# 038, and archived 002, 026) without being an exact match for any of them.
set +e
resolve_plan_ref review >/dev/null 2>"$err_file"
code=$?
set -e
[ "$code" -eq "$EXIT_REF_AMBIGUOUS" ] || fail "resolve_plan_ref review exited $code, expected EXIT_REF_AMBIGUOUS ($EXIT_REF_AMBIGUOUS)"
grep -q "ambiguous ref 'review'" "$err_file" || fail "ambiguous stderr diagnostic missing candidate list"
echo "[plan-ref-smoke] resolve_plan_ref review -> exit $code (EXIT_REF_AMBIGUOUS) as expected"

# 4. An unknown fragment exits EXIT_REF_NOT_FOUND.
set +e
resolve_plan_ref zzz-not-a-real-plan-fragment >/dev/null 2>/dev/null
code=$?
set -e
[ "$code" -eq "$EXIT_REF_NOT_FOUND" ] || fail "resolve_plan_ref zzz-not-a-real-plan-fragment exited $code, expected EXIT_REF_NOT_FOUND ($EXIT_REF_NOT_FOUND)"
echo "[plan-ref-smoke] resolve_plan_ref zzz-not-a-real-plan-fragment -> exit $code (EXIT_REF_NOT_FOUND) as expected"

# 5. Whole-token boundary: "03" must NOT match 031/032/033 (no plan's id
# normalizes to 3 via this fragment, and it isn't a whole token in any
# slug/title either), so it resolves only via plan_file_for_id's id lookup —
# it must NOT ambiguously match the 03x plans by substring.
out="$(resolve_plan_ref 03)" || fail "resolve_plan_ref 03 errored"
id_field="${out%% *}"
[ "$id_field" = "3" ] || fail "resolve_plan_ref 03 -> '$out' (id field '$id_field', expected 3 via numeric-ID normalization, not a 031/032/033 substring match)"
echo "[plan-ref-smoke] resolve_plan_ref 03 -> $out (bare-ID normalization, not a substring match on 031/032/033)"

echo "[plan-ref-smoke] ok"
