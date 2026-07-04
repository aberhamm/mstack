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
#   assert-work-committed <plan> exit 0 iff the working tree carries no
#                                plan-attributable dirt at completion time:
#                                (current porcelain set) minus the persisted
#                                `.mstack/pre-dirty-<id>.txt` baseline is empty.
#                                Both sides normalized by lib.sh porcelain_paths
#                                (`-uall -z`, rename/space/untracked-safe). Fail
#                                closed (EXIT_GATE_WORK_UNCOMMITTED) when the
#                                baseline file is absent or git status is
#                                unreadable — cannot verify => not completable.
#                                Pre-existing baseline paths for files the plan
#                                did not touch are allowed and never force-added.
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
  echo "usage: review-gate.sh <required|cleared|assert-completable|assert-no-downgrade|assert-committed|assert-work-committed|assert-hook-installed|audit|record|backfill|hook-pre-commit|hook-pre-push> ..." >&2
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

# _completable_check <abs-file>: return 0 iff every required review for the
# plan CONTENT in <abs-file> has a passing record. Prints "not completable ..."
# reasons to stderr on failure. Does NOT exit the process, so callers that must
# evaluate several plans in one invocation (the pre-commit hook) can reuse it.
_completable_check() {
  local file="$1" required missing=0 t
  [ -f "$file" ] || { echo "not completable: plan unreadable: $file" >&2; return 1; }
  required="$(cmd_required "$file")"
  [ -n "$required" ] || return 0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if ! _type_cleared "$file" "$t"; then
      echo "not completable: review '$t' has no passing record" >&2
      missing=1
    fi
  done <<EOF
$required
EOF
  return "$missing"
}

cmd_assert_completable() {
  local file="$1"
  if _completable_check "$file"; then
    echo "completable: all required reviews recorded passing (or none required)"
    exit 0
  fi
  exit "$EXIT_GATE_NOT_COMPLETABLE"
}

# _no_downgrade_between <head-file> <new-file>: return 0 iff <new-file> does
# not weaken the recorded review state versus <head-file>; return 1 (printing
# the reasons to stderr) if it does. Both arguments are readable plan files.
# Factored out so both cmd_assert_no_downgrade (working tree vs HEAD) and the
# pre-commit hook (STAGED content vs HEAD) share one implementation.
_no_downgrade_between() {
  local head_file="$1" new_file="$2"
  local fail=0 line t hv hrank wrank
  local head_reviewed new_reviewed

  # 1. reviewed: true -> false (or gone).
  head_reviewed="$(fm_get "$head_file" reviewed 2>/dev/null || true)"
  new_reviewed="$(fm_get "$new_file" reviewed 2>/dev/null || true)"
  if [ "$head_reviewed" = "true" ] && [ "$new_reviewed" != "true" ]; then
    echo "downgrade: reviewed flipped true -> '${new_reviewed:-absent}'" >&2
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
    wrank="$(_max_rank_for_type "$new_file" "$t")"
    if [ "$wrank" -lt "$hrank" ]; then
      echo "downgrade: review '$t' weakened or removed ($hv -> new rank $wrank)" >&2
      fail=1
    fi
  done <<EOF
$head_entries
EOF

  # 3. review-required must not shrink: every HEAD-declared type stays declared.
  local head_req new_req present
  head_req="$(_raw_required "$head_file")"
  new_req="$(_raw_required "$new_file")"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    present=0
    local w
    while IFS= read -r w; do
      [ "$w" = "$t" ] && { present=1; break; }
    done <<EOF
$new_req
EOF
    if [ "$present" -ne 1 ]; then
      echo "downgrade: review-required shrank — '$t' no longer declared" >&2
      fail=1
    fi
  done <<EOF
$head_req
EOF

  return "$fail"
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

  if _no_downgrade_between "$head_file" "$abs"; then
    echo "no-downgrade: ok"
    exit 0
  fi
  exit "$EXIT_GATE_DOWNGRADE"
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

# cmd_assert_work_committed <plan-arg>: plan 039's "done => declared work
# committed" invariant. At completion time the working tree must carry no
# plan-attributable dirt — every dirty/untracked path must already have been in
# the persisted baseline captured at plan start (mstack-run Step 3). The rule
# is exactly `(current porcelain set) minus baseline == empty`, with BOTH sides
# produced by the single lib.sh porcelain_paths normalizer so the sets are the
# same shape.
#
# Fail closed on every ambiguity: a missing baseline file (cannot verify what
# was pre-existing) or an unreadable git status both exit
# EXIT_GATE_WORK_UNCOMMITTED, never 0. Never auto-`git add` — this only
# reports; committing declared work product is the orchestrator's job (Step 7a).
# Pre-existing baseline paths for files the plan did not touch are allowed and
# never force-committed (they are in the baseline, so subtraction drops them).
cmd_assert_work_committed() {
  local arg="$1" root rel abs id id_num baseline cur line stray=""
  root="$(repo_root)"
  rel="$(_plan_relpath "$arg")" || die "cannot resolve plan: $arg"
  abs="$root/$rel"
  [ -f "$abs" ] || die "plan file not found: $abs"
  id="$(fm_get "$abs" id 2>/dev/null || true)"
  [ -n "$id" ] || die "cannot read plan id from $rel"
  id_num="$(normalize_id "$id")"
  baseline="$root/.mstack/pre-dirty-${id_num}.txt"

  # Missing baseline => cannot verify => fail closed.
  if [ ! -f "$baseline" ]; then
    echo "not committed: baseline $baseline is missing — cannot verify the tree was clean of plan work (fail closed). The Step-3 capture must have written it at plan start." >&2
    exit "$EXIT_GATE_WORK_UNCOMMITTED"
  fi

  # Unreadable git status => fail closed (porcelain_paths returns nonzero).
  if ! cur="$(porcelain_paths "$root")"; then
    echo "not committed: could not read git status for $root — cannot verify (fail closed)." >&2
    exit "$EXIT_GATE_WORK_UNCOMMITTED"
  fi

  # stray = current porcelain paths NOT present in the baseline set.
  # grep -x whole-line, -F fixed-string (paths are literals, not regex), -- so a
  # leading-dash path is not read as an option.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! grep -qxF -- "$line" "$baseline"; then
      stray="${stray}${line}
"
    fi
  done <<EOF
$cur
EOF

  if [ -n "$stray" ]; then
    echo "not committed: $rel left plan-attributable changes uncommitted at completion (not in the plan-start baseline):" >&2
    printf '%s' "$stray" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      echo "  $line" >&2
    done
    echo "Commit the declared work product (MODIFIED + CREATED + DELETED) before completing. Do NOT 'git add .' — stage only declared paths, then re-run." >&2
    exit "$EXIT_GATE_WORK_UNCOMMITTED"
  fi

  echo "work committed: $rel — no plan-attributable dirt beyond the plan-start baseline"
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

# --- Hook installation guard + audit (plan 038) ----------------------------

# _hooks_src_dir: absolute path of the hook scripts shipped with this skill
# (sibling of scripts/). This is the canonical source that mstack-init / setup
# copy into a consumer repo's .githooks/, and what assert-hook-installed
# compares the installed copy against for staleness.
_hooks_src_dir() {
  ( cd "$SCRIPT_DIR/.." 2>/dev/null && pwd ) && return 0
  return 1
}

_hook_install_hint() {
  echo "hook not installed: $1" >&2
  echo "install the mstack enforcement hooks (idempotent): run mstack-init in this repo, or ./setup from the mstack source repo. That sets git core.hooksPath to the tracked .githooks/ dir and installs pre-commit + pre-push." >&2
}

# cmd_assert_hook_installed: exit 0 iff core.hooksPath is set and the pre-commit
# + pre-push hooks exist there, are executable, and match the shipped source.
# Exit EXIT_GATE_HOOK_MISSING (with install instructions) otherwise. This is the
# startup guard mstack-run / mstack-plan-doctor call so an agent that removes or
# edits the hook is caught on the next run.
cmd_assert_hook_installed() {
  local root hp abs_hp src hook
  root="$(repo_root)"
  src="$(_hooks_src_dir 2>/dev/null || true)/hooks"
  hp="$(git -C "$root" config --get core.hooksPath 2>/dev/null || true)"
  if [ -z "$hp" ]; then
    _hook_install_hint "git core.hooksPath is unset in $root"
    exit "$EXIT_GATE_HOOK_MISSING"
  fi
  case "$hp" in
    /*) abs_hp="$hp" ;;
    *)  abs_hp="$root/$hp" ;;
  esac
  for hook in pre-commit pre-push; do
    if [ ! -f "$abs_hp/$hook" ]; then
      _hook_install_hint "hook '$hook' missing at $abs_hp"
      exit "$EXIT_GATE_HOOK_MISSING"
    fi
    if [ ! -x "$abs_hp/$hook" ]; then
      _hook_install_hint "hook '$hook' at $abs_hp is not executable"
      exit "$EXIT_GATE_HOOK_MISSING"
    fi
    # Staleness: exact compare against shipped source when it is readable.
    if [ -f "$src/$hook" ] && ! cmp -s "$abs_hp/$hook" "$src/$hook"; then
      _hook_install_hint "hook '$hook' at $abs_hp is stale (differs from the shipped source at $src/$hook)"
      exit "$EXIT_GATE_HOOK_MISSING"
    fi
  done
  echo "hook installed: core.hooksPath=$hp (pre-commit + pre-push current)"
  exit 0
}

# cmd_audit: scan every done/archived plan and flag any whose review-required
# types lack a passing reviews: record. Prints offenders to stdout and exits
# EXIT_GATE_AUDIT_FOUND; silent + exit 0 when all clean. This is the retroactive
# backstop that catches --no-verify / out-of-band completions the write-time
# hook never saw.
cmd_audit() {
  local pdir f status required t offenders="" found=0
  pdir="$(plans_dir 2>/dev/null)" || exit 0
  for f in "$pdir"/*.md "$pdir"/archive/*.md; do
    [ -f "$f" ] || continue
    status="$(fm_get "$f" status 2>/dev/null || true)"
    [ "$status" = "done" ] || continue
    required="$(cmd_required "$f")"
    [ -n "$required" ] || continue
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      if ! _type_cleared "$f" "$t"; then
        local id label
        id="$(fm_get "$f" id 2>/dev/null || true)"
        label="$(plan_label "$id" 2>/dev/null || true)"
        [ -n "$label" ] || label="${f##*/}"
        offenders="${offenders}  ${label} — missing passing record for review '$t'
"
        found=1
      fi
    done <<EOF
$required
EOF
  done
  if [ "$found" -ne 0 ]; then
    echo "audit: done/archived plans missing a required review record:"
    printf '%s' "$offenders"
    exit "$EXIT_GATE_AUDIT_FOUND"
  fi
  exit 0
}

# cmd_hook_pre_commit: the pre-commit barrier. For each STAGED plan file
# (git show :path — never the working tree), reject the commit when the staged
# content transitions status -> done while assert-completable fails, or weakens
# a recorded review state versus HEAD. Non-plan commits, claim commits
# (pending->in-progress), archive moves of a completable done plan, and
# empty-required-set completions all pass.
cmd_hook_pre_commit() {
  local root staged path rejected=0
  root="$(repo_root)"
  staged="$(git -C "$root" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"
  [ -n "$staged" ] || exit 0

  local tmp_staged tmp_head
  tmp_staged="$(mktemp "${TMPDIR:-/tmp}/rg-hook-staged-XXXXXX")"
  tmp_head="$(mktemp "${TMPDIR:-/tmp}/rg-hook-head-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_staged' '$tmp_head'" EXIT

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      docs/plans/*.md|plans/*.md) ;;
      *) continue ;;
    esac
    git -C "$root" show ":$path" > "$tmp_staged" 2>/dev/null || continue
    local staged_status head_status has_head=1
    staged_status="$(fm_get "$tmp_staged" status 2>/dev/null || true)"
    if git -C "$root" show "HEAD:$path" > "$tmp_head" 2>/dev/null; then
      head_status="$(fm_get "$tmp_head" status 2>/dev/null || true)"
    else
      : > "$tmp_head"; head_status=""; has_head=0
    fi

    # (a) done-transition: gate the STAGED content.
    if [ "$staged_status" = "done" ] && [ "$head_status" != "done" ]; then
      if ! _completable_check "$tmp_staged"; then
        echo "mstack pre-commit: refusing to mark $path done — review gate open." >&2
        rejected=1
      fi
    fi

    # (b) downgrade: staged weakens review state vs HEAD (skip brand-new plans).
    if [ "$has_head" -eq 1 ]; then
      if ! _no_downgrade_between "$tmp_head" "$tmp_staged"; then
        echo "mstack pre-commit: refusing $path — weakens a recorded review state." >&2
        rejected=1
      fi
    fi
  done <<EOF
$staged
EOF

  if [ "$rejected" -ne 0 ]; then
    {
      echo ""
      echo "Commit rejected by the mstack enforcement hook (plan 038)."
      echo "Record the missing review(s) via the named review skill (plan-eng-review /"
      echo "plan-design-review / plan-ceo-review through mstack-plan-doctor, or"
      echo "mstack-code-review for a code gate), then re-commit. Do not self-clear the gate."
    } >&2
    exit 1
  fi
  exit 0
}

# cmd_hook_pre_push: the remote barrier for completion tags. Reads the git
# pre-push ref lines from stdin and rejects a push that creates/updates a
# refs/tags/mstack/plan-*-done tag pointing at a plan that is not completable.
# All other refs (branches, other tags, tag deletions) pass untouched.
#
# Optional dirty-tree guard (plan 039): if any mstack/plan-*-done tag is being
# published while `git status` is dirty, reject as well. This is a BEST-EFFORT
# deterrent, NOT a guarantee: it is inherently TOCTOU (the tree can be dirtied
# again after the check) and `--no-verify`-bypassable like every local hook. It
# does not, and cannot, prove the tagged commit contains the plan's work — a
# pre-commit hook and the retroactive audit likewise CANNOT detect uncommitted
# work. The real enforcement is the mstack-run Step 7a honest-path
# `assert-work-committed` check; this guard only catches the obvious case of
# pushing a completion tag from a visibly dirty tree.
cmd_hook_pre_push() {
  local root local_sha remote_ref rejected=0 saw_done_tag=0
  root="$(repo_root)"
  while read -r _local_ref local_sha remote_ref _remote_sha; do
    [ -n "${remote_ref:-}" ] || continue
    case "$remote_ref" in
      refs/tags/mstack/plan-*-done) ;;
      *) continue ;;
    esac
    # Deletion (local_sha all zeros) => nothing to validate.
    case "$local_sha" in
      *[!0]*) ;;
      *) continue ;;
    esac
    saw_done_tag=1
    local tagname id rel abs
    tagname="${remote_ref#refs/tags/}"
    id="${tagname#mstack/plan-}"
    id="${id%-done}"
    if ! rel="$(plan_file_for_id "$id" 2>/dev/null)"; then
      echo "mstack pre-push: tag $tagname references plan $id but no plan file was found — refusing (cannot verify completion)." >&2
      rejected=1
      continue
    fi
    abs="$root/$rel"
    if ! _completable_check "$abs"; then
      echo "mstack pre-push: tag $tagname points at a plan that is not completable — refusing to publish a completion tag without recorded reviews." >&2
      rejected=1
    fi
  done
  # Best-effort dirty-tree guard: a completion tag push from a dirty tree is
  # rejected. TOCTOU + --no-verify-able (see header) — a deterrent, not a proof.
  if [ "$saw_done_tag" -eq 1 ]; then
    local dirty
    if dirty="$(git -C "$root" status --porcelain 2>/dev/null)" && [ -n "$dirty" ]; then
      echo "mstack pre-push: refusing to publish a completion tag while the working tree is dirty (best-effort guard — TOCTOU and --no-verify-bypassable). Commit or stash the changes, then push." >&2
      rejected=1
    fi
  fi
  if [ "$rejected" -ne 0 ]; then
    echo "" >&2
    echo "Push rejected by the mstack enforcement hook (plan 038): one or more completion tags fail the review gate." >&2
    exit 1
  fi
  exit 0
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
    assert-work-committed)
      [ $# -ge 1 ] || usage "assert-work-committed <plan>"
      cmd_assert_work_committed "$1"
      ;;
    assert-hook-installed)
      cmd_assert_hook_installed
      ;;
    audit)
      cmd_audit
      ;;
    hook-pre-commit)
      cmd_hook_pre_commit
      ;;
    hook-pre-push)
      cmd_hook_pre_push
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
