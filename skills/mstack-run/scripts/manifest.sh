#!/usr/bin/env bash
# mstack execution manifest. Tracks scoped goal state across iterations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT="$(repo_root)"
MANIFEST="$ROOT/$MANIFEST_FILE"

# Resolve a plan ID to its file path on disk.
# Searches both plans/ and archive/ directories.
resolve_plan_file() {
  local id="$1"
  local pdir
  pdir="$(plans_dir)" || return 1
  local id_num
  id_num="$(echo "$id" | sed 's/^0*//')"
  [ -z "$id_num" ] && id_num="0"

  local f
  for f in "$pdir"/*.md "$pdir"/archive/*.md; do
    [ -f "$f" ] || continue
    local fid
    fid="$(fm_get "$f" id 2>/dev/null || true)"
    [ -n "$fid" ] || continue
    local fid_num
    fid_num="$(echo "$fid" | sed 's/^0*//')"
    [ -z "$fid_num" ] && fid_num="0"
    if [ "$fid_num" = "$id_num" ]; then
      # Return path relative to repo root
      echo "${f#$ROOT/}"
      return 0
    fi
  done
  return 1
}

# create <scope_ids_csv> [--goal <slug>]
# Resolve each scope ID to a file path and write the initial manifest.
# Optional --goal flag stores an informational goal name at the root level.
cmd_create() {
  local scope_csv="${1:?usage: manifest.sh create <scope_ids_csv> [--goal <slug>]}"
  shift
  local goal=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --goal) goal="${2:?--goal requires a value}"; shift 2 ;;
      *) shift ;;
    esac
  done
  ensure_mstack_dir

  local scope_raw="${scope_csv//,/ }"
  local scope_ids_json=""
  local plans_json=""
  local now
  now="$(iso_now)"

  for sid in $scope_raw; do
    # Normalize: strip leading zeros for display but keep original for ID
    local sid_clean
    sid_clean="$(echo "$sid" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
    [ -z "$sid_clean" ] && continue

    # Build scope_ids array entry
    if [ -n "$scope_ids_json" ]; then
      scope_ids_json="$scope_ids_json, \"$sid_clean\""
    else
      scope_ids_json="\"$sid_clean\""
    fi

    # Resolve file path
    local fpath
    fpath="$(resolve_plan_file "$sid_clean" 2>/dev/null)" || fpath=""

    if [ -n "$plans_json" ]; then
      plans_json="$plans_json, \"$sid_clean\": {\"file\": \"$fpath\"}"
    else
      plans_json="\"$sid_clean\": {\"file\": \"$fpath\"}"
    fi
  done

  if has_jq; then
    # Build with jq for proper JSON
    local ids_array="[$scope_ids_json]"
    local plans_obj="{$plans_json}"
    jq -n \
      --argjson scope_ids "$ids_array" \
      --argjson plans "$plans_obj" \
      --arg goal "$goal" \
      --arg created_at "$now" \
      --arg updated_at "$now" \
      '{
        version: 1,
        goal: $goal,
        scope_ids: $scope_ids,
        plans: $plans,
        picked_history: [],
        terminal_ids: [],
        prev_terminal_count: 0,
        path_diverged: [],
        iteration_count: 0,
        created_at: $created_at,
        updated_at: $updated_at
      }' > "$MANIFEST"
  else
    # Fallback: manual JSON construction
    cat > "$MANIFEST" <<ENDJSON
{
  "version": 1,
  "goal": "$goal",
  "scope_ids": [$scope_ids_json],
  "plans": {$plans_json},
  "picked_history": [],
  "terminal_ids": [],
  "prev_terminal_count": 0,
  "path_diverged": [],
  "iteration_count": 0,
  "created_at": "$now",
  "updated_at": "$now"
}
ENDJSON
  fi

  echo "$MANIFEST"
}

# read
# Print the manifest contents to stdout.
cmd_read() {
  [ -f "$MANIFEST" ] || { echo "no manifest" >&2; exit 2; }
  cat "$MANIFEST"
}

# update <picked_id> <terminal_ids_csv>
# Increment iteration_count, append to picked_history, update terminal_ids,
# re-resolve file paths and log divergences.
cmd_update() {
  local picked_id="${1:?usage: manifest.sh update <picked_id> <terminal_ids_csv>}"
  local terminal_csv="${2:-}"
  [ -f "$MANIFEST" ] || die "no manifest to update"

  local now
  now="$(iso_now)"

  if has_jq; then
    local tmp="${MANIFEST}.tmp.$$"

    # Parse terminal IDs into a JSON array
    local terminal_json="[]"
    if [ -n "$terminal_csv" ]; then
      local terminal_raw="${terminal_csv//,/ }"
      local terminal_arr=""
      for tid in $terminal_raw; do
        local tid_clean
        tid_clean="$(echo "$tid" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
        [ -z "$tid_clean" ] && continue
        if [ -n "$terminal_arr" ]; then
          terminal_arr="$terminal_arr, \"$tid_clean\""
        else
          terminal_arr="\"$tid_clean\""
        fi
      done
      terminal_json="[$terminal_arr]"
    fi

    # Store prev_terminal_count before updating
    local prev_count
    prev_count=$(jq '.terminal_ids | length' "$MANIFEST")

    # Re-resolve file paths and detect divergence
    local diverged_ids=""
    local scope_ids
    scope_ids=$(jq -r '.scope_ids[]' "$MANIFEST")
    local plans_updates="{}"
    for sid in $scope_ids; do
      local current_path
      current_path="$(resolve_plan_file "$sid" 2>/dev/null)" || current_path=""
      local stored_path
      stored_path=$(jq -r ".plans[\"$sid\"].file // \"\"" "$MANIFEST")
      if [ -n "$current_path" ] && [ "$current_path" != "$stored_path" ]; then
        warn "manifest: path diverged for plan $sid: $stored_path -> $current_path"
        if [ -n "$diverged_ids" ]; then
          diverged_ids="$diverged_ids, \"$sid\""
        else
          diverged_ids="\"$sid\""
        fi
      fi
      # Use current path if resolved, otherwise keep stored
      local use_path="${current_path:-$stored_path}"
      plans_updates=$(echo "$plans_updates" | jq --arg sid "$sid" --arg fp "$use_path" '. + {($sid): {"file": $fp}}')
    done

    local diverged_json="[$diverged_ids]"

    jq \
      --arg picked "$picked_id" \
      --argjson terminal "$terminal_json" \
      --arg updated_at "$now" \
      --argjson prev_count "$prev_count" \
      --argjson diverged "$diverged_json" \
      --argjson plans_updates "$plans_updates" \
      '
      .iteration_count += 1 |
      .picked_history += [$picked] |
      .terminal_ids = ($terminal | unique) |
      .prev_terminal_count = $prev_count |
      .path_diverged = (.path_diverged + $diverged | unique) |
      .plans = (.plans * $plans_updates) |
      .updated_at = $updated_at
      ' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
  else
    die "manifest update requires jq"
  fi

  echo "$MANIFEST"
}

# delete
# Remove the manifest file.
cmd_delete() {
  [ -f "$MANIFEST" ] || return 0
  rm -f "$MANIFEST"
  echo "manifest deleted"
}

# validate
# Check manifest exists, is valid JSON, and detect staleness.
cmd_validate() {
  if [ ! -f "$MANIFEST" ]; then
    echo "NO_MANIFEST"
    exit 2
  fi

  # Check valid JSON
  if has_jq; then
    if ! jq empty "$MANIFEST" 2>/dev/null; then
      echo "INVALID_JSON"
      exit 1
    fi
  fi

  # Check staleness (updated_at > 1 hour ago)
  local updated_at
  if has_jq; then
    updated_at=$(jq -r '.updated_at // ""' "$MANIFEST")
  else
    updated_at=$(grep '"updated_at"' "$MANIFEST" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')
  fi

  if [ -n "$updated_at" ]; then
    local now_epoch updated_epoch
    now_epoch=$(date +%s)

    # Parse ISO 8601 timestamp
    local date_part="${updated_at%%T*}"
    if date -j -f "%Y-%m-%d" "$date_part" +%s >/dev/null 2>&1; then
      # macOS — parse in UTC to match iso_now output
      updated_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null) || updated_epoch=0
    else
      # Linux
      updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null) || updated_epoch=0
    fi

    if [ "$updated_epoch" -gt 0 ]; then
      local age_seconds=$(( now_epoch - updated_epoch ))
      if [ "$age_seconds" -gt 3600 ]; then
        local age_minutes=$(( age_seconds / 60 ))
        warn "manifest is stale (${age_minutes}m old, updated: $updated_at)"
        echo "STALE"
        exit 0
      fi
    fi
  fi

  echo "VALID"
}

# check
# Evaluate anomaly conditions against manifest state.
# Returns exit 0 (clear) or exit 1 (anomaly, reason string on stdout).
# Anomaly types: iteration_bound, repeat_pick, no_progress, path_divergence.
cmd_check() {
  [ -f "$MANIFEST" ] || { echo "no manifest" >&2; exit 2; }
  has_jq || die "manifest check requires jq"

  local iteration_count scope_size prev_terminal_count terminal_count
  iteration_count=$(jq '.iteration_count' "$MANIFEST")
  scope_size=$(jq '.scope_ids | length' "$MANIFEST")
  prev_terminal_count=$(jq '.prev_terminal_count' "$MANIFEST")
  terminal_count=$(jq '.terminal_ids | length' "$MANIFEST")

  # 1. iteration_bound: iteration_count > scope_size + 1
  local bound=$(( scope_size + 1 ))
  if [ "$iteration_count" -gt "$bound" ]; then
    echo "iteration_bound: iteration_count ($iteration_count) exceeds scope_size + 1 ($bound)"
    exit 1
  fi

  # 2. repeat_pick: last two picked_history entries are the same AND plan not terminal
  local history_len
  history_len=$(jq '.picked_history | length' "$MANIFEST")
  if [ "$history_len" -ge 2 ]; then
    local last_pick prev_pick
    last_pick=$(jq -r '.picked_history[-1]' "$MANIFEST")
    prev_pick=$(jq -r '.picked_history[-2]' "$MANIFEST")
    if [ "$last_pick" = "$prev_pick" ]; then
      # Check if the repeated plan is terminal
      local is_terminal
      is_terminal=$(jq --arg id "$last_pick" '[.terminal_ids[] | select(. == $id)] | length' "$MANIFEST")
      if [ "$is_terminal" -eq 0 ]; then
        echo "repeat_pick: plan $last_pick picked consecutively without becoming terminal"
        exit 1
      fi
    fi
  fi

  # 3. no_progress: iteration_count increased but terminal_ids size unchanged
  if [ "$iteration_count" -gt 0 ] && [ "$terminal_count" -eq "$prev_terminal_count" ]; then
    echo "no_progress: iteration completed but terminal_ids unchanged (was $prev_terminal_count, still $terminal_count)"
    exit 1
  fi

  # 4. path_divergence: path_diverged contains non-terminal plan IDs
  local diverged_non_terminal
  diverged_non_terminal=$(jq '[.path_diverged[] as $d | select([.terminal_ids[] | select(. == $d)] | length == 0)] | length' "$MANIFEST")
  if [ "$diverged_non_terminal" -gt 0 ]; then
    local diverged_ids
    diverged_ids=$(jq -r '[.path_diverged[] as $d | select([.terminal_ids[] | select(. == $d)] | length == 0)] | join(", ")' "$MANIFEST")
    echo "path_divergence: file path changed for non-terminal plan(s): $diverged_ids"
    exit 1
  fi

  # All clear
  exit 0
}

case "${1:-validate}" in
  create)   cmd_create "${2:-}" ;;
  read)     cmd_read ;;
  update)   cmd_update "${2:-}" "${3:-}" ;;
  delete)   cmd_delete ;;
  validate) cmd_validate ;;
  check)    cmd_check ;;
  *)        die "usage: manifest.sh {create|read|update|delete|validate|check}" ;;
esac
