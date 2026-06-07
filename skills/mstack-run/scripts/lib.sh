#!/usr/bin/env bash
# Shared library for mstack scripts. Source this, don't execute it.

# --- Exit codes for pick-next.sh ---
# Range 10-19 avoids collision with bash/system codes (1=general error,
# 2=misuse, 126/127=permission/not-found, 128+=signals).
EXIT_PLAN_FOUND=0
EXIT_ALL_DONE=10
EXIT_SCOPED_NOT_FOUND=11
EXIT_ALL_BLOCKED=12
EXIT_CYCLE=13
EXIT_DUPLICATE_IDS=14
EXIT_GOAL_NOT_FOUND=15

# Cached repo root
_MSTACK_REPO_ROOT=""
repo_root() {
  [ -n "$_MSTACK_REPO_ROOT" ] && { echo "$_MSTACK_REPO_ROOT"; return; }
  _MSTACK_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  echo "$_MSTACK_REPO_ROOT"
}

# Create .mstack/ and add to .gitignore if missing
ensure_mstack_dir() {
  local root
  root="$(repo_root)"
  mkdir -p "$root/.mstack"
  if [ -f "$root/.gitignore" ]; then
    grep -q "^\.mstack/" "$root/.gitignore" 2>/dev/null || echo ".mstack/" >> "$root/.gitignore"
  else
    echo ".mstack/" > "$root/.gitignore"
  fi
}

# Check if jq is available
has_jq() { command -v jq >/dev/null 2>&1; }

# Extract a value from a JSON file using a dot path (e.g., health.weights.test)
# Falls back to awk when jq is unavailable. Supports 1-3 levels of nesting.
json_get() {
  local file="$1" path="$2"
  [ -f "$file" ] || return 1
  if has_jq; then
    jq -r ".$(echo "$path" | sed 's/\././g') // empty" "$file" 2>/dev/null
  else
    local IFS='.'
    # shellcheck disable=SC2086
    set -- $path
    case $# in
      1) awk -F'"' -v k="$1" '$2==k{gsub(/[, \t]/, "", $4); print $4}' "$file" | head -1 ;;
      2) awk -v k1="$1" -v k2="$2" '
           $0 ~ "\""k1"\"" { in_block=1 }
           in_block && $0 ~ "\""k2"\"" {
             match($0, /: *(.+)/, a) || match($0, /: *"([^"]*)"/, a)
             gsub(/[," \t]/, "", a[1]); print a[1]; exit
           }
           in_block && /}/ && !/\{/ { in_block=0 }
         ' "$file" | head -1 ;;
      *) return 1 ;;
    esac
  fi
}

# Append a JSON line to a JSONL file
jsonl_append() {
  local file="$1" line="$2"
  local dir
  dir="$(dirname "$file")"
  [ -d "$dir" ] || mkdir -p "$dir"
  printf '%s\n' "$line" >> "$file"
}

# Print the last line of a JSONL file
jsonl_last() {
  local file="$1"
  [ -f "$file" ] || return 1
  tail -1 "$file" 2>/dev/null
}

# Count lines in a JSONL file
jsonl_count() {
  local file="$1"
  [ -f "$file" ] || { echo "0"; return; }
  wc -l < "$file" | tr -d ' '
}

# Rotate a JSONL file to keep only the last N lines
jsonl_rotate() {
  local file="$1" max="${2:-100}"
  [ -f "$file" ] || return 0
  local count
  count=$(wc -l < "$file" | tr -d ' ')
  if [ "$count" -gt "$max" ]; then
    local tmp="${file}.tmp.$$"
    tail -"$max" "$file" > "$tmp" && mv "$tmp" "$file"
  fi
}

# Portable ISO 8601 timestamp (works on macOS and Linux)
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# YYYY-MM-DD
today() { date -u +%Y-%m-%d; }

# Days since a YYYY-MM-DD date (approximate, works on macOS and Linux)
days_since() {
  local then_date="$1"
  local now_epoch then_epoch
  if date -j -f "%Y-%m-%d" "$then_date" +%s >/dev/null 2>&1; then
    # macOS
    then_epoch=$(date -j -f "%Y-%m-%d" "$then_date" +%s 2>/dev/null)
    now_epoch=$(date +%s)
  else
    # Linux
    then_epoch=$(date -d "$then_date" +%s 2>/dev/null) || return 1
    now_epoch=$(date +%s)
  fi
  echo $(( (now_epoch - then_epoch) / 86400 ))
}

# Extract a frontmatter scalar from a markdown plan file (same as pick-next.sh)
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

# Find the plans directory
plans_dir() {
  local root
  root="$(repo_root)"
  if [ -d "$root/docs/plans" ]; then
    echo "$root/docs/plans"
  elif [ -d "$root/plans" ]; then
    echo "$root/plans"
  else
    return 1
  fi
}

# Find the archive directory for completed plans
archive_dir() {
  local pdir
  pdir="$(plans_dir)" || return 1
  echo "$pdir/archive"
}

# Resolve an installed skill directory across supported agent runtimes.
skill_dir() {
  local name="$1" dir
  for dir in \
    "${HOME}/.config/skillshare/skills/${name}" \
    "${HOME}/.agents/skills/${name}" \
    "${HOME}/.codex/skills/${name}" \
    "${HOME}/.claude/skills/${name}"; do
    [ -d "$dir" ] && { echo "$dir"; return; }
  done
  return 1
}

# Resolve the mstack scripts directory
scripts_dir() {
  local dir
  dir="$(skill_dir "mstack-run" 2>/dev/null || true)"
  if [ -n "$dir" ] && [ -d "$dir/scripts" ]; then
    echo "$dir/scripts"
    return
  fi
  # Fallback: relative to this file
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -d "$dir" ] && { echo "$dir"; return; }
  return 1
}

# Print project guidance files in precedence order.
guidance_files() {
  local root="${1:-$(repo_root)}"
  [ -f "$root/AGENTS.md" ] && echo "$root/AGENTS.md"
  [ -f "$root/CLAUDE.md" ] && echo "$root/CLAUDE.md"
}

# Execution manifest path
MANIFEST_FILE=".mstack/execution-manifest.json"

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warn: $*" >&2; }
info() { echo "$*" >&2; }
