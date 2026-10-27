#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # sourced: vars are used by the suites; samples are literal
# Shared throwaway-repo builder for waiver-smoke.sh and result-gate-smoke.sh
# (plan 099). Source it; do not execute it. Every repo it builds lives under a
# caller-supplied temp dir and runs no hooks except the one the caller installs.
#
# Fixture health stack (declared in the fixture's tracked AGENTS.md): each
# category prints a recorded sample file from out/ and fails when it is
# non-empty, so a category's failures are whatever the test writes there.

# wf_plus_days <YYYY-MM-DD> <n>
wf_plus_days() {
  local e
  if e="$(date -u -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s 2>/dev/null)"; then
    date -u -j -f %s "$((e + $2 * 86400))" +%Y-%m-%d
  else
    date -u -d "$1 + $2 days" +%Y-%m-%d
  fi
}

WF_TODAY="$(date -u +%Y-%m-%d)"
WF_EXPIRES="$(wf_plus_days "$WF_TODAY" 10)"

# Recorded shellcheck sample (default format): two findings in dev.sh.
WF_SC_BASE='
In dev.sh line 3:
echo $FOO
     ^--^ SC2086 (info): Double quote to prevent globbing and word splitting.

In dev.sh line 7:
cd $DIR
^-----^ SC2164 (warning): Use cd ... || exit in case cd fails.
   ^--^ SC2086 (info): Double quote to prevent globbing and word splitting.

For more information:
  https://www.shellcheck.net/wiki/SC2164 -- Use cd ... || exit in case cd fails.
  https://www.shellcheck.net/wiki/SC2086 -- Double quote to prevent globbing ...'

# Recorded tsc sample, both output forms.
WF_TSC_BASE='src/a.ts(3,5): error TS2322: Type string is not assignable to type number.
src/b.ts:10:1 - error TS2304: Cannot find name foo.'

# wf_repo <dir> [hooks-dir]: init a fixture repo at <dir>. With a hooks dir,
# core.hooksPath points at it; otherwise at an empty dir, so the operator's
# global hooks never run inside fixtures.
wf_repo() {
  local d="$1" hooks="${2:-}"
  mkdir -p "$d/docs/plans/waivers" "$d/out"
  (
    cd "$d" || exit 1
    git init -q
    git config user.email waiver@example.com
    git config user.name waiver-smoke
    if [ -n "$hooks" ]; then
      git config core.hooksPath "$hooks"
    else
      mkdir -p .nohooks
      git config core.hooksPath "$d/.nohooks"
    fi
    printf '.mstack/\n.nohooks/\n' > .gitignore
    cat > AGENTS.md <<'AGENTS'
# Fixture

## Health Stack

- typecheck: cat out/tsc.txt; test ! -s out/tsc.txt
- lint: cat out/lint.txt; test ! -s out/lint.txt
- shell: cat out/sc.txt; test ! -s out/sc.txt
AGENTS
    : > out/tsc.txt
    : > out/lint.txt
    : > out/sc.txt
    printf '# approvers\nmatthew  # the owner\n' > docs/plans/waivers/APPROVERS
    cat > docs/plans/001-fixture.md <<'PLAN'
---
id: 001
title: Fixture plan
status: pending
needs-review: none
review-required: none
---

## Requirements

Fixture.
PLAN
    git add -A
    git commit -q -m "init"
  )
}

# wf_set_status <dir> <status> : rewrite the plan's status line (no commit).
wf_set_status() {
  local f="$1/docs/plans/001-fixture.md" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/wf-status-XXXXXX")"
  sed "s/^status: .*/status: $2/" "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

wf_commit() {  # <dir> <msg>
  ( cd "$1" && git add -A && git commit -q -m "$2" )
}

# wf_valid <dir> <waiver.sh> [hooks-dir]: a repo whose plan carries a valid
# baseline-delta shell waiver and a valid blanket lint waiver, committed before
# the claim. Sequence: init -> baseline commit -> waiver commit -> claim.
wf_valid() {
  local d="$1" ws="$2"
  wf_repo "$d" "${3:-}"
  printf '%s\n' "$WF_SC_BASE" > "$d/out/sc.txt"
  printf 'src/x.ts: warning no-unused-vars\n' > "$d/out/lint.txt"
  wf_commit "$d" "pre-existing failures"
  ( cd "$d" && bash "$ws" capture-baseline 001 shell >/dev/null 2>&1 ) || return 1
  wf_commit "$d" "baseline"
  ( cd "$d" \
    && bash "$ws" waive 001 shell baseline-delta matthew "$WF_EXPIRES" mdec-1 dev.sh_pre-existing >/dev/null 2>&1 \
    && bash "$ws" waive 001 lint blanket matthew "$WF_EXPIRES" mdec-1 pre-existing no-lint-extractor >/dev/null 2>&1 ) || return 1
  wf_commit "$d" "waive"
  wf_set_status "$d" in-progress
  wf_commit "$d" "chore(plan 001): claim, in progress"
}

# wf_add_line <dir> <payload>: hand-write a waivers: entry (bypasses waive's
# validation, so tests can commit malformed or out-of-order entries).
wf_add_line() {
  local f="$1/docs/plans/001-fixture.md" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/wf-line-XXXXXX")"
  awk -v entry="  - $2" '
    /^---[[:space:]]*$/ {
      fm++
      if (fm == 2 && !done) { if (!inw) print "waivers:"; print entry; done = 1 }
      print; next
    }
    fm == 1 && inw && !done && $0 !~ /^[[:space:]]+-[[:space:]]/ { print entry; done = 1; inw = 0 }
    fm == 1 && /^waivers:/ { inw = 1 }
    { print }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

# wf_hooks <dir> <review-gate.sh>: a hooks dir whose pre-commit is the real
# review-gate.sh hook-pre-commit barrier.
wf_hooks() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\nexec bash %q hook-pre-commit "$@"\n' "$2" > "$1/pre-commit"
  chmod +x "$1/pre-commit"
}
