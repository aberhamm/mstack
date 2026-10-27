#!/usr/bin/env bash
# waiver.sh — human-approved health-gate waivers (plan 099).
#
# A plan whose repo fails the health gate for reasons the plan did not cause
# could never complete; the only way out was hand-writing `status: done`,
# which the completion gate and the plan-038 hooks exist to stop. A waiver is
# the sanctioned override: per plan, per health category, approved by someone
# on a committed approvers list, and honoured only when git history shows it
# was in place BEFORE the plan was claimed.
#
# Record (plan frontmatter, one entry per line, values never contain spaces):
#
#   waivers:
#     - category=shell mode=baseline-delta approver=matthew date=2026-10-27 expires=2026-11-10 ref=mdec-1027-x reason=dev.sh_pre-existing
#     - category=lint mode=blanket approver=matthew date=2026-10-27 expires=2026-11-10 ref=mdec-1027-x reason=pre-existing fallback=no-lint-extractor
#
# Approvers: the TRACKED file <plans dir>/waivers/APPROVERS, one token per line,
# `#` comments. `agent` and `mstack-*` are never approvers. Nothing is read from
# the gitignored .mstack/ config (plan 043: a declaration there is per-checkout
# and invisible to review).
#
# History rule (all must hold; first failure is reported, exit 40):
#   (a) the repo is not shallow and the plan's `git log --follow` is readable;
#   (b) the entry line is present at the tip and unchanged from its introducing
#       commit W (newest commit in the plan's history containing the line whose
#       predecessor does not) to the tip;
#   (c) W is neither a merge nor a root commit (a merge that is a fast-forward
#       for the plan file is looked through to the side branch's commits; see
#       _history_load);
#   (d) the approver is listed in APPROVERS at W^ AND at the tip;
#   (e) the latest claim commit C exists and W is a strict ancestor of C;
#   (f) `expires` is on or after the evaluation date, and `date` is no more
#       than one day after W's committer date (UTC) — no future-dating;
#   (g) baseline-delta only: the baseline exists at W, is byte-identical at the
#       tip, its base-commit is a full commit sha that is an ancestor of W^,
#       and its extractor is the one this script ships for the category.
#
# Honest residual: there are no signatures. An agent with a shell can add
# itself to APPROVERS, commit a waiver, then claim, in three commits. What this
# buys is that a waiver is deliberate, sits in history, and is listed by the
# audit with its approver and ref — deterrent plus detectable, like plan 038.
#
# Subcommands:
#   check <plan> <category> [--tip <rev>] [--date YYYY-MM-DD]
#   evaluate <plan> <category> <full-output-file> <exit-code>
#   assert-delta <plan> <category>
#   waive <plan> <category> <mode> <approver> <expires> <ref> <reason> [fallback]
#   capture-baseline <plan> <category>
#   extract <category> [file]          (prints identity<TAB>count)
#   hook-check <staged-plan-file> <head-path>
#   audit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

WAIVER_CATEGORIES="typecheck lint test e2e deadcode shell"
WAIVER_KEYS="category mode approver date expires ref reason fallback"
WAIVER_MAX_DAYS=30
V_ERR=""

ROOT="$(repo_root)"

WTMP="$(mktemp -d "${TMPDIR:-/tmp}/mstack-waiver-XXXXXX")"
# shellcheck disable=SC2064
trap "rm -rf '$WTMP'" EXIT

usage() {
  echo "usage: waiver.sh <check|evaluate|assert-delta|waive|capture-baseline|extract|hook-check|audit> ..." >&2
  [ -n "${1:-}" ] && echo "  $1" >&2
  exit 1
}

# --- Small helpers ----------------------------------------------------------

_git() { git -C "$ROOT" "$@"; }

# The extractor this script ships for a category. Empty for categories with no
# parseable failure identity (lint/test/e2e/deadcode: blanket only).
_extractor_for() {
  case "$1" in
    typecheck) echo "tsc-v1" ;;
    shell)     echo "shellcheck-v1" ;;
    *)         echo "" ;;
  esac
}

_plans_rel() {
  local pdir
  pdir="$(plans_dir)" || return 1
  printf '%s\n' "${pdir#"$ROOT"/}"
}

_approvers_rel() { printf '%s/waivers/APPROVERS\n' "$(_plans_rel)"; }

_baseline_rel() {  # <plan-id> <category>
  printf '%s/waivers/%s-%s.baseline\n' "$(_plans_rel)" "$1" "$2"
}

# _plan_rel <arg>: repo-relative path of a plan given a path or an id/ref.
_plan_rel() {
  local arg="$1" abs out id
  if [ -f "$arg" ]; then
    # Physical paths on both sides: TMPDIR on macOS is a symlink
    # (/var -> /private/var), and git reports the resolved toplevel.
    local proot
    abs="$(cd "$(dirname "$arg")" && pwd -P)/$(basename "$arg")"
    proot="$(cd "$ROOT" && pwd -P)"
    printf '%s\n' "${abs#"$proot"/}"
    return 0
  fi
  out="$(resolve_plan_ref "$arg")" || return 1
  id="${out%% *}"
  plan_file_for_id "$id"
}

# _epoch <YYYY-MM-DD>: UTC midnight epoch; nonzero for anything not a real date.
_epoch() {
  local d="$1" e back
  case "$d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  if e="$(date -u -j -f '%Y-%m-%d %H:%M:%S' "$d 00:00:00" +%s 2>/dev/null)"; then
    back="$(date -u -j -f %s "$e" +%Y-%m-%d 2>/dev/null)" || return 1
  elif e="$(date -u -d "$d" +%s 2>/dev/null)"; then
    back="$(date -u -d "@$e" +%Y-%m-%d 2>/dev/null)" || return 1
  else
    return 1
  fi
  # Round-trip: rejects 2026-02-30 that a lenient parser would normalize.
  [ "$back" = "$d" ] || return 1
  printf '%s\n' "$e"
}

# Status scalar from plan content on stdin.
_fm_status_stdin() {
  awk '
    /^---[[:space:]]*$/ { fm++; next }
    fm==1 && /^status:/ { sub(/^status:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }
    fm==2 { exit }
  '
}

_fm_id_stdin() {
  awk '
    /^---[[:space:]]*$/ { fm++; next }
    fm==1 && /^id:/ { sub(/^id:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }
    fm==2 { exit }
  '
}

# waiver_payloads [file]: each `waivers:` entry's key=value payload, one per
# line (modelled on lib.sh review_entries; that function is not modified).
waiver_payloads() {
  awk '
    /^---[[:space:]]*$/ { fm++; if (fm==2) exit; next }
    fm==1 {
      if (inw) {
        if ($0 ~ /^[[:space:]]+-[[:space:]]/) {
          line=$0
          sub(/^[[:space:]]*-[[:space:]]*/, "", line)
          sub(/[[:space:]]+$/, "", line)
          print line
          next
        }
        inw=0
      }
      if ($0 ~ /^waivers:/) { inw=1; next }
    }
  ' "${1:--}"
}

# The raw `waivers:` block (header + entry lines), for byte-identity checks.
_waivers_block() {
  awk '
    /^---[[:space:]]*$/ { fm++; if (fm==2) exit; next }
    fm==1 {
      if (inw) {
        if ($0 ~ /^[[:space:]]+-[[:space:]]/) { print; next }
        inw=0
      }
      if ($0 ~ /^waivers:/) { inw=1; print; next }
    }
  ' "${1:--}"
}

_has_payload() {  # <content-file> <payload>
  waiver_payloads "$1" | grep -Fxq -- "$2"
}

# --- Structural validation -------------------------------------------------

# _parse_payload <payload>: set V_<key> globals. Returns nonzero with V_ERR set.
_parse_payload() {
  local payload="$1" tok k v seen=" "
  V_category=""; V_mode=""; V_approver=""; V_date=""; V_expires=""
  V_ref=""; V_reason=""; V_fallback=""; V_has_fallback=0; V_ERR=""
  set -f
  for tok in $payload; do
    case "$tok" in
      *=*) ;;
      *) set +f; V_ERR="malformed token '$tok' (expected key=value)"; return 1 ;;
    esac
    k="${tok%%=*}"; v="${tok#*=}"
    case " $WAIVER_KEYS " in
      *" $k "*) ;;
      *) set +f; V_ERR="unknown key '$k'"; return 1 ;;
    esac
    case "$seen" in
      *" $k "*) set +f; V_ERR="duplicate key '$k'"; return 1 ;;
    esac
    seen="$seen$k "
    [ -n "$v" ] || { set +f; V_ERR="empty value for '$k'"; return 1; }
    # shellcheck disable=SC2034  # reason/fallback are parsed for validation only
    case "$k" in
      category) V_category="$v" ;;
      mode)     V_mode="$v" ;;
      approver) V_approver="$v" ;;
      date)     V_date="$v" ;;
      expires)  V_expires="$v" ;;
      ref)      V_ref="$v" ;;
      reason)   V_reason="$v" ;;
      fallback) V_fallback="$v"; V_has_fallback=1 ;;
    esac
  done
  set +f
  local req
  for req in category mode approver date expires ref reason; do
    case "$seen" in
      *" $req "*) ;;
      *) V_ERR="missing required key '$req'"; return 1 ;;
    esac
  done
  case " $WAIVER_CATEGORIES " in
    *" $V_category "*) ;;
    *) V_ERR="unknown category '$V_category'"; return 1 ;;
  esac
  case "$V_mode" in
    baseline-delta)
      [ "$V_has_fallback" -eq 0 ] || { V_ERR="fallback is only allowed with mode=blanket"; return 1; }
      [ -n "$(_extractor_for "$V_category")" ] \
        || { V_ERR="baseline-delta is not available for '$V_category' (no failure-identity extractor); use blanket"; return 1; }
      ;;
    blanket)
      [ "$V_has_fallback" -eq 1 ] || { V_ERR="mode=blanket requires fallback= (why baseline-delta was not used)"; return 1; }
      ;;
    *) V_ERR="unknown mode '$V_mode' (baseline-delta|blanket)"; return 1 ;;
  esac
  _approver_token_ok "$V_approver" || { V_ERR="approver '$V_approver' is not a valid approver token"; return 1; }
  local de ee
  de="$(_epoch "$V_date")" || { V_ERR="date '$V_date' is not a YYYY-MM-DD date"; return 1; }
  ee="$(_epoch "$V_expires")" || { V_ERR="expires '$V_expires' is not a YYYY-MM-DD date"; return 1; }
  [ "$ee" -ge "$de" ] || { V_ERR="expires $V_expires is before date $V_date"; return 1; }
  [ $(( (ee - de) / 86400 )) -le "$WAIVER_MAX_DAYS" ] \
    || { V_ERR="expires $V_expires is more than $WAIVER_MAX_DAYS days after date $V_date"; return 1; }
  return 0
}

_approver_token_ok() {
  local t="$1"
  printf '%s' "$t" | grep -Eq '^[a-z][a-z0-9._-]*$' || return 1
  [ "$t" != "agent" ] || return 1
  case "$t" in mstack-*) return 1 ;; esac
  return 0
}

# _approver_listed <token> <approvers-content-file>
_approver_listed() {
  local t="$1" f="$2"
  _approver_token_ok "$t" || return 1
  [ -s "$f" ] || return 1
  sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f" | grep -Fxq -- "$t"
}

# _entry_for <content-file> <category>: print the single payload for the
# category. 1 = no entry; 2 = invalid block (the reason is printed instead:
# callers capture stdout in a subshell, so a global would be lost).
_entry_for() {
  local f="$1" cat="$2" p pc tok found="" n=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    pc=""
    set -f
    for tok in $p; do case "$tok" in category=*) pc="${tok#category=}" ;; esac; done
    set +f
    case " $WAIVER_CATEGORIES " in
      *" $pc "*) ;;
      *) printf '%s\n' "waivers: entry without a known category: '$p'"; return 2 ;;
    esac
    if [ "$pc" = "$cat" ]; then n=$((n + 1)); found="$p"; fi
  done < <(waiver_payloads "$f")
  [ "$n" -gt 0 ] || return 1
  [ "$n" -eq 1 ] || { printf '%s\n' "duplicate waivers: entries for category '$cat'"; return 2; }
  printf '%s\n' "$found"
}

# --- Failure-identity extractors (versioned) --------------------------------
#
# Line numbers are ignored: an edit above an old error must not turn it into a
# "new" one. The comparison is a multiset, so a second instance of a known
# error IS new. Changing an extractor's behaviour requires a new version tag:
# a baseline written by another version is non-comparable (fail closed).

_extract_tsc_v1() {
  awk '
    { gsub(/\033\[[0-9;]*m/, "") }
    match($0, /\([0-9]+,[0-9]+\): error TS[0-9]+:/) {
      f = substr($0, 1, RSTART - 1); r = substr($0, RSTART)
      sub(/^[[:space:]]+/, "", f)
      if (f != "" && match(r, /TS[0-9]+/)) print f "|" substr(r, RSTART, RLENGTH)
      next
    }
    match($0, /:[0-9]+:[0-9]+ - error TS[0-9]+:/) {
      f = substr($0, 1, RSTART - 1); r = substr($0, RSTART)
      sub(/^[[:space:]]+/, "", f)
      if (f != "" && match(r, /TS[0-9]+/)) print f "|" substr(r, RSTART, RLENGTH)
    }
  ' "${1:--}"
}

_extract_shellcheck_v1() {
  awk '
    /^In .+ line [0-9]+:[[:space:]]*$/ {
      f = $0; sub(/^In /, "", f); sub(/ line [0-9]+:[[:space:]]*$/, "", f); next
    }
    /^For more information:/ { f = ""; next }
    f != "" {
      s = $0
      while (match(s, /\^[-^]*[ ]+SC[0-9]+/)) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        if (match(m, /SC[0-9]+/)) print f "|" substr(m, RSTART, RLENGTH)
      }
    }
  ' "${1:--}"
}

# _extract <extractor> [file]: identity<TAB>count, sorted.
_extract() {
  local ex="$1" src="${2:--}"
  case "$ex" in
    tsc-v1)        _extract_tsc_v1 "$src" ;;
    shellcheck-v1) _extract_shellcheck_v1 "$src" ;;
    *) return 1 ;;
  esac | LC_ALL=C sort | LC_ALL=C uniq -c | awk '{ c=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]/, ""); print $0 "\t" c }'
}

# Header value from a baseline file.
_baseline_header() {  # <file> <key>
  awk -v k="$2" 'index($0, "\t") == 0 && index($0, k ": ") == 1 { sub("^" k ": ", ""); print; exit }' "$1"
}

_baseline_identities() { awk 'index($0, "\t") > 0' "$1"; }

# _multiset_new <baseline-ids> <head-ids>: print head identities whose count
# exceeds the baseline count, as "identity<TAB>head<TAB>base".
_multiset_new() {
  awk -F '\t' '
    NR == FNR { base[$1] = $2; next }
    { b = ($1 in base) ? base[$1] : 0; if ($2 + 0 > b + 0) print $1 "\t" $2 "\t" b }
  ' "$1" "$2"
}

# --- History rule ------------------------------------------------------------

# _history_load <tip> <path>: newest-first H_SHA[] / H_PATH[] of commits that
# touched the plan (following renames). Nonzero when unreadable or empty.
#
# --follow alone silently drops merge commits, so a waiver introduced by a
# merge would be attributed to some later commit. `-m --first-parent` lists a
# merge (diffed against its first parent) so rule (c) can see and refuse it.
#
# A first-parent walk alone, though, attributes everything a side branch did to
# the merge that brought it in, so a waiver committed (and claimed) properly on
# a branch merged with --no-ff would look merge-introduced. A merge is therefore
# SPLICED — replaced by the side branch's own commits — when, for the plan
# file, it is equivalent to a fast-forward: exactly one non-first parent P has
# the merge's blob, P and the first parent have a single merge base, and the
# first parent's blob is unchanged since that base. Any other merge that
# changed the plan (an evil merge, a two-sided edit, an octopus with two
# matching sides) stays in the list as itself, and rule (c) refuses it when it
# is W: fail closed on ambiguity.
_history_load() {
  H_SHA=(); H_PATH=()
  _hist_walk "$1" "" "$2" 0 || return 1
  [ "${#H_SHA[@]}" -gt 0 ]
}

_blob_at() { _git rev-parse -q --verify "$1:$2" 2>/dev/null || true; }

# _merge_side <merge> <path>: print the single side parent to splice, if any.
_merge_side() {
  local m="$1" path="$2" parents p1 mb b side="" nside=0 bases
  parents="$(_git rev-list --parents -n 1 "$m" 2>/dev/null)" || return 0
  set -f
  # shellcheck disable=SC2086
  set -- $parents
  set +f
  shift
  p1="$1"; shift
  mb="$(_blob_at "$m" "$path")"
  for b in "$@"; do
    if [ "$(_blob_at "$b" "$path")" = "$mb" ]; then side="$b"; nside=$((nside + 1)); fi
  done
  [ "$nside" -eq 1 ] || return 0
  bases="$(_git merge-base --all "$p1" "$side" 2>/dev/null)" || return 0
  [ -n "$bases" ] && [ "$(printf '%s\n' "$bases" | wc -l | tr -d ' ')" -eq 1 ] || return 0
  [ "$(_blob_at "$bases" "$path")" = "$(_blob_at "$p1" "$path")" ] || return 0
  printf '%s\n' "$side"
}

# _hist_walk <tip> <excludes> <path> <depth>: append the first-parent history of
# <tip> (minus commits reachable from the space-separated <excludes>), splicing
# fast-forward-equivalent merges recursively.
_hist_walk() {
  local tip="$1" excl="$2" path="$3" depth="$4" out line sha="" last="$3" i side x
  local -a shas=() paths=() neg=()
  [ "$depth" -le 32 ] || return 1
  for x in $excl; do neg+=("^$x"); done
  out="$(_git log --follow -m --first-parent --format='%x01%H' --name-only "$tip" ${neg[@]+"${neg[@]}"} -- "$path" 2>/dev/null)" || return 1
  # Defensive: a commit that prints no path keeps the newer entry's path.
  while IFS= read -r line; do
    case "$line" in
      $'\001'*)
        if [ -n "$sha" ]; then shas+=("$sha"); paths+=("$last"); fi
        sha="${line#$'\001'}" ;;
      "") ;;
      *)
        if [ -n "$sha" ]; then shas+=("$sha"); paths+=("$line"); last="$line"; sha=""; fi
        ;;
    esac
  done <<< "$out"
  if [ -n "$sha" ]; then shas+=("$sha"); paths+=("$last"); fi
  for ((i = 0; i < ${#shas[@]}; i++)); do
    side=""
    _is_merge "${shas[$i]}" && side="$(_merge_side "${shas[$i]}" "${paths[$i]}")"
    if [ -n "$side" ]; then
      _hist_walk "$side" "$excl ${shas[$i]}^1" "${paths[$i]}" $((depth + 1)) || return 1
      continue
    fi
    H_SHA+=("${shas[$i]}"); H_PATH+=("${paths[$i]}")
  done
}

# _hist_content <i>: path of a cached file holding the plan content at H_SHA[i].
_hist_content() {
  local i="$1" f="$WTMP/h.$1"
  if [ ! -f "$f" ]; then
    _git show "${H_SHA[$i]}:${H_PATH[$i]}" > "$f" 2>/dev/null || : > "$f"
  fi
  printf '%s\n' "$f"
}

_hist_status() { _fm_status_stdin < "$(_hist_content "$1")"; }

# _claims: newest-first list of claim commits (status becomes in-progress).
_claims() {
  local i n="${#H_SHA[@]}" st prev
  for ((i = 0; i < n; i++)); do
    st="$(_hist_status "$i")"
    [ "$st" = "in-progress" ] || continue
    prev=""
    [ $((i + 1)) -lt "$n" ] && prev="$(_hist_status $((i + 1)))"
    [ "$prev" = "in-progress" ] || printf '%s\n' "${H_SHA[$i]}"
  done
}

_is_merge() {
  local parents
  parents="$(_git rev-list --parents -n 1 "$1" 2>/dev/null)" || return 0
  set -f
  # shellcheck disable=SC2086
  set -- $parents
  set +f
  [ "$#" -gt 2 ]
}

_has_parent() { _git rev-parse -q --verify "$1^" >/dev/null 2>&1; }

# _check_entry <tip> <path> <category> <eval-date>
# Sets W_SHA, W_MODE, W_APPROVER, W_REF, W_RECLAIMED on success. On failure
# returns nonzero with FAIL_RULE / FAIL_MSG.
_check_entry() {
  local tip="$1" path="$2" cat="$3" evald="$4"
  FAIL_RULE=""; FAIL_MSG=""; W_SHA=""; W_MODE=""; W_APPROVER=""; W_REF=""; W_RECLAIMED=0

  # (a) history readable, not shallow.
  local shallow
  shallow="$(_git rev-parse --is-shallow-repository 2>/dev/null || echo unknown)"
  if [ "$shallow" != "false" ]; then
    FAIL_RULE="a"; FAIL_MSG="repository is shallow or unreadable (is-shallow-repository=$shallow); cannot verify"; return 1
  fi
  local tipc="$WTMP/tip.content"
  if ! _git show "$tip:$path" > "$tipc" 2>/dev/null; then
    FAIL_RULE="b"; FAIL_MSG="plan $path does not exist at $tip"; return 1
  fi
  rm -f "$WTMP"/h.*
  if ! _history_load "$tip" "$path"; then
    FAIL_RULE="a"; FAIL_MSG="git log --follow for $path is unreadable or empty"; return 1
  fi

  # Structural.
  local payload rc=0
  payload="$(_entry_for "$tipc" "$cat")" || rc=$?
  if [ "$rc" -eq 1 ]; then FAIL_RULE="b"; FAIL_MSG="no committed waivers: entry for '$cat' at $tip"; return 1; fi
  if [ "$rc" -ne 0 ]; then FAIL_RULE="s"; FAIL_MSG="$payload"; return 1; fi
  if ! _parse_payload "$payload"; then FAIL_RULE="s"; FAIL_MSG="$V_ERR"; return 1; fi
  W_MODE="$V_mode"; W_APPROVER="$V_approver"; W_REF="$V_ref"

  # (b) W: walk newest-first while the line is present.
  local n="${#H_SHA[@]}" i=0
  if ! _has_payload "$(_hist_content 0)" "$payload"; then
    FAIL_RULE="b"; FAIL_MSG="entry is not in the newest committed version of $path"; return 1
  fi
  while [ $((i + 1)) -lt "$n" ] && _has_payload "$(_hist_content $((i + 1)))" "$payload"; do
    i=$((i + 1))
  done
  W_SHA="${H_SHA[$i]}"

  # (c) W is not a merge and not a root.
  if _is_merge "$W_SHA"; then FAIL_RULE="c"; FAIL_MSG="introducing commit ${W_SHA:0:7} is a merge commit"; return 1; fi
  if ! _has_parent "$W_SHA"; then FAIL_RULE="c"; FAIL_MSG="introducing commit ${W_SHA:0:7} is a root commit"; return 1; fi

  # (d) approver listed at W^ and at the tip.
  local arel apre="$WTMP/appr.pre" atip="$WTMP/appr.tip"
  arel="$(_approvers_rel)" || { FAIL_RULE="d"; FAIL_MSG="no plans directory"; return 1; }
  _git show "$W_SHA^:$arel" > "$apre" 2>/dev/null || : > "$apre"
  _git show "$tip:$arel" > "$atip" 2>/dev/null || : > "$atip"
  if ! _approver_listed "$V_approver" "$apre"; then
    FAIL_RULE="d"; FAIL_MSG="approver '$V_approver' is not in $arel at ${W_SHA:0:7}^ (the approver must be listed before the waiver commit)"; return 1
  fi
  if ! _approver_listed "$V_approver" "$atip"; then
    FAIL_RULE="d"; FAIL_MSG="approver '$V_approver' is no longer in $arel at $tip (revoked)"; return 1
  fi

  # (e) W strict ancestor of the latest claim commit.
  local claims c
  claims="$(_claims)"
  c="$(printf '%s\n' "$claims" | sed -n 1p)"
  if [ -z "$c" ]; then FAIL_RULE="e"; FAIL_MSG="no claim commit (status -> in-progress) in the history of $path"; return 1; fi
  if [ "$W_SHA" = "$c" ] || ! _git merge-base --is-ancestor "$W_SHA" "$c" 2>/dev/null; then
    FAIL_RULE="e"; FAIL_MSG="waiver commit ${W_SHA:0:7} is not strictly before the latest claim ${c:0:7}"; return 1
  fi
  local older
  while IFS= read -r older; do
    [ -n "$older" ] && [ "$older" != "$c" ] || continue
    if [ "$older" = "$W_SHA" ] || _git merge-base --is-ancestor "$older" "$W_SHA" 2>/dev/null; then
      W_RECLAIMED=1
    fi
  done <<< "$claims"

  # (f) not expired, and not future-dated: `date` may be at most one day after
  # W's committer date (UTC; the day of slack absorbs a local-time date written
  # east of UTC), so the 30-day cap on expires-date cannot be stretched by
  # dating the entry ahead of the commit that introduced it.
  if [[ "$V_expires" < "$evald" ]]; then
    FAIL_RULE="f"; FAIL_MSG="waiver expired $V_expires (evaluated at $evald)"; return 1
  fi
  local wday wde de
  wday="$(TZ=UTC0 _git log -1 --format=%cd --date=format-local:%Y-%m-%d "$W_SHA" 2>/dev/null || true)"
  if ! wde="$(_epoch "$wday")" || ! de="$(_epoch "$V_date")"; then
    FAIL_RULE="f"; FAIL_MSG="cannot read the committer date of ${W_SHA:0:7}"; return 1
  fi
  if [ "$de" -gt $((wde + 86400)) ]; then
    FAIL_RULE="f"; FAIL_MSG="date $V_date is after the waiver commit ${W_SHA:0:7} ($wday): a waiver may not be future-dated"; return 1
  fi

  # (g) baseline provenance.
  if [ "$V_mode" = "baseline-delta" ]; then
    local id brel bw bt bfile="$WTMP/baseline" base
    id="$(_fm_id_stdin < "$tipc")"
    brel="$(_baseline_rel "$id" "$cat")"
    if ! bw="$(_git rev-parse -q --verify "$W_SHA:$brel" 2>/dev/null)"; then
      FAIL_RULE="g"; FAIL_MSG="baseline $brel does not exist at waiver commit ${W_SHA:0:7}"; return 1
    fi
    bt="$(_git rev-parse -q --verify "$tip:$brel" 2>/dev/null || true)"
    if [ "$bw" != "$bt" ]; then
      FAIL_RULE="g"; FAIL_MSG="baseline $brel changed after waiver commit ${W_SHA:0:7}"; return 1
    fi
    _git show "$tip:$brel" > "$bfile" 2>/dev/null || : > "$bfile"
    base="$(_baseline_header "$bfile" base-commit)"
    # A full object name only: a rev expression (HEAD~2, a branch) would be
    # resolved against whatever checkout evaluates it, not recorded provenance.
    if ! printf '%s' "$base" | grep -Eqx '[0-9a-f]{40}|[0-9a-f]{64}' \
       || ! _git cat-file -e "$base^{commit}" 2>/dev/null; then
      FAIL_RULE="g"; FAIL_MSG="baseline base-commit '${base:-none}' is not a full commit sha in this repository"; return 1
    fi
    if ! _git merge-base --is-ancestor "$base" "$W_SHA^" 2>/dev/null; then
      FAIL_RULE="g"; FAIL_MSG="baseline base-commit '${base:-none}' is not an ancestor of ${W_SHA:0:7}^"; return 1
    fi
    if [ "$(_baseline_header "$bfile" category)" != "$cat" ]; then
      FAIL_RULE="g"; FAIL_MSG="baseline $brel is not for category '$cat'"; return 1
    fi
    if [ "$(_baseline_header "$bfile" extractor)" != "$(_extractor_for "$cat")" ]; then
      FAIL_RULE="g"; FAIL_MSG="baseline extractor '$(_baseline_header "$bfile" extractor)' does not match shipped '$(_extractor_for "$cat")' (non-comparable)"; return 1
    fi
  fi
  return 0
}

# --- Subcommands -------------------------------------------------------------

cmd_check() {
  [ $# -ge 2 ] || usage "check <plan> <category> [--tip <rev>] [--date YYYY-MM-DD]"
  local plan="$1" cat="$2" tip="HEAD" evald rel
  evald="$(today)"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --tip)  tip="${2:?--tip needs a rev}"; shift 2 ;;
      --date) evald="${2:?--date needs YYYY-MM-DD}"; shift 2 ;;
      *) usage "unknown option $1" ;;
    esac
  done
  rel="$(_plan_rel "$plan")" || { echo "INVALID $cat a: cannot resolve plan '$plan'"; exit "$EXIT_WAIVER_INVALID"; }
  if _check_entry "$tip" "$rel" "$cat" "$evald"; then
    echo "VALID $cat $W_MODE"
    exit 0
  fi
  echo "INVALID $cat $FAIL_RULE: $FAIL_MSG"
  echo "waiver invalid ($cat): rule ($FAIL_RULE) $FAIL_MSG" >&2
  exit "$EXIT_WAIVER_INVALID"
}

_delta_file() {  # <plan-id> <category>
  printf '%s/.mstack/waivers/plan-%s-%s.delta\n' "$ROOT" "$1" "$2"
}

# evaluate <plan> <category> <full-output-file> <exit-code>
# Prints exactly one classification line and exits 0:
#   NONE | WAIVED <mode> | INVALID <rule> | REGRESSED <n> | NONCOMPARABLE <why>
cmd_evaluate() {
  [ $# -ge 4 ] || usage "evaluate <plan> <category> <full-output-file> <exit-code>"
  local plan="$1" cat="$2" out="$3" ec="$4" rel headc="$WTMP/head.content" rc=0 hp wp
  rel="$(_plan_rel "$plan")" || { echo "INVALID unresolvable-plan"; return 0; }
  # Live checks read COMMITTED waivers only.
  if ! _git show "HEAD:$rel" > "$headc" 2>/dev/null; then echo "NONE"; return 0; fi
  hp="$(_entry_for "$headc" "$cat")" || rc=$?
  if [ "$rc" -eq 1 ]; then
    # Present only in the working tree => not honoured, but say so.
    if [ -f "$ROOT/$rel" ] && _entry_for "$ROOT/$rel" "$cat" >/dev/null 2>&1; then
      echo "INVALID uncommitted"; return 0
    fi
    echo "NONE"; return 0
  fi
  [ "$rc" -eq 0 ] || { echo "INVALID s"; return 0; }
  wp=""
  [ -f "$ROOT/$rel" ] && wp="$(_entry_for "$ROOT/$rel" "$cat" 2>/dev/null || true)"
  if [ "$wp" != "$hp" ]; then echo "INVALID worktree-differs-from-HEAD"; return 0; fi

  if ! _check_entry HEAD "$rel" "$cat" "$(today)"; then
    echo "INVALID $FAIL_RULE"
    echo "waiver not honoured ($cat): rule ($FAIL_RULE) $FAIL_MSG" >&2
    return 0
  fi
  if [ "$W_MODE" = "blanket" ]; then echo "WAIVED blanket"; return 0; fi

  # baseline-delta: compare the full head output against the committed baseline.
  local id ex brel bfile="$WTMP/baseline" heads="$WTMP/head.ids" bases="$WTMP/base.ids" newf="$WTMP/new.ids" dfile head_sha
  id="$(_fm_id_stdin < "$headc")"
  ex="$(_extractor_for "$cat")"
  brel="$(_baseline_rel "$id" "$cat")"
  _git show "HEAD:$brel" > "$bfile" 2>/dev/null || : > "$bfile"
  _baseline_identities "$bfile" > "$bases"
  dfile="$(_delta_file "$id" "$cat")"
  mkdir -p "$(dirname "$dfile")"
  head_sha="$(_git rev-parse HEAD)"
  if [ ! -r "$out" ]; then
    printf 'result=noncomparable\nhead=%s\nreason=no-output\n' "$head_sha" > "$dfile"
    echo "NONCOMPARABLE no-output"; return 0
  fi
  _extract "$ex" "$out" > "$heads"
  if [ ! -s "$heads" ] && [ "$ec" != "0" ]; then
    printf 'result=noncomparable\nhead=%s\nreason=no-identities-parsed\n' "$head_sha" > "$dfile"
    echo "NONCOMPARABLE no-identities-parsed"; return 0
  fi
  _multiset_new "$bases" "$heads" > "$newf"
  if [ -s "$newf" ]; then
    {
      printf 'result=new-failures\nhead=%s\nextractor=%s\nbaseline=%s\n' "$head_sha" "$ex" "$brel"
      sed 's/^/new=/' "$newf"
    } > "$dfile"
    sed 's/^/  new failure: /' "$newf" >&2
    echo "REGRESSED $(wc -l < "$newf" | tr -d ' ')"; return 0
  fi
  printf 'result=no-new-failures\nhead=%s\nextractor=%s\nbaseline=%s\nts=%s\n' \
    "$head_sha" "$ex" "$brel" "$(iso_now)" > "$dfile"
  echo "WAIVED baseline-delta"
}

# assert-delta <plan> <category>: the delta evidence says no new failures at HEAD.
cmd_assert_delta() {
  [ $# -ge 2 ] || usage "assert-delta <plan> <category>"
  local rel id dfile head_sha
  rel="$(_plan_rel "$1")" || { echo "assert-delta: cannot resolve plan '$1'" >&2; exit "$EXIT_WAIVER_INVALID"; }
  id="$(_git show "HEAD:$rel" 2>/dev/null | _fm_id_stdin)"
  [ -n "$id" ] || id="$(_fm_id_stdin < "$ROOT/$rel")"
  dfile="$(_delta_file "$id" "$2")"
  head_sha="$(_git rev-parse HEAD)"
  if [ ! -f "$dfile" ]; then echo "assert-delta: no delta evidence $dfile" >&2; exit "$EXIT_WAIVER_INVALID"; fi
  grep -qx 'result=no-new-failures' "$dfile" \
    || { echo "assert-delta: $dfile does not record result=no-new-failures" >&2; exit "$EXIT_WAIVER_INVALID"; }
  grep -qx "head=$head_sha" "$dfile" \
    || { echo "assert-delta: $dfile was not recorded at HEAD $head_sha" >&2; exit "$EXIT_WAIVER_INVALID"; }
  exit 0
}

# waive <plan> <category> <mode> <approver> <expires> <ref> <reason> [fallback]
cmd_waive() {
  [ $# -ge 7 ] || usage "waive <plan> <category> <mode> <approver> <expires> <ref> <reason> [fallback]"
  local plan="$1" cat="$2" mode="$3" approver="$4" expires="$5" ref="$6" reason="$7" fallback="${8:-}"
  local rel abs payload a
  for a in "$@"; do
    case "$a" in *[[:space:]]*) die "waive: values may not contain whitespace ('$a'); use _ or -" ;; esac
  done
  rel="$(_plan_rel "$plan")" || die "waive: cannot resolve plan '$plan'"
  abs="$ROOT/$rel"
  payload="category=$cat mode=$mode approver=$approver date=$(today) expires=$expires ref=$ref reason=$reason"
  [ -n "$fallback" ] && payload="$payload fallback=$fallback"
  _parse_payload "$payload" || die "waive: $V_ERR"

  local apf="$WTMP/appr.head"
  _git show "HEAD:$(_approvers_rel)" > "$apf" 2>/dev/null || : > "$apf"
  _approver_listed "$approver" "$apf" \
    || die "waive: approver '$approver' is not in the committed $(_approvers_rel) at HEAD"

  if [ "$mode" = "baseline-delta" ]; then
    local id brel
    id="$(fm_get "$abs" id)"
    brel="$(_baseline_rel "$id" "$cat")"
    _git cat-file -e "HEAD:$brel" 2>/dev/null \
      || die "waive: baseline-delta needs a committed baseline at $brel (run: waiver.sh capture-baseline $plan $cat, then commit it)"
  fi

  local rc=0
  _entry_for "$abs" "$cat" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || die "waive: $rel already has a waivers: entry for '$cat' (or an invalid block); remove it first"

  local tmp="$WTMP/plan.new"
  awk -v entry="  - $payload" '
    BEGIN { fm = 0; done = 0; inw = 0 }
    /^---[[:space:]]*$/ {
      fm++
      if (fm == 2 && !done) {
        if (inw) { print entry; done = 1 }
        else { print "waivers:"; print entry; done = 1 }
      }
      print; next
    }
    fm == 1 && inw && !done && $0 !~ /^[[:space:]]+-[[:space:]]/ { print entry; done = 1; inw = 0 }
    fm == 1 && /^waivers:/ { inw = 1 }
    { print }
  ' "$abs" > "$tmp"
  cat "$tmp" > "$abs"
  echo "waiver written to $rel: $payload"
  echo "NOTE: this waiver counts only after it is COMMITTED and the plan is THEN claimed" >&2
  echo "      (the waiver commit must be strictly before the claim commit)." >&2
}

# capture-baseline <plan> <category>
cmd_capture_baseline() {
  [ $# -ge 2 ] || usage "capture-baseline <plan> <category>"
  local plan="$1" cat="$2" rel ex dirty raw="$WTMP/raw" body="$WTMP/raw.body" ids="$WTMP/raw.ids" rc id brel head_sha
  rel="$(_plan_rel "$plan")" || die "capture-baseline: cannot resolve plan '$plan'"
  ex="$(_extractor_for "$cat")"
  [ -n "$ex" ] || die "capture-baseline: no failure-identity extractor for '$cat' (only typecheck, shell); use a blanket waiver"
  dirty="$(porcelain_paths "$ROOT")" || die "capture-baseline: cannot read git status"
  [ -z "$dirty" ] || die "capture-baseline: working tree is not clean; commit or stash first:
$dirty"
  if ! bash "$SCRIPT_DIR/health-check.sh" raw "$cat" > "$raw"; then
    die "capture-baseline: health-check.sh raw $cat failed (category not detected?)"
  fi
  rc="$(tail -n 1 "$raw")"
  case "$rc" in EXIT:*) rc="${rc#EXIT:}" ;; *) die "capture-baseline: raw output has no EXIT line" ;; esac
  sed '$d' "$raw" > "$body"
  _extract "$ex" "$body" > "$ids"
  if [ "$rc" != "0" ] && [ ! -s "$ids" ]; then
    die "capture-baseline: '$cat' exited $rc but no failure identity parsed with $ex (unrecognized output format)"
  fi
  id="$(fm_get "$ROOT/$rel" id)"
  brel="$(_baseline_rel "$id" "$cat")"
  head_sha="$(_git rev-parse HEAD)"
  mkdir -p "$ROOT/$(dirname "$brel")"
  {
    echo "base-commit: $head_sha"
    echo "category: $cat"
    echo "extractor: $ex"
    cat "$ids"
  } > "$ROOT/$brel"
  echo "baseline written: $brel ($(wc -l < "$ids" | tr -d ' ') identities, command exit $rc)"
  echo "NOTE: commit the baseline, then record the waiver (waiver.sh waive ...), commit that, then claim." >&2
}

cmd_extract() {
  [ $# -ge 1 ] || usage "extract <category> [file]"
  local ex
  ex="$(_extractor_for "$1")"
  [ -n "$ex" ] || die "extract: no extractor for '$1'"
  _extract "$ex" "${2:--}"
}

# hook-check <staged-plan-file> <head-path>: every entry in the staged waivers
# block must pass the history rule with HEAD as the tip. An entry not in HEAD
# fails rule (b) by definition (it was introduced by the commit being made).
cmd_hook_check() {
  [ $# -ge 2 ] || usage "hook-check <staged-plan-file> <head-path>"
  local staged="$1" hpath="$2" p cat bad=0 headc="$WTMP/hook.head"
  _git show "HEAD:$hpath" > "$headc" 2>/dev/null || : > "$headc"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! _parse_payload "$p"; then
      echo "waiver invalid: rule (s) $V_ERR: '$p'" >&2; bad=1; continue
    fi
    cat="$V_category"
    local rc=0 why
    why="$(_entry_for "$staged" "$cat")" || rc=$?
    if [ "$rc" -ne 0 ]; then echo "waiver invalid ($cat): rule (s) $why" >&2; bad=1; continue; fi
    if ! _has_payload "$headc" "$p"; then
      echo "waiver invalid ($cat): rule (b) entry is not in HEAD — a waiver added or altered in this commit is never honoured" >&2
      bad=1; continue
    fi
    if ! _check_entry HEAD "$hpath" "$cat" "$(today)"; then
      echo "waiver invalid ($cat): rule ($FAIL_RULE) $FAIL_MSG" >&2; bad=1
    fi
  done < <(waiver_payloads "$staged")
  [ "$bad" -eq 0 ] || exit "$EXIT_WAIVER_INVALID"
  exit 0
}

# _waiver_touched_basenames: basenames of plan files whose history (any commit,
# merges included, across renames inside the plans dir) ever added or removed a
# line containing `category=`. Nonzero when history cannot be read.
_waiver_touched_basenames() {
  local prel touched renames old new
  prel="$(_plans_rel)" || return 1
  touched="$(_git log -m -G 'category=' --format= --name-only HEAD -- "$prel" 2>/dev/null)" || return 1
  renames="$(_git log -M --diff-filter=R --name-status --format= HEAD -- "$prel" 2>/dev/null)" || return 1
  touched="$(printf '%s\n' "$touched" | sed 's|.*/||' | LC_ALL=C sort -u)"
  # Oldest rename first, so a chain a -> b -> c carries a's waiver to c.
  while IFS="$(printf '\t')" read -r _ old new; do
    [ -n "$new" ] || continue
    if printf '%s\n' "$touched" | grep -Fxq -- "${old##*/}"; then
      touched="$(printf '%s\n%s\n' "$touched" "${new##*/}")"
    fi
  done < <(printf '%s\n' "$renames" | sed '1!G;h;$!d')
  printf '%s\n' "$touched"
}

# audit: for each done/archived plan whose history ever carried a waiver (not
# only those whose CURRENT file does: deleting the block after a --no-verify
# completion must not erase the evidence), evaluate every entry at EVERY done
# commit — each commit whose status is done while its predecessor's is not.
# Offenders exit 27; every waived completion is listed.
cmd_audit() {
  local pdir f rel status offenders="" infos="" found=0 touched="" hist_ok=1
  pdir="$(plans_dir 2>/dev/null)" || exit 0
  touched="$(_waiver_touched_basenames)" || hist_ok=0
  for f in "$pdir"/*.md "$pdir"/archive/*.md; do
    [ -f "$f" ] || continue
    status="$(fm_get "$f" status 2>/dev/null || true)"
    [ "$status" = "done" ] || continue
    if [ -z "$(waiver_payloads "$f")" ] && [ "$hist_ok" -eq 1 ] \
       && ! printf '%s\n' "$touched" | grep -Fxq -- "${f##*/}"; then
      continue
    fi
    rel="${f#"$ROOT"/}"
    local id label
    id="$(fm_get "$f" id 2>/dev/null || true)"
    label="$(plan_label "$id" 2>/dev/null || true)"
    [ -n "$label" ] || label="${f##*/}"

    rm -f "$WTMP"/h.*
    if [ "$(_git rev-parse --is-shallow-repository 2>/dev/null || echo unknown)" != "false" ] \
       || ! _history_load HEAD "$rel"; then
      offenders="${offenders}  ${label} — cannot verify waivers (shallow or unreadable history)
"
      found=1; continue
    fi
    # Every done-transition, snapshotted before _check_entry reloads history.
    local n="${#H_SHA[@]}" i st prev k=0
    local -a t_sha=() t_path=()
    for ((i = 0; i < n; i++)); do
      st="$(_hist_status "$i")"
      [ "$st" = "done" ] || continue
      prev=""
      [ $((i + 1)) -lt "$n" ] && prev="$(_hist_status $((i + 1)))"
      [ "$prev" != "done" ] || continue
      cp "$(_hist_content "$i")" "$WTMP/audit.t.$k"
      t_sha+=("${H_SHA[$i]}"); t_path+=("${H_PATH[$i]}"); k=$((k + 1))
    done
    if [ "$k" -eq 0 ]; then
      offenders="${offenders}  ${label} — cannot verify waivers (no done commit in history)
"
      found=1; continue
    fi
    local j d_sha d_path d_date p
    for ((j = 0; j < k; j++)); do
      d_sha="${t_sha[$j]}"; d_path="${t_path[$j]}"
      d_date="$(TZ=UTC0 _git log -1 --format=%cd --date=format-local:%Y-%m-%d "$d_sha")"
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! _parse_payload "$p"; then
          offenders="${offenders}  ${label} — invalid waiver entry at done commit ${d_sha:0:7}: $V_ERR
"
          found=1; continue
        fi
        local cat="$V_category" mode="$V_mode"
        if _check_entry "$d_sha" "$d_path" "$cat" "$d_date"; then
          local suffix=""
          [ "$W_RECLAIMED" -eq 1 ] && suffix=" re-claimed"
          infos="${infos}  ${label} — ${cat}:${mode} approver=${W_APPROVER} ref=${W_REF}${suffix}
"
          if [ "$mode" = "blanket" ]; then
            echo "warn: ${label} completed with '${cat}' blanket-waived — nothing was measured for it" >&2
          fi
        else
          offenders="${offenders}  ${label} — waiver ${cat}:${mode} fails rule (${FAIL_RULE}) at done commit ${d_sha:0:7}: ${FAIL_MSG}
"
          found=1
        fi
      done < <(waiver_payloads "$WTMP/audit.t.$j")
    done
  done
  if [ -n "$infos" ]; then
    echo "completed under waiver:"
    printf '%s' "$infos"
  fi
  if [ "$found" -ne 0 ]; then
    echo "audit: done/archived plans with an invalid health waiver:"
    printf '%s' "$offenders"
    exit "$EXIT_GATE_AUDIT_FOUND"
  fi
  exit 0
}

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || usage
  shift
  case "$cmd" in
    check)            cmd_check "$@" ;;
    evaluate)         cmd_evaluate "$@" ;;
    assert-delta)     cmd_assert_delta "$@" ;;
    waive)            cmd_waive "$@" ;;
    capture-baseline) cmd_capture_baseline "$@" ;;
    extract)          cmd_extract "$@" ;;
    hook-check)       cmd_hook_check "$@" ;;
    audit)            cmd_audit "$@" ;;
    *) usage "unknown subcommand: $cmd" ;;
  esac
}

main "$@"
