#!/usr/bin/env bash
# simplifier-brief-smoke.sh — prove the vendored simplifier is licensed,
# reachable from every execution surface, and ordered before code review.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || {
  echo "[simplifier-brief-smoke] SKIP: not a git work tree" >&2
  exit 0
}

FAILED=0
PASSED=0
fail() { FAILED=$((FAILED + 1)); echo "[simplifier-brief-smoke] FAIL: $*" >&2; }
ok() { PASSED=$((PASSED + 1)); echo "[simplifier-brief-smoke] ok: $*"; }

BRIEF="$ROOT/skills/mstack-code-review/references/simplifier-brief.md"
LICENSE_FILE="$ROOT/skills/mstack-code-review/references/LICENSE-anthropic-code-simplifier"
REVIEW_SKILL="$ROOT/skills/mstack-code-review/SKILL.md"
REVIEW_SPEC="$ROOT/skills/mstack-run/references/review-spec.md"
WORKER_PROMPT="$ROOT/skills/mstack-run/references/subagent-prompt.md"

need_file() {
  local path="$1" label="$2"
  if [ -r "$path" ]; then
    ok "$label is readable"
  else
    fail "$label is missing or unreadable: ${path#"$ROOT"/}"
  fi
}

need_text() {
  local path="$1" pattern="$2" label="$3"
  if [ -r "$path" ] && grep -qiF -- "$pattern" "$path"; then
    ok "$label"
  else
    fail "$label — missing: $pattern"
  fi
}

before() {
  local path="$1" first="$2" second="$3" label="$4"
  local first_line second_line
  first_line="$(grep -nF -- "$first" "$path" 2>/dev/null | head -1 | cut -d: -f1)"
  second_line="$(grep -nF -- "$second" "$path" 2>/dev/null | head -1 | cut -d: -f1)"
  if [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ]; then
    ok "$label"
  else
    fail "$label — expected '$first' before '$second'"
  fi
}

need_file "$BRIEF" "vendored simplifier brief"
need_file "$LICENSE_FILE" "vendored Apache license"

need_text "$BRIEF" "published by Anthropic" "Anthropic attribution is retained"
need_text "$BRIEF" "preserving its exact behavior" "behavior preservation is explicit"
need_text "$BRIEF" "Fewer lines are not inherently simpler" "line count is not treated as simplicity"
need_text "$BRIEF" "helpful abstractions" "useful abstractions are protected"
need_text "$BRIEF" "Modify only files already changed" "scope stays inside changed files"
need_text "$LICENSE_FILE" "Apache License" "Apache license text is distributed"
need_text "$LICENSE_FILE" "Version 2.0, January 2004" "Apache license version is intact"

need_text "$REVIEW_SKILL" "references/simplifier-brief.md" "standalone review reads the brief"
need_text "$REVIEW_SPEC" "references/simplifier-brief.md" "authoritative worker spec reads the brief"
need_text "$WORKER_PROMPT" "references/simplifier-brief.md" "executable worker prompt reads the brief"
before "$REVIEW_SKILL" "## Step 1b: Behavior-preserving simplification pass" "## Step 2: Run review" \
  "standalone simplification precedes review"
before "$REVIEW_SPEC" "## Behavior-preserving simplification" "## Run review (configurable depth)" \
  "worker spec simplification precedes review"
before "$WORKER_PROMPT" "STEP C4: Behavior-preserving simplification" "STEP D: Code review" \
  "executable worker simplification precedes review"

if [ "$FAILED" -gt 0 ]; then
  echo "[simplifier-brief-smoke] $FAILED failure(s), $PASSED checks passed" >&2
  exit 1
fi

echo "[simplifier-brief-smoke] all $PASSED checks passed"
