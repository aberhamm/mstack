#!/usr/bin/env bash
# Pick the next plan to work on.
#
# Outputs (stdout): path to the chosen plan file, or empty string if none.
# Selection rules:
#   - File must be in $PLANS_DIR (default: <repo-root>/plans).
#   - Frontmatter `status:` must be `pending`.
#   - All ids in `blocked-by:` must have `status: done` somewhere in $PLANS_DIR.
#   - Sort: lowest `priority:` first, then lowest `id:` as tiebreaker.
#   - `priority:` is optional; defaults to `id:` when absent.
#
# Frontmatter is parsed leniently — single-line YAML scalars only.
# `blocked-by:` accepts inline list `[1, 2]` OR comma-separated `1, 2`.
# Anything fancier (multi-line lists, anchors) is unsupported by design.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
# Convention: plans live in docs/plans/ (human-authored prose docs; the picker
# only considers files with YAML frontmatter declaring `status:`, so legacy
# plans without frontmatter are silently ignored).
PLANS_DIR="${PLANS_DIR:-$REPO_ROOT/docs/plans}"
[ -d "$PLANS_DIR" ] || PLANS_DIR="$REPO_ROOT/plans"

[ -d "$PLANS_DIR" ] || exit 0

# Optional scope filter: comma-separated list of plan IDs to consider.
# Usage: pick-next.sh [id1,id2,id3]
# When provided, only plans whose id matches one of these IDs are candidates.
# When empty, all pending plans are considered (backward compatible).
SCOPE_FILTER="${1:-}"

# Build a space-padded string for fast membership check: " 8 9 10 11 "
SCOPE_IDS_PADDED=""
if [ -n "$SCOPE_FILTER" ]; then
  # Normalize: replace commas with spaces, strip leading zeros for matching
  _scope_raw="${SCOPE_FILTER//,/ }"
  for _sid in $_scope_raw; do
    # Strip leading zeros for consistent matching (008 -> 8)
    _sid_num="$(echo "$_sid" | sed 's/^0*//' )"
    [ -z "$_sid_num" ] && _sid_num="0"
    SCOPE_IDS_PADDED="$SCOPE_IDS_PADDED$_sid_num "
  done
  SCOPE_IDS_PADDED=" $SCOPE_IDS_PADDED"
fi

# Check if an id is in the scope filter (returns 0 if in scope or no filter)
in_scope() {
  local id="$1"
  [ -z "$SCOPE_FILTER" ] && return 0
  # Strip leading zeros from the id for matching
  local id_num
  id_num="$(echo "$id" | sed 's/^0*//')"
  [ -z "$id_num" ] && id_num="0"
  case "$SCOPE_IDS_PADDED" in
    *" $id_num "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Extract a single-line frontmatter scalar. Args: <file> <key>
fm_get() {
  awk -v key="$2" '
    /^---[[:space:]]*$/ { fm++; next }
    fm == 1 && $0 ~ "^"key":" {
      sub("^"key":[[:space:]]*", "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
    fm == 2 { exit }
  ' "$1"
}

# Parse blocked-by line into space-separated ids.
parse_blocked() {
  local raw="$1"
  raw="${raw#[}"; raw="${raw%]}"
  raw="${raw//,/ }"
  echo "$raw" | tr -s ' '
}

# Build list of done ids for fast membership check.
DONE_IDS=" "
while IFS= read -r f; do
  status="$(fm_get "$f" status || true)"
  [ "$status" = "done" ] || continue
  id="$(fm_get "$f" id || true)"
  [ -n "$id" ] && DONE_IDS="$DONE_IDS$id "
done < <(find "$PLANS_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' | sort)

# --- Cycle detection (bash 3.2 compatible, no associative arrays) ---
# Flat lists: NONDONE_IDS holds "id1 id2 ...", NONDONE_DEPS_<id> holds deps.
# We use eval to simulate per-id storage without declare -A.
NONDONE_IDS=""
while IFS= read -r f; do
  _id="$(fm_get "$f" id || true)"
  [ -n "$_id" ] || continue
  _status="$(fm_get "$f" status || true)"
  [ "$_status" = "done" ] && continue
  NONDONE_IDS="$NONDONE_IDS $_id"
  _blocked_raw="$(fm_get "$f" blocked-by || true)"
  _deps=""
  if [ -n "$_blocked_raw" ] && [ "$_blocked_raw" != "[]" ]; then
    _deps="$(parse_blocked "$_blocked_raw")"
  fi
  eval "DEPS_$_id=\"$_deps\""
done < <(find "$PLANS_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' | sort)

cycle_dfs() {
  local node="$1" visited="$2"
  case " $visited " in
    *" $node "*) echo "$visited $node"; return 0 ;;
  esac
  local deps
  eval "deps=\"\${DEPS_$node:-}\""
  for dep in $deps; do
    [ -z "$dep" ] && continue
    case "$DONE_IDS" in
      *" $dep "*) continue ;;
    esac
    local result
    result="$(cycle_dfs "$dep" "$visited $node")" || true
    if [ -n "$result" ]; then
      echo "$result"
      return 0
    fi
  done
  return 1
}

for _pid in $NONDONE_IDS; do
  _cycle="$(cycle_dfs "$_pid" "" 2>/dev/null)" || true
  if [ -n "$_cycle" ]; then
    echo "WARNING: dependency cycle detected:$_cycle" >&2
  fi
done
# --- End cycle detection ---

best_id=""
best_pri=""
best_path=""

while IFS= read -r f; do
  status="$(fm_get "$f" status || true)"
  [ "$status" = "pending" ] || continue

  # Skip plans that still need a review pass (eng, design, or both).
  needs_review="$(fm_get "$f" needs-review || true)"
  [ -z "$needs_review" ] || [ "$needs_review" = "none" ] || continue

  id="$(fm_get "$f" id || true)"
  [ -n "$id" ] || continue

  # If a scope filter is active, skip plans not in the scope.
  in_scope "$id" || continue

  blocked_raw="$(fm_get "$f" blocked-by || true)"
  unblocked=true
  if [ -n "$blocked_raw" ] && [ "$blocked_raw" != "[]" ]; then
    for dep in $(parse_blocked "$blocked_raw"); do
      [ -z "$dep" ] && continue
      case "$DONE_IDS" in
        *" $dep "*) ;;
        *) unblocked=false; break ;;
      esac
    done
  fi
  $unblocked || continue

  # Optional priority field; defaults to id when absent.
  pri="$(fm_get "$f" priority || true)"
  [ -n "$pri" ] || pri="$id"

  # Sort by priority first, then id as tiebreaker.
  if [ -z "$best_id" ] \
     || [ "$((10#$pri))" -lt "$((10#$best_pri))" ] \
     || { [ "$((10#$pri))" -eq "$((10#$best_pri))" ] && [ "$((10#$id))" -lt "$((10#$best_id))" ]; }; then
    best_id="$id"
    best_pri="$pri"
    best_path="$f"
  fi
done < <(find "$PLANS_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' | sort)

[ -n "$best_path" ] && echo "$best_path"
