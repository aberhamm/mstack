#!/usr/bin/env bash
# mstack status dashboard. Read-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT="$(repo_root)"

normalize_id() {
  local n="$1"
  while [ "${n#0}" != "$n" ]; do
    n="${n#0}"
  done
  [ -n "$n" ] || n="0"
  echo "$n"
}

# Format "NNN: Title" for a plan whose id/title/file are already in hand
# from an fm_get pass over the backlog (matches plan_label's output in
# lib.sh: zero-padded id, title falling back to a humanized filename slug).
# Callers that loop over the backlog must call this instead of plan_label()
# per row — plan_label() re-scans the plans+archive directories on every
# call, so calling it once per row is O(n^2) over the backlog (see plan 032
# Design). This helper reuses values already fetched in the single pass
# instead of re-scanning.
format_plan_label() {
  local id="$1" title="$2" file="$3"
  if [ -z "$title" ]; then
    local base slug
    base="$(basename "$file" .md)"
    slug="${base#*-}"
    title="$(echo "$slug" | tr '-' ' ')"
  fi
  [ -n "$title" ] || title="(untitled)"
  local id_num padded
  id_num="$(normalize_id "$id")"
  padded="$(printf '%03d' "$id_num" 2>/dev/null)" || padded="$id_num"
  echo "${padded}: ${title}"
}

cmd_dashboard() {
  local pdir
  pdir="$(plans_dir 2>/dev/null)" || { echo "No plans directory found."; exit 2; }

  local done=0 failed=0 in_progress=0 blocked=0 pending=0 skipped=0
  local next_id="" next_label=""
  local recent_done=""
  local open_gates=""

  # Build done-ids list for dependency checking (scan both main dir and archive/)
  local DONE_IDS=" "
  while IFS= read -r f; do
    local status
    status="$(fm_get "$f" status || true)"
    [ "$status" = "done" ] || continue
    local fid
    fid="$(fm_get "$f" id || true)"
    [ -n "$fid" ] && DONE_IDS="$DONE_IDS$fid "
  done < <({ find "$pdir" -maxdepth 1 -type f -name '*.md'; [ -d "$pdir/archive" ] && find "$pdir/archive" -maxdepth 1 -type f -name '*.md'; } | sort)

  while IFS= read -r f; do
    local status id title
    status="$(fm_get "$f" status || true)"
    id="$(fm_get "$f" id || true)"
    title="$(fm_get "$f" title || true)"
    [ -n "$status" ] || continue

    # Open-gate check (plan 036): cheap frontmatter pre-filter first, so we
    # only spawn review-gate.sh for plans that actually declare a review
    # requirement — one bounded subprocess per flagged plan, not O(n^2) over
    # the backlog. Only pending/blocked plans are checked; done plans already
    # passed the gate at Step 7a, and failed/skipped/in-progress aren't
    # completion candidates right now.
    case "$status" in
      pending|blocked)
        local gate_nr gate_rr gate_flagged=false
        gate_nr="$(fm_get "$f" needs-review || true)"
        gate_rr="$(fm_get "$f" review-required || true)"
        if { [ -n "$gate_nr" ] && [ "$gate_nr" != "none" ]; } \
          || { [ -n "$gate_rr" ] && [ "$gate_rr" != "none" ]; }; then
          gate_flagged=true
        fi
        if [ "$gate_flagged" = "true" ]; then
          local gate_msg gate_rc=0 gate_detail
          gate_msg="$(bash "$SCRIPT_DIR/review-gate.sh" assert-completable "$f" 2>&1 1>/dev/null)" || gate_rc=$?
          if [ "$gate_rc" -ne 0 ]; then
            gate_detail="$(echo "$gate_msg" | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
            open_gates="${open_gates}  $(format_plan_label "$id" "$title" "$f")  blocked: review required but not recorded (${gate_detail})
"
          fi
        fi
        ;;
    esac

    case "$status" in
      done)
        done=$((done + 1))
        local completed
        completed="$(fm_get "$f" completed || true)"
        recent_done="${recent_done}  $(format_plan_label "$id" "$title" "$f")  done   ${completed:-?}
"
        ;;
      failed)      failed=$((failed + 1)) ;;
      in-progress) in_progress=$((in_progress + 1)) ;;
      blocked)     blocked=$((blocked + 1)) ;;
      skipped)     skipped=$((skipped + 1)) ;;
      pending)
        pending=$((pending + 1))
        # Check if this could be the next ready plan
        if [ -z "$next_id" ]; then
          local needs_review
          needs_review="$(fm_get "$f" needs-review || true)"
          [ -z "$needs_review" ] || [ "$needs_review" = "none" ] || continue

          local blocked_raw unblocked=true
          blocked_raw="$(fm_get "$f" blocked-by || true)"
          if [ -n "$blocked_raw" ] && [ "$blocked_raw" != "[]" ]; then
            local clean="${blocked_raw#[}"; clean="${clean%]}"
            for dep in $( echo "$clean" | tr ',' ' ' ); do
              dep="$(echo "$dep" | tr -d ' ')"
              [ -z "$dep" ] && continue
              case "$DONE_IDS" in
                *" $dep "*) ;;
                *) unblocked=false; break ;;
              esac
            done
          fi
          if [ "$unblocked" = "true" ]; then
            next_id="$id"
            next_label="$(format_plan_label "$id" "$title" "$f")"
          fi
        fi
        ;;
    esac
  done < <({ find "$pdir" -maxdepth 1 -type f -name '*.md'; [ -d "$pdir/archive" ] && find "$pdir/archive" -maxdepth 1 -type f -name '*.md'; } | sort)

  local project_name
  project_name="$(basename "$ROOT")"
  local branch
  branch="$(git branch --show-current 2>/dev/null || echo unknown)"

  # Compute last activity age from most recent plan completion date
  local last_activity_ago=""
  local last_activity_date=""
  if [ -n "$recent_done" ]; then
    last_activity_date="$(echo "$recent_done" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' | head -1)"
    if [ -n "$last_activity_date" ]; then
      local last_epoch now_epoch
      last_epoch="$(date -j -f '%Y-%m-%d' "$last_activity_date" '+%s' 2>/dev/null \
        || date -d "$last_activity_date" '+%s' 2>/dev/null \
        || true)"
      now_epoch="$(date '+%s')"
      if [ -n "$last_epoch" ]; then
        local diff_days=$(( (now_epoch - last_epoch) / 86400 ))
        if [ "$diff_days" -eq 0 ]; then
          last_activity_ago="today"
        elif [ "$diff_days" -eq 1 ]; then
          last_activity_ago="yesterday"
        elif [ "$diff_days" -lt 7 ]; then
          last_activity_ago="${diff_days} days ago"
        elif [ "$diff_days" -lt 30 ]; then
          last_activity_ago="$(( diff_days / 7 )) weeks ago"
        else
          last_activity_ago="$(( diff_days / 30 )) months ago"
        fi
      fi
    fi
  fi

  echo "MSTACK STATUS"
  echo "============="
  echo "Project: $project_name"
  echo "Branch:  $branch"
  echo "Date:    $(today)"
  if [ -n "$last_activity_ago" ]; then
    echo "Last activity: $last_activity_ago ($last_activity_date)"
  fi
  echo ""
  echo "BACKLOG"
  echo "  Done:        $done plans"
  [ "$failed" -gt 0 ] && echo "  Failed:      $failed plans"
  [ "$in_progress" -gt 0 ] && echo "  In Progress: $in_progress plans"
  [ "$blocked" -gt 0 ] && echo "  Blocked:     $blocked plans"
  echo "  Pending:     $pending plans"
  if [ -n "$next_id" ]; then
    echo "  Next ready:  $next_label"
  elif [ "$pending" -gt 0 ]; then
    echo "  Next ready:  none (all pending plans are blocked)"
  fi

  if [ -n "$recent_done" ]; then
    echo ""
    echo "  Recent completions:"
    echo "$recent_done" | tail -5
  fi

  if [ -n "$open_gates" ]; then
    echo ""
    echo "  Open gates (review required but not recorded):"
    echo "$open_gates"
  fi

  # Health trend
  echo ""
  echo "HEALTH TREND"
  local history="$ROOT/.mstack/health-history.jsonl"
  if [ -f "$history" ] && [ -s "$history" ]; then
    local latest
    latest="$(tail -1 "$history")"
    if has_jq; then
      local score
      score=$(echo "$latest" | jq -r '.score // "?"')
      echo "  Latest: ${score}/10"
      local count
      count=$(wc -l < "$history" | tr -d ' ')
      if [ "$count" -gt 1 ]; then
        local trend
        trend=$(tail -5 "$history" | jq -r '.score' 2>/dev/null | tr '\n' ' → ' | sed 's/ → $//')
        echo "  Trend:  $trend"
      fi
    else
      echo "  $(tail -1 "$history")"
    fi
  else
    echo "  No data yet"
  fi

  # Stashed threads
  echo ""
  echo "STASHED"
  local stash_dir="$ROOT/.mstack/stashed"
  if [ -d "$stash_dir" ] && [ "$(find "$stash_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    local stash_count oldest_age
    stash_count=$(find "$stash_dir" -name '*.md' | wc -l | tr -d ' ')
    local oldest_file
    # shellcheck disable=SC2012
    oldest_file="$(ls -t "$stash_dir"/*.md 2>/dev/null | tail -1)"
    oldest_age="$(stat -f '%Sm' -t '%Y-%m-%d' "$oldest_file" 2>/dev/null \
      || stat -c '%y' "$oldest_file" 2>/dev/null | cut -d' ' -f1 \
      || echo "?")"
    echo "  $stash_count threads (oldest: $oldest_age)"
    # shellcheck disable=SC2012
    while IFS= read -r sf; do
      local stash_title
      stash_title=$(head -1 "$sf" | sed 's/^# //')
      local stash_date
      stash_date=$(grep -m1 '^Stashed:' "$sf" | awk '{print $2}')
      echo "    \"$stash_title\" ($stash_date)"
    done < <(ls -t "$stash_dir"/*.md 2>/dev/null | head -5)
  else
    echo "  None"
  fi

  # Reviews
  echo ""
  echo "REVIEWS"
  local reviews_dir="$ROOT/.mstack/reviews"
  if [ -d "$reviews_dir" ] && [ "$(ls -A "$reviews_dir" 2>/dev/null)" ]; then
    local latest_review
    # shellcheck disable=SC2012
    latest_review=$(ls -t "$reviews_dir"/*.json 2>/dev/null | head -1)
    if [ -n "$latest_review" ] && has_jq; then
      local plan_id findings fixed review_label
      plan_id=$(jq -r '.plan_id // "?"' "$latest_review")
      findings=$(jq -r '.findings_above_threshold // 0' "$latest_review")
      fixed=$(jq -r '.findings_fixed // 0' "$latest_review")
      review_label="$(plan_label "$plan_id" 2>/dev/null || echo "plan-$plan_id")"
      echo "  Last review: $review_label — $findings findings, $fixed fixed"
    else
      echo "  $(find "$reviews_dir" -maxdepth 1 -type f | wc -l | tr -d ' ') review artifacts"
    fi
  else
    echo "  No data yet"
  fi

  # Recently shipped (recent git commits)
  echo ""
  echo "RECENTLY SHIPPED"
  local recent_commits
  recent_commits="$(git log --oneline -10 --format='  %h %s (%cr)' 2>/dev/null || true)"
  if [ -n "$recent_commits" ]; then
    echo "$recent_commits"
  else
    echo "  No commits found"
  fi

  # Learnings
  echo ""
  echo "LEARNINGS"
  local learnings_file="$ROOT/.mstack/learnings.jsonl"
  if [ -f "$learnings_file" ] && [ -s "$learnings_file" ]; then
    local learn_count
    learn_count=$(wc -l < "$learnings_file" | tr -d ' ')
    echo "  $learn_count patterns accumulated"
    if has_jq; then
      local recent_learn
      recent_learn="$(tail -3 "$learnings_file" | jq -r '"    " + (.key // .type // "?") + ": " + (.insight // .value // "?")' 2>/dev/null || true)"
      if [ -n "$recent_learn" ]; then
        echo "  Recent:"
        echo "$recent_learn"
      fi
    fi
  else
    echo "  None yet"
  fi

  # Checkpoint session info
  echo ""
  echo "SESSION"
  local cp="$ROOT/.mstack/checkpoints/latest.json"
  if [ -f "$cp" ] && has_jq; then
    local cp_completed cp_failed cp_remaining
    cp_completed=$(jq -r '.counters.plans_completed // 0' "$cp")
    cp_failed=$(jq -r '.counters.plans_failed // 0' "$cp")
    cp_remaining=$(jq -r '.counters.plans_remaining // 0' "$cp")
    local ctx_count
    ctx_count=$(jq '.user_context | length' "$cp" 2>/dev/null || echo 0)
    echo "  Plans this session: $cp_completed completed, $cp_failed failed, $cp_remaining remaining"
    echo "  User notes:         $ctx_count carried forward"
  else
    echo "  No checkpoint data"
  fi
}

cmd_plan() {
  local plan_id="${1:-}"
  [ -n "$plan_id" ] || die "usage: status.sh plan <id|name>"

  local pdir
  pdir="$(plans_dir 2>/dev/null)" || die "no plans directory"

  # Resolve a name/slug/title fragment to a canonical numeric id (plan 033).
  # A single identifier argument here is unambiguous without delimiters
  # (unlike mstack-run's free-form scope position): the whole argument IS
  # the reference. Numeric ids pass straight through unchanged (fast path).
  case "$plan_id" in
    *[!0-9]*)
      local _ref_out="" _ref_rc=0
      _ref_out="$(resolve_plan_ref "$plan_id")" || _ref_rc=$?
      if [ "$_ref_rc" -eq "$EXIT_REF_AMBIGUOUS" ]; then
        # resolve_plan_ref already printed the candidate list to stderr.
        exit "$EXIT_REF_AMBIGUOUS"
      elif [ "$_ref_rc" -ne 0 ]; then
        die "plan '$plan_id' not found"
      fi
      plan_id="${_ref_out%% *}"
      ;;
  esac

  # Strip leading zeros for matching (e.g., 011 -> 11)
  local plan_id_num
  plan_id_num="$(normalize_id "$plan_id")"

  local plan_file=""
  while IFS= read -r f; do
    local fid fid_num
    fid="$(fm_get "$f" id || true)"
    fid_num="$(normalize_id "$fid")"
    if [ "$fid" = "$plan_id" ] || [ "$fid_num" = "$plan_id_num" ]; then
      plan_file="$f"
      break
    fi
  done < <({ find "$pdir" -maxdepth 1 -type f -name '*.md'; [ -d "$pdir/archive" ] && find "$pdir/archive" -maxdepth 1 -type f -name '*.md'; } | sort)

  [ -n "$plan_file" ] || die "plan $plan_id not found"

  local title status blocked_by completed failed_reason
  title="$(fm_get "$plan_file" title || true)"
  status="$(fm_get "$plan_file" status || true)"
  blocked_by="$(fm_get "$plan_file" blocked-by || true)"
  completed="$(fm_get "$plan_file" completed || true)"
  failed_reason="$(fm_get "$plan_file" failed-reason || true)"

  local label
  label="$(format_plan_label "$plan_id" "$title" "$plan_file")"
  echo "PLAN $label"
  printf '=%.0s' $(seq 1 $((${#label} + 5)))
  printf '\n'
  echo "Status:     $status"
  [ -n "$completed" ] && echo "Completed:  $completed"
  [ -n "$failed_reason" ] && echo "Failed:     $failed_reason"

  # Render each blocked-by dependency as "NNN: Title" (via plan_label) so no
  # lookup is required. This is a single plan's small dependency list, not a
  # backlog-wide loop, so calling plan_label per dependency here is fine.
  if [ -n "$blocked_by" ] && [ "$blocked_by" != "[]" ]; then
    local clean dep dep_label dep_labels=""
    clean="${blocked_by#[}"; clean="${clean%]}"
    for dep in $(echo "$clean" | tr ',' ' '); do
      dep="$(echo "$dep" | tr -d ' ')"
      [ -n "$dep" ] || continue
      dep_label="$(plan_label "$dep" 2>/dev/null || echo "$dep")"
      dep_labels="${dep_labels}${dep_labels:+, }${dep_label}"
    done
    echo "Blocked by: ${dep_labels:-none}"
  else
    echo "Blocked by: none"
  fi
  echo ""
  echo "File: $plan_file"
}

case "${1:-dashboard}" in
  dashboard) cmd_dashboard ;;
  plan)      cmd_plan "${2:-}" ;;
  *)         die "usage: status.sh {dashboard|plan <id|name>}" ;;
esac
