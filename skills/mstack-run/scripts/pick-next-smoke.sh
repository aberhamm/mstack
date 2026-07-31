#!/usr/bin/env bash
# Smoke test for pick-next.sh — the backlog selector every mstack run flows
# through (plan 057).
#
# WHY THIS EXISTS. pick-next.sh is ~469 lines of enforcement-critical bash that
# had ZERO coverage while every other gate script had a suite. It produced three
# Tier-1 audit findings (plans 054/055/056) precisely because nothing pinned its
# behavior: the exit-code contract, `blocked-by` parsing, priority ordering, and
# the scope/goal filters were enforced by nobody.
#
# THIS IS A CHARACTERIZATION SUITE, and that is deliberate (plan 057's backlog
# amendment of 2026-07-31 reordered it to land BEFORE 054/055). It pins what the
# picker does TODAY, including behavior that is known-wrong. Plan 055 rewrites
# the picker's internals — including a recursive `cycle_dfs` port whose silent
# failure mode is a missed cycle, i.e. a picker that never terminates. Without a
# net underneath it, that rewrite is unverifiable.
#
# Cases that pin a KNOWN DEFECT are marked `CHARACTERIZATION`. They assert
# today's behavior so the rewrite that fixes them must come here and flip the
# assertion deliberately, in the open, instead of changing the picker silently.
# Do NOT "fix" a CHARACTERIZATION case by loosening it; either the defect is
# fixed (flip the assertion) or it is not (leave it pinned).
#
# Exit codes are asserted against the sourced lib.sh CONSTANTS, never bare
# numbers, so a renumbering fails loudly here rather than drifting.
#
# Every case builds its own throwaway git repo under mktemp; the suite asserts
# it is not operating on the mstack checkout before it writes a single fixture,
# because a picker suite that scribbled in docs/plans/ would be worse than none.
#
# Usage: bash skills/mstack-run/scripts/pick-next-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PN="$SCRIPT_DIR/pick-next.sh"
# shellcheck source=skills/mstack-run/scripts/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"

CLEAN=()
cleanup() { [ "${#CLEAN[@]}" -gt 0 ] && rm -rf "${CLEAN[@]}"; return 0; }
trap cleanup EXIT
PASSED=0
fail() { echo "[pick-next-smoke] FAIL: $*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); echo "[pick-next-smoke] ok: $*"; }

[ -f "$PN" ] || fail "pick-next.sh not found at $PN"

# The checkout we must never touch.
MSTACK_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

# --- Harness ----------------------------------------------------------------

# new_repo: a fresh git repo with an empty docs/plans/. Echoes the resolved
# (symlink-free) path, so stdout comparisons match what pick-next.sh derives
# from `git rev-parse --show-toplevel` (/var -> /private/var on macOS).
new_repo() {
  local t
  t="$(mktemp -d "${TMPDIR:-/tmp}/pick-next-smoke-XXXXXX")" || fail "mktemp failed"
  t="$(cd "$t" && pwd -P)"
  CLEAN+=("$t")
  mkdir -p "$t/docs/plans"
  ( cd "$t" && git init -q && git config user.email s@e.com && git config user.name s ) \
    || fail "git init failed in $t"
  # Fixture guard: if this ever resolves to the mstack checkout, abort before
  # writing anything.
  local top
  top="$(git -C "$t" rev-parse --show-toplevel 2>/dev/null || true)"
  [ "$top" = "$t" ] || fail "fixture repo toplevel is '$top', expected '$t'"
  [ -n "$MSTACK_ROOT" ] && [ "$top" = "$MSTACK_ROOT" ] \
    && fail "REFUSING to run: fixture resolved to the mstack checkout ($top)"
  printf '%s\n' "$t"
}

# plan <repo> <filename>  — body on stdin.
plan() { cat > "$1/docs/plans/$2"; }

# run_pick <repo> [args...] — sets OUT (stdout), ERR (stderr), RC (exit code).
OUT="" ERR="" RC=0
run_pick() {
  local repo="$1"; shift
  local errf
  errf="$(mktemp "${TMPDIR:-/tmp}/pick-next-smoke-err-XXXXXX")" || fail "mktemp failed"
  OUT="$( cd "$repo" && bash "$PN" "$@" 2>"$errf" )" && RC=0 || RC=$?
  ERR="$(cat "$errf")"
  rm -f "$errf"
}

# --- 1. exit 0: a pending, unblocked plan is picked and its PATH is stdout ---
# The path is the whole product: mstack-run reads stdout and opens that file.
R="$(new_repo)"
plan "$R" 001-done.md <<'P'
---
id: 001
title: already finished
status: done
blocked-by: []
needs-review: none
---
P
plan "$R" 002-next.md <<'P'
---
id: 002
title: the one to pick
status: pending
blocked-by: [001]
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_PLAN_FOUND" ] || fail "expected EXIT_PLAN_FOUND ($EXIT_PLAN_FOUND) for an unblocked plan, got $RC (stderr: $ERR)"
[ "$OUT" = "$R/docs/plans/002-next.md" ] || fail "stdout must be the chosen plan's path, got '$OUT'"
ok "a pending plan whose deps are done is picked, exit $EXIT_PLAN_FOUND, path on stdout"

# --- 2. exit 10: nothing to pick -------------------------------------------
R="$(new_repo)"
run_pick "$R"
[ "$RC" -eq "$EXIT_ALL_DONE" ] || fail "empty docs/plans must exit EXIT_ALL_DONE ($EXIT_ALL_DONE), got $RC"
[ -z "$OUT" ] || fail "exit $EXIT_ALL_DONE must print no path, got '$OUT'"
ok "an empty backlog exits EXIT_ALL_DONE ($EXIT_ALL_DONE) with empty stdout"

R="$(new_repo)"
plan "$R" 001-a.md <<'P'
---
id: 001
title: a
status: done
blocked-by: []
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_ALL_DONE" ] || fail "an all-done backlog must exit EXIT_ALL_DONE, got $RC"
ok "a backlog where every plan is done exits EXIT_ALL_DONE ($EXIT_ALL_DONE)"

# --- 3. exit 11: a scoped id with no plan file ------------------------------
R="$(new_repo)"
plan "$R" 050-a.md <<'P'
---
id: 050
title: a
status: pending
blocked-by: []
needs-review: none
---
P
run_pick "$R" 999
[ "$RC" -eq "$EXIT_SCOPED_NOT_FOUND" ] || fail "a scoped id with no file must exit EXIT_SCOPED_NOT_FOUND ($EXIT_SCOPED_NOT_FOUND), got $RC"
printf '%s' "$ERR" | grep -q '999' || fail "the diagnostic must name the missing id: $ERR"
ok "a scoped id that matches no plan exits EXIT_SCOPED_NOT_FOUND ($EXIT_SCOPED_NOT_FOUND) and names it"

# --- 4. exit 12 (scoped): blocked by an out-of-scope dep --------------------
# The distinction that matters to the runner: "your scope cannot progress"
# is not "you are finished". Conflating them makes a stuck run look successful.
R="$(new_repo)"
plan "$R" 060-dep.md <<'P'
---
id: 060
title: the dependency, left out of scope
status: pending
blocked-by: []
needs-review: none
---
P
plan "$R" 061-b.md <<'P'
---
id: 061
title: scoped but blocked
status: pending
blocked-by: [060]
needs-review: none
---
P
run_pick "$R" 061
[ "$RC" -eq "$EXIT_ALL_BLOCKED" ] || fail "an out-of-scope dep must exit EXIT_ALL_BLOCKED ($EXIT_ALL_BLOCKED), got $RC"
printf '%s' "$ERR" | grep -q '60' || fail "the diagnostic must name the blocking dep: $ERR"
[ -z "$OUT" ] || fail "exit $EXIT_ALL_BLOCKED must print no path, got '$OUT'"
ok "a scoped plan blocked by an out-of-scope dep exits EXIT_ALL_BLOCKED ($EXIT_ALL_BLOCKED)"

# --- 5. CHARACTERIZATION: unscoped all-blocked is reported as all-done ------
# Same repo shape, no scope filter: the backlog cannot progress (061 is blocked,
# 060 is review-gated) yet the picker says "all plans done" and exits 10. That
# is the plan-054 defect, pinned here so 054 must flip THIS line.
R="$(new_repo)"
plan "$R" 060-gated.md <<'P'
---
id: 060
title: review-gated, cannot be picked
status: pending
blocked-by: []
needs-review: eng
---
P
plan "$R" 061-blocked.md <<'P'
---
id: 061
title: blocked on the gated plan
status: pending
blocked-by: [060]
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_ALL_DONE" ] \
  || fail "CHARACTERIZATION drift: unscoped dep-blocked backlog now exits $RC. If plan 054 landed, flip this case to expect EXIT_ALL_BLOCKED ($EXIT_ALL_BLOCKED)."
ok "CHARACTERIZATION: an unscoped, dep-blocked + review-gated backlog still exits EXIT_ALL_DONE (plan 054 must flip this to EXIT_ALL_BLOCKED)"

# --- 6. exit 13: a 2-node dependency cycle ---------------------------------
# The one that must never regress silently: a missed cycle is a picker that
# never terminates.
R="$(new_repo)"
plan "$R" 020-a.md <<'P'
---
id: 020
title: a
status: pending
blocked-by: [021]
needs-review: none
---
P
plan "$R" 021-b.md <<'P'
---
id: 021
title: b
status: pending
blocked-by: [020]
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_CYCLE" ] || fail "a 2-node cycle must exit EXIT_CYCLE ($EXIT_CYCLE), got $RC (stderr: $ERR)"
printf '%s' "$ERR" | grep -qi 'cycle' || fail "the diagnostic must say it found a cycle: $ERR"
printf '%s' "$ERR" | grep -q '20' || fail "the diagnostic must name the nodes on the cycle: $ERR"
ok "a 2-node dependency cycle exits EXIT_CYCLE ($EXIT_CYCLE) and names the nodes"

# --- 7. exit 14: duplicate (goal, id) --------------------------------------
R="$(new_repo)"
plan "$R" 030-a.md <<'P'
---
id: 030
title: a
status: pending
blocked-by: []
goal: g
needs-review: none
---
P
plan "$R" 030-b.md <<'P'
---
id: 030
title: b
status: pending
blocked-by: []
goal: g
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_DUPLICATE_IDS" ] || fail "a duplicate (goal,id) must exit EXIT_DUPLICATE_IDS ($EXIT_DUPLICATE_IDS), got $RC"
printf '%s' "$ERR" | grep -q '030-a.md' || fail "the diagnostic must name both colliding files: $ERR"
printf '%s' "$ERR" | grep -q '030-b.md' || fail "the diagnostic must name both colliding files: $ERR"
ok "two plans sharing a (goal,id) exit EXIT_DUPLICATE_IDS ($EXIT_DUPLICATE_IDS) and name both files"

# Positive control: identity is (goal, id), so the same id under DIFFERENT
# goals is legal. Without this, case 7 would also pass if the picker rejected
# every repeated id outright.
R="$(new_repo)"
plan "$R" 030-a.md <<'P'
---
id: 030
title: a
status: pending
blocked-by: []
goal: g1
needs-review: none
---
P
plan "$R" 030-b.md <<'P'
---
id: 030
title: b
status: pending
blocked-by: []
goal: g2
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_PLAN_FOUND" ] || fail "the same id under different goals is NOT a duplicate, got $RC (stderr: $ERR)"
ok "the same id under two different goals is not a duplicate (identity is (goal,id))"

# --- 8. exit 15: --goal names a slug no plan declares -----------------------
R="$(new_repo)"
plan "$R" 040-a.md <<'P'
---
id: 040
title: a
status: pending
blocked-by: []
goal: known
needs-review: none
---
P
run_pick "$R" --goal nosuchgoal
[ "$RC" -eq "$EXIT_GOAL_NOT_FOUND" ] || fail "an undeclared goal must exit EXIT_GOAL_NOT_FOUND ($EXIT_GOAL_NOT_FOUND), got $RC"
printf '%s' "$ERR" | grep -q 'nosuchgoal' || fail "the diagnostic must name the goal: $ERR"
ok "--goal with a slug no plan declares exits EXIT_GOAL_NOT_FOUND ($EXIT_GOAL_NOT_FOUND)"

# --- 9. blocked-by parsing: bare, zero-padded, and cross-goal --------------
# A dep that silently fails to resolve does not error — it just makes the plan
# permanently unpickable, which reads exactly like "not ready yet".
R="$(new_repo)"
plan "$R" 001-done.md <<'P'
---
id: 1
title: done with an unpadded id
status: done
blocked-by: []
needs-review: none
---
P
plan "$R" 002-padded.md <<'P'
---
id: 002
title: depends on 001, zero-padded both ways
status: pending
blocked-by: [001]
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_PLAN_FOUND" ] || fail "a zero-padded dep must match an unpadded done id, got $RC (stderr: $ERR)"
[ "$OUT" = "$R/docs/plans/002-padded.md" ] || fail "expected 002 to be pickable, got '$OUT'"
ok "blocked-by [001] resolves against a done plan whose id: is 1 (zero-padding normalizes both sides)"

R="$(new_repo)"
plan "$R" 080-auth.md <<'P'
---
id: 080
title: auth dep, another goal
status: done
goal: auth
blocked-by: []
needs-review: none
---
P
plan "$R" 081-x.md <<'P'
---
id: 081
title: cross-goal dependent
status: pending
goal: main
blocked-by: [auth:080]
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_PLAN_FOUND" ] || fail "a satisfied cross-goal dep must not block, got $RC (stderr: $ERR)"
[ "$OUT" = "$R/docs/plans/081-x.md" ] || fail "expected 081 to be picked, got '$OUT'"
ok "blocked-by [auth:080] resolves cross-goal against a done plan in goal 'auth'"

# Negative half: the goal qualifier is load-bearing. An UNMET cross-goal dep
# must keep the plan blocked, or the case above passes for the wrong reason.
plan "$R" 082-y.md <<'P'
---
id: 082
title: unmet cross-goal dependent
status: pending
goal: main
blocked-by: [auth:999]
needs-review: none
---
P
run_pick "$R" 082
[ "$RC" -eq "$EXIT_ALL_BLOCKED" ] || fail "an unmet cross-goal dep must block, got $RC (stderr: $ERR)"
printf '%s' "$ERR" | grep -q 'auth|999' || fail "the diagnostic must name the unmet cross-goal dep: $ERR"
ok "an unmet cross-goal dep (auth:999) leaves the plan blocked (EXIT_ALL_BLOCKED)"

# --- 10. CHARACTERIZATION: a quoted dep token is silently unresolvable ------
# `blocked-by: ["001"]` — the quotes are never stripped, so the token becomes
# the literal `"001`, matches no done plan, and the plan is withheld forever
# with no diagnostic. Plan 055 makes this a loud die.
R="$(new_repo)"
plan "$R" 001-done.md <<'P'
---
id: 001
title: done
status: done
blocked-by: []
needs-review: none
---
P
plan "$R" 005-quoted.md <<'P'
---
id: 005
title: dep written with quotes
status: pending
blocked-by: ["001"]
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_ALL_DONE" ] \
  || fail "CHARACTERIZATION drift: a quoted dep token now exits $RC. If plan 055 landed, flip this case to expect a loud die naming 005-quoted.md."
printf '%s' "$ERR" | grep -q '005-quoted.md' \
  && fail "CHARACTERIZATION drift: the diagnostic now names the offending plan — plan 055 landed, flip this case"
ok "CHARACTERIZATION: blocked-by [\"001\"] withholds the plan and reports it as 'all plans done' (plan 055 must make this a loud die naming the plan)"

# --- 11. CHARACTERIZATION: a garbage dep token is silently unresolvable -----
R="$(new_repo)"
plan "$R" 010-garbage.md <<'P'
---
id: 010
title: garbage dep token
status: pending
blocked-by: [nonsense-token]
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_ALL_DONE" ] \
  || fail "CHARACTERIZATION drift: a garbage dep token now exits $RC — flip this case if plan 055 landed"
ok "CHARACTERIZATION: an unparseable dep token silently withholds the plan (plan 055 must make this a loud die)"

# --- 12. CHARACTERIZATION (SECURITY): blocked-by is passed through eval -----
# pick-next.sh builds its dependency table with `eval "DEPS_...=\"$_deps\""`.
# A `$(...)` token in a plan's blocked-by is therefore EXECUTED. The payload
# below writes a marker file into the fixture repo's working directory; today
# that file appears. This is the plan-055 finding, pinned as a live repro.
#
# When 055 removes the eval, this case flips to the assertion plan 057's design
# specifies: nonzero exit AND no side-effect file.
R="$(new_repo)"
# Unquoted heredoc: the payload is deliberately a shell substitution. It has no
# spaces, because parse_blocked_qualified word-splits the dep list.
cat > "$R/docs/plans/011-inject.md" <<PINJ
---
id: 011
title: injection payload in blocked-by
status: pending
blocked-by: [\$(id>PWNED)]
needs-review: none
---
PINJ
[ -e "$R/PWNED" ] && fail "fixture is dirty: PWNED existed before the run"
run_pick "$R"
if [ ! -e "$R/PWNED" ]; then
  fail "CHARACTERIZATION drift: the blocked-by eval no longer executes its payload (exit was $RC). If plan 055 landed, flip this case to assert a nonzero exit AND the ABSENCE of \$R/PWNED."
fi
ok "CHARACTERIZATION (security): a \$(...) token in blocked-by is executed by pick-next.sh's eval (plan 055 must eliminate this side effect)"

# --- 13. Priority: lower priority: beats lower id: -------------------------
R="$(new_repo)"
plan "$R" 100-low-id.md <<'P'
---
id: 100
title: lower id, no priority (defaults to id 100)
status: pending
blocked-by: []
needs-review: none
---
P
plan "$R" 200-high-id.md <<'P'
---
id: 200
title: higher id but explicit priority 1
status: pending
blocked-by: []
priority: 1
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_PLAN_FOUND" ] || fail "expected a pick, got $RC (stderr: $ERR)"
[ "$OUT" = "$R/docs/plans/200-high-id.md" ] \
  || fail "priority 1 must beat an id-defaulted 100, got '$OUT'"
ok "an explicit lower priority: beats a lower id:"

# Absent priority defaults to the id, so among two priority-less plans the
# lower id wins.
R="$(new_repo)"
plan "$R" 100-a.md <<'P'
---
id: 100
title: lower id
status: pending
blocked-by: []
needs-review: none
---
P
plan "$R" 200-b.md <<'P'
---
id: 200
title: higher id
status: pending
blocked-by: []
needs-review: none
---
P
run_pick "$R"
[ "$OUT" = "$R/docs/plans/100-a.md" ] || fail "absent priority must default to id (lower id wins), got '$OUT'"
ok "an absent priority: defaults to id:, so the lower id wins"

# --- 14. CHARACTERIZATION: a non-numeric priority mis-orders, does not die --
# `priority: high` makes `$((10#high))` blow up mid-comparison. errexit is
# suppressed inside the `if` condition, so the picker prints raw bash
# arithmetic noise, silently loses the comparison, and returns the WRONG plan
# with exit 0. Plan 055 turns this into a loud die naming the plan.
R="$(new_repo)"
plan "$R" 011-badpri.md <<'P'
---
id: 011
title: non-numeric priority
status: pending
blocked-by: []
priority: high
needs-review: none
---
P
plan "$R" 012-goodpri.md <<'P'
---
id: 012
title: should have won on priority 5
status: pending
blocked-by: []
priority: 5
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_PLAN_FOUND" ] \
  || fail "CHARACTERIZATION drift: a non-numeric priority now exits $RC. If plan 055 landed, flip this case to expect a loud die naming 011-badpri.md."
[ "$OUT" = "$R/docs/plans/011-badpri.md" ] \
  || fail "CHARACTERIZATION drift: the mis-ordered pick changed (got '$OUT') — re-derive this case against the new behavior"
printf '%s' "$ERR" | grep -q '011-badpri.md' \
  && fail "CHARACTERIZATION drift: the diagnostic now names the offending plan — plan 055 landed, flip this case"
ok "CHARACTERIZATION: priority: high mis-orders the pick and exits 0 without naming the plan (plan 055 must make this a loud die)"

# --- 15. Filters: needs-review gates a plan out ----------------------------
R="$(new_repo)"
plan "$R" 070-gated.md <<'P'
---
id: 070
title: awaiting eng review
status: pending
blocked-by: []
needs-review: eng
---
P
plan "$R" 071-open.md <<'P'
---
id: 071
title: reviewed
status: pending
blocked-by: []
needs-review: none
---
P
run_pick "$R"
[ "$OUT" = "$R/docs/plans/071-open.md" ] \
  || fail "a needs-review: eng plan must be skipped even though its id is lower, got '$OUT'"
ok "a plan with needs-review: eng is skipped in favour of a reviewed one"

# CHARACTERIZATION: the skip is completely silent today. Plan 054 adds a
# stderr note so an operator can tell "gated" from "absent".
[ -z "$ERR" ] \
  || fail "CHARACTERIZATION drift: the review skip now writes to stderr ('$ERR'). If plan 054 landed, flip this case to REQUIRE the skip note."
ok "CHARACTERIZATION: the review-gated skip is silent, no stderr note (plan 054 must add one)"

# --- 16. Filters: a numeric scope selects only in-scope plans --------------
R="$(new_repo)"
plan "$R" 060-a.md <<'P'
---
id: 060
title: a
status: pending
blocked-by: []
needs-review: none
---
P
plan "$R" 061-b.md <<'P'
---
id: 061
title: b
status: pending
blocked-by: []
needs-review: none
---
P
run_pick "$R" 061
[ "$OUT" = "$R/docs/plans/061-b.md" ] \
  || fail "a scope of 061 must select 061 even though 060 sorts first, got '$OUT'"
ok "a numeric scope filter selects only the in-scope plan"

run_pick "$R" 061,060
[ "$OUT" = "$R/docs/plans/060-a.md" ] || fail "a multi-id scope must still apply the ordering rules, got '$OUT'"
ok "a CSV scope keeps normal priority/id ordering within the scope"

run_pick "$R" 0061
[ "$OUT" = "$R/docs/plans/061-b.md" ] || fail "a zero-padded scope token must match, got '$OUT'"
ok "a zero-padded scope token (0061) matches plan 061"

# --- 17. Filters: --goal selects only the matching goal --------------------
R="$(new_repo)"
plan "$R" 040-known.md <<'P'
---
id: 040
title: in goal known
status: pending
blocked-by: []
goal: known
needs-review: none
---
P
plan "$R" 041-other.md <<'P'
---
id: 041
title: in goal other, and it would win on priority
status: pending
blocked-by: []
goal: other
priority: 1
needs-review: none
---
P
run_pick "$R" --goal known
[ "$OUT" = "$R/docs/plans/040-known.md" ] \
  || fail "--goal known must select 040 even though 041 has a better priority, got '$OUT'"
ok "--goal selects only plans declaring that goal, ignoring better-priority plans elsewhere"

# Control: without the filter the better priority wins, proving the case above
# was decided by the goal filter and not by ordering.
run_pick "$R"
[ "$OUT" = "$R/docs/plans/041-other.md" ] || fail "unfiltered, priority 1 should win, got '$OUT'"
ok "unfiltered, the same repo picks the priority-1 plan (the goal filter was what decided the previous case)"

# --- 18. plans-dir resolution: an empty docs/plans/ shadows plans/ ---------
# `[ -d docs/plans ] || PLANS_DIR=plans` tests for EXISTENCE, not content, so a
# leftover empty docs/plans/ hides a fully populated plans/ and the backlog
# reports itself done. Pinned as a repro. (Plan 056, which would have made the
# resolution content-aware, is `status: skipped`, so this is current-and-staying
# behavior until someone deliberately revisits it.)
R="$(new_repo)"
mkdir -p "$R/plans"
cat > "$R/plans/090-a.md" <<'P'
---
id: 090
title: in the legacy plans/ dir
status: pending
blocked-by: []
needs-review: none
---
P
run_pick "$R"
[ "$RC" -eq "$EXIT_ALL_DONE" ] \
  || fail "CHARACTERIZATION drift: empty docs/plans/ no longer shadows plans/ (exit $RC) — plan 056 was skipped, so this change was not planned; re-derive."
ok "CHARACTERIZATION: an empty docs/plans/ shadows a populated plans/ and reports EXIT_ALL_DONE (plan 056, skipped)"

# Control: with no docs/plans/ at all, the legacy plans/ dir IS used — so the
# case above is about the shadowing, not about plans/ being unsupported.
R="$(new_repo)"
rmdir "$R/docs/plans" "$R/docs"
mkdir -p "$R/plans"
cat > "$R/plans/090-a.md" <<'P'
---
id: 090
title: in the legacy plans/ dir
status: pending
blocked-by: []
needs-review: none
---
P
run_pick "$R"
[ "$OUT" = "$R/plans/090-a.md" ] || fail "with no docs/plans/, the legacy plans/ dir must be used, got '$OUT' (rc $RC)"
ok "with no docs/plans/ present, the legacy plans/ directory is used"

# --- 19. done plans in archive/ still satisfy dependencies -----------------
# Completed plans are archived out of docs/plans/; if the picker stopped seeing
# them, every dependent plan in the backlog would deadlock at once.
R="$(new_repo)"
mkdir -p "$R/docs/plans/archive"
cat > "$R/docs/plans/archive/001-archived.md" <<'P'
---
id: 001
title: archived and done
status: done
blocked-by: []
needs-review: none
---
P
plan "$R" 002-dependent.md <<'P'
---
id: 002
title: depends on the archived plan
status: pending
blocked-by: [001]
needs-review: none
---
P
run_pick "$R"
[ "$OUT" = "$R/docs/plans/002-dependent.md" ] \
  || fail "a dep satisfied by an ARCHIVED done plan must unblock, got '$OUT' (rc $RC, stderr: $ERR)"
ok "a done plan in docs/plans/archive/ satisfies a dependency"

echo "[pick-next-smoke] all $PASSED checks passed"
