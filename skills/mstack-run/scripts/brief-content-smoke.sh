#!/usr/bin/env bash
# brief-content-smoke.sh — the shipped briefs still carry Rule 4's directives
# (plan 090).
#
# WHAT THIS GUARDS. Rule 4 is a PROSE rule. Its entire mechanism is what four
# skill files tell a model to do: attack premises rather than sharpen the
# primary reviewer's findings, feed in Rule 1's UNCITED lines, and treat a
# unanimous cross-model clearance as a smell instead of a confirmation. There is
# no script to break, no exit code to regress, and therefore nothing that fails
# when a later edit quietly rewrites a paragraph away.
#
# That is the whole risk. A deleted directive leaves no stack trace: the audit
# still runs, codex still answers, the report still prints — and the pipeline is
# back to the confirmatory brief that cleared two P1 defects on the cctrl
# 051-053 batch. This suite is the only thing that turns "someone reworded the
# brief" into a failing check. Plan 045's rule, applied to prose: a mechanism
# whose absence looks exactly like its presence has to be asserted or it is not
# covered at all.
#
# WHAT IT DOES NOT CLAIM. Matching a substring is not evidence that the brief
# READS well or that a model obeys it. This asserts presence, nothing more. It
# is deliberately anchored on short, load-bearing phrases rather than whole
# paragraphs, so honest rewording survives and DELETION does not.
#
# WHITESPACE IS NORMALIZED BEFORE MATCHING. These are wrapped prose files; a
# directive that gets reflowed across a line break has not changed, and a suite
# that fails on rewrapping is a suite that gets deleted. Each file is collapsed
# to single-spaced text and matched case-insensitively with fixed strings.
#
# The machinery assertions are as load-bearing as the mandate ones. Plan 090
# changed the brief and explicitly NOT the invocation: the sandbox flags, the
# stdin redirect, the stderr capture, the timeout, the finding schema, and the
# GENUINE/FORWARD-DEPENDENCY classifier. A rewrite that adopts the new mandate
# while dropping one of those has broken the audit in a way the mandate checks
# alone would pass.
#
# Usage: bash skills/mstack-run/scripts/brief-content-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || { echo "[brief-content-smoke] SKIP: not a git work tree" >&2; exit 0; }

PASSED=0
FAILED=0
fail() { FAILED=$((FAILED + 1)); echo "[brief-content-smoke] FAIL: $*" >&2; }
ok()   { PASSED=$((PASSED + 1)); echo "[brief-content-smoke] ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/brief-content-smoke-XXXXXX")" || {
  echo "[brief-content-smoke] FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# Normalize a file once, then match against the normalized copy. Two markdown
# artifacts are stripped first, because both split a directive without changing
# it: a line-leading blockquote marker (the reviewer prompts are blockquotes, so
# collapsing alone leaves a stray ">" mid-sentence) and emphasis asterisks (a
# directive stays a directive whether or not half of it is bolded).
FLAT=""
CURRENT=""
load() {
  CURRENT="$1"
  local path="$ROOT/$1"
  [ -r "$path" ] || { fail "$1 is missing or unreadable — Rule 4 has no brief to carry"; FLAT=""; return 1; }
  FLAT="$TMP/$(printf '%s' "$1" | tr '/' '_').flat"
  sed -e 's/^[[:space:]]*>[[:space:]]\{0,1\}//' -e 's/\*//g' < "$path" \
    | tr -s '[:space:]' ' ' > "$FLAT"
  return 0
}

# need <what it guards> <literal substring>
need() {
  local label="$1" pat="$2"
  [ -n "$FLAT" ] || return 0
  if grep -qiF -- "$pat" "$FLAT"; then
    ok "$CURRENT: $label"
  else
    fail "$CURRENT: $label — missing directive: \"$pat\""
  fi
}

# --- 1. The codex brief: premise-attack mandate -----------------------------
AUDIT="skills/mstack-plan-doctor/references/adversarial-audit.md"
if load "$AUDIT"; then
  need "the do-not-sharpen instruction" "do not sharpen or extend"
  need "priority (a): the plan's uncited factual claims" "uncited factual claims"
  need "priority (b): the hedge-word sentences" "by construction"
  need "priority (c): a premise that kills a whole AC" "invalidate a whole acceptance criterion"
  need "the UNCITED PREMISES injection slot" "UNCITED PREMISES (attack these first):"
  need "the omit-when-empty rule for that slot" "OMIT THIS ENTIRE SECTION"
  need "the never-send-none-found rule" "never send"
  need "the rules.premise_brief gate" "premise_brief"
  need "the named pre-090 fallback brief" "Fallback brief"

  # --- Machinery plan 090 must NOT have touched ---
  need "MACHINERY: the read-only sandbox flag" "--sandbox read-only"
  need "MACHINERY: stdin from /dev/null" "< /dev/null"
  # Single quotes are the point on both of these: the patterns are the LITERAL
  # `$TMPERR` and the LITERAL backticked `X`s as they appear in the shipped
  # brief. Expanding either would search for something the file never contains.
  # shellcheck disable=SC2016
  need "MACHINERY: stderr captured to TMPERR" '2>"$TMPERR"'
  # shellcheck disable=SC2016
  need "MACHINERY: the mktemp trailing-X warning" 'must END in `X`s'
  need "MACHINERY: the 300s timeout" "timeout: 300000"
  need "MACHINERY: the FINDING schema" "FINDING: <critical|high|medium> | <file:line>"
  need "MACHINERY: the GENUINE/FORWARD-DEPENDENCY classifier" "FORWARD-DEPENDENCY"
fi

# --- 2. plan-doctor: the no-tension trigger and the canonical log line ------
DOCTOR="skills/mstack-plan-doctor/SKILL.md"
if load "$DOCTOR"; then
  need "the no-tension convention is named" "no tension"
  need "the canonical log line carries BOTH counts" \
    "codex clean on N/N conclusive plans, primary validation raised M findings"
  need "the running arm" "running one premise-directed pass"
  need "the waiver arm" "premise pass WAIVED"
  need "no-tension without an arm is illegal" "not a legal report state"
  need "the trigger fires at most once per run" "once per doctor run"
  need "an inconclusive audit is never counted clean" "is not a clean plan"
  need "the AUDIT [PREMISE-PASS] report row" "PREMISE-PASS"
  need "the Step 5 premise-attack mandate line" "Premise-attack mandate"
  need "that mandate ranks premises over details" "invalidates a whole AC"
  need "the rules.premise_brief gate" "premise_brief"
  need "the named pre-090 fallback" "pre-090"
fi

# --- 3. plan-multi: both-clear is a smell ----------------------------------
CRITIQUE="skills/mstack-plan-multi/references/structural-critique.md"
if load "$CRITIQUE"; then
  need "the no-tension convention is named" "no tension"
  need "both-clear is a smell, not a confirmation" "smell, not a confirmation"
  need "the one premise-directed re-ask" "premise re-ask"
  need "the re-ask attacks premises, not structure" "attack the breakdown's premises"
  need "an explicit skip note is required" "premise re-ask SKIPPED"
  need "the rules.premise_brief gate" "premise_brief"
  need "the named pre-090 fallback" "pre-090"
fi

# --- 4. code-review: premise framing adapted to code, no batch trigger -----
REVIEW="skills/mstack-code-review/SKILL.md"
if load "$REVIEW"; then
  need "the code-adapted premise framing" "assumes about the code around it"
  need "the hedge-word priority" "by construction"
  need "the single-reviewer row" "CROSS-MODEL: n/a (single reviewer)"
  need "the no-tension row" "CROSS-MODEL: no tension (external reviewer added nothing)"
  need "that row is weak evidence, not a confirmation" "never as a second confirmation"
  # SCOPE: code review has no batch, so it must NOT import plan-doctor's trigger.
  need "the no-batch-trigger scope rule" "no multi-plan aggregation point"
  need "Rule 4 adds no extra pass here" "triggers no extra pass"
  need "the rules.premise_brief gate" "premise_brief"
  need "the named pre-090 fallback briefs" "pre-090"
fi

if [ "$FAILED" -gt 0 ]; then
  echo "[brief-content-smoke] $FAILED directive(s) missing, $PASSED present" >&2
  echo "Rule 4 is prose: a missing directive means the brief silently reverted to the pre-090 mandate." >&2
  exit 1
fi

echo "[brief-content-smoke] all $PASSED directives present across 4 shipped briefs"
