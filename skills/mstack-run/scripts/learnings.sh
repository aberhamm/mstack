#!/usr/bin/env bash
# mstack learnings manager. JSONL knowledge base operations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT="$(repo_root)"
PROJECT_FILE="$ROOT/.mstack/learnings.jsonl"
GLOBAL_FILE="${HOME}/.mstack/learnings.jsonl"

# Ensure project file exists
ensure_file() {
  ensure_mstack_dir
  touch "$PROJECT_FILE"
}

cmd_list() {
  ensure_file
  local count
  count=$(jsonl_count "$PROJECT_FILE")
  echo "Project learnings ($count entries):"
  echo ""

  if [ "$count" -eq 0 ]; then
    echo "  (none)"
  elif has_jq; then
    for type in pattern pitfall convention dependency; do
      local type_upper
      type_upper=$(echo "$type" | tr '[:lower:]' '[:upper:]')
      local entries
      entries=$(grep "\"type\":\"$type\"" "$PROJECT_FILE" 2>/dev/null || true)
      [ -n "$entries" ] || continue
      local n
      n=$(echo "$entries" | wc -l | tr -d ' ')
      echo "  $type_upper ($n):"
      echo "$entries" | while read -r line; do
        local key conf insight
        key=$(echo "$line" | jq -r '.key' 2>/dev/null)
        conf=$(echo "$line" | jq -r '.confidence' 2>/dev/null)
        insight=$(echo "$line" | jq -r '.insight' 2>/dev/null)
        echo "    [$conf] $key — $insight"
      done
      echo ""
    done
  else
    cat "$PROJECT_FILE"
  fi

  if [ -f "$GLOBAL_FILE" ]; then
    local gcount
    gcount=$(jsonl_count "$GLOBAL_FILE")
    echo "Global learnings ($gcount entries)"
  fi
}

cmd_search() {
  local query="${1:-}"
  [ -n "$query" ] || die "usage: learnings.sh search <query>"
  ensure_file

  local results=""
  # Search project learnings
  if [ -s "$PROJECT_FILE" ]; then
    results=$(grep -i "$query" "$PROJECT_FILE" 2>/dev/null || true)
  fi
  # Search global learnings
  if [ -f "$GLOBAL_FILE" ] && [ -s "$GLOBAL_FILE" ]; then
    local global_results
    global_results=$(grep -i "$query" "$GLOBAL_FILE" 2>/dev/null || true)
    results="${results:+$results
}${global_results}"
  fi

  if [ -z "$results" ]; then
    echo "NO_MATCHES"
    exit 2
  fi

  if has_jq; then
    echo "$results" | while read -r line; do
      [ -n "$line" ] || continue
      local key conf insight type
      key=$(echo "$line" | jq -r '.key' 2>/dev/null)
      conf=$(echo "$line" | jq -r '.confidence' 2>/dev/null)
      insight=$(echo "$line" | jq -r '.insight' 2>/dev/null)
      type=$(echo "$line" | jq -r '.type' 2>/dev/null)
      echo "  [$conf] $key ($type) — $insight"
    done
  else
    echo "$results"
  fi
}

cmd_prune() {
  ensure_file
  [ -s "$PROJECT_FILE" ] || { echo "Learnings clean (0 entries)."; return 0; }
  has_jq || { warn "prune requires jq"; return 1; }

  local pruned=0 decayed=0 deduped=0
  local surviving=""
  local seen_keys=""
  local today_str
  today_str="$(today)"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local key conf refs_json last_verified type
    key=$(echo "$line" | jq -r '.key' 2>/dev/null)
    conf=$(echo "$line" | jq -r '.confidence // 5' 2>/dev/null)
    refs_json=$(echo "$line" | jq -r '.refs // [] | .[]' 2>/dev/null)
    last_verified=$(echo "$line" | jq -r '.last_verified // ""' 2>/dev/null)

    # 1. Check refs exist
    local total=0 gone=0
    if [ -n "$refs_json" ]; then
      while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        total=$((total + 1))
        [ -e "$ROOT/$ref" ] || gone=$((gone + 1))
      done <<< "$refs_json"
    fi

    if [ "$total" -gt 0 ] && [ "$gone" -gt 0 ]; then
      local gone_pct=$((gone * 100 / total))
      if [ "$gone_pct" -gt 50 ]; then
        info "pruned: $key (>50% refs gone)"
        pruned=$((pruned + 1))
        continue
      else
        conf=$((conf - 2))
        [ "$conf" -lt 1 ] && conf=1
        line=$(echo "$line" | jq --argjson c "$conf" '.confidence = $c')
      fi
    fi

    # 2. Dedup by key
    case " $seen_keys " in
      *" $key "*)
        info "deduped: $key"
        deduped=$((deduped + 1))
        continue ;;
    esac
    seen_keys="$seen_keys $key"

    # 3. Low-confidence decay
    if [ "$conf" -le 3 ] && [ -n "$last_verified" ]; then
      local age
      age=$(days_since "$last_verified" 2>/dev/null || echo 0)
      if [ "$age" -gt 30 ]; then
        info "pruned: $key (confidence $conf, unverified ${age}d)"
        pruned=$((pruned + 1))
        continue
      fi
    fi

    # 4. Graduated confidence decay (14+ days unverified)
    if [ -n "$last_verified" ]; then
      local age
      age=$(days_since "$last_verified" 2>/dev/null || echo 0)
      if [ "$age" -gt 14 ]; then
        conf=$((conf - 1))
        [ "$conf" -lt 1 ] && conf=1
        line=$(echo "$line" | jq --argjson c "$conf" '.confidence = $c')
        decayed=$((decayed + 1))
      fi
    fi

    surviving="${surviving:+$surviving
}$line"
  done < "$PROJECT_FILE"

  # Write survivors back
  if [ -n "$surviving" ]; then
    printf '%s\n' "$surviving" > "$PROJECT_FILE"
  else
    : > "$PROJECT_FILE"
  fi

  local remaining
  remaining=$(jsonl_count "$PROJECT_FILE")
  if [ "$pruned" -eq 0 ] && [ "$deduped" -eq 0 ] && [ "$decayed" -eq 0 ]; then
    echo "Learnings clean ($remaining entries)."
  else
    echo "Pruned: $pruned removed, $deduped deduped, $decayed decayed. $remaining remaining."
  fi
}

cmd_append() {
  local json="${1:-}"
  [ -n "$json" ] || json="$(cat)"
  [ -n "$json" ] || die "no learning data provided"
  ensure_file

  if has_jq; then
    local new_key
    new_key=$(echo "$json" | jq -r '.key' 2>/dev/null)
    [ -n "$new_key" ] || die "learning must have a key"

    # Check for existing entry with same key
    local existing
    existing=$(grep "\"key\":\"$new_key\"" "$PROJECT_FILE" 2>/dev/null || true)
    if [ -n "$existing" ]; then
      # Merge: bump confidence, update last_verified
      local old_conf new_conf
      old_conf=$(echo "$existing" | head -1 | jq -r '.confidence // 5')
      new_conf=$((old_conf + 1))
      [ "$new_conf" -gt 10 ] && new_conf=10
      json=$(echo "$json" | jq --argjson c "$new_conf" '.confidence = $c | .last_verified = "'"$(today)"'"')
      # Remove old entry, append new
      grep -v "\"key\":\"$new_key\"" "$PROJECT_FILE" > "${PROJECT_FILE}.tmp" || true
      mv "${PROJECT_FILE}.tmp" "$PROJECT_FILE"
      info "updated: $new_key (confidence $old_conf → $new_conf)"
    fi
  fi

  jsonl_append "$PROJECT_FILE" "$json"
  echo "OK"
}

cmd_get() {
  local key="${1:-}"
  [ -n "$key" ] || die "usage: learnings.sh get <key>"
  ensure_file
  grep "\"key\":\"$key\"" "$PROJECT_FILE" 2>/dev/null || exit 2
}

cmd_bump() {
  local key="${1:-}"
  [ -n "$key" ] || die "usage: learnings.sh bump <key>"
  ensure_file
  has_jq || { warn "bump requires jq"; return 1; }

  local existing
  existing=$(grep "\"key\":\"$key\"" "$PROJECT_FILE" 2>/dev/null || true)
  [ -n "$existing" ] || { warn "key not found: $key"; exit 2; }

  local old_conf new_conf
  old_conf=$(echo "$existing" | head -1 | jq -r '.confidence // 5')
  new_conf=$((old_conf + 1))
  [ "$new_conf" -gt 10 ] && new_conf=10

  local updated
  updated=$(echo "$existing" | head -1 | jq --argjson c "$new_conf" '.confidence = $c | .last_verified = "'"$(today)"'"')

  grep -v "\"key\":\"$key\"" "$PROJECT_FILE" > "${PROJECT_FILE}.tmp" || true
  mv "${PROJECT_FILE}.tmp" "$PROJECT_FILE"
  jsonl_append "$PROJECT_FILE" "$updated"
  echo "bumped $key: $old_conf → $new_conf"
}

case "${1:-list}" in
  list)    cmd_list ;;
  search)  cmd_search "${2:-}" ;;
  prune)   cmd_prune ;;
  append)  cmd_append "${2:-}" ;;
  get)     cmd_get "${2:-}" ;;
  bump)    cmd_bump "${2:-}" ;;
  *)       die "usage: learnings.sh {list|search|prune|append|get|bump}" ;;
esac
