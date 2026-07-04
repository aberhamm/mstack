#!/usr/bin/env bash
# review-gate.sh — fail-closed review-record + completion-gate primitive.
#
# A plan flagged for review must not be markable done/cleared until that review
# has actually been performed and RECORDED. This script provides the
# deterministic mechanism; plan 036 wires it into completion and plan 038 makes
# it non-optional (git hook + audit). On its own this is anti-forgetfulness,
# not anti-adversary — see docs/plans/034.
#
# FAIL CLOSED, ALWAYS. Any ambiguity — no record, malformed record, unreadable
# plan, unknown verdict, absent review-required — resolves to "required" /
# "not completable". The gate never fails open.
#
# Record store = frontmatter `reviews:` block (single source of truth):
#   reviews:
#     - type=eng verdict=approved date=2026-07-04 by=agent
#     - type=code verdict=pass date=2026-07-04 by=mstack-code-review
#   type    ∈ eng | design | ceo | code
#   verdict ∈ approved | changes-requested | pass | fail
#           (eng/design/ceo pass with `approved`; code passes with `pass`)
#
# Required-review source (precedence):
#   1. `review-required:` frontmatter field (immutable, comma list). Present and
#      `none` => explicitly nothing required. Present with tags => those tags.
#   2. ABSENT `review-required` => derive from `needs-review:` (any non-`none`
#      tag is required). Absent field is NEVER treated as "nothing required" —
#      that is the whole fail-closed point.
#
# Subcommands:
#   required <plan>              print required review types (one per line)
#   cleared  <plan> <type>       exit 0 iff a passing record exists for <type>
#   assert-completable <plan>    exit 0 iff every required review is recorded passing
#   assert-no-downgrade <plan>   exit nonzero if the working tree weakens the
#                                record/required set versus committed HEAD
#   assert-committed <plan>      exit 0 iff the plan is either (a) unapproved
#                                (no recorded reviews: entry — exempt, may sit
#                                dirty) or (b) approved AND clean vs HEAD.
#                                Exit EXIT_GATE_NOT_COMMITTED when approved but
#                                dirty. Plan 037's "approved => committed"
#                                invariant. Single-path: checks only the plan
#                                file (.mstack/reviews/*.json is gitignored and
#                                can never be committed — see .gitignore:6).
#   record   <plan> <type> <verdict> [by]   append/update (idempotent) a record
#   backfill <plan> | --all      stamp review-required from needs-review on
#                                legacy plans that lack review-required
#
# <plan> is a plan id/name/ref (resolved via lib.sh resolve_plan_ref) or a
# direct path to a plan file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  echo "usage: review-gate.sh <required|cleared|assert-completable|assert-no-downgrade|assert-committed|record|backfill> ..." >&2
  [ -n "${1:-}" ] && echo "  $1" >&2
  exit 1
}

# --- Path resolution -------------------------------------------------------

# _plan_relpath <arg>: print the repo-relative path of the target plan. Accepts
# a direct file path (existing) or a plan id/name/ref. Returns nonzero on
# failure.
_plan_relpath() {
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

# _read_target <arg>: print an absolute, readable plan path (or die).
_read_target() {
  local arg="$1" root rel
  root="$(repo_root)"
  rel="$(_plan_relpath "$arg")" || die "cannot resolve plan: $arg"
  local abs="$root/$rel"
  [ -f "$abs" ] || die "plan file not found: $abs"
  printf '%s\n' "$abs"
}

# --- Required-set derivation ----------------------------------------------

# _types_of <comma/space list>: print each type token on its own line, skipping
# empties and the literal `none`.
_types_of() {
  local raw="$1" t
  local IFS=', '
  # shellcheck disable=SC2086
  set -- $raw
  for t in "$@"; do
    [ -n "$t" ] || continue
    [ "$t" = "none" ] && continue
    printf '%s\n' "$t"
  done
}

# _raw_required <file>: print explicit review-required tokens only (empty when
# the field is absent). Used by the downgrade check, which must compare the
# declared field, not the derived fallback.
_raw_required() {
  local rr
  rr="$(fm_get "$1" review-required 2>/dev/null || true)"
  _types_of "$rr"
}

# cmd_required <abs-plan>: print required review types (fail closed).
cmd_required() {
  local file="$1" rr nr
  rr="$(fm_get "$file" review-required 2>/dev/null || true)"
  if [ -n "$rr" ]; then
    # Field present: `none` => empty set; otherwise its tags.
    _types_of "$rr"
    return 0
  fi
  # Field ABSENT: derive from needs-review (fail closed — never empty by default).
  nr="$(fm_get "$file" needs-review 2>/dev/null || true)"
  _types_of "$nr"
}

# --- Record reading --------------------------------------------------------

# _type_cleared <abs-plan> <type>: exit 0 iff at least one reviews entry for
# <type> exists AND every entry for <type> has a passing verdict. Any
# non-passing (or unknown) verdict for the type fails closed.
_type_cleared() {
  local file="$1" type="$2" entries line t v found=0
  entries="$(review_entries "$file" 2>/dev/null || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    t="$(kv_get "$line" type || true)"
    [ "$t" = "$type" ] || continue
    v="$(kv_get "$line" verdict || true)"
    if verdict_passing "$type" "$v"; then
      found=1
    else
      return 1
    fi
  done <<EOF
$entries
EOF
  [ "$found" -eq 1 ]
}

# _max_rank_for_type <abs-plan> <type>: print the strongest verdict rank among
# reviews entries for <type> (0 when none present).
_max_rank_for_type() {
  local file="$1" type="$2" entries line t v r max=0
  entries="$(review_entries "$file" 2>/dev/null || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    t="$(kv_get "$line" type || true)"
    [ "$t" = "$type" ] || continue
    v="$(kv_get "$line" verdict || true)"
    r="$(verdict_rank "$v")"
    if [ "$r" -gt "$max" ]; then max="$r"; fi
  done <<EOF
$entries
EOF
  printf '%s\n' "$max"
}

# --- Assertions ------------------------------------------------------------

cmd_assert_completable() {
  local file="$1" required missing=0 t
  [ -f "$file" ] || { echo "not completable: plan unreadable: $file" >&2; exit "$EXIT_GATE_NOT_COMPLETABLE"; }
  required="$(cmd_required "$file")"
  if [ -z "$required" ]; then
    echo "completable: no required reviews"
    exit 0
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if ! _type_cleared "$file" "$t"; then
      echo "not completable: review '$t' has no passing record" >&2
      missing=1
    fi
  done <<EOF
$required
EOF
  if [ "$missing" -ne 0 ]; then
    exit "$EXIT_GATE_NOT_COMPLETABLE"
  fi
  echo "completable: all required reviews recorded passing"
  exit 0
}

cmd_assert_no_downgrade() {
  local arg="$1" root rel abs head_file
  root="$(repo_root)"
  rel="$(_plan_relpath "$arg")" || die "cannot resolve plan: $arg"
  abs="$root/$rel"
  [ -f "$abs" ] || die "working-tree plan not found: $abs"

  head_file="$(mktemp "${TMPDIR:-/tmp}/review-gate-head-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$head_file'" EXIT
  if ! git show "HEAD:$rel" > "$head_file" 2>/dev/null; then
    echo "no-downgrade: no HEAD baseline for $rel (new plan) — nothing to downgrade from"
    exit 0
  fi

  local fail=0 line t hv hrank wrank
  local head_reviewed work_reviewed

  # 1. reviewed: true -> false (or gone).
  head_reviewed="$(fm_get "$head_file" reviewed 2>/dev/null || true)"
  work_reviewed="$(fm_get "$abs" reviewed 2>/dev/null || true)"
  if [ "$head_reviewed" = "true" ] && [ "$work_reviewed" != "true" ]; then
    echo "downgrade: reviewed flipped true -> '${work_reviewed:-absent}'" >&2
    fail=1
  fi

  # 2. reviews entries: no type's verdict rank may decrease (removal => rank 0).
  local head_entries
  head_entries="$(review_entries "$head_file" 2>/dev/null || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    t="$(kv_get "$line" type || true)"
    [ -n "$t" ] || continue
    hv="$(kv_get "$line" verdict || true)"
    hrank="$(verdict_rank "$hv")"
    wrank="$(_max_rank_for_type "$abs" "$t")"
    if [ "$wrank" -lt "$hrank" ]; then
      echo "downgrade: review '$t' weakened or removed ($hv -> working rank $wrank)" >&2
      fail=1
    fi
  done <<EOF
$head_entries
EOF

  # 3. review-required must not shrink: every HEAD-declared type stays declared.
  local head_req work_req present
  head_req="$(_raw_required "$head_file")"
  work_req="$(_raw_required "$abs")"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    present=0
    local w
    while IFS= read -r w; do
      [ "$w" = "$t" ] && { present=1; break; }
    done <<EOF
$work_req
EOF
    if [ "$present" -ne 1 ]; then
      echo "downgrade: review-required shrank — '$t' no longer declared" >&2
      fail=1
    fi
  done <<EOF
$head_req
EOF

  if [ "$fail" -ne 0 ]; then
    exit "$EXIT_GATE_DOWNGRADE"
  fi
  echo "no-downgrade: ok"
  exit 0
}

# cmd_assert_committed <plan-arg>: plan 037's "approved => committed"
# invariant. "Approved" here means "has >=1 recorded reviews: entry" (any
# type, any verdict — including changes-requested, which is still a recorded
# verdict that must not be lost) — NOT "gate reads cleared". A plan with no
# recorded verdict (needs-review: none, no review-required, or a legacy plan
# that was simply never reviewed) is exempt: authoring-only / review-pending
# plans are allowed to sit uncommitted by design. The invariant binds only
# once a verdict is recorded.
#
# Single-path check: only the plan file itself. .mstack/reviews/*.json is
# gitignored (.gitignore:6) and can never be committed or diffed against
# HEAD, so it is never part of this check (unlike the Design section's
# mention of a "record-path" — that path cannot participate in a git-based
# check by construction).
cmd_assert_committed() {
  local arg="$1" root rel abs entries dirty
  root="$(repo_root)"
  rel="$(_plan_relpath "$arg")" || die "cannot resolve plan: $arg"
  abs="$root/$rel"
  [ -f "$abs" ] || die "plan file not found: $abs"

  entries="$(review_entries "$abs" 2>/dev/null || true)"
  if [ -z "$entries" ]; then
    echo "exempt: no recorded review verdict on $rel — uncommitted state allowed"
    exit 0
  fi

  # Fail closed: if git status itself cannot be read (e.g. not a work tree),
  # do not treat that as "clean" — refuse just like a real dirty state.
  if ! dirty="$(git status --porcelain -- "$abs" 2>&1)"; then
    echo "not committed: could not read git status for $rel: $dirty" >&2
    exit "$EXIT_GATE_NOT_COMMITTED"
  fi
  if [ -n "$dirty" ]; then
    echo "not committed: $rel has a recorded review verdict but uncommitted changes (or is untracked) — commit the approval: git add $rel && git commit" >&2
    exit "$EXIT_GATE_NOT_COMMITTED"
  fi

  echo "committed: $rel has a recorded review verdict and is clean vs HEAD"
  exit 0
}

# --- Mutations -------------------------------------------------------------

cmd_record() {
  local arg="$1" type="$2" verdict="$3" by="${4:-mstack-review}"
  case "$type" in eng|design|ceo|code) ;; *) die "invalid review type: $type" ;; esac
  case "$verdict" in approved|changes-requested|pass|fail) ;; *) die "invalid verdict: $verdict" ;; esac
  # `by` becomes a token on the compact record line; restrict it to a safe
  # charset so it cannot inject a second `key=value` (e.g. a spurious verdict=).
  case "$by" in ''|*[!A-Za-z0-9._-]*) die "invalid by identifier (allowed: A-Za-z0-9._-): $by" ;; esac

  local root rel abs
  root="$(repo_root)"
  rel="$(_plan_relpath "$arg")" || die "cannot resolve plan: $arg"
  abs="$root/$rel"
  [ -f "$abs" ] || die "plan file not found: $abs"

  local date_str new_entry existing others="" replaced=0 line t
  date_str="$(date +%Y-%m-%d)"
  new_entry="type=$type verdict=$verdict date=$date_str by=$by"

  existing="$(review_entries "$abs" 2>/dev/null || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    t="$(kv_get "$line" type || true)"
    if [ "$t" = "$type" ]; then
      others="${others}${new_entry}
"
      replaced=1
    else
      others="${others}${line}
"
    fi
  done <<EOF
$existing
EOF
  if [ "$replaced" -eq 0 ]; then
    others="${others}${new_entry}
"
  fi

  local block e
  block="reviews:
"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    block="${block}  - ${e}
"
  done <<EOF
$others
EOF

  # Pass the multi-line block through a file: awk -v cannot carry literal
  # newlines portably (macOS awk errors "newline in string").
  local tmp blockfile
  tmp="$(mktemp "${TMPDIR:-/tmp}/review-gate-rec-XXXXXX")"
  blockfile="$(mktemp "${TMPDIR:-/tmp}/review-gate-blk-XXXXXX")"
  printf '%s' "$block" > "$blockfile"
  if awk -v bf="$blockfile" '
    BEGIN { fm=0; inr=0; printed=0 }
    {
      if ($0 ~ /^---[[:space:]]*$/) {
        fm++
        if (fm==2 && !printed) {
          while ((getline l < bf) > 0) print l
          close(bf)
          printed=1
        }
        print; next
      }
      if (fm==1) {
        if (inr) {
          if ($0 ~ /^[[:space:]]+-[[:space:]]/) next
          inr=0
        }
        if ($0 ~ /^reviews:/) { inr=1; next }
      }
      print
    }
  ' "$abs" > "$tmp"; then
    mv "$tmp" "$abs"
  else
    rm -f "$tmp" "$blockfile"
    die "record: failed to rewrite $rel"
  fi
  rm -f "$blockfile"
  echo "recorded: $type=$verdict on $rel"
}

_backfill_one() {
  local abs="$1" rr nr tokens tmp
  [ -f "$abs" ] || { warn "not found: $abs"; return 1; }
  rr="$(fm_get "$abs" review-required 2>/dev/null || true)"
  if [ -n "$rr" ]; then
    info "skip (review-required already present): $abs"
    return 0
  fi
  nr="$(fm_get "$abs" needs-review 2>/dev/null || true)"
  tokens="$(_types_of "$nr" | tr '\n' ',' | sed 's/,$//')"
  if [ -z "$tokens" ]; then
    info "skip (nothing flagged in needs-review): $abs"
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/review-gate-bf-XXXXXX")"
  awk -v val="$tokens" '
    BEGIN { fm=0; done=0 }
    {
      if ($0 ~ /^---[[:space:]]*$/) {
        fm++
        if (fm==2 && !done) { print "review-required: " val; done=1 }
        print; next
      }
      print
    }
  ' "$abs" > "$tmp" && mv "$tmp" "$abs"
  info "backfilled review-required: $tokens -> $abs"
}

cmd_backfill() {
  if [ "${1:-}" = "--all" ]; then
    local pdir f
    pdir="$(plans_dir)" || die "no plans dir"
    for f in "$pdir"/*.md; do
      [ -f "$f" ] || continue
      _backfill_one "$f" || true
    done
    return 0
  fi
  [ -n "${1:-}" ] || usage "backfill <plan> | --all"
  local root rel abs
  root="$(repo_root)"
  rel="$(_plan_relpath "$1")" || die "cannot resolve plan: $1"
  abs="$root/$rel"
  _backfill_one "$abs"
}

# --- Dispatch --------------------------------------------------------------

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || usage
  shift
  case "$cmd" in
    required)
      [ $# -ge 1 ] || usage "required <plan>"
      cmd_required "$(_read_target "$1")"
      ;;
    cleared)
      [ $# -ge 2 ] || usage "cleared <plan> <type>"
      if _type_cleared "$(_read_target "$1")" "$2"; then
        echo "cleared: $2"
      else
        echo "not cleared: $2" >&2
        exit "$EXIT_GATE_NOT_COMPLETABLE"
      fi
      ;;
    assert-completable)
      [ $# -ge 1 ] || usage "assert-completable <plan>"
      cmd_assert_completable "$(_read_target "$1")"
      ;;
    assert-no-downgrade)
      [ $# -ge 1 ] || usage "assert-no-downgrade <plan>"
      cmd_assert_no_downgrade "$1"
      ;;
    assert-committed)
      [ $# -ge 1 ] || usage "assert-committed <plan>"
      cmd_assert_committed "$1"
      ;;
    record)
      [ $# -ge 3 ] || usage "record <plan> <type> <verdict> [by]"
      cmd_record "$@"
      ;;
    backfill)
      cmd_backfill "$@"
      ;;
    *)
      usage "unknown subcommand: $cmd"
      ;;
  esac
}

main "$@"
