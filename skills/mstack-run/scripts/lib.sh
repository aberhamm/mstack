#!/usr/bin/env bash
# Shared library for mstack scripts. Source this, don't execute it.
# shellcheck disable=SC2034

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

# --- Exit codes for resolve_plan_ref() (plan-ref resolver, this file) ---
# Range 21-22 avoids collision with pick-next.sh's 10-19 and seam-check.sh's
# own contract (20).
EXIT_REF_AMBIGUOUS=21
EXIT_REF_NOT_FOUND=22

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
    jq -r ".$path // empty" "$file" 2>/dev/null
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

# Normalize a plan ID: strip leading zeros (008 -> 8, 0 -> 0).
# Note: pick-next.sh, status.sh, and manifest.sh each carry their own copy of
# this (pre-existing duplication, out of scope for this change); this copy is
# what the plan-ref helpers below use.
normalize_id() {
  local raw="$1"
  local n="$raw"
  while [ "${n#0}" != "$n" ]; do
    n="${n#0}"
  done
  [ -n "$n" ] || n="0"
  echo "$n"
}

# plan_file_for_id <id>: print the repo-relative path of the plan whose
# frontmatter id: matches the normalized ID. Searches the plans dir and its
# archive/ subdirectory. Returns nonzero when no plan matches.
plan_file_for_id() {
  local id="$1"
  local pdir root id_num
  pdir="$(plans_dir)" || return 1
  root="$(repo_root)"
  id_num="$(normalize_id "$id")"

  local f fid fid_num
  for f in "$pdir"/*.md "$pdir"/archive/*.md; do
    [ -f "$f" ] || continue
    fid="$(fm_get "$f" id 2>/dev/null || true)"
    [ -n "$fid" ] || continue
    fid_num="$(normalize_id "$fid")"
    if [ "$fid_num" = "$id_num" ]; then
      echo "${f#"$root"/}"
      return 0
    fi
  done
  return 1
}

# plan_title <id>: print the plan's frontmatter title, falling back to a
# humanized filename slug (hyphens replaced with spaces) when the title is
# empty/absent, and finally to "(untitled)" if neither is available. Returns
# nonzero when no plan matches the id.
plan_title() {
  local id="$1"
  local f
  f="$(plan_file_for_id "$id")" || return 1
  local title
  title="$(fm_get "$f" title 2>/dev/null || true)"
  if [ -z "$title" ]; then
    local base slug
    base="$(basename "$f" .md)"
    slug="${base#*-}"
    title="$(echo "$slug" | tr '-' ' ')"
  fi
  [ -n "$title" ] || title="(untitled)"
  echo "$title"
}

# plan_label <id>: print the display string "NNN: Title" (id zero-padded to
# width 3, the current filename convention). Returns nonzero when no plan
# matches the id.
plan_label() {
  local id="$1"
  local title
  title="$(plan_title "$id")" || return 1
  local id_num padded
  id_num="$(normalize_id "$id")"
  padded="$(printf '%03d' "$id_num" 2>/dev/null)" || padded="$id_num"
  echo "${padded}: ${title}"
}

# Internal: print "archived" or "active" for a plan file path, based on
# whether it lives under the archive/ subdirectory.
_plan_ref_status() {
  case "$1" in
    */archive/*) echo "archived" ;;
    *) echo "active" ;;
  esac
}

# Internal: whole-token, case-insensitive containment check. Tokens are
# delimited by '-', ' ', or string start/end — never a raw substring match
# (e.g. "03" must not match inside "031"). Caller passes both operands
# already lowercased.
_ref_whole_token_match() {
  local needle="$1" haystack="$2"
  local padded
  padded=" $(echo "$haystack" | tr '-' ' ') "
  case "$padded" in
    *" $needle "*) return 0 ;;
    *) return 1 ;;
  esac
}

# resolve_plan_ref <ref>: resolve a numeric ID (bare or zero-padded) or a
# case-insensitive name fragment (matched against the filename slug and the
# frontmatter title) to a canonical bare numeric ID.
#
# Precedence:
#   1. ref is all digits -> normalize -> exact ID match.
#   2. Exact case-insensitive match against a plan's slug or title.
#   3. A unique whole-token case-insensitive match against slug or title.
# Multiple candidates at step 2 or 3 is ambiguous: prints each candidate as
# "NNN: Title" (via plan_label) to stderr and returns EXIT_REF_AMBIGUOUS. No
# match at all returns EXIT_REF_NOT_FOUND.
#
# Archive-aware: on success, stdout is a single line "<bare_id> <status>"
# (status is "active" or "archived") so callers needing an executable plan
# can reject an archive-only match — e.g. `read -r id status <<<"$(resolve_plan_ref
# "$ref")"`. Callers that only want the ID take the first field, e.g.
# `id="$(resolve_plan_ref "$ref")"; id="${id%% *}"`.
#
# NOTE: an earlier draft of this function reported status via a global
# variable instead. That does not work: the standard calling convention
# `id=$(resolve_plan_ref "$ref")` runs the function in a subshell (command
# substitution forks), so any global variable it sets is discarded when the
# subshell exits. Encoding status in stdout itself is the only channel that
# survives that call pattern, hence the two-field line below.
resolve_plan_ref() {
  local ref="$1"
  [ -n "$ref" ] || return "$EXIT_REF_NOT_FOUND"

  # 1. Numeric ID: exact match.
  case "$ref" in
    *[!0-9]*) ;;
    *)
      local f
      if f="$(plan_file_for_id "$ref")"; then
        echo "$(normalize_id "$ref") $(_plan_ref_status "$f")"
        return 0
      fi
      return "$EXIT_REF_NOT_FOUND"
      ;;
  esac

  # 2/3. Name fragment: exact slug/title match, else unique whole-token match.
  local pdir
  pdir="$(plans_dir)" || return "$EXIT_REF_NOT_FOUND"
  local ref_lc
  ref_lc="$(echo "$ref" | tr '[:upper:]' '[:lower:]')"

  local exact_list="" token_list=""
  local f fid base slug title slug_lc title_lc
  for f in "$pdir"/*.md "$pdir"/archive/*.md; do
    [ -f "$f" ] || continue
    fid="$(fm_get "$f" id 2>/dev/null || true)"
    [ -n "$fid" ] || continue

    base="$(basename "$f" .md)"
    slug="${base#*-}"
    title="$(fm_get "$f" title 2>/dev/null || true)"
    slug_lc="$(echo "$slug" | tr '[:upper:]' '[:lower:]')"
    title_lc="$(echo "$title" | tr '[:upper:]' '[:lower:]')"

    if [ "$slug_lc" = "$ref_lc" ] || [ "$title_lc" = "$ref_lc" ]; then
      printf -v exact_list '%s%s %s\n' "$exact_list" "$fid" "$f"
      continue
    fi

    if _ref_whole_token_match "$ref_lc" "$slug_lc" || _ref_whole_token_match "$ref_lc" "$title_lc"; then
      printf -v token_list '%s%s %s\n' "$token_list" "$fid" "$f"
    fi
  done

  local chosen="$exact_list"
  [ -n "$chosen" ] || chosen="$token_list"

  local match_count
  match_count="$(printf '%s' "$chosen" | grep -c . || true)"

  if [ "$match_count" -eq 0 ]; then
    return "$EXIT_REF_NOT_FOUND"
  fi

  if [ "$match_count" -gt 1 ]; then
    echo "resolve_plan_ref: ambiguous ref '$ref' matches multiple plans:" >&2
    printf '%s' "$chosen" | while IFS= read -r _line; do
      [ -n "$_line" ] || continue
      plan_label "${_line%% *}" >&2 || echo "  (unresolved: $_line)" >&2
    done
    return "$EXIT_REF_AMBIGUOUS"
  fi

  # Exactly one match.
  local sole_line sole_fid sole_f
  sole_line="$(printf '%s' "$chosen" | head -1)"
  sole_fid="${sole_line%% *}"
  sole_f="${sole_line#* }"
  echo "$(normalize_id "$sole_fid") $(_plan_ref_status "$sole_f")"
  return 0
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
