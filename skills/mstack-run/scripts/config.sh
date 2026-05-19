#!/usr/bin/env bash
# mstack config manager. Read/write .mstack/config.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CONFIG_FILE="$(repo_root)/.mstack/config.json"

DEFAULT_CONFIG='{
  "health": {
    "commands": {},
    "weights": {
      "typecheck": 25,
      "lint": 20,
      "test": 30,
      "deadcode": 15,
      "shell": 10
    }
  },
  "review": {
    "provider": "auto"
  },
  "autonomy": "full",
  "commit": {
    "conventional": true,
    "trailer": true
  },
  "ignored_paths": []
}'

cmd_init() {
  if [ -f "$CONFIG_FILE" ]; then
    echo "$CONFIG_FILE"
    return 0
  fi
  ensure_mstack_dir
  printf '%s\n' "$DEFAULT_CONFIG" > "$CONFIG_FILE"
  echo "$CONFIG_FILE"
}

cmd_get() {
  local path="${1:-}"
  [ -n "$path" ] || die "usage: config.sh get <dotpath>"
  local val=""
  if [ -f "$CONFIG_FILE" ]; then
    val="$(json_get "$CONFIG_FILE" "$path" 2>/dev/null || true)"
  fi
  if [ -z "$val" ]; then
    # Fall back to defaults
    local tmpfile
    tmpfile="$(mktemp)"
    printf '%s\n' "$DEFAULT_CONFIG" > "$tmpfile"
    val="$(json_get "$tmpfile" "$path" 2>/dev/null || true)"
    rm -f "$tmpfile"
  fi
  [ -n "$val" ] && echo "$val" || exit 2
}

cmd_set() {
  local path="${1:-}" value="${2:-}"
  [ -n "$path" ] || die "usage: config.sh set <dotpath> <value>"
  [ -n "$value" ] || die "usage: config.sh set <dotpath> <value>"

  # Validate known keys
  case "$path" in
    autonomy)
      case "$value" in
        full|checkpoint|supervised) ;;
        *) die "autonomy must be full, checkpoint, or supervised" ;;
      esac ;;
    review.provider)
      case "$value" in
        auto|codex|gemini|claude-only) ;;
        *) die "review.provider must be auto, codex, gemini, or claude-only" ;;
      esac ;;
    health.weights.*)
      case "$value" in
        ''|*[!0-9]*) die "weight must be a number" ;;
      esac ;;
    commit.conventional|commit.trailer)
      case "$value" in
        true|false) ;;
        *) die "$path must be true or false" ;;
      esac ;;
  esac

  [ -f "$CONFIG_FILE" ] || cmd_init > /dev/null

  if has_jq; then
    local jq_path
    jq_path=".$(echo "$path" | sed 's/\././g')"
    # Detect value type
    case "$value" in
      true|false) jq "$jq_path = $value" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" ;;
      ''|*[!0-9]*) jq "$jq_path = \"$value\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" ;;
      *) jq "$jq_path = $value" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" ;;
    esac
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  else
    warn "jq not available — config.sh set requires jq for reliable JSON editing"
    return 1
  fi
  echo "set $path = $value"
}

cmd_show() {
  if [ -f "$CONFIG_FILE" ]; then
    if has_jq; then
      jq '.' "$CONFIG_FILE"
    else
      cat "$CONFIG_FILE"
    fi
  else
    info "no config file — showing defaults"
    printf '%s\n' "$DEFAULT_CONFIG"
  fi
}

cmd_reset() {
  ensure_mstack_dir
  printf '%s\n' "$DEFAULT_CONFIG" > "$CONFIG_FILE"
  echo "config reset to defaults"
}

case "${1:-show}" in
  init)  cmd_init ;;
  get)   cmd_get "${2:-}" ;;
  set)   cmd_set "${2:-}" "${3:-}" ;;
  show)  cmd_show ;;
  reset) cmd_reset ;;
  *)     die "usage: config.sh {init|get|set|show|reset}" ;;
esac
