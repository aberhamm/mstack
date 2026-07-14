#!/usr/bin/env bash
# wrapup-scan.sh (mstack plan 040) — deterministic, read-only mechanical scan
# of one or more git repos for leftover session mess.
#
# Usage:
#   wrapup-scan.sh [repo-path ...]     # no args = the repo containing $PWD
#
# Strictly READ-ONLY: nothing here mutates git state (no add/commit/stash
# write/fetch/push) or the filesystem beyond mktemp scratch files. Findings are
# reported, never cleaned — the consuming layer (mstack-handoff's artifact
# check, mstack-wrap-up) decides what is litter and what is deliberate.
#
# Output contract (PINNED — parsers depend on it):
#   repo=<abs path>
#   section=uncommitted count=<n>
#     <raw path>
#   section=artifacts count=<n>
#     <raw path>
#   section=stashes count=<n>
#     <raw stash line>
#   section=merged-branches count=<n> local-refs-only
#     <branch>
#   section=unpushed count=<n> local-refs-only
#     <branch> ahead=<n>          (or:  <branch> upstream=none)
#   findings=<N>
# Sections always appear, in that order, even when empty. Entry values are RAW
# on their own two-space-indented lines (never embedded in key=value pairs), so
# spaces or '=' in a path cannot break parsing. N is the total entry count
# across every section of that repo. Branch-derived sections are marked
# `local-refs-only`: this script never fetches, so they reflect local refs.
#
# The one exception to that shape: when a repo's git status cannot be read, its
# report is `repo=<path>` followed by `error=git-status-unreadable` and NOTHING
# else — no sections, no `findings=` line. Fail closed: a parser must treat a
# repo block with no `findings=` line as UNKNOWN, never as clean.
#
# Exit codes:
#   0  scan completed (findings are data, not an error)
#   29 EXIT_SCAN_NOT_GIT — a target path is not a git repository (other targets
#      are still scanned; their stdout stays complete and valid)
#   1  a repo's git status was unreadable (fail closed — never a "clean" print)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Artifact heuristics: untracked files only, matched on the BASENAME. Advisory
# — a match is a report line, never a deletion. This script is the single
# committable home of the pattern list; other layers reference it rather than
# restating it.
ARTIFACT_PATTERNS='*.tmp *.bak *.orig test-* debug-* *.log'

exit_code=0
SECTION_COUNT=0

is_artifact() {
  local base pat
  base="$(basename "$1")"
  for pat in $ARTIFACT_PATTERNS; do
    # shellcheck disable=SC2254
    case "$base" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# untracked_paths <root>: NUL-safe parse of `git status --porcelain -uall -z`
# that PRESERVES the XY status so untracked (`??`) entries can be told apart
# from tracked-dirty ones — lib.sh's porcelain_paths deliberately emits paths
# only, so this second pass is required, not redundant. Same `read -r -d ''`
# style as lib.sh's _porcelain_split (never awk: awk drops rename targets and
# mangles paths with spaces). Returns nonzero when git status cannot be read.
untracked_paths() {
  local root="$1"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/mstack-wrapup-XXXXXX")" || return 2
  if ! git -C "$root" status --porcelain -uall -z >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  local token x path expect_orig=0
  while IFS= read -r -d '' token; do
    if [ "$expect_orig" -eq 1 ]; then
      # rename/copy ORIGINAL path (bare, no XY prefix) — never an untracked entry.
      expect_orig=0
      continue
    fi
    x="${token:0:1}"
    path="${token:3}"
    case "$x" in
      R|C) expect_orig=1 ;;
      '?') [ -n "$path" ] && printf '%s\n' "$path" ;;
    esac
  done <"$tmp"
  rm -f "$tmp"
  return 0
}

# default_branch <root>: origin/HEAD when known, else a local main/master.
# Nonzero when neither is knowable (no-remote, oddly-named default).
default_branch() {
  local root="$1" ref b
  ref="$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#refs/remotes/origin/}"
    return 0
  fi
  for b in main master; do
    if git -C "$root" show-ref --verify --quiet "refs/heads/$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 1
}

# emit_section <name> <marker-or-empty> <entries>: print the section header and
# its raw two-space-indented entries. Sets SECTION_COUNT to the entry count so
# the caller can accumulate the findings total.
emit_section() {
  local name="$1" marker="$2" entries="$3"
  while [ -n "$entries" ] && [ "${entries%$'\n'}" != "$entries" ]; do
    entries="${entries%$'\n'}"
  done
  local n=0
  if [ -n "$entries" ]; then
    n="$(printf '%s\n' "$entries" | wc -l | tr -d ' ')"
  fi
  SECTION_COUNT="$n"
  if [ -n "$marker" ]; then
    echo "section=${name} count=${n} ${marker}"
  else
    echo "section=${name} count=${n}"
  fi
  [ "$n" -gt 0 ] || return 0
  local line
  while IFS= read -r line; do
    printf '  %s\n' "$line"
  done <<EOF
$entries
EOF
}

scan_repo() {
  local root="$1"
  local total=0

  echo "repo=${root}"

  # 1. uncommitted — lib.sh porcelain_paths (paths only, rename/space-safe).
  local uncommitted
  if ! uncommitted="$(porcelain_paths "$root")"; then
    echo "error=git-status-unreadable"
    echo "mechanical check failed: ${root}: git status unreadable" >&2
    exit_code=1
    return 0
  fi
  emit_section uncommitted "" "$uncommitted"
  total=$((total + SECTION_COUNT))

  # 2. artifacts — UNTRACKED entries only, basename pattern match.
  local untracked artifacts="" p
  if ! untracked="$(untracked_paths "$root")"; then
    echo "error=git-status-unreadable"
    echo "mechanical check failed: ${root}: git status unreadable" >&2
    exit_code=1
    return 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if is_artifact "$p"; then
      artifacts="${artifacts}${p}"$'\n'
    fi
  done <<EOF
$untracked
EOF
  emit_section artifacts "" "$artifacts"
  total=$((total + SECTION_COUNT))

  # 3. stashes.
  local stashes
  stashes="$(git -C "$root" stash list 2>/dev/null || true)"
  emit_section stashes "" "$stashes"
  total=$((total + SECTION_COUNT))

  # 4. merged-branches — local refs only, no fetch. Degrades to an empty
  # section (not an error) when the default branch is unknowable, and skips the
  # default and current branches.
  local def cur merged="" b
  def="$(default_branch "$root" || true)"
  cur="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -n "$def" ]; then
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      [ "$b" = "$def" ] && continue
      if [ -n "$cur" ] && [ "$b" = "$cur" ]; then continue; fi
      merged="${merged}${b}"$'\n'
    done <<EOF
$(git -C "$root" branch --merged "$def" --format='%(refname:short)' 2>/dev/null || true)
EOF
  fi
  emit_section merged-branches local-refs-only "$merged"
  total=$((total + SECTION_COUNT))

  # 5. unpushed — ahead counts for EVERY local branch (not just HEAD), so
  # side-branch work cannot produce a false all-clear. A branch with no
  # upstream is reported as upstream=none, never silently skipped.
  local unpushed="" line br up ahead
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    br="${line%%	*}"
    up="${line#*	}"
    if [ -z "$up" ] || [ "$up" = "$br" ]; then
      unpushed="${unpushed}${br} upstream=none"$'\n'
      continue
    fi
    ahead="$(git -C "$root" rev-list --count "${up}..${br}" 2>/dev/null || echo 0)"
    case "$ahead" in
      ''|*[!0-9]*) ahead=0 ;;
    esac
    if [ "$ahead" -gt 0 ]; then
      unpushed="${unpushed}${br} ahead=${ahead}"$'\n'
    fi
  done <<EOF
$(git -C "$root" for-each-ref --format='%(refname:short)	%(upstream:short)' refs/heads 2>/dev/null || true)
EOF
  emit_section unpushed local-refs-only "$unpushed"
  total=$((total + SECTION_COUNT))

  echo "findings=${total}"
}

main() {
  local targets=()
  if [ "$#" -eq 0 ]; then
    targets=("$PWD")
  else
    targets=("$@")
  fi

  local t root
  for t in "${targets[@]}"; do
    if [ ! -d "$t" ] || ! root="$(git -C "$t" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$root" ]; then
      echo "mechanical check unavailable: ${t} is not a git repository" >&2
      exit_code="$EXIT_SCAN_NOT_GIT"
      continue
    fi
    scan_repo "$root"
  done

  exit "$exit_code"
}

main "$@"
