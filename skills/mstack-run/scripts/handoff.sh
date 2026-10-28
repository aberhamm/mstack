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
  resume [short-summary]      Print and archive the selected checkpoint
  prune [--all-projects]      Delete active/consumed checkpoints older than 7 days
  write-anomaly <reason>      Write an anomaly handoff from execution manifest
  cctrl-status                Report whether a cctrl spawn handoff is available
  spawn [short-summary]       Spawn a detached cctrl session to resume a handoff
  close-self [grace-seconds]  Close the current cctrl session (default grace)
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
  local wanted="${1:-}" file archive_dir archived
  [ $# -le 1 ] || die "usage: handoff.sh resume [short-summary]"
  file="$(cmd_resolve "$wanted")" || return $?
  if ! LC_ALL=C grep -q '[^[:space:]]' "$file"; then
    echo "Handoff checkpoint is empty or unreadable: $file" >&2
    return 1
  fi
  # Keep a recovery copy outside active lookup. A unique directory avoids
  # overwriting an earlier consumption of the same checkpoint filename.
  mkdir -p "$(dirname "$file")/consumed" || return 1
  archive_dir="$(mktemp -d "$(dirname "$file")/consumed/checkpoint.XXXXXX")" || return 1
  if ! cat "$file"; then
    rmdir "$archive_dir"
    return 1
  fi
  archived="$archive_dir/$(basename "$file")"
  if ! mv "$file" "$archived"; then
    rmdir "$archive_dir"
    return 1
  fi
  # Retention starts at consumption, not at the checkpoint's creation date.
  touch "$archived" || return 1
  printf '\nRecovery checkpoint: %s\n' "$archived"
  printf 'Handoff context loaded. Verify current state and present the resume briefing before continuing.\n'
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
$(find "$hdir" -maxdepth 1 -type f -name "$HANDOFF_GLOB" -mtime +6 -print 2>/dev/null)
EOF
  if [ -d "$hdir/consumed" ]; then
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      rm -f "$file"
      rmdir "$(dirname "$file")" 2>/dev/null || true
      count=$((count + 1))
    done <<EOF
$(find "$hdir/consumed" -mindepth 2 -maxdepth 2 -type f -name "$HANDOFF_GLOB" -mtime +6 -print 2>/dev/null)
EOF
  fi
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
<!-- CONTEXT ONLY: Verify current state, brief the user on what matters, and recommend the next action. Wait for authorization before continuing the work. -->

<!-- ON RESUME: Treat this as historical working context. Check current disk state and the latest user message, then present task/status, the recommended next action, and decisions or important outstanding state. Do not dump this document or start implementation without authorization. -->

# Handoff: Anomaly during plan execution — ${anomaly_type}

**Date:** ${today}
**Checkout:** $(repo_root)
**HEAD:** $(git rev-parse HEAD 2>/dev/null || echo "n/a")
**Branch:** ${git_branch}

## Goal
$([ -n "$manifest_goal" ] && echo "Goal name: ${manifest_goal}")
Execute scoped plans: ${manifest_scope}

## Constraints and decisions
- The execution loop halted on an anomaly; inspect current state before restarting.

## Current state
Completed plans: ${manifest_terminal}
Pending plans: ${pending}
Iteration count: ${manifest_iteration}
Anomaly detected at iteration ${manifest_iteration}.

## Verification
- This snapshot comes from the execution manifest, not an independent verification
  of completed work, review gates, or health checks. Re-check the relevant plans.

## Files touched
- .mstack/execution-manifest.json (preserved for debugging)

## What's been tried and failed
- Anomaly type: ${anomaly_type}
- Reason: ${anomaly_reason}
- Picked history: ${manifest_picked}
- Manifest state at anomaly: scope=[${manifest_scope}], terminal=[${manifest_terminal}], iterations=${manifest_iteration}

## What's been ruled out
- No root cause has been established by this snapshot.

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
  local out count target dup_status archived second_archive failure_status
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
  [ ! -f "$target" ] || { echo "self-test failed: resumed checkpoint is still active" >&2; exit 1; }
  archived="$(printf '%s\n' "$out" | sed -n 's/^Recovery checkpoint: //p')"
  [ -f "$archived" ] || { echo "self-test failed: recovery checkpoint missing" >&2; exit 1; }
  [ "$(cat "$archived")" = "# Resume target" ] || { echo "self-test failed: archived content changed" >&2; exit 1; }
  out="$(cd "$alpha" && HOME="$fixture_home" "$SCRIPT_PATH" list)"
  assert_not_contains "$out" "resume-target" "consumed checkpoint excluded from list"
  failure_status=0
  (cd "$alpha" && HOME="$fixture_home" "$SCRIPT_PATH" resolve resume-target >/dev/null 2>&1) || failure_status=$?
  [ "$failure_status" -eq 2 ] || { echo "self-test failed: consumed checkpoint resolved as active" >&2; exit 1; }
  # Recovery and repeated consumption must preserve both copies.
  cp "$archived" "$target"
  out="$(cd "$alpha" && HOME="$fixture_home" "$SCRIPT_PATH" resume resume-target)"
  second_archive="$(printf '%s\n' "$out" | sed -n 's/^Recovery checkpoint: //p')"
  if [ "$second_archive" = "$archived" ] || ! cmp "$archived" "$second_archive"; then
    echo "self-test failed: repeated consumption overwrote recovery copy" >&2; exit 1;
  fi
  [ -f "$alpha/.mstack/handoffs/2026-06-08-handoff-01-alpha-summary.md" ] || {
    echo "self-test failed: resume consumed the wrong checkpoint" >&2
    exit 1
  }

  # Refuse empty content; preserve the original on setup or output failure.
  write_fixture_handoff "$beta" "2026-06-08-handoff-01-empty.md" " "
  failure_status=0
  (cd "$beta" && HOME="$fixture_home" "$SCRIPT_PATH" resume empty >/dev/null 2>&1) || failure_status=$?
  [ "$failure_status" -ne 0 ] && [ -f "$beta/.mstack/handoffs/2026-06-08-handoff-01-empty.md" ] || {
    echo "self-test failed: empty checkpoint consumed" >&2; exit 1;
  }
  write_fixture_handoff "$beta" "2026-06-08-handoff-02-blocked.md" "# Archive blocked"
  printf 'block archive directory\n' > "$beta/.mstack/handoffs/consumed"
  failure_status=0
  (cd "$beta" && HOME="$fixture_home" "$SCRIPT_PATH" resume blocked >/dev/null 2>&1) || failure_status=$?
  [ "$failure_status" -ne 0 ] && [ -f "$beta/.mstack/handoffs/2026-06-08-handoff-02-blocked.md" ] || {
    echo "self-test failed: checkpoint lost on archive failure" >&2; exit 1;
  }
  mkdir -p "$tmp/mock-bin"
  cat > "$tmp/mock-bin/cat" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  *-output-failure.md) exit 1 ;;
  *) exec /bin/cat "$@" ;;
esac
SH
  chmod +x "$tmp/mock-bin/cat"
  write_fixture_handoff "$alpha" "2026-06-08-handoff-04-output-failure.md" "# Output failure"
  failure_status=0
  (cd "$alpha" && PATH="$tmp/mock-bin:$PATH" HOME="$fixture_home" "$SCRIPT_PATH" resume output-failure >/dev/null 2>&1) || failure_status=$?
  [ "$failure_status" -ne 0 ] && [ -f "$alpha/.mstack/handoffs/2026-06-08-handoff-04-output-failure.md" ] || {
    echo "self-test failed: checkpoint lost on output failure" >&2; exit 1;
  }
  # Expire an active and a consumed checkpoint, retaining the fresh recovery.
  touch -t 200001010000 "$archived" "$alpha/.mstack/handoffs/2026-06-08-handoff-04-output-failure.md"
  out="$(cd "$alpha" && HOME="$fixture_home" "$SCRIPT_PATH" prune)"
  assert_contains "$out" "pruned 2 old handoff checkpoints" "prune covers active and consumed"
  [ ! -e "$archived" ] && [ ! -d "$(dirname "$archived")" ] && [ -f "$second_archive" ] || {
    echo "self-test failed: archive retention/pruning incorrect" >&2; exit 1;
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

# --- cctrl spawn-handoff support -------------------------------------------
#
# These commands are only meaningful when the handoff runs inside a
# cctrl-managed session. They degrade silently everywhere else: cctrl-status
# reports available=false and the skill simply never offers the spawn mode.

cctrl_available() {
  command -v cctrl >/dev/null 2>&1 && [ -n "${CCTRL_SESSION_NAME:-}" ]
}

# Names of all cctrl-managed sessions, one per line, sorted.
cctrl_session_names() {
  cctrl session ls --json 2>/dev/null | jq -r '.[].name' 2>/dev/null | sort || true
}

# Emit key=value lines describing the current session so the skill can decide
# whether to offer spawn mode and can show the user their session id.
cmd_cctrl_status() {
  if ! cctrl_available; then
    echo "available=false"
    return 0
  fi

  local json session target agent cwd can_close
  json="$(cctrl session current --json 2>/dev/null || true)"
  session="${CCTRL_SESSION_NAME:-}"
  target="${CCTRL_SESSION_TARGET:-}"
  agent="${CCTRL_AGENT:-}"
  cwd=""
  can_close="false"

  if [ -n "$json" ] && command -v jq >/dev/null 2>&1; then
    local v
    v="$(printf '%s' "$json" | jq -r '.session // empty' 2>/dev/null || true)"
    [ -n "$v" ] && session="$v"
    v="$(printf '%s' "$json" | jq -r '.target // empty' 2>/dev/null || true)"
    [ -n "$v" ] && target="$v"
    v="$(printf '%s' "$json" | jq -r '.agent // empty' 2>/dev/null || true)"
    [ -n "$v" ] && agent="$v"
    cwd="$(printf '%s' "$json" | jq -r '.cwd // empty' 2>/dev/null || true)"
    can_close="$(printf '%s' "$json" | jq -r 'if .can_close_self then "true" else "false" end' 2>/dev/null || echo false)"
  fi

  echo "available=true"
  echo "session=${session}"
  echo "target=${target}"
  echo "agent=${agent}"
  echo "cwd=${cwd}"
  echo "can_close_self=${can_close}"
}

# Spawn a detached cctrl session seeded to resume the named handoff, then
# validate that a new managed session actually appeared. Prints key=value
# lines: spawn_ok, plus new_session/attach_command/resume_command on success.
cmd_spawn() {
  local wanted="${1:-}"
  [ $# -le 1 ] || die "usage: handoff.sh spawn [short-summary]"
  cctrl_available || die "spawn requires a cctrl-managed session"

  # Resolve (without deleting) the checkpoint so we fail early on a bad summary
  # and build a stable resume command from the canonical short-summary.
  local file summary
  file="$(cmd_resolve "$wanted")" || return $?
  summary="$(summary_from_path "$file")"

  local target spawn_msg before after new_session
  target="${CCTRL_SESSION_TARGET:-}"
  spawn_msg="resume from handoff ${summary}"

  before="$(mktemp)"
  after="$(mktemp)"
  cctrl_session_names > "$before"

  # Detached launch so the new agent loads the handoff and waits for the user.
  if [ -n "$target" ]; then
    cctrl start "$target" -d -m "$spawn_msg" >/dev/null 2>&1 || true
  else
    cctrl start "$(repo_root)" -d -m "$spawn_msg" >/dev/null 2>&1 || true
  fi

  # Validate: poll briefly for a new managed session name to appear.
  new_session=""
  for _ in 1 2 3 4 5 6 7 8; do
    cctrl_session_names > "$after"
    new_session="$(comm -13 "$before" "$after" 2>/dev/null | head -1)"
    [ -n "$new_session" ] && break
    sleep 1
  done
  rm -f "$before" "$after"

  if [ -z "$new_session" ]; then
    echo "spawn_ok=false"
    echo "reason=no new cctrl session appeared after launch"
    return 1
  fi

  echo "spawn_ok=true"
  echo "new_session=${new_session}"
  echo "resume_command=${spawn_msg}"
  echo "attach_command=cctrl session attach ${new_session}"
}

# Close the current cctrl session. Default uses cctrl's built-in grace period
# so the calling turn can finish before the pane is killed.
cmd_close_self() {
  local grace="${1:-}"
  cctrl_available || die "close-self requires a cctrl-managed session"
  if [ -n "$grace" ]; then
    cctrl close --in "$grace"
  else
    cctrl close
  fi
}

case "${1:---help}" in
  --help|-h|help) usage ;;
  list) shift; cmd_list "$@" ;;
  resolve) shift; cmd_resolve "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  prune) shift; cmd_prune "$@" ;;
  write-anomaly) shift; cmd_write_anomaly "$@" ;;
  cctrl-status) shift; cmd_cctrl_status "$@" ;;
  spawn) shift; cmd_spawn "$@" ;;
  close-self) shift; cmd_close_self "$@" ;;
  self-test) shift; cmd_self_test "$@" ;;
  *) usage >&2; exit 2 ;;
esac
