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

# Source shared library for exit code constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
# Convention: plans live in docs/plans/ (human-authored prose docs; the picker
# only considers files with YAML frontmatter declaring `status:`, so legacy
# plans without frontmatter are silently ignored).
PLANS_DIR="${PLANS_DIR:-$REPO_ROOT/docs/plans}"
[ -d "$PLANS_DIR" ] || PLANS_DIR="$REPO_ROOT/plans"

if [ ! -d "$PLANS_DIR" ]; then
  echo "all plans done" >&2
  exit "$EXIT_ALL_DONE"
fi

# Parse optional flags before positional arguments.
# Usage: pick-next.sh [--goal <slug>] [id1,id2,id3]
GOAL_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --goal) GOAL_FILTER="$2"; shift 2 ;;
    *) break ;;
  esac
done
# --goal consumed; $1 is now the numeric scope CSV if any
SCOPE_FILTER="${1:-}"

# Normalize a plan ID: strip leading zeros (008 -> 8, 0 -> 0).
normalize_id() {
  local raw="$1"
  local n="$raw"
  while [ "${n#0}" != "$n" ]; do
    n="${n#0}"
  done
  [ -n "$n" ] || n="0"
  echo "$n"
}

# --- Name resolution pre-pass (plan 033) ---
# Scope tokens may be numeric IDs (existing fast path) or plan name/slug
# fragments resolved via resolve_plan_ref (plan 031, lib.sh). This runs
# BEFORE SCOPE_IDS_PADDED is built so a purely-numeric scope never touches
# this code path at all (SCOPE_FILTER is left completely untouched below) —
# regression-critical: a purely numeric scope must select the exact same
# file as before this change.
case "$SCOPE_FILTER" in
  *[!0-9,\ ]*)
    # Contains at least one char that isn't a digit, comma, or space: at
    # least one token is a name/slug, not a bare numeric id. Resolve each
    # non-numeric token; pass numeric tokens through untouched.
    _resolved_scope=""
    _scope_raw="${SCOPE_FILTER//,/ }"
    for _tok in $_scope_raw; do
      [ -n "$_tok" ] || continue
      case "$_tok" in
        *[!0-9]*)
          # Non-numeric token: resolve via resolve_plan_ref.
          _ref_out="" _ref_rc=0
          _ref_out="$(resolve_plan_ref "$_tok")" || _ref_rc=$?
          if [ "$_ref_rc" -eq "$EXIT_REF_AMBIGUOUS" ]; then
            # resolve_plan_ref already printed the candidate list to stderr.
            exit "$EXIT_REF_AMBIGUOUS"
          elif [ "$_ref_rc" -eq "$EXIT_REF_NOT_FOUND" ]; then
            echo "scoped name '$_tok' not found in plans/ or archive/" >&2
            exit "$EXIT_SCOPED_NOT_FOUND"
          elif [ "$_ref_rc" -ne 0 ]; then
            echo "scoped name '$_tok' failed to resolve (unexpected error, code $_ref_rc)" >&2
            exit "$EXIT_SCOPED_NOT_FOUND"
          fi
          _ref_id="${_ref_out%% *}"
          _ref_status="${_ref_out##* }"
          if [ "$_ref_status" = "archived" ]; then
            _ref_label="$(plan_label "$_ref_id" 2>/dev/null || echo "$_ref_id")"
            echo "scoped name '$_tok' matches only a completed plan: $_ref_label" >&2
            exit "$EXIT_SCOPED_NOT_FOUND"
          fi
          _resolved_scope="$_resolved_scope $_ref_id"
          ;;
        *)
          # Purely numeric token within a mixed scope: pass through as-is.
          _resolved_scope="$_resolved_scope $_tok"
          ;;
      esac
    done
    SCOPE_FILTER="$(echo "$_resolved_scope" | xargs | tr ' ' ',')"
    ;;
  *) ;;  # Empty or purely numeric (with commas/spaces): fast path, untouched.
esac

# Build a space-padded string for fast membership check: " 8 9 10 11 "
SCOPE_IDS_PADDED=""
if [ -n "$SCOPE_FILTER" ]; then
  # Normalize: replace commas with spaces, strip leading zeros for matching
  _scope_raw="${SCOPE_FILTER//,/ }"
  for _sid in $_scope_raw; do
    # Strip leading zeros for consistent matching (008 -> 8)
    _sid_num="$(normalize_id "$_sid")"
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
  id_num="$(normalize_id "$id")"
  case "$SCOPE_IDS_PADDED" in
    *" $id_num "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Check if a plan file matches the goal filter.
# Returns 0 if GOAL_FILTER is empty OR if the plan's goal: matches.
matches_goal() {
  local f="$1"
  [ -z "$GOAL_FILTER" ] && return 0
  local plan_goal
  plan_goal="$(fm_get "$f" goal || true)"
  [ "$plan_goal" = "$GOAL_FILTER" ]
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

# shellcheck disable=SC2329
# Parse blocked-by line into space-separated ids (legacy, unqualified).
parse_blocked() {
  local raw="$1"
  raw="${raw#[}"; raw="${raw%]}"
  raw="${raw//,/ }"
  echo "$raw" | tr -s ' '
}

# Parse blocked-by line into goal-qualified tokens for DONE_IDS lookup.
# Args: <blocked_raw> <current_goal>
# Returns: space-separated "goal|id" tokens.
# - Bare numeric deps (e.g. "001") resolve within current_goal -> "goal|1"
# - Cross-goal deps use colon syntax (e.g. "auth:003") -> "auth|3"
parse_blocked_qualified() {
  local raw="$1" current_goal="$2"
  raw="${raw#[}"; raw="${raw%]}"
  raw="${raw//,/ }"
  local result=""
  for _dep in $(echo "$raw" | tr -s ' '); do
    [ -z "$_dep" ] && continue
    case "$_dep" in
      *:*)
        # Cross-goal reference: "goal:id"
        local _dep_goal="${_dep%%:*}"
        local _dep_id="${_dep#*:}"
        _dep_id="$(normalize_id "$_dep_id")"
        result="$result ${_dep_goal}|${_dep_id}"
        ;;
      *)
        # Within-goal reference: bare numeric id
        local _dep_id
        _dep_id="$(normalize_id "$_dep")"
        result="$result ${current_goal}|${_dep_id}"
        ;;
    esac
  done
  echo "$result" | tr -s ' '
}

# Build list of done ids for fast membership check.
# Scan both the main plans dir and the archive/ subdir for done plans.
# Format: space-padded goal-qualified tokens " |1 auth|2 "
# Plans without a goal: field use empty goal (prefix "|").
DONE_IDS=" "
while IFS= read -r f; do
  status="$(fm_get "$f" status || true)"
  [ "$status" = "done" ] || continue
  id="$(fm_get "$f" id || true)"
  [ -n "$id" ] || continue
  _goal="$(fm_get "$f" goal || true)"
  _id_norm="$(normalize_id "$id")"
  DONE_IDS="$DONE_IDS${_goal}|${_id_norm} "
done < <({ find "$PLANS_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md'; [ -d "$PLANS_DIR/archive" ] && find "$PLANS_DIR/archive" -maxdepth 1 -type f -name '*.md' ! -name 'README.md'; } | sort)

# --- Duplicate ID detection (exit 14) ---
# Scan all plan files for frontmatter `id:` and `goal:` values.
# Identity is (goal, id) — two plans with the same id but different goals are OK.
# Exit 14 if any (goal, id) pair appears in multiple files.
ALL_ID_MAP=""   # "goal|id:filepath goal|id:filepath ..."
while IFS= read -r f; do
  _did="$(fm_get "$f" id || true)"
  [ -n "$_did" ] || continue
  _dgoal="$(fm_get "$f" goal || true)"
  _did_norm="$(normalize_id "$_did")"
  ALL_ID_MAP="$ALL_ID_MAP ${_dgoal}|${_did_norm}:$f"
done < <({ find "$PLANS_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md'; [ -d "$PLANS_DIR/archive" ] && find "$PLANS_DIR/archive" -maxdepth 1 -type f -name '*.md' ! -name 'README.md'; } | sort)

# Check for duplicates by sorting on the goal|id identity part
_prev_id="" _prev_file=""
for _entry in $(echo "$ALL_ID_MAP" | tr ' ' '\n' | sort); do
  _eid="${_entry%%:*}"
  _efile="${_entry#*:}"
  [ -z "$_eid" ] && continue
  if [ "$_eid" = "$_prev_id" ]; then
    echo "duplicate plan ID $_eid in: $_prev_file, $_efile" >&2
    exit "$EXIT_DUPLICATE_IDS"
  fi
  _prev_id="$_eid"
  _prev_file="$_efile"
done

# --- Scoped ID not found detection (exit 11) ---
# When SCOPE_FILTER is set, verify each scoped ID has at least one matching
# plan file in plans/ or archive/. Exit 11 for the first missing ID.
# Compares normalized bare IDs (strip leading zeros, ignore goal) since
# scope filter operates on bare numeric IDs.
if [ -n "$SCOPE_FILTER" ]; then
  _scope_raw="${SCOPE_FILTER//,/ }"
  for _sid in $_scope_raw; do
    _sid_num="$(normalize_id "$_sid")"
    _found=false
    for _entry in $ALL_ID_MAP; do
      _eid="${_entry%%:*}"   # goal|id
      [ -z "$_eid" ] && continue
      _eid_bare="${_eid#*|}" # strip goal prefix to get bare id (already normalized)
      if [ "$_eid_bare" = "$_sid_num" ]; then
        _found=true
        break
      fi
    done
    if [ "$_found" = "false" ]; then
      echo "scoped ID $_sid not found in plans/ or archive/" >&2
      exit "$EXIT_SCOPED_NOT_FOUND"
    fi
  done
fi

# --- Cycle detection (bash 3.2 compatible, no associative arrays) ---
# Flat lists: NONDONE_IDS holds "goal|id1 goal|id2 ...", DEPS_<sanitized> holds deps.
# We use eval to simulate per-id storage without declare -A.
# Sanitization: goal|id -> goal__id for valid bash variable names (| -> __).
# Also collapse any remaining non-identifier chars (e.g. hyphens in goal slugs)
# to underscores so DEPS_<key> stays a valid bash identifier.
_sanitize_key() { local s="${1//|/__}"; echo "${s//[^a-zA-Z0-9_]/_}"; }

NONDONE_IDS=""
while IFS= read -r f; do
  _id="$(fm_get "$f" id || true)"
  [ -n "$_id" ] || continue
  _status="$(fm_get "$f" status || true)"
  [ "$_status" = "done" ] && continue
  _goal="$(fm_get "$f" goal || true)"
  _id_norm="$(normalize_id "$_id")"
  _qualified="${_goal}|${_id_norm}"
  NONDONE_IDS="$NONDONE_IDS $_qualified"
  _blocked_raw="$(fm_get "$f" blocked-by || true)"
  _deps=""
  if [ -n "$_blocked_raw" ] && [ "$_blocked_raw" != "[]" ]; then
    _deps="$(parse_blocked_qualified "$_blocked_raw" "$_goal")"
  fi
  # Sanitize goal|id to goal__id for eval variable names (pipe is not valid in bash identifiers)
  _skey="$(_sanitize_key "$_qualified")"
  eval "DEPS_${_skey}=\"$_deps\""
done < <({ find "$PLANS_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md'; [ -d "$PLANS_DIR/archive" ] && find "$PLANS_DIR/archive" -maxdepth 1 -type f -name '*.md' ! -name 'README.md'; } | sort)

cycle_dfs() {
  local node="$1" visited="$2"
  case " $visited " in
    *" $node "*) echo "$visited $node"; return 0 ;;
  esac
  local deps _snode
  # Sanitize node key for DEPS_ variable lookup
  _snode="$(_sanitize_key "$node")"
  eval "deps=\"\${DEPS_${_snode}:-}\""
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
  # Only check cycles for candidate plans (in scope or all non-done)
  if [ -n "$SCOPE_FILTER" ]; then
    # Extract bare id from goal|id for scope check
    _pid_bare="${_pid#*|}"
    in_scope "$_pid_bare" || continue
  fi
  _cycle="$(cycle_dfs "$_pid" "" 2>/dev/null)" || true
  if [ -n "$_cycle" ]; then
    # Format cycle as "A -> B -> A"
    _cycle_fmt="$(echo "$_cycle" | xargs | sed 's/ / -> /g')"
    echo "dependency cycle: $_cycle_fmt" >&2
    exit "$EXIT_CYCLE"
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

  # If a goal filter is active, skip plans not matching the goal.
  matches_goal "$f" || continue

  # Read this plan's goal for blocked-by resolution
  _plan_goal="$(fm_get "$f" goal || true)"

  blocked_raw="$(fm_get "$f" blocked-by || true)"
  unblocked=true
  if [ -n "$blocked_raw" ] && [ "$blocked_raw" != "[]" ]; then
    for dep in $(parse_blocked_qualified "$blocked_raw" "$_plan_goal"); do
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
done < <({ find "$PLANS_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md'; [ -d "$PLANS_DIR/archive" ] && find "$PLANS_DIR/archive" -maxdepth 1 -type f -name '*.md' ! -name 'README.md'; } | sort)

if [ -n "$best_path" ]; then
  echo "$best_path"
  exit "$EXIT_PLAN_FOUND"
fi

# Goal filter with no candidate: check if any plan has this goal at all.
# If no plan declares the goal, exit EXIT_GOAL_NOT_FOUND (15).
# If plans exist but are all done/blocked, fall through to exit 10/12 below.
if [ -n "$GOAL_FILTER" ]; then
  _goal_exists=false
  for _entry in $ALL_ID_MAP; do
    _eid="${_entry%%:*}"   # goal|id
    _efile="${_entry#*:}"
    [ -z "$_eid" ] && continue
    _egoal="${_eid%%|*}"
    if [ "$_egoal" = "$GOAL_FILTER" ]; then
      _goal_exists=true
      break
    fi
  done
  if [ "$_goal_exists" = "false" ]; then
    echo "goal '$GOAL_FILTER' not found in any plan file" >&2
    exit "$EXIT_GOAL_NOT_FOUND"
  fi
fi

# No plan found — determine which specific failure condition applies.
# Priority: 12 (all blocked) > 10 (all done).
# (14/11/13 are checked earlier and would have already exited.)

if [ -n "$SCOPE_FILTER" ]; then
  # Check if any scoped plans are pending but blocked (all-blocked condition)
  _scope_raw="${SCOPE_FILTER//,/ }"
  _blocked_count=0
  _blocked_deps=""
  for _sid in $_scope_raw; do
    _sid_num="$(normalize_id "$_sid")"
    # Find the plan file for this scoped ID
    for _entry in $ALL_ID_MAP; do
      _eid="${_entry%%:*}"    # goal|id
      _efile="${_entry#*:}"
      [ -z "$_eid" ] && continue
      _eid_bare="${_eid#*|}"  # strip goal prefix (already normalized)
      if [ "$_eid_bare" = "$_sid_num" ]; then
        _st="$(fm_get "$_efile" status || true)"
        if [ "$_st" = "pending" ] || [ "$_st" = "in-progress" ]; then
          # This plan is not done — check if it's blocked by out-of-scope deps
          _bl_raw="$(fm_get "$_efile" blocked-by || true)"
          _plan_goal_bl="$(fm_get "$_efile" goal || true)"
          if [ -n "$_bl_raw" ] && [ "$_bl_raw" != "[]" ]; then
            for _dep in $(parse_blocked_qualified "$_bl_raw" "$_plan_goal_bl"); do
              [ -z "$_dep" ] && continue
              case "$DONE_IDS" in
                *" $_dep "*) ;;  # dep is done, fine
                *)
                  # dep not done — is it in scope? Extract bare id for scope check
                  _dep_bare="${_dep#*|}"
                  if ! in_scope "$_dep_bare"; then
                    _blocked_count=$((_blocked_count + 1))
                    _blocked_deps="$_blocked_deps $_dep"
                    break
                  fi
                  ;;
              esac
            done
          fi
        fi
        break
      fi
    done
  done
  if [ "$_blocked_count" -gt 0 ]; then
    _blocked_deps="$(echo "$_blocked_deps" | xargs)"
    echo "$_blocked_count scoped plans blocked by out-of-scope deps: $_blocked_deps" >&2
    exit "$EXIT_ALL_BLOCKED"
  fi
  echo "all scoped plans done" >&2
  exit "$EXIT_ALL_DONE"
else
  echo "all plans done" >&2
  exit "$EXIT_ALL_DONE"
fi
