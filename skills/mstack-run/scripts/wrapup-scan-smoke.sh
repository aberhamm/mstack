#!/usr/bin/env bash
# Smoke test for wrapup-scan.sh (mstack plan 040). Builds a throwaway git
# fixture — dirty file, artifact files (one with a SPACE in the name, proving
# the NUL-safe parse end-to-end), a stash, a merged branch, a local BARE repo
# wired as origin (push once, commit again => unpushed count) and a branch with
# no upstream (=> upstream=none) — plus a non-git dir and a clean repo, then
# asserts the pinned output contract and exit codes.
#
# Usage: bash skills/mstack-run/scripts/wrapup-scan-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

SCAN="$SCRIPT_DIR/wrapup-scan.sh"

fail() {
  echo "[wrapup-scan-smoke] FAIL: $*" >&2
  exit 1
}

pass() { echo "[wrapup-scan-smoke] ok: $*"; }

# section_entries <name> <scan-output>: print the raw entries of one section
# (the two-space-indented lines between its header and the next non-indented
# line), de-indented. Keeps assertions from matching an entry in a *different*
# section (e.g. an untracked path listed under both uncommitted and artifacts).
section_entries() {
  awk -v name="$1" '
    $0 == "section=" name || index($0, "section=" name " ") == 1 { inside=1; next }
    inside && /^  / { sub(/^  /, ""); print; next }
    inside { inside=0 }
  ' <<<"$2"
}

[ -x "$SCAN" ] || fail "wrapup-scan.sh is not executable (skills resolve helpers with [ -x ])"
pass "wrapup-scan.sh is executable"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrapup-scan-smoke-XXXXXX")" || fail "mktemp -d failed"
trap 'rm -rf "$TMPROOT"' EXIT

g() { git -C "$1" "${@:2}"; }

# --- fixture: bare origin + work repo -------------------------------------
BARE="$TMPROOT/origin.git"
REPO="$TMPROOT/work"
NOTGIT="$TMPROOT/plain"
CLEAN="$TMPROOT/clean"
mkdir -p "$NOTGIT"

git init --bare --quiet "$BARE" >/dev/null 2>&1 || fail "git init --bare failed"
git -c init.defaultBranch=main init --quiet "$REPO" >/dev/null 2>&1 || fail "git init failed"
g "$REPO" config user.email smoke@example.com
g "$REPO" config user.name "Smoke Test"
g "$REPO" symbolic-ref HEAD refs/heads/main

printf 'hello\n' > "$REPO/README.md"
g "$REPO" add README.md
g "$REPO" commit --quiet -m "initial"
g "$REPO" remote add origin "$BARE"
g "$REPO" push --quiet -u origin main >/dev/null 2>&1 || fail "push to bare origin failed"

# merged branch (merged into main, not deleted) => merged-branches entry
g "$REPO" checkout --quiet -b feature-merged
printf 'feature\n' > "$REPO/feature.txt"
g "$REPO" add feature.txt
g "$REPO" commit --quiet -m "feature work"
g "$REPO" checkout --quiet main
g "$REPO" merge --quiet --no-ff -m "merge feature-merged" feature-merged

# branch with NO upstream and its own unmerged commit => upstream=none entry
# (a branch pointing at main's tip would legitimately count as merged instead)
g "$REPO" checkout --quiet -b orphan-side
printf 'side\n' > "$REPO/side.txt"
g "$REPO" add side.txt
g "$REPO" commit --quiet -m "side work"
g "$REPO" checkout --quiet main

# a stash entry
printf 'stashed edit\n' >> "$REPO/README.md"
g "$REPO" stash push --quiet -m "wip stash" >/dev/null 2>&1 || fail "git stash push failed"

# dirty tracked file + untracked artifacts (incl. a filename with a SPACE)
printf 'dirty edit\n' >> "$REPO/README.md"
: > "$REPO/scratch.tmp"
: > "$REPO/debug notes.log"
: > "$REPO/keeper.md"

# clean repo (committed, nothing pending)
git -c init.defaultBranch=main init --quiet "$CLEAN" >/dev/null 2>&1 || fail "git init clean failed"
g "$CLEAN" config user.email smoke@example.com
g "$CLEAN" config user.name "Smoke Test"
printf 'clean\n' > "$CLEAN/README.md"
g "$CLEAN" add README.md
g "$CLEAN" commit --quiet -m "initial"

# --- 1. full scan of the dirty fixture ------------------------------------
out="$(bash "$SCAN" "$REPO" 2>/dev/null)"
code=$?
[ "$code" -eq 0 ] || fail "scan of dirty fixture exited $code, expected 0 (findings are data, not an error)"
pass "scan of dirty fixture exits 0"

grep -q "^repo=" <<<"$out" || fail "missing repo= header"$'\n'"$out"

# uncommitted: README.md (tracked-dirty) + 3 untracked = 4
grep -q '^section=uncommitted count=4$' <<<"$out" \
  || fail "expected 'section=uncommitted count=4'"$'\n'"$out"
uncommitted="$(section_entries uncommitted "$out")"
grep -qx 'README.md' <<<"$uncommitted" || fail "uncommitted section missing README.md"
pass "section=uncommitted count=4"

# artifacts: scratch.tmp + 'debug notes.log' (keeper.md is untracked but not an artifact)
grep -q '^section=artifacts count=2$' <<<"$out" \
  || fail "expected 'section=artifacts count=2'"$'\n'"$out"
artifacts="$(section_entries artifacts "$out")"
grep -qx 'scratch.tmp' <<<"$artifacts" || fail "artifacts section missing scratch.tmp"
grep -qx 'debug notes.log' <<<"$artifacts" \
  || fail "artifacts section missing 'debug notes.log' (NUL-safe parse of a spaced path)"
grep -qx 'keeper.md' <<<"$artifacts" && fail "keeper.md must not be flagged as an artifact"
pass "section=artifacts count=2 (incl. spaced filename, excl. non-matching untracked)"

grep -q '^section=stashes count=1$' <<<"$out" \
  || fail "expected 'section=stashes count=1'"$'\n'"$out"
pass "section=stashes count=1"

grep -q '^section=merged-branches count=1 local-refs-only$' <<<"$out" \
  || fail "expected 'section=merged-branches count=1 local-refs-only'"$'\n'"$out"
grep -qx 'feature-merged' <<<"$(section_entries merged-branches "$out")" \
  || fail "merged-branches missing feature-merged"
pass "section=merged-branches count=1 (feature-merged), local-refs-only"

grep -q '^section=unpushed count=[0-9]* local-refs-only$' <<<"$out" \
  || fail "expected an 'section=unpushed count=<n> local-refs-only' line"$'\n'"$out"
unpushed="$(section_entries unpushed "$out")"
grep -qx 'main ahead=2' <<<"$unpushed" \
  || fail "expected 'main ahead=2' (feature commit + merge commit unpushed)"$'\n'"$unpushed"
grep -qx 'orphan-side upstream=none' <<<"$unpushed" \
  || fail "expected 'orphan-side upstream=none' (no-upstream branch must not be skipped)"$'\n'"$unpushed"
grep -qx 'feature-merged upstream=none' <<<"$unpushed" \
  || fail "expected 'feature-merged upstream=none'"$'\n'"$unpushed"
pass "section=unpushed covers all local branches (ahead counts + upstream=none)"

# findings = 4 + 2 + 1 + 1 + 3 = 11
grep -q '^findings=11$' <<<"$out" || fail "expected 'findings=11'"$'\n'"$out"
pass "findings=11 (total entries across sections)"

# section order is fixed
order="$(grep -E '^section=' <<<"$out" | sed 's/ .*//')"
expected_order='section=uncommitted
section=artifacts
section=stashes
section=merged-branches
section=unpushed'
[ "$order" = "$expected_order" ] || fail "section order drifted:"$'\n'"$order"
pass "section order is uncommitted, artifacts, stashes, merged-branches, unpushed"

# --- 2. clean repo: exit 0, all sections present ---------------------------
out_clean="$(bash "$SCAN" "$CLEAN" 2>/dev/null)"
code=$?
[ "$code" -eq 0 ] || fail "scan of clean repo exited $code, expected 0"
grep -q '^section=uncommitted count=0$' <<<"$out_clean" || fail "clean repo should have 0 uncommitted"
grep -q '^section=artifacts count=0$' <<<"$out_clean" || fail "clean repo should have 0 artifacts"
grep -q '^findings=' <<<"$out_clean" || fail "clean repo missing findings= line"
pass "clean repo scans to exit 0 with empty sections"

# --- 3. non-git target: loud, dedicated exit code, never a clean print -----
err="$TMPROOT/err.txt"
out_ng="$(bash "$SCAN" "$NOTGIT" 2>"$err")"
code=$?
[ "$code" -eq "$EXIT_SCAN_NOT_GIT" ] \
  || fail "non-git target exited $code, expected EXIT_SCAN_NOT_GIT ($EXIT_SCAN_NOT_GIT)"
grep -q "mechanical check unavailable: ${NOTGIT} is not a git repository" "$err" \
  || fail "non-git target missing the loud stderr diagnostic"
[ -z "$out_ng" ] || fail "non-git target must not print any scan result, got:"$'\n'"$out_ng"
pass "non-git target: exit $EXIT_SCAN_NOT_GIT, loud stderr, no clean print"

# --- 4. multi-target: valid repos still fully scanned, exit still nonzero ---
out_multi="$(bash "$SCAN" "$REPO" "$NOTGIT" "$CLEAN" 2>/dev/null)"
code=$?
[ "$code" -eq "$EXIT_SCAN_NOT_GIT" ] \
  || fail "multi-target with a bad target exited $code, expected EXIT_SCAN_NOT_GIT"
[ "$(grep -c '^findings=' <<<"$out_multi")" -eq 2 ] \
  || fail "multi-target: expected 2 complete repo reports (the valid targets)"$'\n'"$out_multi"
[ "$(grep -c '^repo=' <<<"$out_multi")" -eq 2 ] || fail "multi-target: expected 2 repo= headers"
pass "multi-target: valid repos fully scanned, exit code reflects the bad target"

echo "[wrapup-scan-smoke] all checks passed"
