#!/usr/bin/env bash
# mstack health check. Detect tools, run them, score, track trends.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT="$(repo_root)"
HISTORY_FILE="$ROOT/.mstack/health-history.jsonl"
PLAN_ID="${PLAN_ID:-}"

# Score a tool's output. Args: category, exit_code, output
score_category() {
  local cat="$1" exit_code="$2" output="$3"
  if [ "$exit_code" = "SKIPPED" ]; then echo "SKIPPED"; return; fi

  local count=0
  case "$cat" in
    typecheck)
      count=$(echo "$output" | grep -c "error TS" 2>/dev/null || true)
      count="${count:-0}"
      if [ "$exit_code" -eq 0 ] && [ "$count" -eq 0 ]; then echo 10
      elif [ "$count" -lt 10 ]; then echo 7
      elif [ "$count" -lt 50 ]; then echo 4
      else echo 0; fi ;;
    lint)
      if [ "$exit_code" -eq 0 ] && [ -z "$(echo "$output" | tr -d '[:space:]')" ]; then echo 10; return; fi
      count=$(echo "$output" | grep -ciE "error|warning|warn" 2>/dev/null || true)
      count="${count:-0}"
      if [ "$exit_code" -eq 0 ] && [ "$count" -eq 0 ]; then echo 10
      elif [ "$count" -lt 5 ]; then echo 7
      elif [ "$count" -lt 20 ]; then echo 4
      else echo 0; fi ;;
    test|e2e)
      # e2e shares the test scoring rules deliberately: both report as a
      # pass/fail suite, and a second rubric would be a second thing to keep
      # honest. Plan 065.
      if [ "$exit_code" -eq 0 ]; then echo 10
      else
        local passed failed
        passed=$(echo "$output" | grep -oE '[0-9]+ pass' | grep -oE '[0-9]+' | head -1 || echo "0")
        failed=$(echo "$output" | grep -oE '[0-9]+ fail' | grep -oE '[0-9]+' | head -1 || echo "1")
        passed="${passed:-0}"; failed="${failed:-1}"
        local total=$((passed + failed))
        if [ "$total" -gt 0 ]; then
          local pct=$((passed * 100 / total))
          if [ "$pct" -gt 95 ]; then echo 7
          elif [ "$pct" -gt 80 ]; then echo 4
          else echo 0; fi
        else echo 4; fi
      fi ;;
    deadcode)
      count=$(echo "$output" | grep -ciE "unused|dead|unreachable" 2>/dev/null || true)
      count="${count:-0}"
      if [ "$exit_code" -eq 0 ] && [ "$count" -eq 0 ]; then echo 10
      elif [ "$count" -lt 5 ]; then echo 7
      elif [ "$count" -lt 20 ]; then echo 4
      else echo 0; fi ;;
    shell)
      count=$(echo "$output" | grep -c "^In .* line" 2>/dev/null || true)
      count="${count:-0}"
      if [ "$exit_code" -eq 0 ] && [ "$count" -eq 0 ]; then echo 10
      elif [ "$count" -lt 5 ]; then echo 7
      else echo 4; fi ;;
    *) echo 0 ;;
  esac
}

# --- Shell-script discovery (plan 043) ---
#
# Prune policy — what belongs to the repo's health surface. A depth-unbounded
# scan must not start shellchecking history, dependencies, or vendored code, so
# the surface is defined as: every `*.sh` file git considers part of the working
# tree — TRACKED, plus UNTRACKED-but-not-ignored. Deriving it from git buys
# `.gitignore` semantics for free (build output, `node_modules/`, caches and
# every other ignored path drop out without a hand-maintained deny list) and
# excludes submodule contents (a gitlink lists as one entry, not its files).
# `.git/`, `.mstack/`, `node_modules/` and `vendor/` are additionally pruned
# explicitly so the non-git fallback and any force-added path behave the same.
#
# Untracked files MUST be included: workers never commit before the health gate
# runs, so a `.sh` a plan just created is untracked. Linting only tracked files
# would skip exactly the code under test.
SHELL_FILES=()

_sh_candidates() {
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    # Tracked and untracked-not-ignored are disjoint sets, so no dedupe needed.
    git -C "$ROOT" ls-files -z -- '*.sh'
    git -C "$ROOT" ls-files -z --others --exclude-standard -- '*.sh'
  else
    (cd "$ROOT" && find . -type f -name '*.sh' -print0 2>/dev/null)
  fi
}

# Populate SHELL_FILES with repo-relative paths. No depth cap, no count cap:
# truncating the list would report PASS over scripts never linted.
collect_shell_files() {
  SHELL_FILES=()
  local f
  while IFS= read -r -d '' f; do
    f="${f#./}"
    case "/$f" in
      */.git/* | */.mstack/* | */node_modules/* | */vendor/*) continue ;;
    esac
    [ -f "$ROOT/$f" ] || continue
    SHELL_FILES+=("$f")
  done < <(_sh_candidates)
}

# Explicitly configured command for a category: config first, then the tracked
# `## Health Stack` section of project guidance. Empty when neither declares one.
configured_cmd() {
  local cat="$1" cmd=""
  cmd="$(bash "$SCRIPT_DIR/config.sh" get "health.commands.$cat" 2>/dev/null || true)"
  if [ -n "$cmd" ]; then printf '%s\n' "$cmd"; return 0; fi

  local doc
  while IFS= read -r doc; do
    cmd=$(awk -v c="$cat" '
      /^## Health Stack/ { in_section=1; next }
      /^## / && in_section { exit }
      in_section && $0 ~ "^- *"c":" {
        sub("^- *"c": *", ""); print; exit
      }
    ' "$doc")
    if [ -n "$cmd" ]; then printf '%s\n' "$cmd"; return 0; fi
  done < <(guidance_files "$ROOT")
  return 0
}

# Does the repo explicitly declare it has NO health tools?
#
# The declaration is a `- none:` entry in the `## Health Stack` section of a
# TRACKED guidance file (AGENTS.md / CLAUDE.md). It is deliberately NOT readable
# from `.mstack/config.json`: `.mstack/` is gitignored, so a declaration there
# would be invisible to review, per-checkout, and gone on a fresh clone — which
# would make "explicit declaration" mean "whatever happened on this machine".
guidance_declares_none() {
  local doc hit
  while IFS= read -r doc; do
    hit=$(awk '
      /^## Health Stack/ { in_section=1; next }
      /^## / && in_section { exit }
      in_section && /^- *none:/ { print "yes"; exit }
    ' "$doc")
    [ -n "$hit" ] && return 0
  done < <(guidance_files "$ROOT")
  return 1
}

# --- Structured failure (plan 043 doctrine, extended by plan 065) -----------
#
# Every exit path out of `run` carries a `VERDICT:` line. A bare `die` produces
# output indistinguishable from a crashed gate, and "crashed" is exactly the
# state a worker once papered over by inventing `HEALTH_VERDICT: SKIP`. So an
# internal error reports FAIL with a named reason and exits nonzero.
emit_failure() {
  local reason="$1" msg="$2"
  echo "VERDICT:FAIL"
  echo "COMPOSITE:n/a"
  echo "FAILURES:$reason"
  echo "error: $msg" >&2
  exit "$EXIT_HEALTH_INTERNAL"
}

# --- Weights: ONE source of truth (plan 065) --------------------------------
#
# `config.sh get` already falls back to its own `DEFAULT_CONFIG`, so a literal
# fallback here would only ever fire when config.sh itself is broken — and it
# would then score the repo against a DIFFERENT weight set than the one the
# config advertises. That divergence (25/20/30/15/10 here vs 20/15/25/20/10/10
# there) is the bug. Fail closed instead: no literals, no silent second rubric.
weight_for() {
  local cat="$1" val
  val="$(bash "$SCRIPT_DIR/config.sh" get "health.weights.$cat" 2>/dev/null || true)"
  case "$val" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$val"
}

# Detect available tools. Checks config, AGENTS.md/CLAUDE.md, then auto-detect.
cmd_detect() {
  local categories="typecheck lint test e2e deadcode shell"
  for cat in $categories; do
    local cmd=""
    # 1-2. Explicit config / project guidance
    cmd="$(configured_cmd "$cat")"
    if [ -n "$cmd" ]; then
      echo "$cat:$cmd"
      continue
    fi

    # 3. Auto-detect (each block either echoes+continues or falls through silently)
    case "$cat" in
      typecheck)
        if [ -f "$ROOT/tsconfig.json" ]; then echo "typecheck:npx tsc --noEmit"; continue; fi
        if [ -f "$ROOT/pyproject.toml" ] && grep -q "mypy" "$ROOT/pyproject.toml" 2>/dev/null; then echo "typecheck:mypy ."; continue; fi
        if [ -f "$ROOT/Cargo.toml" ]; then echo "typecheck:cargo check"; continue; fi
        ;;
      lint)
        if [ -f "$ROOT/biome.json" ] || [ -f "$ROOT/biome.jsonc" ]; then echo "lint:npx biome check ."; continue; fi
        if find "$ROOT" -maxdepth 1 \( -name 'eslint.config.*' -o -name '.eslintrc*' \) -print -quit | grep -q .; then echo "lint:npx eslint ."; continue; fi
        if [ -f "$ROOT/pyproject.toml" ] && grep -q "ruff" "$ROOT/pyproject.toml" 2>/dev/null; then echo "lint:ruff check ."; continue; fi
        ;;
      test)
        if [ -f "$ROOT/package.json" ] && grep -q '"test"' "$ROOT/package.json" 2>/dev/null; then echo "test:npm test"; continue; fi
        if [ -f "$ROOT/pyproject.toml" ] && grep -q "pytest" "$ROOT/pyproject.toml" 2>/dev/null; then echo "test:pytest"; continue; fi
        if command -v pytest >/dev/null 2>&1 && [ -d "$ROOT/tests" ]; then echo "test:python -m pytest"; continue; fi
        if [ -f "$ROOT/Cargo.toml" ]; then echo "test:cargo test"; continue; fi
        if [ -f "$ROOT/go.mod" ]; then echo "test:go test ./..."; continue; fi
        ;;
      e2e)
        if [ -f "$ROOT/package.json" ] && grep -q '"test:e2e"' "$ROOT/package.json" 2>/dev/null; then echo "e2e:npm run test:e2e"; continue; fi
        if [ -f "$ROOT/package.json" ] && grep -q '"test:playwright"' "$ROOT/package.json" 2>/dev/null; then echo "e2e:npm run test:playwright"; continue; fi
        if find "$ROOT" -maxdepth 1 -name 'playwright.config.*' -print -quit | grep -q .; then echo "e2e:npx playwright test"; continue; fi
        if find "$ROOT" -maxdepth 1 -name 'cypress.config.*' -print -quit | grep -q .; then echo "e2e:npx cypress run"; continue; fi
        if [ -f "$ROOT/package.json" ] && grep -q '"test:cypress"' "$ROOT/package.json" 2>/dev/null; then echo "e2e:npm run test:cypress"; continue; fi
        ;;
      deadcode)
        if command -v knip >/dev/null 2>&1; then echo "deadcode:knip"; continue; fi
        if [ -f "$ROOT/package.json" ] && grep -q '"knip"' "$ROOT/package.json" 2>/dev/null; then echo "deadcode:npx knip"; continue; fi
        ;;
      shell)
        if command -v shellcheck >/dev/null 2>&1; then
          collect_shell_files
          # Display form only. cmd_run does NOT re-parse these filenames out of
          # the string — it re-collects them into an argv array, so a path with
          # a space or a shell metacharacter cannot break or misexecute.
          if [ ${#SHELL_FILES[@]} -gt 0 ]; then echo "shell:shellcheck ${SHELL_FILES[*]}"; continue; fi
        fi
        ;;
    esac
  done
  return 0
}

# Run all detected tools, score, compute composite, persist.
cmd_run() {
  ensure_mstack_dir

  local tools
  tools="$(cmd_detect)"

  # Zero tools across ALL categories: block unless declared (plan 043).
  # A single empty category is not this state — a JS repo with typecheck+lint+
  # test and no `.sh` files detects tools and never lands here.
  if [ -z "$tools" ]; then
    if guidance_declares_none; then
      warn "no health check tools detected; repo declares '- none:' under '## Health Stack'"
      echo "VERDICT:NONE-DECLARED"
      echo "COMPOSITE:n/a"
      echo "FAILURES:none"
      return 0
    fi
    echo "VERDICT:NO-TOOLS"
    echo "COMPOSITE:n/a"
    echo "FAILURES:no-tools-detected"
    echo "error: no health check tools detected, and no '- none:' declaration under" >&2
    echo "       '## Health Stack' in AGENTS.md/CLAUDE.md. Undeclared absence reads as" >&2
    echo "       'not yet declared', never as 'nothing required' — this plan is NOT" >&2
    echo "       completable. Configure health commands, or declare the repo has none." >&2
    exit "$EXIT_HEALTH_NO_TOOLS"
  fi

  # Auto-detected shell runs through an argv array below, not through eval.
  local shell_cfg shell_auto=false
  shell_cfg="$(configured_cmd shell)"
  if [ -z "$shell_cfg" ]; then
    shell_auto=true
    collect_shell_files
  fi

  # Get weights (single source of truth: config.sh; see weight_for)
  local w_typecheck w_lint w_test w_e2e w_deadcode w_shell
  if ! w_typecheck=$(weight_for typecheck) ||
     ! w_lint=$(weight_for lint) ||
     ! w_test=$(weight_for test) ||
     ! w_e2e=$(weight_for e2e) ||
     ! w_deadcode=$(weight_for deadcode) ||
     ! w_shell=$(weight_for shell); then
    emit_failure "config-unreadable" \
      "could not read health.weights.* from config.sh — refusing to score against
       an improvised weight set. Check .mstack/config.json, or run
       'bash skills/mstack-run/scripts/config.sh reset'."
  fi

  local total_start total_end
  total_start=$(date +%s)

  # Run each tool and score
  local s_typecheck="SKIPPED" s_lint="SKIPPED" s_test="SKIPPED" s_e2e="SKIPPED" s_deadcode="SKIPPED" s_shell="SKIPPED"
  local failures=""

  # Waivers (plan 099). Each category's UNTRUNCATED output is tee'd to a
  # private temp file used only for a baseline-delta comparison; scoring keeps
  # reading the same `tail -50` as before. Without PLAN_ID no waiver is read.
  local waived="" waived_measured=false waiver_notes="" full_dir
  full_dir="$(mktemp -d "${TMPDIR:-/tmp}/mstack-health-full-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$full_dir'" EXIT

  while IFS=: read -r cat cmd; do
    [ -n "$cat" ] || continue
    [ -n "$cmd" ] || continue
    info "running $cat: $cmd"
    local output exit_code full="$full_dir/$cat.out"
    if [ "$cat" = "shell" ] && [ "$shell_auto" = true ]; then
      # Argv array, no eval: the detected file list is never spliced into a
      # string, so `my script.sh` runs as one argument instead of two.
      output=$(cd "$ROOT" && shellcheck "${SHELL_FILES[@]}" 2>&1 | tee "$full" | tail -50; echo "EXIT:${PIPESTATUS[0]:-0}") || true
    else
      # Explicitly configured commands are author-written shell (globs, pipes,
      # `npx ...`) and are evaluated as such — that is their contract.
      output=$(cd "$ROOT" && eval "$cmd" 2>&1 | tee "$full" | tail -50; echo "EXIT:${PIPESTATUS[0]:-0}") || true
    fi
    exit_code="${output##*EXIT:}"
    exit_code="${exit_code%%[^0-9]*}"
    exit_code="${exit_code:-0}"
    output="${output%EXIT:*}"
    local score
    score=$(score_category "$cat" "$exit_code" "$output")

    # A failing category may be WAIVED (plan 099). WAIVED is excluded from the
    # composite exactly like SKIPPED — never scored 10, because nobody measured
    # a 10. A failed delta or an unhonoured waiver leaves the score as is and
    # names the reason in FAILURES.
    local is_waived=false
    if [ -n "$PLAN_ID" ] && [ "$exit_code" -ne 0 ] && [ "$score" != "SKIPPED" ]; then
      local wv
      wv="$(bash "$SCRIPT_DIR/waiver.sh" evaluate "$PLAN_ID" "$cat" "$full" "$exit_code" 2>/dev/null | head -1)" || wv=""
      case "$wv" in
        "WAIVED blanket")
          score="WAIVED"; is_waived=true
          waived="${waived:+$waived,}$cat:blanket" ;;
        "WAIVED baseline-delta")
          score="WAIVED"; is_waived=true; waived_measured=true
          waived="${waived:+$waived,}$cat:baseline-delta" ;;
        NONE) ;;
        REGRESSED*)     waiver_notes="${waiver_notes:+$waiver_notes, }waiver-delta-regressed:$cat" ;;
        NONCOMPARABLE*) waiver_notes="${waiver_notes:+$waiver_notes, }waiver-noncomparable:$cat" ;;
        INVALID*)       waiver_notes="${waiver_notes:+$waiver_notes, }waiver-invalid:$cat" ;;
        *)              waiver_notes="${waiver_notes:+$waiver_notes, }waiver-error:$cat" ;;
      esac
    fi

    case "$cat" in
      typecheck) s_typecheck="$score" ;;
      lint)      s_lint="$score" ;;
      test)      s_test="$score" ;;
      e2e)       s_e2e="$score" ;;
      deadcode)  s_deadcode="$score" ;;
      shell)     s_shell="$score" ;;
    esac

    if [ "$exit_code" -ne 0 ] && [ "$is_waived" = false ]; then
      failures="${failures:+$failures, }$cat"
    fi
  done <<< "$tools"
  [ -n "$waiver_notes" ] && failures="${failures:+$failures, }$waiver_notes"

  total_end=$(date +%s)
  local duration=$(( total_end - total_start ))

  # Redistribute weights for skipped AND waived categories (plan 099: WAIVED is
  # excluded exactly like SKIPPED).
  scored() { [ "$1" != "SKIPPED" ] && [ "$1" != "WAIVED" ]; }
  local active_weight=0
  scored "$s_typecheck" && active_weight=$((active_weight + w_typecheck))
  scored "$s_lint" && active_weight=$((active_weight + w_lint))
  scored "$s_test" && active_weight=$((active_weight + w_test))
  scored "$s_e2e" && active_weight=$((active_weight + w_e2e))
  scored "$s_deadcode" && active_weight=$((active_weight + w_deadcode))
  scored "$s_shell" && active_weight=$((active_weight + w_shell))

  # Every category that ran is WAIVED (plan 099). Checked BEFORE the
  # internal-no-active-weight branch, which must not fire for this state.
  # A passing baseline-delta comparison is a MEASUREMENT; a blanket waiver is
  # not. All-blanket means nothing was measured => FAIL. All-waived with at
  # least one delta => PASS-WAIVED with nothing left to score (COMPOSITE:n/a).
  local all_waived=false
  if [ "$active_weight" -le 0 ] && [ -n "$waived" ]; then
    all_waived=true
  fi

  # Unreachable in normal operation: `tools` was non-empty, so at least one
  # category scored. Reachable only if a detected category has no score slot —
  # the exact bug plan 065 fixed for e2e. Report it structurally, never as a
  # bare die with no VERDICT line (plan 043).
  if [ "$active_weight" -le 0 ] && [ "$all_waived" = false ]; then
    emit_failure "internal-no-active-weight" \
      "tools were detected and run, but no category carried weight into the
       composite. This is an mstack bug, not a repo problem: a detected
       category has no scoring slot. Detected: $(echo "$tools" | cut -d: -f1 | tr '\n' ' ')"
  fi

  # Compute composite (integer math, scale by 10 for one decimal)
  local composite=0 composite_str verdict="PASS"
  if [ "$all_waived" = true ]; then
    composite_str="n/a"
    if [ "$waived_measured" = true ]; then
      verdict="PASS-WAIVED"
    else
      verdict="FAIL"
      failures="${failures:+$failures, }all-categories-waived"
    fi
  else
    scored "$s_typecheck" && composite=$((composite + s_typecheck * w_typecheck * 10 / active_weight))
    scored "$s_lint" && composite=$((composite + s_lint * w_lint * 10 / active_weight))
    scored "$s_test" && composite=$((composite + s_test * w_test * 10 / active_weight))
    scored "$s_e2e" && composite=$((composite + s_e2e * w_e2e * 10 / active_weight))
    scored "$s_deadcode" && composite=$((composite + s_deadcode * w_deadcode * 10 / active_weight))
    scored "$s_shell" && composite=$((composite + s_shell * w_shell * 10 / active_weight))

    local composite_int=$((composite / 10))
    local composite_frac=$((composite % 10))
    composite_str="${composite_int}.${composite_frac}"

    # Determine verdict
    local any_zero=false
    for s in "$s_typecheck" "$s_lint" "$s_test" "$s_e2e" "$s_deadcode" "$s_shell"; do
      scored "$s" || continue
      [ "$s" -eq 0 ] && any_zero=true
    done

    if [ "$composite" -lt 70 ] || [ "$any_zero" = "true" ]; then
      verdict="FAIL"
    elif [ -n "$waived" ]; then
      verdict="PASS-WAIVED"
    fi
  fi

  # Check for regression. Applies to PASS-WAIVED exactly as to PASS when the
  # composite is numeric; skipped when it is n/a (nothing to compare).
  local prev
  prev="$(jsonl_last "$HISTORY_FILE" 2>/dev/null || true)"
  if [ -n "$prev" ] && [ "$composite_str" != "n/a" ] && { [ "$verdict" = "PASS" ] || [ "$verdict" = "PASS-WAIVED" ]; }; then
    if has_jq; then
      local prev_score
      prev_score=$(echo "$prev" | jq -r '.score // 0' 2>/dev/null || echo "0")
      local prev_int=${prev_score%.*}
      local prev_frac=${prev_score#*.}
      prev_frac=${prev_frac:-0}
      local prev_scaled=$((prev_int * 10 + prev_frac))
      local drop=$((prev_scaled - composite))
      [ "$drop" -ge 10 ] && verdict="REGRESSED"
    fi
  fi

  # Persist to health history. SKIPPED and WAIVED categories are null; an n/a
  # composite is null (never the bare string, which is not JSON).
  jnum() { scored "$1" && echo "$1" || echo "null"; }
  local json_tc json_li json_te json_e2 json_dc json_sh json_score json_waived
  json_tc=$(jnum "$s_typecheck")
  json_li=$(jnum "$s_lint")
  json_te=$(jnum "$s_test")
  json_e2=$(jnum "$s_e2e")
  json_dc=$(jnum "$s_deadcode")
  json_sh=$(jnum "$s_shell")
  json_score=$( [ "$composite_str" = "n/a" ] && echo "null" || echo "$composite_str" )
  json_waived="[]"
  if [ -n "$waived" ]; then
    json_waived="[\"$(printf '%s' "$waived" | sed 's/,/","/g')\"]"
  fi
  local plan_json
  plan_json=$( [ -n "$PLAN_ID" ] && echo "\"$PLAN_ID\"" || echo "null" )

  local entry ts branch
  ts="$(iso_now)"
  branch="$(git branch --show-current 2>/dev/null || echo unknown)"
  entry="{\"ts\":\"$ts\",\"branch\":\"$branch\",\"plan_id\":${plan_json},\"score\":${json_score},\"typecheck\":${json_tc},\"lint\":${json_li},\"test\":${json_te},\"e2e\":${json_e2},\"deadcode\":${json_dc},\"shell\":${json_sh},\"waived\":${json_waived},\"duration_s\":${duration}}"
  jsonl_append "$HISTORY_FILE" "$entry"
  jsonl_rotate "$HISTORY_FILE" 100

  # Output structured result
  echo "VERDICT:$verdict"
  echo "COMPOSITE:$composite_str"
  echo "TYPECHECK:$s_typecheck"
  echo "LINT:$s_lint"
  echo "TEST:$s_test"
  echo "E2E:$s_e2e"
  echo "DEADCODE:$s_deadcode"
  echo "SHELL:$s_shell"
  echo "WAIVED:${waived:-none}"
  echo "DURATION:$duration"
  echo "FAILURES:${failures:-none}"
}

# raw <category>: run ONE detected category's command once and print its FULL
# output (no tail truncation, no scoring, no history write), followed by a final
# `EXIT:<code>` line. Used by `waiver.sh capture-baseline` (plan 099).
cmd_raw() {
  local want="${1:-}" tools cat cmd found="" rc
  [ -n "$want" ] || die "usage: health-check.sh raw <category>"
  tools="$(cmd_detect)"
  while IFS=: read -r cat cmd; do
    [ "$cat" = "$want" ] && { found="$cmd"; break; }
  done <<< "$tools"
  [ -n "$found" ] || die "raw: category '$want' is not detected in this repo"
  local shell_cfg
  shell_cfg="$(configured_cmd shell)"
  set +e
  if [ "$want" = "shell" ] && [ -z "$shell_cfg" ]; then
    collect_shell_files
    (cd "$ROOT" && shellcheck "${SHELL_FILES[@]}") 2>&1
    rc=$?
  else
    (cd "$ROOT" && eval "$found") 2>&1
    rc=$?
  fi
  set -e
  printf '\nEXIT:%s\n' "$rc"
}

# Show health trend
cmd_trend() {
  local count="${1:-10}"
  [ -f "$HISTORY_FILE" ] || { echo "NO_HISTORY"; exit 2; }
  tail -"$count" "$HISTORY_FILE"
}

case "${1:-run}" in
  detect) cmd_detect ;;
  run)    cmd_run ;;
  trend)  cmd_trend "${2:-10}" ;;
  raw)    cmd_raw "${2:-}" ;;
  *)      die "usage: health-check.sh {detect|run|trend|raw <category>}" ;;
esac
