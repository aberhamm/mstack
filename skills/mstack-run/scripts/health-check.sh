#!/usr/bin/env bash
# mstack health check. Detect tools, run them, score, track trends.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
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
      count=$(echo "$output" | grep -c "error TS" 2>/dev/null || echo "0")
      if [ "$exit_code" -eq 0 ] && [ "$count" -eq 0 ]; then echo 10
      elif [ "$count" -lt 10 ]; then echo 7
      elif [ "$count" -lt 50 ]; then echo 4
      else echo 0; fi ;;
    lint)
      if [ "$exit_code" -eq 0 ] && [ -z "$(echo "$output" | tr -d '[:space:]')" ]; then echo 10; return; fi
      count=$(echo "$output" | grep -ciE "error|warning|warn" 2>/dev/null || echo "0")
      if [ "$exit_code" -eq 0 ] && [ "$count" -eq 0 ]; then echo 10
      elif [ "$count" -lt 5 ]; then echo 7
      elif [ "$count" -lt 20 ]; then echo 4
      else echo 0; fi ;;
    test)
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
      count=$(echo "$output" | grep -ciE "unused|dead|unreachable" 2>/dev/null || echo "0")
      if [ "$exit_code" -eq 0 ] && [ "$count" -eq 0 ]; then echo 10
      elif [ "$count" -lt 5 ]; then echo 7
      elif [ "$count" -lt 20 ]; then echo 4
      else echo 0; fi ;;
    shell)
      count=$(echo "$output" | grep -c "^In .* line" 2>/dev/null || echo "0")
      if [ "$exit_code" -eq 0 ] && [ "$count" -eq 0 ]; then echo 10
      elif [ "$count" -lt 5 ]; then echo 7
      else echo 4; fi ;;
    *) echo 0 ;;
  esac
}

# Detect available tools. Checks config, AGENTS.md/CLAUDE.md, then auto-detect.
cmd_detect() {
  local categories="typecheck lint test e2e deadcode shell"
  for cat in $categories; do
    local cmd=""
    # 1. Check config
    cmd="$(bash "$SCRIPT_DIR/config.sh" get "health.commands.$cat" 2>/dev/null || true)"
    if [ -n "$cmd" ]; then
      echo "$cat:$cmd"
      continue
    fi

    # 2. Check project guidance Health Stack
    local doc
    while IFS= read -r doc; do
      cmd=$(awk -v c="$cat" '
        /^## Health Stack/ { in_section=1; next }
        /^## / && in_section { exit }
        in_section && $0 ~ "^- *"c":" {
          sub("^- *"c": *", ""); print; exit
        }
      ' "$doc")
      if [ -n "$cmd" ]; then
        echo "$cat:$cmd"
        break
      fi
    done < <(guidance_files "$ROOT")
    [ -n "$cmd" ] && continue

    # 3. Auto-detect (each block either echoes+continues or falls through silently)
    case "$cat" in
      typecheck)
        if [ -f "$ROOT/tsconfig.json" ]; then echo "typecheck:npx tsc --noEmit"; continue; fi
        if [ -f "$ROOT/pyproject.toml" ] && grep -q "mypy" "$ROOT/pyproject.toml" 2>/dev/null; then echo "typecheck:mypy ."; continue; fi
        if [ -f "$ROOT/Cargo.toml" ]; then echo "typecheck:cargo check"; continue; fi
        ;;
      lint)
        if [ -f "$ROOT/biome.json" ] || [ -f "$ROOT/biome.jsonc" ]; then echo "lint:npx biome check ."; continue; fi
        if ls "$ROOT"/eslint.config.* "$ROOT"/.eslintrc* 2>/dev/null | head -1 | grep -q .; then echo "lint:npx eslint ."; continue; fi
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
        if ls "$ROOT"/playwright.config.* 2>/dev/null | head -1 | grep -q .; then echo "e2e:npx playwright test"; continue; fi
        if ls "$ROOT"/cypress.config.* 2>/dev/null | head -1 | grep -q .; then echo "e2e:npx cypress run"; continue; fi
        if [ -f "$ROOT/package.json" ] && grep -q '"test:cypress"' "$ROOT/package.json" 2>/dev/null; then echo "e2e:npm run test:cypress"; continue; fi
        ;;
      deadcode)
        if command -v knip >/dev/null 2>&1; then echo "deadcode:knip"; continue; fi
        if [ -f "$ROOT/package.json" ] && grep -q '"knip"' "$ROOT/package.json" 2>/dev/null; then echo "deadcode:npx knip"; continue; fi
        ;;
      shell)
        if command -v shellcheck >/dev/null 2>&1; then
          local sh_files
          sh_files=$(find "$ROOT" -maxdepth 3 -name '*.sh' -not -path '*/.mstack/*' -not -path '*/node_modules/*' 2>/dev/null | head -20 | tr '\n' ' ')
          if [ -n "$sh_files" ]; then echo "shell:shellcheck $sh_files"; continue; fi
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
  [ -n "$tools" ] || die "no health check tools detected"

  # Get weights
  local w_typecheck w_lint w_test w_deadcode w_shell
  w_typecheck=$(bash "$SCRIPT_DIR/config.sh" get health.weights.typecheck 2>/dev/null || echo 25)
  w_lint=$(bash "$SCRIPT_DIR/config.sh" get health.weights.lint 2>/dev/null || echo 20)
  w_test=$(bash "$SCRIPT_DIR/config.sh" get health.weights.test 2>/dev/null || echo 30)
  w_deadcode=$(bash "$SCRIPT_DIR/config.sh" get health.weights.deadcode 2>/dev/null || echo 15)
  w_shell=$(bash "$SCRIPT_DIR/config.sh" get health.weights.shell 2>/dev/null || echo 10)

  local total_start total_end
  total_start=$(date +%s)

  # Run each tool and score
  local s_typecheck="SKIPPED" s_lint="SKIPPED" s_test="SKIPPED" s_deadcode="SKIPPED" s_shell="SKIPPED"
  local failures=""

  while IFS=: read -r cat cmd; do
    [ -n "$cat" ] || continue
    [ -n "$cmd" ] || continue
    info "running $cat: $cmd"
    local output exit_code
    output=$(cd "$ROOT" && eval "$cmd" 2>&1 | tail -50; echo "EXIT:${PIPESTATUS[0]:-0}") || true
    exit_code="${output##*EXIT:}"
    exit_code="${exit_code%%[^0-9]*}"
    exit_code="${exit_code:-0}"
    output="${output%EXIT:*}"
    local score
    score=$(score_category "$cat" "$exit_code" "$output")

    case "$cat" in
      typecheck) s_typecheck="$score" ;;
      lint)      s_lint="$score" ;;
      test)      s_test="$score" ;;
      deadcode)  s_deadcode="$score" ;;
      shell)     s_shell="$score" ;;
    esac

    if [ "$exit_code" -ne 0 ]; then
      failures="${failures:+$failures, }$cat"
    fi
  done <<< "$tools"

  total_end=$(date +%s)
  local duration=$(( total_end - total_start ))

  # Redistribute weights for skipped categories
  local active_weight=0
  [ "$s_typecheck" != "SKIPPED" ] && active_weight=$((active_weight + w_typecheck))
  [ "$s_lint" != "SKIPPED" ] && active_weight=$((active_weight + w_lint))
  [ "$s_test" != "SKIPPED" ] && active_weight=$((active_weight + w_test))
  [ "$s_deadcode" != "SKIPPED" ] && active_weight=$((active_weight + w_deadcode))
  [ "$s_shell" != "SKIPPED" ] && active_weight=$((active_weight + w_shell))

  [ "$active_weight" -gt 0 ] || die "no tools ran successfully"

  # Compute composite (integer math, scale by 10 for one decimal)
  local composite=0
  [ "$s_typecheck" != "SKIPPED" ] && composite=$((composite + s_typecheck * w_typecheck * 10 / active_weight))
  [ "$s_lint" != "SKIPPED" ] && composite=$((composite + s_lint * w_lint * 10 / active_weight))
  [ "$s_test" != "SKIPPED" ] && composite=$((composite + s_test * w_test * 10 / active_weight))
  [ "$s_deadcode" != "SKIPPED" ] && composite=$((composite + s_deadcode * w_deadcode * 10 / active_weight))
  [ "$s_shell" != "SKIPPED" ] && composite=$((composite + s_shell * w_shell * 10 / active_weight))

  local composite_int=$((composite / 10))
  local composite_frac=$((composite % 10))
  local composite_str="${composite_int}.${composite_frac}"

  # Determine verdict
  local verdict="PASS"
  local any_zero=false
  for s in "$s_typecheck" "$s_lint" "$s_test" "$s_deadcode" "$s_shell"; do
    [ "$s" = "SKIPPED" ] && continue
    [ "$s" -eq 0 ] && any_zero=true
  done

  if [ "$composite" -lt 70 ] || [ "$any_zero" = "true" ]; then
    verdict="FAIL"
  fi

  # Check for regression
  local prev
  prev="$(jsonl_last "$HISTORY_FILE" 2>/dev/null || true)"
  if [ -n "$prev" ] && [ "$verdict" = "PASS" ]; then
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

  # Persist to health history
  local json_tc json_li json_te json_dc json_sh
  json_tc=$( [ "$s_typecheck" = "SKIPPED" ] && echo "null" || echo "$s_typecheck" )
  json_li=$( [ "$s_lint" = "SKIPPED" ] && echo "null" || echo "$s_lint" )
  json_te=$( [ "$s_test" = "SKIPPED" ] && echo "null" || echo "$s_test" )
  json_dc=$( [ "$s_deadcode" = "SKIPPED" ] && echo "null" || echo "$s_deadcode" )
  json_sh=$( [ "$s_shell" = "SKIPPED" ] && echo "null" || echo "$s_shell" )
  local plan_json
  plan_json=$( [ -n "$PLAN_ID" ] && echo "\"$PLAN_ID\"" || echo "null" )

  local entry="{\"ts\":\"$(iso_now)\",\"branch\":\"$(git branch --show-current 2>/dev/null || echo unknown)\",\"plan_id\":${plan_json},\"score\":${composite_str},\"typecheck\":${json_tc},\"lint\":${json_li},\"test\":${json_te},\"deadcode\":${json_dc},\"shell\":${json_sh},\"duration_s\":${duration}}"
  jsonl_append "$HISTORY_FILE" "$entry"
  jsonl_rotate "$HISTORY_FILE" 100

  # Output structured result
  echo "VERDICT:$verdict"
  echo "COMPOSITE:$composite_str"
  echo "TYPECHECK:$s_typecheck"
  echo "LINT:$s_lint"
  echo "TEST:$s_test"
  echo "DEADCODE:$s_deadcode"
  echo "SHELL:$s_shell"
  echo "DURATION:$duration"
  echo "FAILURES:${failures:-none}"
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
  *)      die "usage: health-check.sh {detect|run|trend}" ;;
esac
