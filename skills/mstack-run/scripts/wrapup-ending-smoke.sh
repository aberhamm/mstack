#!/usr/bin/env bash
# wrapup-ending-smoke.sh — the shipped wrap-up prose still carries plan 092's
# directives (execute-in-flow findings, guarded litter deletion, a combined
# git-hygiene file list, and the unconditional close-or-handoff ending).
#
# WHAT THIS GUARDS. Plan 092 is a PROSE change: no script's behavior moved,
# only what skills/mstack-wrap-up/SKILL.md tells a model to do. There is no
# exit code to regress and no test harness that exercises a markdown skill
# file, so a later edit can quietly revert any one of these directives and
# nothing else would notice — the file still parses, the other smoke suites
# still pass, and wrap-up silently goes back to proposing instead of applying,
# or back to only offering Close, or back to a session with
# `can_close_self=false` becoming closable through a hand-off spawn. Same
# reasoning as brief-content-smoke.sh (plan 090, Rule 4): a mechanism whose
# absence looks exactly like its presence has to be asserted, or it is not
# covered at all.
#
# POSITIVE AND NEGATIVE CHECKS. `need` pins a directive that must survive.
# `need_absent` pins a phrase from the OLD design that the rewrite retired —
# a later edit that reintroduces it (e.g. by reverting part of the diff) is
# exactly as much a regression as losing a new directive, and a positive-only
# suite cannot see it: the old and new phrasing could both be present at once
# and every `need` would still pass.
#
# WHAT IT DOES NOT CLAIM. Matching a substring is not evidence that the prose
# reads well, is internally consistent beyond what is checked here, or that a
# model actually obeys it at runtime. This asserts presence/absence of
# load-bearing phrases only. Anchors are short and specific so honest
# rewording survives and deletion does not.
#
# WHITESPACE IS NORMALIZED BEFORE MATCHING, and markdown emphasis asterisks
# are stripped first — these are wrapped prose files, and a directive that
# gets reflowed or re-bolded has not changed.
#
# Usage: bash skills/mstack-run/scripts/wrapup-ending-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || { echo "[wrapup-ending-smoke] SKIP: not a git work tree" >&2; exit 0; }

PASSED=0
FAILED=0
fail() { FAILED=$((FAILED + 1)); echo "[wrapup-ending-smoke] FAIL: $*" >&2; }
ok()   { PASSED=$((PASSED + 1)); echo "[wrapup-ending-smoke] ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wrapup-ending-smoke-XXXXXX")" || {
  echo "[wrapup-ending-smoke] FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

FLAT=""
CURRENT=""
load() {
  CURRENT="$1"
  local path="$ROOT/$1"
  [ -r "$path" ] || { fail "$1 is missing or unreadable — plan 092 has no file to carry its directives"; FLAT=""; return 1; }
  FLAT="$TMP/$(printf '%s' "$1" | tr '/' '_').flat"
  sed -e 's/\*//g' < "$path" | tr -s '[:space:]' ' ' > "$FLAT"
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

# need_absent <what regression it would signal> <literal substring from the old design>
need_absent() {
  local label="$1" pat="$2"
  [ -n "$FLAT" ] || return 0
  if grep -qiF -- "$pat" "$FLAT"; then
    fail "$CURRENT: $label — found retired phrase: \"$pat\""
  else
    ok "$CURRENT: $label"
  fi
}

WRAPUP="skills/mstack-wrap-up/SKILL.md"
if load "$WRAPUP"; then
  # --- Findings execute in-flow, doc edits included -------------------------
  need "doc edits are approved at the findings question, not a later prompt" \
    "approved at the findings question, applied in-flow"
  need "a doc edit writes during route execution, not a deferred apply" \
    "it is written during"
  need "the old apply-#2 deferral is explicitly retired" \
    "defer a doc-edit's write to a later conversational"
  need_absent "the old doc-edit deferral section is gone" \
    "Doc-edit proposals never block the flow"
  need_absent "doc writes are no longer described as blanket propose-by-default" \
    "Doc writes are propose-by-default"

  # --- Guarded litter deletion ----------------------------------------------
  need "litter deletion exists as its own mechanism" "Litter deletion"
  need "deletion is scoped to untracked paths only" \
    "git ls-files --error-unmatch"
  need "a tracked path is never deleted directly" \
    "A tracked path is never deleted directly by this skill"
  need "deletion is an exact rm, never a glob" "rm -- <exact path>"
  need "deletion is never swept into a blanket apply all" \
    "never bundled into a blanket"
  need "apply all spends the second findings-question slot on pending deletions" \
    "deletions-only multiSelect"
  need "the delete guardrail requires individual, explicit approval" \
    "Never delete anything the user did not individually, explicitly approve"
  need_absent "the old blanket never-delete guardrail is gone" \
    "Don't delete anything. This skill proposes"

  # --- Git hygiene covers route writes too, but never a gitignored sink -----
  need "git hygiene widens to include what routes just wrote" \
    "add those paths to the set by name"
  need "one combined question, not a second commit prompt" \
    "combined file list"
  need "terminal mode has no separate route-write commit offer" \
    "also the only commit offer"
  need "mid-session mode keeps the deferred post-flow offer" \
    "no git-hygiene step runs at all"
  need "stash and learned-patterns writes are excluded from the commit list" \
    "mstack-stash\` and \`mstack-learned-patterns\` are never added"
  need "a gitignored path can't be git-add'ed, so it's never offered" \
    "a gitignored path staged with"
  need "a plan-new scaffold stays a scaffold even though a route just wrote it" \
    "excluded here exactly as any other scaffold plan is"
  need "a doc edit to an already-dirty file is labeled mixed, not claimed whole" \
    "doc-edit route + pre-existing"

  # --- The unconditional close-or-handoff ending ----------------------------
  need "the ending question is unconditional, not finding-gated" \
    "asked unconditionally"
  need "the three-branch option table survives" "Close session"
  need "can_close_self=true is the only row offering Close" \
    "\`true\` | \`true\` | Close session"
  need "can_close_self=false offers no Close option" \
    "\`true\` | \`false\` | Hand off remaining work / Stay open"
  need "available=false offers no Close option" \
    "\`false\` | n/a | Hand off remaining work / Stay open"
  need "Hand off is an ending option" "Hand off remaining work"
  need "Stay open is a first-class ending option" "Stay open"
  need "the dedup rule is gone: handoff is not a findings route" \
    "mstack-handoff\` is never a findings route"
  need_absent "the old Dedup rule subsection is gone" \
    "Dedup rule:"
  need "the budget ceiling math is unchanged" \
    "2 findings + 1 git-hygiene + 1 ending = 4 questions"

  # --- Blocker: a can_close_self=false session must stay unclosable even via
  # hand-off's own spawn-mode close confirmation (handoff.sh checks neither
  # can_close_self nor anything else before asking) --------------------------
  need "hand-off's own spawn confirmation doesn't itself check can_close_self" \
    "does not itself check"
  need "wrap-up overrides that gap for can_close_self=false callers" \
    "do not ask to close this session at all"
  need "the override cites the guardrail it is protecting" \
    "NEVER close a session that"
fi

if [ "$FAILED" -gt 0 ]; then
  echo "[wrapup-ending-smoke] $FAILED directive(s) missing, $PASSED present" >&2
  echo "Plan 092 is prose: a missing directive means wrap-up silently reverted to propose-only / finding-gated hand-off / a closable can_close_self=false session." >&2
  exit 1
fi

echo "[wrapup-ending-smoke] all $PASSED directives present in $WRAPUP"
