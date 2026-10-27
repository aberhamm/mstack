#!/usr/bin/env bash
# Smoke test for waiver.sh and its wiring into health-check.sh and
# review-gate.sh (plan 099). Every case runs in a throwaway git repo.
#
# THE INVARIANT UNDER TEST: a health waiver counts only when git history shows
# it was committed, by a listed approver, strictly before the plan's latest
# claim — and a waived category is never scored, never silently PASS. Each
# history rule (a)-(g) is broken on its own below, because a rule that no case
# breaks is a rule nothing proves is checked.
#
# Section 9 pins the 2026-10-27 code-review fixes (merge look-through, audit
# by history, no future-dating, full-sha base-commit, jq required).
#
# Usage: bash skills/mstack-run/scripts/waiver-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$SCRIPT_DIR/waiver.sh"
HC="$SCRIPT_DIR/health-check.sh"
RG="$SCRIPT_DIR/review-gate.sh"
# shellcheck source=skills/mstack-run/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=skills/mstack-run/scripts/fixtures/waiver/fixture.sh disable=SC1091
. "$SCRIPT_DIR/fixtures/waiver/fixture.sh"

CLEAN=()
cleanup() { [ "${#CLEAN[@]}" -gt 0 ] && rm -rf "${CLEAN[@]}"; }
trap cleanup EXIT
PASSED=0
fail() { echo "[waiver-smoke] FAIL: $*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); echo "[waiver-smoke] ok: $*"; }

[ -f "$WS" ] || fail "waiver.sh does not exist"
# jq is required (the fixture health runs read and write JSON history). A
# missing dependency is a FAILURE, not a skip: an exit 0 here would count as
# passing in the dev pre-commit hook while verifying nothing (plan 045).
command -v jq >/dev/null 2>&1 || { echo "[waiver-smoke] FAIL: jq not found. NOTHING WAS VERIFIED." >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/waiver-smoke-XXXXXX")"
CLEAN+=("$TMP")
PLAN=docs/plans/001-fixture.md

# in <dir> <cmd...>: run in a fixture repo.
in_repo() { local d="$1"; shift; ( cd "$d" && "$@" ); }
ws() { local d="$1"; shift; ( cd "$d" && bash "$WS" "$@" ); }
field() { printf '%s\n' "$1" | grep "^$2:" | head -1 | cut -d: -f2-; }
hc() { ( cd "$1" && PLAN_ID=001 bash "$HC" run 2>/dev/null ); }

# expect_rule <dir> <category> <rule> <label>
expect_rule() {
  local d="$1" cat="$2" rule="$3" label="$4" out rc=0
  out="$(ws "$d" check 001 "$cat" 2>/dev/null)" || rc=$?
  [ "$rc" -eq "$EXIT_WAIVER_INVALID" ] || fail "$label: check exit $rc, expected $EXIT_WAIVER_INVALID ($out)"
  case "$out" in
    "INVALID $cat $rule:"*) ;;
    *) fail "$label: expected rule ($rule), got: $out" ;;
  esac
  ok "$label -> rule ($rule)"
}

n=0
newrepo() { n=$((n + 1)); R="$TMP/r$n"; wf_repo "$R" "${1:-}"; }
claim() { wf_set_status "$1" in-progress; wf_commit "$1" "chore(plan 001): claim, in progress"; }

# --- 1. waive: arity and structural refusals (writes nothing) --------------
newrepo
cp "$R/$PLAN" "$TMP/plan.orig"
waive_refuses() {
  local label="$1"; shift
  if ws "$R" waive "$@" >/dev/null 2>&1; then fail "waive accepted: $label"; fi
  cmp -s "$R/$PLAN" "$TMP/plan.orig" || fail "waive wrote the plan despite refusing: $label"
  ok "waive refuses $label"
}
E="$WF_EXPIRES"
waive_refuses "fewer than 7 arguments" 001 lint blanket matthew "$E" mdec-1
waive_refuses "unknown category" 001 style blanket matthew "$E" mdec-1 r fb
waive_refuses "unknown mode" 001 lint partial matthew "$E" mdec-1 r fb
waive_refuses "blanket without fallback" 001 lint blanket matthew "$E" mdec-1 r
waive_refuses "baseline-delta with fallback" 001 shell baseline-delta matthew "$E" mdec-1 r fb
waive_refuses "baseline-delta for a category without an extractor" 001 lint baseline-delta matthew "$E" mdec-1 r
waive_refuses "baseline-delta without a committed baseline" 001 shell baseline-delta matthew "$E" mdec-1 r
waive_refuses "approver 'agent'" 001 lint blanket agent "$E" mdec-1 r fb
waive_refuses "approver 'mstack-run'" 001 lint blanket mstack-run "$E" mdec-1 r fb
waive_refuses "approver not in APPROVERS" 001 lint blanket bob "$E" mdec-1 r fb
waive_refuses "malformed approver token" 001 lint blanket Matthew "$E" mdec-1 r fb
waive_refuses "expiry more than 30 days out" 001 lint blanket matthew "$(wf_plus_days "$WF_TODAY" 31)" mdec-1 r fb
waive_refuses "expiry before the waiver date" 001 lint blanket matthew 2020-01-01 mdec-1 r fb
waive_refuses "an impossible date" 001 lint blanket matthew 2026-02-30 mdec-1 r fb
waive_refuses "a value with whitespace" 001 lint blanket matthew "$E" mdec-1 "two words" fb

msg="$(ws "$R" waive 001 lint blanket matthew "$E" mdec-1 pre-existing no-extractor 2>&1)" \
  || fail "valid blanket waive refused: $msg"
printf '%s' "$msg" | grep -q 'counts only after it is COMMITTED' || fail "waive did not print the commit-then-claim notice"
grep -q '^  - category=lint mode=blanket approver=matthew date=' "$R/$PLAN" || fail "waive did not write the entry"
ok "waive writes one entry and says it counts only once committed and then claimed"
cp "$R/$PLAN" "$TMP/plan.orig"
waive_refuses "a duplicate category" 001 lint blanket matthew "$E" mdec-1 again fb2

# Working-tree-only entry: never honoured (live checks read HEAD).
expect_rule "$R" lint b "an uncommitted entry"
out="$(ws "$R" evaluate 001 lint /dev/null 1)"
[ "$out" = "INVALID uncommitted" ] || fail "evaluate honoured an uncommitted entry: $out"
ok "evaluate reports an uncommitted entry as INVALID, not WAIVED"

# --- 2. structural rejections of committed entries -------------------------
newrepo
wf_add_line "$R" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f colour=red"
wf_commit "$R" "waive (unknown key)"; claim "$R"
expect_rule "$R" lint s "an unknown key"

newrepo
wf_add_line "$R" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
wf_add_line "$R" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r2 fallback=f"
wf_commit "$R" "waive (duplicate)"; claim "$R"
expect_rule "$R" lint s "a duplicate category"

newrepo
wf_add_line "$R" "category=lint mode=blanket approver=matthew date=$WF_TODAY ref=m reason=r fallback=f"
wf_commit "$R" "waive (missing expires)"; claim "$R"
expect_rule "$R" lint s "a missing expires key"

# --- 3. the valid baseline: both waivers honoured --------------------------
V="$TMP/valid"
wf_valid "$V" "$WS" || fail "could not build the valid fixture"
[ "$(ws "$V" check 001 shell)" = "VALID shell baseline-delta" ] || fail "valid shell waiver rejected"
[ "$(ws "$V" check 001 lint)" = "VALID lint blanket" ] || fail "valid lint waiver rejected"
ok "a waiver committed by a listed approver before the claim is VALID (delta and blanket)"

# Worktree differing from HEAD is not honoured.
cp "$V/$PLAN" "$TMP/v.plan"
sed 's/reason=pre-existing/reason=edited/' "$TMP/v.plan" > "$V/$PLAN"
out="$(ws "$V" evaluate 001 lint /dev/null 1)"
[ "$out" = "INVALID worktree-differs-from-HEAD" ] || fail "evaluate honoured a worktree-edited entry: $out"
cp "$TMP/v.plan" "$V/$PLAN"
ok "an entry that differs between the working tree and HEAD is not honoured"

# --- 4. history rules, each broken on its own ------------------------------
# (a) shallow clone.
SH="$TMP/shallow"
git clone -q --depth 1 "file://$V" "$SH" 2>/dev/null || fail "could not make a shallow clone"
expect_rule "$SH" shell a "a shallow clone (cannot verify)"

# (c) root commit introduces the waiver.
R="$TMP/root"; mkdir -p "$R"
wf_repo "$R"
( cd "$R" && rm -rf .git && git init -q && git config user.email w@e.com && git config user.name w \
  && git config core.hooksPath "$R/.nohooks" )
wf_add_line "$R" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
wf_commit "$R" "root with waiver"; claim "$R"
expect_rule "$R" lint c "a waiver introduced by the root commit"

# (c) merge commit introduces the waiver.
newrepo
in_repo "$R" git checkout -q -b side
echo side > "$R/side.txt"; wf_commit "$R" "side"
in_repo "$R" git checkout -q -
echo main > "$R/main.txt"; wf_commit "$R" "main"
in_repo "$R" git merge -q --no-ff --no-commit side >/dev/null 2>&1
wf_add_line "$R" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
( cd "$R" && git add -A && git commit -q -m "merge with waiver" )
claim "$R"
expect_rule "$R" lint c "a waiver introduced by a merge commit"

# (d) approver added in the waiver commit itself.
newrepo
echo bob >> "$R/docs/plans/waivers/APPROVERS"
wf_add_line "$R" "category=lint mode=blanket approver=bob date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
wf_commit "$R" "add bob and his waiver"; claim "$R"
expect_rule "$R" lint d "an approver added in the waiver commit itself"

# (d) approver later removed from the file (revocation).
R="$TMP/revoked"; wf_valid "$R" "$WS" || fail "fixture"
printf '# approvers\n' > "$R/docs/plans/waivers/APPROVERS"; wf_commit "$R" "revoke"
expect_rule "$R" lint d "an approver later removed from APPROVERS"

# (e) waiver added in the claim commit.
newrepo
wf_add_line "$R" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
wf_set_status "$R" in-progress; wf_commit "$R" "claim and waive at once"
expect_rule "$R" lint e "a waiver added in the claim commit"

# (e) waiver added after the claim.
newrepo
claim "$R"
wf_add_line "$R" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
wf_commit "$R" "waive mid-run"
expect_rule "$R" lint e "a waiver added after the claim"

# (e) never claimed.
newrepo
wf_add_line "$R" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
wf_commit "$R" "waive"
expect_rule "$R" lint e "a plan with no claim commit"

# (f) expired.
newrepo
wf_add_line "$R" "category=lint mode=blanket approver=matthew date=2020-01-01 expires=2020-01-20 ref=m reason=r fallback=f"
wf_commit "$R" "old waiver"; claim "$R"
expect_rule "$R" lint f "an expired waiver"

# (g) baseline-delta with no baseline at W.
newrepo
wf_add_line "$R" "category=shell mode=baseline-delta approver=matthew date=$WF_TODAY expires=$E ref=m reason=r"
wf_commit "$R" "delta without baseline"; claim "$R"
expect_rule "$R" shell g "a baseline-delta waiver with no baseline"

# (g) baseline edited after W.
R="$TMP/edited-baseline"; wf_valid "$R" "$WS" || fail "fixture"
printf 'dev.sh|SC9999\t5\n' >> "$R/docs/plans/waivers/001-shell.baseline"; wf_commit "$R" "widen baseline"
expect_rule "$R" shell g "a baseline edited after the waiver commit"

# (g) baseline from another extractor version.
newrepo
B="$R/docs/plans/waivers/001-shell.baseline"
printf 'base-commit: %s\ncategory: shell\nextractor: shellcheck-v0\n' "$(in_repo "$R" git rev-parse HEAD)" > "$B"
wf_commit "$R" "old-extractor baseline"
ws "$R" waive 001 shell baseline-delta matthew "$E" m r >/dev/null 2>&1 || fail "waive refused a committed baseline"
wf_commit "$R" "waive"; claim "$R"
expect_rule "$R" shell g "a baseline written by another extractor version"

# (g) base-commit that is not an ancestor of W^.
newrepo
empty_tree="$(in_repo "$R" git hash-object -t tree -w /dev/null)"
orphan="$(in_repo "$R" git commit-tree "$empty_tree" -m orphan)"
printf 'base-commit: %s\ncategory: shell\nextractor: shellcheck-v1\n' "$orphan" > "$R/docs/plans/waivers/001-shell.baseline"
wf_commit "$R" "baseline from elsewhere"
ws "$R" waive 001 shell baseline-delta matthew "$E" m r >/dev/null 2>&1 || fail "waive refused"
wf_commit "$R" "waive"; claim "$R"
expect_rule "$R" shell g "a baseline whose base-commit is not an ancestor of W^"

# --- 5. extractors on recorded sample output -------------------------------
got="$(printf '%s\n' "$WF_SC_BASE" | bash "$WS" extract shell)"
want="$(printf 'dev.sh|SC2086\t2\ndev.sh|SC2164\t1')"
[ "$got" = "$want" ] || fail "shellcheck-v1 extracted: $got"
ok "shellcheck-v1: file|SC identities with multiset counts; wiki links are not findings"

got="$(printf '%s\n\033[91msrc/c.ts(1,1): error TS2322:\033[0m x\n' "$WF_TSC_BASE" | bash "$WS" extract typecheck)"
want="$(printf 'src/a.ts|TS2322\t1\nsrc/b.ts|TS2304\t1\nsrc/c.ts|TS2322\t1')"
[ "$got" = "$want" ] || fail "tsc-v1 extracted: $got"
ok "tsc-v1: both tsc forms, ANSI colour stripped, line numbers ignored"

# --- 6. health-check: WAIVED, PASS-WAIVED, delta, noncomparable -------------
out="$(hc "$V")"
[ "$(field "$out" VERDICT)" = "PASS-WAIVED" ] || fail "valid waivers: $out"
[ "$(field "$out" SHELL)" = "WAIVED" ] && [ "$(field "$out" LINT)" = "WAIVED" ] || fail "waived categories not WAIVED: $out"
[ "$(field "$out" COMPOSITE)" = "10.0" ] || fail "composite must cover only the scored category: $out"
[ "$(field "$out" WAIVED)" = "lint:blanket,shell:baseline-delta" ] || fail "WAIVED line: $out"
[ "$(field "$out" FAILURES)" = "none" ] || fail "FAILURES: $out"
last="$(tail -1 "$V/.mstack/health-history.jsonl")"
[ "$(printf '%s' "$last" | jq -c '[.shell, .lint, .typecheck, .waived]')" = '[null,null,10,["lint:blanket","shell:baseline-delta"]]' ] \
  || fail "history entry: $last"
grep -qx 'result=no-new-failures' "$V/.mstack/waivers/plan-001-shell.delta" || fail "no delta evidence"
ok "valid waivers: SHELL/LINT WAIVED, excluded from the composite, PASS-WAIVED, history nulls + waived field"

# Without PLAN_ID no waiver is consulted.
out="$( cd "$V" && bash "$HC" run 2>/dev/null )"
[ "$(field "$out" WAIVED)" = "none" ] && [ "$(field "$out" SHELL)" != "WAIVED" ] || fail "waiver consulted without PLAN_ID: $out"
ok "without PLAN_ID no waiver is consulted"

# Swapped order and moved lines: same multiset, still waived.
# shellcheck disable=SC2016  # literal shellcheck output
printf '\nIn dev.sh line 40:\ncd $DIR\n^-----^ SC2164 (warning): x\n   ^--^ SC2086 (info): y\n\nIn dev.sh line 90:\necho $FOO\n     ^--^ SC2086 (info): z\n' > "$V/out/sc.txt"
out="$(hc "$V")"
[ "$(field "$out" SHELL)" = "WAIVED" ] || fail "swapped identities regressed: $out"
ok "baseline-delta: reordered findings on new line numbers are not new failures"

# One extra instance of a known identity IS new.
# shellcheck disable=SC2016  # literal shellcheck output
printf '%s\n\nIn dev.sh line 99:\nls $X\n   ^-- SC2086 (info): q\n' "$WF_SC_BASE" > "$V/out/sc.txt"
out="$(hc "$V")"
printf '%s' "$(field "$out" FAILURES)" | grep -q 'waiver-delta-regressed:shell' || fail "duplicated identity not caught: $out"
[ "$(field "$out" SHELL)" != "WAIVED" ] || fail "a regressed delta must be scored: $out"
grep -qx 'result=new-failures' "$V/.mstack/waivers/plan-001-shell.delta" || fail "regressed delta evidence"
ok "baseline-delta: a duplicated identity is a regression (waiver-delta-regressed:shell, scored)"

printf 'segmentation fault\n' > "$V/out/sc.txt"
out="$(hc "$V")"
printf '%s' "$(field "$out" FAILURES)" | grep -q 'waiver-noncomparable:shell' || fail "noncomparable not reported: $out"
ok "unparseable failing output is waiver-noncomparable, never waived"
in_repo "$V" git checkout -q -- out/sc.txt

# All categories waived, all blanket: nothing measured => FAIL.
newrepo
printf 'x\n' > "$R/out/lint.txt"; printf '%s\n' "$WF_TSC_BASE" > "$R/out/tsc.txt"; printf '%s\n' "$WF_SC_BASE" > "$R/out/sc.txt"
for c in typecheck lint shell; do
  wf_add_line "$R" "category=$c mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
done
wf_commit "$R" "waive everything blanket"; claim "$R"
out="$(hc "$R")"
[ "$(field "$out" VERDICT)" = "FAIL" ] || fail "all-blanket must FAIL: $out"
printf '%s' "$(field "$out" FAILURES)" | grep -q 'all-categories-waived' || fail "all-categories-waived missing: $out"
[ "$(field "$out" COMPOSITE)" = "n/a" ] || fail "all-blanket composite: $out"
ok "every category blanket-waived => FAIL all-categories-waived (nothing measured)"

# The 039 shape: every category fails at baseline; typecheck+shell by delta,
# lint blanket => PASS-WAIVED with COMPOSITE:n/a.
D39="$TMP/d39"; wf_repo "$D39"
printf 'x\n' > "$D39/out/lint.txt"; printf '%s\n' "$WF_TSC_BASE" > "$D39/out/tsc.txt"; printf '%s\n' "$WF_SC_BASE" > "$D39/out/sc.txt"
wf_commit "$D39" "everything fails at baseline"
ws "$D39" capture-baseline 001 shell >/dev/null 2>&1 || fail "capture shell"
wf_commit "$D39" "shell baseline"
ws "$D39" capture-baseline 001 typecheck >/dev/null 2>&1 || fail "capture typecheck"
wf_commit "$D39" "typecheck baseline"
ws "$D39" waive 001 typecheck baseline-delta matthew "$E" m r >/dev/null 2>&1 || fail "waive tc"
ws "$D39" waive 001 shell baseline-delta matthew "$E" m r >/dev/null 2>&1 || fail "waive sh"
ws "$D39" waive 001 lint blanket matthew "$E" m r no-extractor >/dev/null 2>&1 || fail "waive lint"
wf_commit "$D39" "waivers"; claim "$D39"
out="$(hc "$D39")"
[ "$(field "$out" VERDICT)" = "PASS-WAIVED" ] && [ "$(field "$out" COMPOSITE)" = "n/a" ] || fail "039 shape: $out"
[ "$(tail -1 "$D39/.mstack/health-history.jsonl" | jq -r '.score')" = "null" ] || fail "n/a must persist as JSON null"
ok "every category failing, mixed delta+blanket (039 shape) => PASS-WAIVED COMPOSITE:n/a, score null"

# capture-baseline refuses a dirty tree and unparseable failing output.
echo dirt > "$D39/dirt.txt"
ws "$D39" capture-baseline 001 shell >/dev/null 2>&1 && fail "capture-baseline accepted a dirty tree"
rm -f "$D39/dirt.txt"
ok "capture-baseline refuses a dirty working tree"
newrepo; printf 'segfault\n' > "$R/out/sc.txt"; wf_commit "$R" "garbage"
ws "$R" capture-baseline 001 shell >/dev/null 2>&1 && fail "capture-baseline accepted unparseable output"
ok "capture-baseline refuses a failing command with zero parsed identities"
ws "$R" capture-baseline 001 lint >/dev/null 2>&1 && fail "capture-baseline accepted lint"
ok "capture-baseline refuses a category without an extractor"

# --- 7. pre-commit hook: done commit, archive commit ------------------------
HOOKS="$TMP/hooks"; wf_hooks "$HOOKS" "$RG"
H="$TMP/hooked"; wf_valid "$H" "$WS" "$HOOKS" || fail "hooked fixture"
wf_set_status "$H" "done"
( cd "$H" && git add -A && git commit -q -m "feat: done" ) >/dev/null 2>&1 || fail "hook rejected a done commit with a valid waiver"
ok "hook accepts a done commit whose waivers were committed before the claim"

mkdir -p "$H/docs/plans/archive"
in_repo "$H" git mv "$PLAN" docs/plans/archive/001-fixture.md
sed 's/reason=pre-existing/reason=widened/' "$H/docs/plans/archive/001-fixture.md" > "$TMP/a.md"
cat "$TMP/a.md" > "$H/docs/plans/archive/001-fixture.md"
in_repo "$H" git add -A
if ( cd "$H" && git commit -q -m "archive and edit waiver" ) >/dev/null 2>&1; then
  fail "hook accepted an archive rename that edits a waiver entry"
fi
ok "hook rejects an archive rename that also edits a waiver entry"
in_repo "$H" git reset -q --hard
mkdir -p "$H/docs/plans/archive"
in_repo "$H" git mv "$PLAN" docs/plans/archive/001-fixture.md
( cd "$H" && git commit -q -m "chore(plan 001): archive" ) >/dev/null 2>&1 || fail "hook rejected the archive commit of a waived done plan"
ok "hook accepts the git mv archive commit of a waived done plan"

H2="$TMP/hooked2"; wf_repo "$H2" "$HOOKS"
printf 'x\n' > "$H2/out/lint.txt"; wf_commit "$H2" "lint fails"
claim "$H2"
wf_add_line "$H2" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
wf_set_status "$H2" "done"
if ( cd "$H2" && git add -A && git commit -q -m "done with a fresh waiver" ) >/dev/null 2>&1; then
  fail "hook accepted a waiver that first appears in the done commit"
fi
ok "hook rejects a done commit whose waiver entry first appears in that commit"

# --- 8. audit: completed-under-waiver listing, re-claimed, offenders ---------
out="$(cd "$H" && bash "$RG" audit 2>/dev/null)" || fail "audit failed on a valid waived plan: $out"
printf '%s\n' "$out" | grep -qx '  001: Fixture plan — shell:baseline-delta approver=matthew ref=mdec-1' \
  || fail "audit listing: $out"
printf '%s\n' "$out" | grep -q 're-claimed' && fail "first-claim waiver marked re-claimed: $out"
ok "audit lists every plan completed under a waiver with approver and ref"
warn="$(cd "$H" && bash "$RG" audit 2>&1 >/dev/null)"
printf '%s' "$warn" | grep -q "blanket-waived" || fail "blanket completion is not warned: $warn"
ok "audit warns (non-failing) on a blanket-waived completion"

RC="$TMP/reclaim"; wf_repo "$RC" "$HOOKS"
printf 'x\n' > "$RC/out/lint.txt"; wf_commit "$RC" "lint fails"
claim "$RC"
wf_set_status "$RC" blocked; wf_commit "$RC" "blocked, health gate fails at baseline"
ws "$RC" waive 001 lint blanket matthew "$E" mdec-2 pre-existing no-extractor >/dev/null 2>&1 || fail "waive"
wf_commit "$RC" "waive"
claim "$RC"
wf_set_status "$RC" "done"
( cd "$RC" && git add -A && git commit -q -m "done" ) >/dev/null 2>&1 || fail "hook rejected the re-claimed done commit"
out="$(cd "$RC" && bash "$RG" audit 2>/dev/null)" || fail "audit: $out"
printf '%s\n' "$out" | grep -qx '  001: Fixture plan — lint:blanket approver=matthew ref=mdec-2 re-claimed' \
  || fail "re-claimed suffix missing: $out"
ok "audit marks a waiver committed between two claims as re-claimed"

OF="$TMP/offender"; wf_repo "$OF"
claim "$OF"
wf_add_line "$OF" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
wf_set_status "$OF" "done"; wf_commit "$OF" "done, waiver smuggled in (no hook)"
rc=0; out="$(cd "$OF" && bash "$RG" audit 2>/dev/null)" || rc=$?
[ "$rc" -eq "$EXIT_GATE_AUDIT_FOUND" ] || fail "audit exit $rc on a smuggled waiver: $out"
printf '%s' "$out" | grep -q 'fails rule (e)' || fail "audit offender line: $out"
ok "audit flags a waiver that first appeared in the done commit (exit $EXIT_GATE_AUDIT_FOUND)"

# --- 9. review fixes (code review 2026-10-27) --------------------------------
# M1: a waiver committed and claimed on a branch merged --no-ff is looked
# through the merge (fast-forward-equivalent for the plan file), not refused.
MB="$TMP/merge-branch"; wf_repo "$MB"
in_repo "$MB" git checkout -q -b feat
printf 'x\n' > "$MB/out/lint.txt"; wf_commit "$MB" "lint fails"
ws "$MB" waive 001 lint blanket matthew "$E" mdec-3 pre-existing no-extractor >/dev/null 2>&1 || fail "waive on branch"
wf_commit "$MB" "waive"; claim "$MB"
wf_set_status "$MB" "done"; wf_commit "$MB" "done on the branch"
in_repo "$MB" git checkout -q -
echo main > "$MB/main.txt"; wf_commit "$MB" "unrelated main work"
in_repo "$MB" git merge -q --no-ff -m "merge feat" feat >/dev/null 2>&1 || fail "merge feat"
rc=0; out="$(cd "$MB" && bash "$RG" audit 2>/dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "M1: audit flags a waiver legitimately completed on a --no-ff-merged branch (rc $rc): $out"
printf '%s\n' "$out" | grep -qx '  001: Fixture plan — lint:blanket approver=matthew ref=mdec-3' || fail "M1 audit listing: $out"
ok "M1: a waived plan completed on a branch merged --no-ff passes the audit"

MC="$TMP/merge-claim"; wf_repo "$MC" "$HOOKS"
in_repo "$MC" git checkout -q -b feat
printf 'x\n' > "$MC/out/lint.txt"; wf_commit "$MC" "lint fails"
ws "$MC" waive 001 lint blanket matthew "$E" mdec-4 pre-existing no-extractor >/dev/null 2>&1 || fail "waive on branch"
wf_commit "$MC" "waive"; claim "$MC"
in_repo "$MC" git checkout -q -
in_repo "$MC" git merge -q --no-ff -m "merge feat" feat >/dev/null 2>&1 || fail "merge feat"
[ "$(ws "$MC" check 001 lint 2>/dev/null)" = "VALID lint blanket" ] || fail "M1: check after a --no-ff merge: $(ws "$MC" check 001 lint 2>&1)"
wf_set_status "$MC" "done"
( cd "$MC" && git add -A && git commit -q -m "done on main" ) >/dev/null 2>&1 \
  || fail "M1: hook refused a done commit on main after the claim branch was merged --no-ff"
ok "M1: waiver+claim on a branch merged --no-ff stays VALID; the done commit on main is accepted"

# The look-through never loosens rule (e): a waiver after the claim on the
# side branch is still refused after the merge.
ML="$TMP/merge-late"; wf_repo "$ML"
in_repo "$ML" git checkout -q -b feat
claim "$ML"
wf_add_line "$ML" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
wf_commit "$ML" "waive after the claim"
in_repo "$ML" git checkout -q -
echo main > "$ML/main.txt"; wf_commit "$ML" "unrelated main work"
in_repo "$ML" git merge -q --no-ff -m "merge feat" feat >/dev/null 2>&1 || fail "merge feat"
expect_rule "$ML" lint e "M1: a side-branch waiver after the claim, merged --no-ff"

# A merge that changed the plan on both sides is ambiguous: still rule (c).
MA="$TMP/merge-both"; wf_repo "$MA"
in_repo "$MA" git checkout -q -b feat
wf_add_line "$MA" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
wf_commit "$MA" "waive on the branch"
in_repo "$MA" git checkout -q -
printf '\nMain-side note.\n' >> "$MA/$PLAN"; wf_commit "$MA" "main edits the plan body"
in_repo "$MA" git merge -q --no-ff -m "merge feat" feat >/dev/null 2>&1 || fail "merge feat (two-sided)"
claim "$MA"
expect_rule "$MA" lint c "M1: a merge that combined plan edits from both sides (ambiguous)"

# M2: deleting the waivers: block after a --no-verify completion does not
# erase the offender: the audit reads the done commit, not the tip.
OD="$TMP/offender-deleted"; wf_repo "$OD"
claim "$OD"
wf_add_line "$OD" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
wf_set_status "$OD" "done"; wf_commit "$OD" "done, waiver smuggled in (no hook)"
grep -v -e '^waivers:' -e 'category=lint' "$OD/$PLAN" > "$TMP/od.md"; cat "$TMP/od.md" > "$OD/$PLAN"
wf_commit "$OD" "delete the waivers block"
rc=0; out="$(cd "$OD" && bash "$RG" audit 2>/dev/null)" || rc=$?
[ "$rc" -eq "$EXIT_GATE_AUDIT_FOUND" ] || fail "M2: audit exit $rc after the waiver was deleted post-done: $out"
printf '%s' "$out" | grep -q 'fails rule (e)' || fail "M2 offender line: $out"
ok "M2: an invalid waiver deleted after done is still an audit offender (exit $EXIT_GATE_AUDIT_FOUND)"

# N2: the history-based audit selects a plan by a real frontmatter waivers:
# block only. Body prose documenting the category= format, and the template's
# commented example, must not make a shallow clone report a false offender.
NB="$TMP/n2-body"; wf_repo "$NB"
claim "$NB"
printf '\nDocumented format:\n\n  - category=lint mode=blanket approver=matthew date=2026-01-01 expires=2026-01-10 ref=m reason=r fallback=f\n' >> "$NB/$PLAN"
wf_set_status "$NB" "done"; wf_commit "$NB" "done, category= appears only in body prose"
NBS="$TMP/n2-body-shallow"
git clone -q --depth 1 "file://$NB" "$NBS" 2>/dev/null || fail "N2: could not make a shallow clone"
rc=0; out="$(cd "$NBS" && bash "$RG" audit 2>/dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "N2(a): shallow audit flags a plan with category= only in body prose (rc $rc): $out"
ok "N2(a): body-prose category= in a shallow clone is not an audit offender"

NT="$TMP/n2-template"; wf_repo "$NT"
claim "$NT"
awk '/^---[[:space:]]*$/ { fm++; if (fm == 2) { print "# waivers:"; print "#   - category=lint mode=blanket approver=matthew date=2026-01-01 expires=2026-01-10 ref=m reason=r fallback=f" } } { print }' \
  "$NT/$PLAN" > "$TMP/n2t.md" && cat "$TMP/n2t.md" > "$NT/$PLAN"
grep -q '^#   - category=' "$NT/$PLAN" || fail "N2(b): fixture did not get the commented example"
wf_set_status "$NT" "done"; wf_commit "$NT" "done, commented template example kept"
NTS="$TMP/n2-template-shallow"
git clone -q --depth 1 "file://$NT" "$NTS" 2>/dev/null || fail "N2: could not make a shallow clone"
rc=0; out="$(cd "$NTS" && bash "$RG" audit 2>/dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "N2(b): shallow audit flags the commented template example (rc $rc): $out"
ok "N2(b): the template's commented waivers: example in a shallow clone is not an audit offender"

# N2(c): a real frontmatter block that existed in history is still selected
# (M2 above asserts exit 27 after deletion). Here the same plan also carries
# body prose, and a shallow clone whose tip holds the block is still flagged.
NR="$TMP/n2-real"; wf_repo "$NR"
claim "$NR"
wf_add_line "$NR" "category=lint mode=blanket approver=matthew date=$WF_TODAY expires=$E ref=m reason=r fallback=f"
wf_set_status "$NR" "done"; wf_commit "$NR" "done, waiver smuggled in (no hook)"
NRS="$TMP/n2-real-shallow"
git clone -q --depth 1 "file://$NR" "$NRS" 2>/dev/null || fail "N2: could not make a shallow clone"
rc=0; out="$(cd "$NRS" && bash "$RG" audit 2>/dev/null)" || rc=$?
[ "$rc" -eq "$EXIT_GATE_AUDIT_FOUND" ] || fail "N2(c): shallow audit misses a real frontmatter waiver (rc $rc): $out"
ok "N2(c): a real frontmatter waivers: block is still audited (M2 covers the deleted-block case)"

# L1: a future-dated entry cannot stretch the 30-day cap.
newrepo
FD="$(wf_plus_days "$WF_TODAY" 300)"
wf_add_line "$R" "category=lint mode=blanket approver=matthew date=$FD expires=$(wf_plus_days "$FD" 20) ref=m reason=r fallback=f"
wf_commit "$R" "future-dated waiver"; claim "$R"
expect_rule "$R" lint f "L1: a waiver dated after its introducing commit"

# L2: base-commit must be a full sha, not a rev expression.
newrepo
printf '%s\n' "$WF_SC_BASE" > "$R/out/sc.txt"; wf_commit "$R" "shell fails"
printf 'base-commit: HEAD~2\ncategory: shell\nextractor: shellcheck-v1\n' > "$R/docs/plans/waivers/001-shell.baseline"
wf_commit "$R" "baseline with a relative rev"
ws "$R" waive 001 shell baseline-delta matthew "$E" m r >/dev/null 2>&1 || fail "waive refused"
wf_commit "$R" "waive"; claim "$R"
expect_rule "$R" shell g "L2: a baseline whose base-commit is a rev expression"

# L3: a missing jq is a failure, never a passing skip.
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
IFS=: read -ra _pdirs <<< "$PATH"
for _d in "${_pdirs[@]}"; do [ -d "$_d" ] && ln -s "$_d"/* "$NOJQ"/ 2>/dev/null; done
rm -f "$NOJQ/jq"
PATH="$NOJQ" command -v jq >/dev/null 2>&1 && fail "L3: could not hide jq"
rc=0; PATH="$NOJQ" bash "$SCRIPT_DIR/result-gate-smoke.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "L3: result-gate-smoke exits 0 without jq"
rc=0; PATH="$NOJQ" bash "$SCRIPT_DIR/waiver-smoke.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "L3: waiver-smoke exits 0 without jq"
ok "L3: result-gate-smoke and waiver-smoke fail (nonzero) when jq is missing"

echo "[waiver-smoke] all $PASSED checks passed"
