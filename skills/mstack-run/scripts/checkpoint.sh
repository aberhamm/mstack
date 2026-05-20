#!/usr/bin/env bash
# mstack checkpoint manager. Crash recovery state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT="$(repo_root)"
CP_DIR="$ROOT/.mstack/checkpoints"
LATEST="$CP_DIR/latest.json"

cmd_write() {
  ensure_mstack_dir
  mkdir -p "$CP_DIR"
  local json
  if [ -n "${1:-}" ]; then
    json="$1"
  else
    json="$(cat)"
  fi
  [ -n "$json" ] || die "no checkpoint data provided"
  printf '%s\n' "$json" > "$LATEST"
  local ts_file="$CP_DIR/$(iso_now | tr ':' '-').json"
  cp "$LATEST" "$ts_file"
  echo "$LATEST"
}

cmd_read() {
  [ -f "$LATEST" ] || exit 2
  cat "$LATEST"
}

cmd_dashboard() {
  [ -f "$LATEST" ] || { echo "NO_CHECKPOINT"; exit 2; }

  if has_jq; then
    local ts branch plan_id plan_status
    ts=$(jq -r '.ts // "unknown"' "$LATEST")
    branch=$(jq -r '.branch // "unknown"' "$LATEST")
    plan_id=$(jq -r '.plan_id // "none"' "$LATEST")
    plan_status=$(jq -r '.plan_status // "unknown"' "$LATEST")

    local completed failed remaining
    completed=$(jq -r '.counters.plans_completed // 0' "$LATEST")
    failed=$(jq -r '.counters.plans_failed // 0' "$LATEST")
    remaining=$(jq -r '.counters.plans_remaining // 0' "$LATEST")
    local health_used=$(jq -r '.counters.health_attempts_this_plan // 0' "$LATEST")
    local invest_used=$(jq -r '.counters.investigate_strikes_this_plan // 0' "$LATEST")

    echo "CHECKPOINT DASHBOARD"
    echo "===================="
    echo "Last updated: $ts"
    echo "Branch: $branch"
    echo ""
    echo "PROGRESS"
    echo "  Completed: $completed plans"
    echo "  Failed:    $failed plans"
    echo "  Remaining: $remaining plans"
    echo ""
    echo "CURRENT STATE"
    echo "  Plan $plan_id: $plan_status"
    echo "  Health attempts:     $health_used"
    echo "  Investigate strikes: $invest_used"
    echo ""

    local ctx_count
    ctx_count=$(jq '.user_context | length' "$LATEST" 2>/dev/null || echo 0)
    if [ "$ctx_count" -gt 0 ]; then
      echo "USER CONTEXT"
      jq -r '.user_context[]' "$LATEST" 2>/dev/null | while read -r line; do
        echo "  - $line"
      done
      echo ""
    fi

    echo "RECENT ATTEMPTS"
    jq -r '.attempts[-5:][] | "  \(.plan_id) \(.action) → \(.outcome)\(if .errors | length > 0 then " (" + (.errors[0]) + ")" else "" end)"' "$LATEST" 2>/dev/null || true
  else
    cat "$LATEST"
  fi
}

cmd_prune() {
  [ -d "$CP_DIR" ] || exit 0
  local count
  count=$(find "$CP_DIR" -name "*.json" ! -name "latest.json" -mtime +7 2>/dev/null | wc -l | tr -d ' ')
  find "$CP_DIR" -name "*.json" ! -name "latest.json" -mtime +7 -delete 2>/dev/null || true
  echo "pruned $count old checkpoints"

  local review_dir="$ROOT/.mstack/reviews"
  if [ -d "$review_dir" ]; then
    local rcount
    rcount=$(find "$review_dir" -name "*.json" -mtime +30 2>/dev/null | wc -l | tr -d ' ')
    find "$review_dir" -name "*.json" -mtime +30 -delete 2>/dev/null || true
    [ "$rcount" -gt 0 ] && echo "pruned $rcount old reviews"
  fi
}

case "${1:-dashboard}" in
  write)     cmd_write "${2:-}" ;;
  read)      cmd_read ;;
  dashboard) cmd_dashboard ;;
  prune)     cmd_prune ;;
  *)         die "usage: checkpoint.sh {write|read|dashboard|prune}" ;;
esac
