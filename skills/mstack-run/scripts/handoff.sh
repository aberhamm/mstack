#!/usr/bin/env bash
# Deterministic handoff checkpoint helper.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/handoff.sh"
# shellcheck disable=SC1091
# shellcheck source=skills/mstack-run/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

HANDOFF_GLOB="*-handoff-*.md"

usage() {
  cat <<'EOF'
usage: handoff.sh <command> [args]

Commands:
  list [--all-projects]       List handoff checkpoints
  resolve [short-summary]     Print the checkpoint selected for resume
  resume [short-summary]      Print and delete the selected checkpoint
  prune [--all-projects]      Delete handoff checkpoints older than 7 days
  write-anomaly <reason>      Write an anomaly handoff from execution manifest
  self-test                   Run fixture-based tests
EOF
}

canonical_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  (cd "$dir" && pwd -P)
}

handoff_dir_for_project() {
  printf '%s/.mstack/handoffs\n' "$1"
}

summary_from_path() {
  local base="$1"
  base="$(basename "$base")"
  base="${base%.md}"
  case "$base" in
    ????-??-??-handoff-??-*) echo "${base#????-??-??-handoff-??-}" ;;
    *) echo "$base" ;;
  esac
}

stat_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"
}

age_label() {
  local file="$1" now mtime delta days hours mins
  now="$(date +%s)"
  mtime="$(stat_mtime "$file")"
  delta=$((now - mtime))
  [ "$delta" -ge 0 ] || delta=0
  days=$((delta / 86400))
  hours=$((delta / 3600))
  mins=$((delta / 60))
  if [ "$days" -gt 0 ]; then
    printf '%dd\n' "$days"
  elif [ "$hours" -gt 0 ]; then
    printf '%dh\n' "$hours"
  else
    printf '%dm\n' "$mins"
  fi
}

handoff_files_for_project() {
  local project="$1" hdir
  hdir="$(handoff_dir_for_project "$project")"
  [ -d "$hdir" ] || return 0
  find "$hdir" -maxdepth 1 -type f -name "$HANDOFF_GLOB" -print 2>/dev/null | sort
}

current_project_list() {
  canonical_dir "$(repo_root)"
}

skip_project_name() {
  case "$(basename "$1")" in
    .git|node_modules|.pnpm|dist|build|.next|coverage|target)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

append_unique_path() {
  local path="$1" file="$2"
  [ -n "$path" ] || return 0
  grep -qxF "$path" "$file" 2>/dev/null && return 0
  printf '%s\n' "$path" >> "$file"
}

known_project_parents() {
  if [ -n "${MSTACK_PROJECT_ROOTS:-}" ]; then
    echo "$MSTACK_PROJECT_ROOTS" | tr ':' '\n'
    return
  fi
  [ -d "$HOME/_projects" ] && echo "$HOME/_projects"
  [ -d "$HOME/dev/projects" ] && echo "$HOME/dev/projects"
}

all_project_list() {
  local tmp root parent canonical_parent child canonical_child
  tmp="$(mktemp)"

  root="$(current_project_list 2>/dev/null || true)"
  append_unique_path "$root" "$tmp"

  while IFS= read -r parent; do
    [ -n "$parent" ] || continue
    canonical_parent="$(canonical_dir "$parent" 2>/dev/null || true)"
    [ -n "$canonical_parent" ] || continue
    for child in "$canonical_parent"/*; do
      [ -d "$child" ] || continue
      skip_project_name "$child" && continue
      canonical_child="$(canonical_dir "$child" 2>/dev/null || true)"
      append_unique_path "$canonical_child" "$tmp"
    done
  done <<EOF
$(known_project_parents)
EOF

  sort "$tmp"
  rm -f "$tmp"
}

project_list_for_mode() {
  local all_projects="$1"
  if [ "$all_projects" = "true" ]; then
    all_project_list
  else
    current_project_list
  fi
}

print_checkpoint_entry() {
  local file="$1" summary
  summary="$(summary_from_path "$file")"
  printf '  %s\n' "$file"
  printf '    age: %s\n' "$(age_label "$file")"
  printf '    summary: %s\n' "$summary"
  printf '    resume: resume from handoff %s\n' "$summary"
}

cmd_list() {
  local all_projects=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --all-projects) all_projects=true; shift ;;
      *) die "usage: handoff.sh list [--all-projects]" ;;
    esac
  done

  local projects files_tmp empty_tmp missing_tmp project hdir count file
  projects="$(mktemp)"
  files_tmp="$(mktemp)"
  empty_tmp="$(mktemp)"
  missing_tmp="$(mktemp)"

  project_list_for_mode "$all_projects" > "$projects"

  while IFS= read -r project; do
    [ -n "$project" ] || continue
    hdir="$(handoff_dir_for_project "$project")"
    if [ ! -d "$hdir" ]; then
      printf '%s\n' "$project" >> "$missing_tmp"
      continue
    fi
    count="$(handoff_files_for_project "$project" | wc -l | tr -d ' ')"
    if [ "$count" -eq 0 ]; then
      printf '%s\n' "$hdir" >> "$empty_tmp"
      continue
    fi
    handoff_files_for_project "$project" >> "$files_tmp"
  done < "$projects"

  if [ -s "$files_tmp" ]; then
    echo "Handoff checkpoints:"
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      print_checkpoint_entry "$file"
    done < "$files_tmp"
  else
    echo "Handoff checkpoints: none"
  fi

  if [ -s "$empty_tmp" ]; then
    echo "Empty handoff directories:"
    sed 's/^/  /' "$empty_tmp"
  fi

  if [ -s "$missing_tmp" ]; then
    echo "Projects without handoff directory:"
    sed 's/^/  /' "$missing_tmp"
  fi
  rm -f "$projects" "$files_tmp" "$empty_tmp" "$missing_tmp"
}

newest_handoff_file() {
  local project="$1" tmp file mtime
  tmp="$(mktemp)"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    mtime="$(stat_mtime "$file")"
    printf '%s\t%s\n' "$mtime" "$file" >> "$tmp"
  done <<EOF
$(handoff_files_for_project "$project")
EOF
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    return 1
  fi
  sort -k1,1n -k2,2 "$tmp" | tail -1 | cut -f2-
  rm -f "$tmp"
}

resolve_by_summary() {
  local project="$1" wanted="$2" tmp file summary count
  tmp="$(mktemp)"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    summary="$(summary_from_path "$file")"
    [ "$summary" = "$wanted" ] || continue
    printf '%s\n' "$file" >> "$tmp"
  done <<EOF
$(handoff_files_for_project "$project")
EOF

  count="$(wc -l < "$tmp" | tr -d ' ')"
  case "$count" in
    0)
      echo "No handoff checkpoint found matching '$wanted' in .mstack/handoffs/." >&2
      rm -f "$tmp"
      return 2 ;;
    1)
      cat "$tmp"
      rm -f "$tmp" ;;
    *)
      echo "Ambiguous handoff summary '$wanted'; matches:" >&2
      sed 's/^/  /' "$tmp" >&2
      rm -f "$tmp"
      return 3 ;;
  esac
}

cmd_resolve() {
  local wanted="${1:-}" project file
  [ $# -le 1 ] || die "usage: handoff.sh resolve [short-summary]"
  project="$(current_project_list)"
  if [ -z "$wanted" ]; then
    file="$(newest_handoff_file "$project" 2>/dev/null || true)"
    if [ -z "$file" ]; then
      echo "No handoff checkpoints found." >&2
      return 2
    fi
    printf '%s\n' "$file"
  else
    resolve_by_summary "$project" "$wanted"
  fi
}

cmd_resume() {
  local wanted="${1:-}" file
  [ $# -le 1 ] || die "usage: handoff.sh resume [short-summary]"
  file="$(cmd_resolve "$wanted")" || return $?
  cat "$file"
  rm -f "$file"
  printf '\nHandoff loaded. Run the command in "Next step" when you are ready.\n'
}

prune_project() {
  local project="$1" hdir file count
  hdir="$(handoff_dir_for_project "$project")"
  [ -d "$hdir" ] || { echo 0; return; }
  count=0
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    rm -f "$file"
    count=$((count + 1))
  done <<EOF
$(find "$hdir" -maxdepth 1 -type f -name "$HANDOFF_GLOB" -mtime +7 -print 2>/dev/null)
EOF
  echo "$count"
}

cmd_prune() {
  local all_projects=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --all-projects) all_projects=true; shift ;;
      *) die "usage: handoff.sh prune [--all-projects]" ;;
    esac
  done

  local total projects project count
  total=0
  projects="$(mktemp)"
  project_list_for_mode "$all_projects" > "$projects"
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    count="$(prune_project "$project")"
    total=$((total + count))
  done < "$projects"
  rm -f "$projects"
  echo "pruned $total old handoff checkpoints"
}

require_jq() {
  has_jq || die "write-anomaly requires jq"
}

pending_ids_from_manifest() {
  local manifest_json="$1"
  echo "$manifest_json" | jq -r '
    . as $m
    | [($m.scope_ids // [])[] as $s | $s | select((($m.terminal_ids // []) | index($s)) | not)]
    | join(", ")
    | if . == "" then "none" else . end
  '
}

recovery_suggestion() {
  local anomaly_type="$1" manifest_json="$2" repeated_plan last_plan
  case "$anomaly_type" in
    iteration_bound)
      echo "Check plan statuses — a plan may be stuck in-progress. Run: /mstack-status" ;;
    repeat_pick)
      repeated_plan="$(echo "$manifest_json" | jq -r '.picked_history[-1] // "unknown"')"
      echo "Plan $repeated_plan was picked twice without completing. Check if it is stuck. Run: /mstack-run $repeated_plan" ;;
    no_progress)
      last_plan="$(echo "$manifest_json" | jq -r '.picked_history[-1] // "unknown"')"
      echo "Last iteration made no progress. Check plan $last_plan status and health gate. Run: /mstack-investigate" ;;
    path_divergence)
      echo "Plan files were moved/renamed during execution. Check docs/plans/ for changes. Run: /mstack-status" ;;
    *)
      echo "Unexpected anomaly type. Run: /mstack-status" ;;
  esac
}

cmd_write_anomaly() {
  local anomaly_reason="$*" anomaly_type manifest_json manifest_iteration
  local manifest_scope manifest_terminal manifest_picked manifest_goal git_branch
  local today handoff_dir handoff_nn handoff_file handoff_path recovery pending

  [ -n "$anomaly_reason" ] || die "usage: handoff.sh write-anomaly <reason>"
  require_jq

  anomaly_type="${anomaly_reason%%:*}"
  manifest_json="$(bash "$SCRIPT_DIR/manifest.sh" read 2>/dev/null || echo '{}')"
  manifest_iteration="$(echo "$manifest_json" | jq -r '.iteration_count // "unknown"')"
  manifest_scope="$(echo "$manifest_json" | jq -r '(.scope_ids // []) | join(", ") | if . == "" then "unknown" else . end')"
  manifest_terminal="$(echo "$manifest_json" | jq -r '(.terminal_ids // []) | join(", ") | if . == "" then "none" else . end')"
  manifest_picked="$(echo "$manifest_json" | jq -r '(.picked_history // []) | join(", ") | if . == "" then "none" else . end')"
  manifest_goal="$(echo "$manifest_json" | jq -r '.goal // ""')"
  pending="$(pending_ids_from_manifest "$manifest_json")"
  git_branch="$(git branch --show-current 2>/dev/null || echo "unknown")"
  today="$(date +%Y-%m-%d)"
  recovery="$(recovery_suggestion "$anomaly_type" "$manifest_json")"

  handoff_dir="$(repo_root)/.mstack/handoffs"
  mkdir -p "$handoff_dir"
  handoff_nn=1
  while [ -f "$handoff_dir/${today}-handoff-$(printf '%02d' "$handoff_nn")-anomaly-${anomaly_type}.md" ]; do
    handoff_nn=$((handoff_nn + 1))
  done
  handoff_file="${today}-handoff-$(printf '%02d' "$handoff_nn")-anomaly-${anomaly_type}.md"
  handoff_path="$handoff_dir/$handoff_file"

  cat > "$handoff_path" <<HANDOFF_EOF
<!-- CONTEXT ONLY: Do not start work. Wait for the user to run a command. -->

# Handoff: Anomaly during plan execution — ${anomaly_type}

**Date:** ${today}
**Branch:** ${git_branch}

## Goal
$([ -n "$manifest_goal" ] && echo "Goal name: ${manifest_goal}")
Execute scoped plans: ${manifest_scope}

## Current state
Completed plans: ${manifest_terminal}
Pending plans: ${pending}
Iteration count: ${manifest_iteration}
Anomaly detected at iteration ${manifest_iteration}.

## Files touched
- .mstack/execution-manifest.json (preserved for debugging)

## What's been tried and failed
- Anomaly type: ${anomaly_type}
- Reason: ${anomaly_reason}
- Picked history: ${manifest_picked}
- Manifest state at anomaly: scope=[${manifest_scope}], terminal=[${manifest_terminal}], iterations=${manifest_iteration}

## What's been ruled out
- The plan execution loop was halted automatically to prevent infinite looping.

## Next step
${recovery}

## Open questions
- Was the backlog intentionally modified during execution?
HANDOFF_EOF

  echo "[mstack] ANOMALY: ${anomaly_type} — ${anomaly_reason}. Handoff checkpoint saved."
  echo "[mstack] Handoff: .mstack/handoffs/${handoff_file}"
  echo "[mstack] To resume: resume from handoff anomaly-${anomaly_type}"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) echo "self-test failed: $label" >&2; exit 1 ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) echo "self-test failed: $label" >&2; exit 1 ;;
    *) ;;
  esac
}

write_fixture_handoff() {
  local project="$1" filename="$2" body="$3"
  mkdir -p "$project/.mstack/handoffs"
  printf '%s\n' "$body" > "$project/.mstack/handoffs/$filename"
}

cmd_self_test() {
  local tmp fixture_home projects alpha beta gamma alpha_real beta_real gamma_real
  local out count target dup_status
  local anomaly_out manifest_file
  tmp="$(mktemp -d)"
  SELF_TEST_TMP="$tmp"
  trap 'rm -rf "${SELF_TEST_TMP:-}"' EXIT
  fixture_home="$tmp/home"
  projects="$fixture_home/dev/projects"
  mkdir -p "$projects"
  ln -s "$projects" "$fixture_home/_projects"

  alpha="$projects/alpha"
  beta="$projects/beta"
  gamma="$projects/gamma"
  mkdir -p "$alpha" "$beta/.mstack/handoffs" "$gamma"
  git -C "$alpha" init -q
  git -C "$beta" init -q
  git -C "$gamma" init -q
  alpha_real="$(canonical_dir "$alpha")"
  beta_real="$(canonical_dir "$beta")"
  gamma_real="$(canonical_dir "$gamma")"

  write_fixture_handoff "$alpha" "2026-06-08-handoff-01-alpha-summary.md" "# Alpha handoff"
  mkdir -p "$projects/node_modules/fake/.mstack/handoffs"
  printf 'poison\n' > "$projects/node_modules/fake/.mstack/handoffs/2026-06-08-handoff-01-poison.md"

  out="$(cd "$alpha" && HOME="$fixture_home" "$SCRIPT_PATH" list)"
  assert_contains "$out" "alpha-summary" "current repo list includes handoff"
  assert_contains "$out" "resume from handoff alpha-summary" "list includes resume command"

  out="$(cd "$alpha" && HOME="$fixture_home" "$SCRIPT_PATH" list --all-projects)"
  count="$(printf '%s\n' "$out" | grep -c "^  $alpha_real/.mstack/handoffs/2026-06-08-handoff-01-alpha-summary.md$" || true)"
  [ "$count" -eq 1 ] || { echo "self-test failed: symlinked roots duplicate results" >&2; exit 1; }
  assert_contains "$out" "$beta_real/.mstack/handoffs" "empty handoff dir reported"
  assert_contains "$out" "$gamma_real" "missing handoff dir reported"
  assert_not_contains "$out" "poison" "node_modules handoff ignored"

  write_fixture_handoff "$alpha" "2026-06-08-handoff-02-resume-target.md" "# Resume target"
  target="$alpha/.mstack/handoffs/2026-06-08-handoff-02-resume-target.md"
  out="$(cd "$alpha" && HOME="$fixture_home" "$SCRIPT_PATH" resume resume-target)"
  assert_contains "$out" "# Resume target" "resume prints checkpoint"
  [ ! -f "$target" ] || { echo "self-test failed: resumed checkpoint was not deleted" >&2; exit 1; }
  [ -f "$alpha/.mstack/handoffs/2026-06-08-handoff-01-alpha-summary.md" ] || {
    echo "self-test failed: resume deleted the wrong checkpoint" >&2
    exit 1
  }

  write_fixture_handoff "$alpha" "2026-06-08-handoff-03-dup.md" "# Dup one"
  write_fixture_handoff "$alpha" "2026-06-09-handoff-01-dup.md" "# Dup two"
  dup_status=0
  (cd "$alpha" && HOME="$fixture_home" "$SCRIPT_PATH" resolve dup >/dev/null 2>"$tmp/dup.err") || dup_status=$?
  [ "$dup_status" -eq 3 ] || { echo "self-test failed: ambiguous summary did not exit 3" >&2; exit 1; }
  assert_contains "$(cat "$tmp/dup.err")" "Ambiguous handoff summary" "ambiguity message"

  manifest_file="$alpha/.mstack/execution-manifest.json"
  cat > "$manifest_file" <<'JSON'
{
  "version": 1,
  "goal": "fixture-goal",
  "scope_ids": ["007", "008"],
  "plans": {},
  "picked_history": ["007", "007"],
  "terminal_ids": ["007"],
  "iteration_count": 2
}
JSON
  anomaly_out="$(cd "$alpha" && HOME="$fixture_home" "$SCRIPT_PATH" write-anomaly "repeat_pick: plan 007 was picked twice")"
  assert_contains "$anomaly_out" "[mstack] ANOMALY: repeat_pick" "anomaly signal"
  assert_contains "$anomaly_out" "resume from handoff anomaly-repeat_pick" "anomaly resume command"
  [ -f "$manifest_file" ] || { echo "self-test failed: anomaly writer removed manifest" >&2; exit 1; }
  [ -f "$alpha/.mstack/handoffs/$(date +%Y-%m-%d)-handoff-01-anomaly-repeat_pick.md" ] || {
    echo "self-test failed: anomaly handoff not created" >&2
    exit 1
  }

  echo "handoff.sh self-test passed"
}

case "${1:---help}" in
  --help|-h|help) usage ;;
  list) shift; cmd_list "$@" ;;
  resolve) shift; cmd_resolve "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  prune) shift; cmd_prune "$@" ;;
  write-anomaly) shift; cmd_write_anomaly "$@" ;;
  self-test) shift; cmd_self_test "$@" ;;
  *) usage >&2; exit 2 ;;
esac
