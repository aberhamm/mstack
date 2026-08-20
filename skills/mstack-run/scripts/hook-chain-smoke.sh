#!/usr/bin/env bash
# Smoke test for the enforcement-hook CHAINING fix.
#
# Regression under test: git's core.hooksPath is single-valued. Once mstack
# points it at the tracked .githooks/ dir, git looks ONLY there and silently
# shadows any pre-existing global hook (e.g. the operator's gitleaks secret
# scanner). Before this fix, mstack's hook exec-replaced the shell and chained
# to nothing, so installing mstack disabled the global scanner in every mstack
# repo. The fix: after the mstack gate passes, chain to the hook of the same
# name from the hooksPath that was active before mstack, captured at install
# time into mstack.priorHooksPath.
#
# Strategy: build a throwaway repo, install the real shipped hooks into
# .githooks/, plant a fake "prior" hooksPath whose pre-commit / pre-push touch a
# sentinel file, wire mstack.priorHooksPath to it, and assert BOTH the mstack
# gate and the prior hook run on a commit and on a push validation.
#
# Usage: bash skills/mstack-run/scripts/hook-chain-smoke.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_SRC="$(cd "$SCRIPT_DIR/../hooks" && pwd)"

# shellcheck source=skills/mstack-run/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

CLEAN=()
cleanup() { [ "${#CLEAN[@]}" -gt 0 ] && rm -rf "${CLEAN[@]}"; }
trap cleanup EXIT

fail() { echo "[hook-chain-smoke] FAIL: $*" >&2; exit 1; }
ok()   { echo "[hook-chain-smoke] ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hook-chain-smoke-XXXXXX")"
CLEAN+=("$TMP")

REPO="$TMP/repo"
PRIOR="$TMP/prior-hooks"   # stand-in for ~/.config/git/hooks
SENTINEL_PC="$TMP/prior-precommit-ran"
SENTINEL_PP="$TMP/prior-prepush-ran"

mkdir -p "$REPO" "$PRIOR"

# --- Plant a fake "prior" global hooksPath ---------------------------------
# Its hooks just record that they ran (and pass), like a real secret scanner
# would when the tree is clean.
cat > "$PRIOR/pre-commit" <<EOF
#!/usr/bin/env bash
touch "$SENTINEL_PC"
exit 0
EOF
cat > "$PRIOR/pre-push" <<EOF
#!/usr/bin/env bash
# Drain stdin (git delivers ref lines) so a real hook contract is exercised.
cat >/dev/null
touch "$SENTINEL_PP"
exit 0
EOF
chmod +x "$PRIOR/pre-commit" "$PRIOR/pre-push"

# --- Build the repo with the REAL shipped hooks installed ------------------
(
  cd "$REPO"
  git init -q
  git config user.email smoke@example.com
  git config user.name smoke
  mkdir -p .githooks docs/plans
  cp "$HOOKS_SRC/pre-commit" .githooks/pre-commit
  cp "$HOOKS_SRC/pre-push"   .githooks/pre-push
  chmod +x .githooks/pre-commit .githooks/pre-push
  git config core.hooksPath .githooks
  # This is what mstack-init/setup capture: the hooksPath that was active before
  # mstack took over. Point it at our planted prior hooks.
  git config mstack.priorHooksPath "$PRIOR"
)

# The chained mstack hook resolves review-gate.sh from the installed skill dirs
# ($HOME/.config/skillshare/... etc). Point HOME at a shim so it finds THIS
# working copy of the skill regardless of what is installed on the machine.
SKILLHOME="$TMP/home"
mkdir -p "$SKILLHOME/.config/skillshare/skills"
ln -s "$(cd "$SCRIPT_DIR/.." && pwd)" "$SKILLHOME/.config/skillshare/skills/mstack-run"

git_c() { HOME="$SKILLHOME" git -C "$REPO" "$@"; }

# --- Test 1: pre-commit runs the mstack gate AND chains to the prior hook ---
echo "hello" > "$REPO/file.txt"
git_c add file.txt
# An ordinary (non-plan) commit: mstack gate is a no-op-pass, then it must chain.
git_c commit -q -m "ordinary commit" || fail "ordinary commit rejected unexpectedly"
[ -f "$SENTINEL_PC" ] || fail "prior pre-commit hook did NOT run (chain broken — the exact gitleaks-shadowing bug)"
ok "pre-commit chained to the prior hook on an ordinary commit"

# --- Test 2: when the mstack gate REJECTS, it must NOT chain (commit blocked) -
# A plan file transitioning to done without any recorded review is rejected by
# the gate; the prior hook should never be reached.
rm -f "$SENTINEL_PC"
cat > "$REPO/docs/plans/900-gate.md" <<'PLAN'
---
id: 900
title: Gate test
status: in-progress
blocked-by: []
needs-review: eng
review-required: eng
created: 2026-07-21
---

body
PLAN
git_c add docs/plans/900-gate.md
git_c commit -q -m "add plan 900 (in-progress)" || fail "adding in-progress plan rejected unexpectedly"
rm -f "$SENTINEL_PC"
# Now flip to done with the eng gate still open.
sed 's/^status: in-progress$/status: done/' "$REPO/docs/plans/900-gate.md" > "$REPO/docs/plans/900-gate.md.tmp"
mv "$REPO/docs/plans/900-gate.md.tmp" "$REPO/docs/plans/900-gate.md"
git_c add docs/plans/900-gate.md
if git_c commit -q -m "mark plan 900 done"; then
  fail "gate did NOT reject an unreviewed done-transition"
fi
[ ! -f "$SENTINEL_PC" ] || fail "prior hook ran even though the mstack gate rejected the commit"
ok "gate rejects unreviewed done-transition and does NOT chain"
# Undo the rejected done-transition so it does not linger staged into later
# tests (the commit was blocked, but `git add` already staged it).
git_c restore --staged docs/plans/900-gate.md
git_c checkout -- docs/plans/900-gate.md

# --- Test 3: pre-push runs the mstack gate AND chains to the prior hook -----
# Drive the pre-push hook directly with a benign (non-completion-tag) ref line,
# exactly as git would, and assert the prior pre-push ran.
rm -f "$SENTINEL_PP"
head_sha="$(git_c rev-parse HEAD)"
# git runs pre-push with cwd at the repo root; replicate that so repo_root
# resolves to the throwaway repo (a real `git push` would do the same).
printf 'refs/heads/main %s refs/heads/main %s\n' "$head_sha" "0000000000000000000000000000000000000000" \
  | ( cd "$REPO" && HOME="$SKILLHOME" bash "$REPO/.githooks/pre-push" origin "file://$REPO" ) \
  || fail "pre-push rejected an ordinary branch ref unexpectedly"
[ -f "$SENTINEL_PP" ] || fail "prior pre-push hook did NOT run (chain broken)"
ok "pre-push chained to the prior hook on an ordinary ref"

# --- Test 4: no prior hook configured => hook still passes (no false block) -
# Unset the capture and confirm an ordinary commit still succeeds (fallback to
# the git default hooks dir, which is empty here => nothing to chain, allow).
rm -f "$SENTINEL_PC"
git_c config --unset mstack.priorHooksPath
echo "second" >> "$REPO/file.txt"
git_c add file.txt
git_c commit -q -m "commit with no prior hook captured" \
  || fail "commit blocked when no prior hook is configured (should pass)"
[ ! -f "$SENTINEL_PC" ] || fail "prior sentinel appeared with no prior hook configured"
ok "no captured prior hook => commit still passes (default hooks dir empty)"

# --- Test 5: fallback path (review-gate.sh unreachable) still chains --------
# Point HOME at a dir with no installed skill so the shim cannot find
# review-gate.sh and falls into its degraded branch — which must still chain to
# the operator's prior hook rather than silently drop it.
git_c config mstack.priorHooksPath "$PRIOR"
rm -f "$SENTINEL_PC"
EMPTYHOME="$TMP/empty-home"
mkdir -p "$EMPTYHOME"
echo "third" >> "$REPO/file.txt"
HOME="$EMPTYHOME" git -C "$REPO" add file.txt
HOME="$EMPTYHOME" git -C "$REPO" commit -q -m "ordinary commit, no skill installed" \
  || fail "fallback path rejected an ordinary commit"
[ -f "$SENTINEL_PC" ] || fail "fallback path did NOT chain to the prior hook"
ok "fallback path (no review-gate.sh) still chains to the prior hook"

# --- Test 6: prior hook that IS an mstack shim => skip, no recursion ---------
# Regression: when the global hooks dir also contains an mstack pre-commit hook,
# chaining to it would recurse infinitely (the chained hook execs back into
# review-gate.sh, which chains again). The content guard detects the mstack
# signature (_find_review_gate) and skips the chain.
MSTACK_PRIOR="$TMP/mstack-prior-hooks"
mkdir -p "$MSTACK_PRIOR"
# Plant a pre-commit that looks like an mstack shim (contains the signature).
cat > "$MSTACK_PRIOR/pre-commit" <<'MHOOK'
#!/usr/bin/env bash
_find_review_gate() { return 1; }
# This hook should never actually run — the content guard should skip it.
echo "BUG: mstack prior hook was invoked, recursion guard failed" >&2
exit 1
MHOOK
chmod +x "$MSTACK_PRIOR/pre-commit"
git_c config mstack.priorHooksPath "$MSTACK_PRIOR"
echo "recursion-test" >> "$REPO/file.txt"
git_c add file.txt
git_c commit -q -m "commit with mstack hook in prior dir" \
  || fail "commit blocked when prior hook is an mstack shim (should be skipped)"
ok "mstack hook in prior dir detected and skipped (no recursion)"

# Also verify the fallback path (no review-gate.sh) has the same guard.
rm -f "$SENTINEL_PC"
echo "recursion-test-fallback" >> "$REPO/file.txt"
HOME="$EMPTYHOME" git -C "$REPO" add file.txt
HOME="$EMPTYHOME" git -C "$REPO" commit -q -m "fallback with mstack prior" \
  || fail "fallback path blocked when prior hook is an mstack shim"
ok "fallback path also skips mstack hook in prior dir"

echo "[hook-chain-smoke] all checks passed"
