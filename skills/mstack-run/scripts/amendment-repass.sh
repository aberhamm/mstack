#!/usr/bin/env bash
# amendment-repass.sh — a review's own fix gets one adversarial re-check
# (Rule 2, plan 091).
#
# THE PROBLEM. The highest-churn text in this pipeline is the text reviews
# WRITE, and it is the only text nothing reviews. One of the two P1s in the
# cctrl 051-053 batch was not in the original plan: the eng review CREATED it,
# correctly replacing a too-loose negative readiness form with an allow-list
# that turns out to be unsatisfiable for codex sessions. The fix was right in
# direction and wrong in fact, and it shipped with zero scrutiny because
# amendments folded in during review are stamped cleared along with everything
# else. Nobody reviews the reviewer.
#
# WHAT THIS DOES. It gives plan-doctor somewhere to put an amendment so the
# amendment can be attacked on its own terms:
#
#   capture <plan> <round> <severity> <trigger>
#       Persist the PRE-EDIT image of the plan file together with the
#       classification of the finding that is about to be fixed.
#   diff <plan> <round>
#       Print the unified diff pre-image -> current. This is the ONLY text the
#       re-pass reviewer is given; scope is what keeps the re-pass one bounded
#       pass instead of a second full review under a different name.
#   record <plan> <round> <severity> <trigger> <by> [defects]
#       Append the re-check record for a captured amendment.
#   assert-rechecked <plan>
#       Exit EXIT_AMENDMENT_UNCHECKED (39) when any captured P2-or-above
#       amendment for that plan has no matching re-check record.
#
# THE SEVERITY SIGNAL IS PRODUCED BY THE CALLER, NOT DERIVED HERE. Nothing else
# in the pipeline classifies an amendment — Step 4b knows only that a plan's
# hash changed, and which finding drove the edit is information the doctor holds
# at edit time and immediately discards. So `capture` takes severity and trigger
# as arguments; this script is the storage, plan-doctor's enumerated capture
# sites are the producer. Without that, `assert-rechecked` would have nothing to
# assert over.
#
# STRICT 4-ARITY ON `capture`, AND THE ASYMMETRY IS DELIBERATE:
#   * FEWER THAN FOUR ARGUMENTS is a usage error. It exits nonzero and writes
#     NOTHING — no pre-image, no record. There is no short form, because a
#     silently-defaulted missing argument is exactly how the classification
#     signal rots back to absent while the records still look complete.
#   * AN UNRECOGNIZED SEVERITY TOKEN (anything outside p1|p2|p3) is TOLERATED
#     and stored as `p2`. Unknown means "needs the re-check", never "skip it".
#     The cost asymmetry is the one the review gate settles the same way: a
#     needless re-pass costs one bounded call; a skipped re-pass on a fix that
#     introduced a P1 costs what the 051-053 batch cost.
# An unrecognized TRIGGER is stored verbatim (the enumerated list is expected to
# grow); only its SHAPE is validated, because record values must stay
# space-free for the same reason the `reviews:` block's do.
#
# THE RECORD IS LOCAL AND NON-AUTHORITATIVE BY CONSTRUCTION. It lives in
# `.mstack/amendments/plan-<id>.jsonl` with pre-images at
# `.mstack/amendments/plan-<id>-r<N>.pre`, and `.mstack/` is gitignored — so it
# is per-checkout working state that is invisible to review, absent on a fresh
# clone, and gone when the directory is cleaned. Same class as
# `health-history.jsonl` and the `.mstack/reviews/*.json` cache, and stated here
# rather than discovered later. It is deliberately NOT frontmatter: the
# `reviews:` block is the completion gate's single source of truth, and an
# amendment record is not a review verdict and must never become one.
#
# HONEST RESIDUAL — this is an HONEST-PATH check only. It fires when the doctor
# calls `capture`. An agent that edits a plan without capturing leaves no
# record, and `assert-rechecked` on a plan with no records exits 0. There is no
# write-time hook and no retroactive audit for amendments, and claiming
# otherwise would repeat the overclaim plan 039 explicitly refused to make about
# uncommitted work. What this buys is that an amendment the doctor DID make can
# no longer reach `ready` unexamined.
#
# Gated on `rule_enabled amendment_repass`; prints its mode either way. Disabled,
# every subcommand is a no-op that exits 0 and writes nothing.
#
# Exit: 0 on success; EXIT_AMENDMENT_UNCHECKED (39) from `assert-rechecked` when
# a P2+ amendment is un-re-checked; 2 on a usage error; 1 on an unresolvable
# plan or an unreadable file.
#
# Usage:
#   amendment-repass.sh capture <plan> <round> <severity> <trigger>
#   amendment-repass.sh diff <plan> <round>
#   amendment-repass.sh record <plan> <round> <severity> <trigger> <by> [defects]
#   amendment-repass.sh assert-rechecked <plan>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
# shellcheck disable=SC1091  # resolved at runtime; lib.sh ships alongside
. "$SCRIPT_DIR/lib.sh"

RULE_KEY="amendment_repass"

# The enumerated trigger vocabulary, in one place so it is readable without
# tracing the callers. plan-doctor's capture sites stamp these; an unrecognized
# value is stored, not rejected, so adding a site does not require editing this
# script first.
#   audit-genuine         GENUINE adversarial-audit finding auto-fixed (p2)
#   seam-blocking         blocking SEAM (MISSING/SHAPE-DIVERGENT) fix     (p2)
#   frame-critical        [critical] frame-review finding fixed           (p2)
#   review-edit           a review skill edited the plan                  (p2)
#   autofix-autonomy      autonomy-readiness auto-fix                     (p3)
#   autofix-verification  verification/testability auto-fix               (p3)
#   autofix-trap          trap-resistance auto-fix                        (p3)
#   autofix-mechanical    mechanical-error auto-fix                       (p3)

usage() {
  cat >&2 <<'USAGE'
usage:
  amendment-repass.sh capture <plan> <round> <severity> <trigger>
  amendment-repass.sh diff <plan> <round>
  amendment-repass.sh record <plan> <round> <severity> <trigger> <by> [defects]
  amendment-repass.sh assert-rechecked <plan>

  <severity>  p1 | p2 | p3   (any other token is stored as p2)
  <trigger>   audit-genuine | seam-blocking | frame-critical | review-edit |
              autofix-autonomy | autofix-verification | autofix-trap |
              autofix-mechanical

All four arguments to `capture` are REQUIRED. There is no short form: a capture
without a severity is what would leave assert-rechecked with nothing to assert
over.
USAGE
  exit 2
}

# --- Value shapes -----------------------------------------------------------
# Every stored value is a single token with no whitespace and no quoting
# metacharacters, so the JSONL lines below need no escaping and can be read back
# with a fixed pattern. This is the same discipline the `reviews:` frontmatter
# block uses ("values never contain spaces") and for the same reason: a record
# format that needs an escaper needs a parser, and neither survives a shell
# helper being edited by an agent.
_valid_token() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

_valid_round() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# _norm_sev <token>: p1|p2|p3 pass through (case-insensitively); EVERYTHING else
# becomes p2. Unknown means "needs the re-check".
_norm_sev() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$s" in
    p1|p2|p3) printf '%s' "$s" ;;
    *) printf 'p2' ;;
  esac
}

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown"; }

# --- Plan + path resolution -------------------------------------------------
# Same shape as premise-lint.sh's resolver: a path on disk wins, otherwise the
# shared plan-ref resolver.
_plan_relpath_ar() {
  local arg="$1" root abs out id
  root="$(repo_root)"
  if [ -f "$arg" ]; then
    abs="$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")"
    printf '%s\n' "${abs#"$root"/}"
    return 0
  fi
  out="$(resolve_plan_ref "$arg")" || return 1
  id="${out%% *}"
  plan_file_for_id "$id"
}

# _plan_id <plan-abs>: the plan's frontmatter id, zero-padded to width 3 — the
# filename convention plan_label already uses. Falls back to the raw value when
# it is not numeric, so a nonstandard id still gets a record rather than
# silently sharing one with another plan.
_plan_id() {
  local raw padded
  raw="$(fm_get "$1" id 2>/dev/null || true)"
  [ -n "$raw" ] || return 1
  padded="$(printf '%03d' "$(normalize_id "$raw")" 2>/dev/null)" || padded="$raw"
  printf '%s' "$padded"
}

_amend_dir() { printf '%s/.mstack/amendments' "$(repo_root)"; }
_jsonl()     { printf '%s/plan-%s.jsonl' "$(_amend_dir)" "$1"; }
_pre()       { printf '%s/plan-%s-r%s.pre' "$(_amend_dir)" "$1" "$2"; }

# _field <line> <key>: read one value out of a record line. The values are
# validated tokens, so a fixed pattern is a complete parser here.
_field() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"
}

# _label <id>: "NNN: Title" per the plan citation convention, degrading to the
# bare id only when the title cannot be read (better a bare id than no output).
_label() {
  plan_label "$1" 2>/dev/null || printf '%s' "$1"
}

# _gate <stream>: print the mode line and return rule_enabled's status. The mode
# line goes to STDERR for `diff` only — that subcommand's stdout is a reviewer
# PAYLOAD, not a report, and prefixing the payload with tooling chatter puts
# mstack's own prose inside the text the reviewer is told to attack. Every other
# subcommand prints it to stdout, matching Rules 1 and 3.
_gate() {
  if [ "${1:-stdout}" = "stderr" ]; then
    rule_mode_line "$RULE_KEY" >&2
    return $?
  fi
  rule_mode_line "$RULE_KEY"
}

# _resolve <plan-ref>: set REL / ABS / PID for the resolved plan.
REL=""; ABS=""; PID=""
_resolve() {
  local arg="$1" root
  root="$(repo_root)"
  REL="$(_plan_relpath_ar "$arg")" || die "cannot resolve plan: $arg"
  case "$REL" in /*) ABS="$REL" ;; *) ABS="$root/$REL" ;; esac
  [ -r "$ABS" ] || die "plan file not readable: $ABS"
  PID="$(_plan_id "$ABS")" || die "plan has no frontmatter id: $REL"
}

# --- capture ----------------------------------------------------------------
cmd_capture() {
  # Arity is checked in main() BEFORE anything else runs, so a usage error can
  # never leave a half-written record behind.
  local plan="$1" round="$2" sev_raw="$3" trigger="$4"

  if ! _gate; then
    echo "amendment-repass: rule disabled — no amendment captured"
    exit 0
  fi

  _valid_round "$round" || { echo "error: round must be a positive integer, got: $round" >&2; exit 2; }
  _valid_token "$trigger" || { echo "error: trigger must be a single [A-Za-z0-9._-] token, got: $trigger" >&2; exit 2; }
  _valid_token "$sev_raw" || { echo "error: severity must be a single [A-Za-z0-9._-] token, got: $sev_raw" >&2; exit 2; }

  _resolve "$plan"

  local sev dir pre rec
  sev="$(_norm_sev "$sev_raw")"
  dir="$(_amend_dir)"
  mkdir -p "$dir" || die "cannot create $dir"
  pre="$(_pre "$PID" "$round")"
  rec="$(_jsonl "$PID")"

  cp "$ABS" "$pre" || die "cannot write pre-image: $pre"
  printf '{"event":"capture","plan":"%s","round":"%s","severity":"%s","trigger":"%s","pre":"%s","ts":"%s"}\n' \
    "$PID" "$round" "$sev" "$trigger" "${pre#"$(repo_root)"/}" "$(_ts)" >> "$rec" \
    || die "cannot append record: $rec"

  printf 'amendment-repass: captured %s round %s [%s %s]\n' "$(_label "$PID")" "$round" "$sev" "$trigger"
  if [ "$sev" != "$(printf '%s' "$sev_raw" | tr '[:upper:]' '[:lower:]')" ]; then
    printf '  severity token "%s" is not p1|p2|p3 — stored as p2 (unknown needs the re-check)\n' "$sev_raw"
  fi
  exit 0
}

# --- diff -------------------------------------------------------------------
cmd_diff() {
  local plan="$1" round="$2"

  if ! _gate stderr; then
    exit 0
  fi

  _valid_round "$round" || { echo "error: round must be a positive integer, got: $round" >&2; exit 2; }
  _resolve "$plan"

  local pre
  pre="$(_pre "$PID" "$round")"
  [ -r "$pre" ] || die "no captured pre-image for plan $PID round $round (expected $pre)"

  # `diff` exits 1 when the files differ, which is the NORMAL case here — an
  # amendment that produced no diff is the anomaly. So the status is swallowed
  # and this subcommand reports success as long as the diff could be produced.
  diff -u "$pre" "$ABS"
  exit 0
}

# --- record -----------------------------------------------------------------
cmd_record() {
  local plan="$1" round="$2" sev_raw="$3" trigger="$4" by="$5" defects="${6:-0}"

  if ! _gate; then
    echo "amendment-repass: rule disabled — no re-check recorded"
    exit 0
  fi

  _valid_round "$round" || { echo "error: round must be a positive integer, got: $round" >&2; exit 2; }
  _valid_token "$trigger" || { echo "error: trigger must be a single [A-Za-z0-9._-] token, got: $trigger" >&2; exit 2; }
  _valid_token "$sev_raw" || { echo "error: severity must be a single [A-Za-z0-9._-] token, got: $sev_raw" >&2; exit 2; }
  _valid_token "$by" || { echo "error: by must be a single [A-Za-z0-9._-] token, got: $by" >&2; exit 2; }
  _valid_round "$defects" || { echo "error: defects must be a non-negative integer, got: $defects" >&2; exit 2; }

  _resolve "$plan"

  local rec sev
  rec="$(_jsonl "$PID")"
  sev="$(_norm_sev "$sev_raw")"

  # A re-check for a round with NO capture is refused rather than appended. The
  # failure it prevents is an off-by-one: `record <plan> 3` against a round-2
  # amendment would look recorded, exit 0, and leave the real amendment
  # un-re-checked — a false clearance manufactured by a typo.
  if ! grep -q "\"event\":\"capture\",\"plan\":\"$PID\",\"round\":\"$round\"" "$rec" 2>/dev/null; then
    echo "error: no captured amendment for plan $PID round $round — nothing to re-check" >&2
    exit 2
  fi

  printf '{"event":"recheck","plan":"%s","round":"%s","severity":"%s","trigger":"%s","by":"%s","defects":"%s","ts":"%s"}\n' \
    "$PID" "$round" "$sev" "$trigger" "$by" "$defects" "$(_ts)" >> "$rec" \
    || die "cannot append record: $rec"

  printf 'amendment-repass: re-checked %s round %s [%s %s] by %s — %s defect(s)\n' \
    "$(_label "$PID")" "$round" "$sev" "$trigger" "$by" "$defects"
  exit 0
}

# --- assert-rechecked -------------------------------------------------------
cmd_assert_rechecked() {
  local plan="$1"

  if ! _gate; then
    echo "amendment-repass: rule disabled — no amendment gate applied"
    exit 0
  fi

  _resolve "$plan"

  local rec
  rec="$(_jsonl "$PID")"
  printf 'amendment-repass: %s\n' "$(_label "$PID")"

  # NO RECORDS IS NOT A FINDING, and this is the honest residual in one branch:
  # the gate can only assert over amendments the doctor captured. A plan edited
  # outside plan-doctor leaves nothing here and passes.
  if [ ! -r "$rec" ]; then
    echo "  no amendments captured — nothing to re-check"
    exit 0
  fi

  local line ev round sev trig
  local rechecked_rounds=" "
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ev="$(_field "$line" event)"
    [ "$ev" = "recheck" ] || continue
    round="$(_field "$line" round)"
    case "$rechecked_rounds" in
      *" $round "*) ;;
      *) rechecked_rounds="${rechecked_rounds}${round} " ;;
    esac
  done < "$rec"

  local captured=0 open=0
  local seen_rounds=" "
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ev="$(_field "$line" event)"
    [ "$ev" = "capture" ] || continue
    round="$(_field "$line" round)"
    # A round captured twice is one amendment, not two: the loop re-captures the
    # same round when a fix re-applies, and counting it twice would demand two
    # re-checks for one diff.
    case "$seen_rounds" in
      *" $round "*) continue ;;
      *) seen_rounds="${seen_rounds}${round} " ;;
    esac
    captured=$((captured + 1))
    sev="$(_field "$line" severity)"
    trig="$(_field "$line" trigger)"
    case "$sev" in
      p1|p2) ;;
      *) printf '  ok    round %s [%s %s] — below P2, no re-check required\n' "$round" "$sev" "$trig"
         continue ;;
    esac
    case "$rechecked_rounds" in
      *" $round "*)
        printf '  ok    round %s [%s %s] — re-checked\n' "$round" "$sev" "$trig" ;;
      *)
        printf '  OPEN  round %s [%s %s] — captured, no re-check recorded\n' "$round" "$sev" "$trig"
        open=$((open + 1)) ;;
    esac
  done < "$rec"

  echo "  ---"
  printf '  %d amendment(s) captured, %d P2+ un-re-checked.\n' "$captured" "$open"
  [ "$open" -eq 0 ] || exit "$EXIT_AMENDMENT_UNCHECKED"
  exit 0
}

main() {
  local c="${1:-}"
  [ -n "$c" ] || usage
  shift
  case "$c" in
    # STRICT arity, checked here and before any side effect. Not "at least four"
    # — a fifth argument means the caller is passing something this script does
    # not store, and accepting it silently would hide the mismatch.
    capture)          [ $# -eq 4 ] || usage; cmd_capture "$1" "$2" "$3" "$4" ;;
    diff)             [ $# -eq 2 ] || usage; cmd_diff "$1" "$2" ;;
    record)           [ $# -eq 5 ] || [ $# -eq 6 ] || usage; cmd_record "$@" ;;
    assert-rechecked) [ $# -eq 1 ] || usage; cmd_assert_rechecked "$1" ;;
    *) usage ;;
  esac
}

main "$@"
