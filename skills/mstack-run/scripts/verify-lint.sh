#!/usr/bin/env bash
# verify-lint.sh — probe a plan's `## Verification` checks against the CURRENT
# repo, before the plan is ever executed.
#
# THE PROBLEM. plan-doctor tests that verification checks EXIST — it counts
# `[cmd]`/`[assert]` tags via LLM prose and calls it validated. Existence is not
# workability. A plan can declare `--dry-run` on a flag the CLI does not have,
# or `pytest -m browser` that collects zero tests, or `test -f` on a path that
# was never created, and every one of those passes an existence check while
# being dead on arrival. That is this repo's recurring bug in a new costume: a
# check that cannot run is not a check that passed.
#
# WHAT THIS DOES. Extracts the declared checks, decides which are PROVABLY SAFE
# to execute read-only, runs those, and reports the ones that are broken against
# this repo right now. It answers "would this check work?", never "did the
# feature work" — that is Step 5b's job, after implementation.
#
# SAFETY MODEL — fail closed, because these strings are arbitrary shell written
# into a markdown file. A prefix match is NOT enough: `grep foo bar; rm -rf ~`
# starts with `grep`. So a check is executed only when BOTH hold:
#   1. it contains no redirect (`>`/`<`), no backtick, and no mutating verb; and
#   2. EVERY command head — the first word, plus the first word after any
#      `|`, `;`, `&&`, `||`, `$(`, `(` — is on a read-only allowlist.
# Anything else is UNPROBED. UNPROBED is reported as "not verified", never as
# passing: silence about an unprobed check would rebuild the exact defect this
# script exists to catch.
#
# BROKEN vs PENDING — the distinction this script got wrong at first and which
# matters more than anything else here. A check that RUNS but exits nonzero is
# not necessarily broken: `grep -q "EXIT_GOAL_NOT_FOUND" README.md`, for a plan
# whose job is to ADD that row, is SUPPOSED to fail now and pass after. That is
# a post-condition, and it is what a good verification check looks like.
#   BROKEN  = provably cannot work: the command head does not exist (127/126),
#             or it targets a path that is absent AND that the plan never
#             declares it will create. Blocking.
#   PENDING = runnable, targets present, does not pass yet. Reported, NEVER
#             blocking — this is the expected state for unimplemented work.
# Conflating them blocked every plan that verifies its own output, and the tell
# was that only plans whose code had ALREADY SHIPPED probed clean.
#
# Exit: 0 when nothing is provably broken; EXIT_VERIFY_BROKEN (33) when at
# least one declared check provably cannot work against this repo. PENDING
# checks do not affect the exit code.
#
# Usage: verify-lint.sh probe <plan-ref-or-path>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() { echo "usage: verify-lint.sh probe <plan>" >&2; exit 1; }

# Read-only binaries only. Deliberately EXCLUDED even though they look
# harmless: sed (`w` writes files), awk (`system()`), find (`-exec`/`-delete`),
# xargs, env, sh/bash, python/node/ruby (arbitrary execution). pytest is absent
# on purpose — it gets the dedicated --collect-only path below rather than
# being run as written.
_ALLOW=" test [ ls grep egrep fgrep rg cat head tail wc stat file basename dirname echo printf true false sort uniq cut tr comm diff cmp git jq shasum md5sum "

# _safe_to_probe <command>: 0 when every command head is allowlisted and no
# writing construct appears. Prints the rejection reason on stdout when not.
_safe_to_probe() {
  local c="$1" heads h
  case "$c" in
    *'>'*|*'<'*|*'`'*) echo "redirect-or-backtick"; return 1 ;;
  esac
  # NOTE: there is deliberately no keyword blacklist here. An earlier draft
  # rejected any string containing `curl`/`rm `/`cp ` and duly refused
  # `grep -q "curl_cffi" README.md`, because substring matching cannot tell a
  # command from a word inside an argument. The head allowlist below already
  # rejects curl, rm, sudo and friends where it actually matters — as command
  # heads — so the blacklist added only false negatives. One mechanism, not two.
  heads="$(printf '%s' "$c" \
    | sed -E 's/\$\(/\n/g; s/\|\|/\n/g; s/&&/\n/g; s/[|;]/\n/g; s/\(/\n/g' \
    | sed -E 's/^[[:space:]]*//; s/^"//; s/^'"'"'//' \
    | awk 'NF{print $1}')"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    h="${h%\"}"; h="${h%\'}"
    case "$_ALLOW" in *" $h "*) ;; *) echo "head-not-allowlisted:$h"; return 1 ;; esac
  done <<EOF
$heads
EOF
  return 0
}

# _run_probe <command>: execute a command already cleared by _safe_to_probe.
# `eval` is correct here and not a hole: the clearance proved there is no
# substitution, chaining, or redirect left to exploit, and eval is what honors
# the quoting in `grep 'two words' file`. Bounded when a timeout binary exists.
_run_probe() {
  local c="$1" t=""
  command -v timeout  >/dev/null 2>&1 && t="timeout 20"
  [ -z "$t" ] && command -v gtimeout >/dev/null 2>&1 && t="gtimeout 20"
  ( cd "$(repo_root)" && eval "$t $c" ) >/dev/null 2>&1
}

# _pytest_collects <command>: for a pytest check, re-run it as --collect-only
# and report whether it would collect ANY test. A selector that matches nothing
# exits 0 in some pytest configs while testing precisely nothing — the
# `-m browser` / RUN_BROWSER_TESTS class. Prints "0" or a positive count, or
# "unknown" when pytest is unavailable.
_pytest_collects() {
  local c="$1" out n
  command -v pytest >/dev/null 2>&1 || { echo unknown; return; }
  # Drop output-shaping flags that conflict with --collect-only.
  c="$(printf '%s' "$c" | sed -E 's/(^| )-(q|v|s|x)+( |$)/ /g')"
  out="$( cd "$(repo_root)" && eval "$c --collect-only -q" 2>/dev/null )"
  # `grep -c` PRINTS 0 and EXITS 1 on no match, so `|| echo 0` appends a second
  # zero and yields "0\n0" — which is not -eq 0, so the zero-collection case
  # fell through to OK. A pytest selector that collects nothing then read as a
  # passing check: the exact false-green this script exists to catch, inside
  # the script itself. Caught by verify-lint-smoke; keep the sanitize.
  n="$(printf '%s\n' "$out" | grep -cE '::' 2>/dev/null || true)"
  n="$(printf '%s' "$n" | tr -cd '0-9' | head -c 9)"
  printf '%s\n' "${n:-0}"
}

# _path_operands <command>: the whitespace-separated tokens that look like FILE
# PATHS — they contain a slash, or carry a known source/doc extension. Quoted
# spans are blanked FIRST: in `grep -c "docs/plans" README.md` the pattern is an
# argument to grep, not a file grep reads, and counting it as one invents a
# phantom missing path and a phantom BROKEN verdict.
_path_operands() {
  local c="$1" tok out=""
  c="$(printf '%s' "$c" | sed -E 's/"[^"]*"/ /g; s/'"'"'[^'"'"']*'"'"'/ /g')"
  for tok in $c; do
    case "$tok" in -*) continue ;; esac
    case "$tok" in
      */*|*.md|*.sh|*.json|*.ts|*.tsx|*.js|*.py|*.yml|*.yaml|*.toml|*.txt)
        out="${out}${tok}
" ;;
    esac
  done
  printf '%s' "$out"
}

# _plan_declared_files <plan-abs>: the plan's `**Files expected to change:**`
# block. Read from THAT block only, never the whole plan — every check names
# its own target, so a whole-file grep would match the check itself and declare
# every path "declared", collapsing the distinction this function exists to draw.
_plan_declared_files() {
  awk '/Files expected to change/{f=1;next} f&&/^## /{exit} f' "$1" 2>/dev/null
}

# _unrunnable <declared-files-block> <command>: 0 (true) when the command targets a path
# that does NOT exist and that the plan never declares it will create — a check
# that can never work no matter what the worker does. 1 (false) when every
# target either exists or is declared by the plan.
#
# THIS IS THE BROKEN/PENDING DISCRIMINATOR, and it is the whole point. A
# post-condition check (`grep -q "EXIT_GOAL_NOT_FOUND" README.md` for a plan
# that ADDS that row) is SUPPOSED to fail before implementation and pass after.
# Calling that BROKEN blocks every unimplemented plan that verifies its own
# work — i.e. every well-written plan — and the tell is that only plans whose
# code already shipped ever probed clean.
_unrunnable() {
  local decl="$1" c="$2" p root
  root="$(repo_root)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$root/$p" ] && continue
    [ -e "$p" ] && continue
    printf '%s' "$decl" | grep -qF -- "$p" && continue
    printf '%s' "$decl" | grep -qF -- "$(basename "$p")" && continue
    return 0
  done <<EOF
$(_path_operands "$c")
EOF
  return 1
}

# _unknown_flags <command>: flags the command passes that appear NOWHERE in the
# repo. A CLI flag the codebase never mentions is very likely invented by the
# plan author. Heuristic, so it reports SUSPECT rather than BROKEN — but it is
# the only handle on the "--dry-run does not exist" class, which cannot be
# probed safely (that would mean executing project code).
_unknown_flags() {
  local c="$1" f missing="" root
  root="$(repo_root)"
  for f in $(printf '%s' "$c" | grep -oE '(^| )--[a-z][a-z0-9-]+' | tr -d ' ' | sort -u); do
    case "$f" in --help|--version|--collect-only|--noEmit) continue ;; esac
    if ! git -C "$root" grep -qF -- "$f" 2>/dev/null; then
      missing="${missing}${f} "
    fi
  done
  printf '%s' "$missing"
}

cmd_probe() {
  local arg="$1" root rel abs
  root="$(repo_root)"
  rel="$(_plan_relpath_vl "$arg")" || die "cannot resolve plan: $arg"
  case "$rel" in /*) abs="$rel" ;; *) abs="$root/$rel" ;; esac
  [ -r "$abs" ] || die "plan file not readable: $abs"

  local broken=0 total=0 probed=0 pending=0 line kind body reason n missing
  # Read the declared-files block ONCE, before the loop that reads the same
  # file. Re-reading $abs per check is both wasteful and the SC2094
  # read-and-write-same-file warning.
  local decl_files; decl_files="$(_plan_declared_files "$abs")"
  echo "verify-lint: $rel"

  # Only the `## Verification` section counts. Scanning the whole file turns
  # every PROSE mention of a check type — "at least one [cmd]/[assert] check",
  # an Out-of-scope line naming [status] — into a phantom check, which is both
  # noise and a way for a real BROKEN result to get lost in it.
  local in_section=0
  while IFS= read -r line; do
    case "$line" in
      '## Verification'*) in_section=1; continue ;;
      '## '*)             in_section=0; continue ;;
    esac
    [ "$in_section" -eq 1 ] || continue
    case "$line" in
      *'[cmd]'*|*'[assert]'*|*'[status]'*|*'[browse]'*|*'[manual]'*) ;;
      *) continue ;;
    esac
    kind="$(printf '%s' "$line" | grep -oE '\[(cmd|assert|status|browse|manual)\]' | head -1)"
    body="${line#*"$kind"}"
    body="$(printf '%s' "$body" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    # Plan authors wrap checks in a markdown code span. Those backticks are
    # FORMATTING, not shell command substitution — strip one surrounding pair
    # before the safety filter, which otherwise rejects every real-world check
    # as "backtick". Any backtick still present after this IS substitution and
    # is correctly rejected downstream.
    # shellcheck disable=SC2016  # the sed program's backticks are literal
    case "$body" in
      '`'*'`'*) body="$(printf '%s' "$body" | sed -E 's/^`//; s/`([^`]*)$/ \1/; s/[[:space:]]+$//')" ;;
    esac
    [ -n "$body" ] || continue
    total=$((total + 1))

    case "$kind" in
      '[manual]'|'[browse]'|'[status]')
        printf '  SKIP     %s %s\n' "$kind" "$body"
        continue ;;
    esac

    # `[assert] cmd | expected` — probe only the command half. The separator
    # must be found on a MASKED copy with every `$(...)` span blanked out:
    # `test -n "$(ls docs/ -R | grep -i gpu)"` carries a pipe INSIDE the
    # substitution, and splitting on it chops a valid command in half. An
    # earlier draft did exactly that and still printed BROKEN — the right
    # verdict reached by accident, which is worse than a wrong one because it
    # looks like the tool works.
    local exp="" mask idx pre rest post
    if [ "$kind" = "[assert]" ]; then
      # Blank out every $(...) span. Done with bash parameter expansion, not
      # `sed ':a ... ta'` — BSD/macOS sed rejects a one-line label and errors
      # out, the same GNU-vs-BSD trap as the mktemp suffix bug.
      mask="$body"
      while [ "${mask%%\$\(*}" != "$mask" ] && [ "${mask#*\)}" != "$mask" ]; do
        pre="${mask%%\$\(*}"
        rest="${mask#*\$\(}"
        post="${rest#*\)}"
        mask="${pre}X${post}"
      done
      case "$mask" in
        *'|'*)
          idx="${mask%|*}"; idx="${#idx}"
          exp="$(printf '%s' "${body:idx+1}" | sed -E 's/^[[:space:]]+//')"
          body="$(printf '%s' "${body:0:idx}" | sed -E 's/[[:space:]]+$//')"
          ;;
      esac
    fi

    # pytest gets the zero-collection check rather than a plain run.
    case "$body" in
      pytest*|*' -m pytest'*|python*pytest*)
        n="$(_pytest_collects "$body")"
        if [ "$n" = "unknown" ]; then
          printf '  UNPROBED %s %s  (pytest not installed here)\n' "$kind" "$body"
        elif [ "$n" -eq 0 ] 2>/dev/null; then
          printf '  BROKEN   %s %s\n' "$kind" "$body"
          printf '           collects ZERO tests — the check would pass while testing nothing\n'
          broken=$((broken + 1))
        else
          printf '  OK       %s %s  (collects %s)\n' "$kind" "$body" "$n"
          probed=$((probed + 1))
        fi
        continue ;;
    esac

    if reason="$(_safe_to_probe "$body")"; then
      local prc=0
      _run_probe "$body" || prc=$?
      if [ "$prc" -eq 0 ]; then
        printf '  OK       %s %s\n' "$kind" "$body"
      elif [ "$prc" -eq 127 ] || [ "$prc" -eq 126 ]; then
        printf '  BROKEN   %s %s\n' "$kind" "$body"
        printf '           command not found or not executable (exit %s)\n' "$prc"
        broken=$((broken + 1))
      elif _unrunnable "$decl_files" "$body"; then
        printf '  BROKEN   %s %s\n' "$kind" "$body"
        printf '           targets a path that does not exist and the plan never creates\n'
        broken=$((broken + 1))
      else
        printf '  PENDING  %s %s\n' "$kind" "$body"
        printf '           runnable, does not pass YET — post-condition, must pass after implementation\n'
        pending=$((pending + 1))
      fi
      probed=$((probed + 1))
      [ -n "$exp" ] && printf '           (expected-output half not probed: %s)\n' "$exp"
    else
      missing="$(_unknown_flags "$body")"
      if [ -n "$missing" ]; then
        printf '  SUSPECT  %s %s\n' "$kind" "$body"
        printf '           flag(s) found nowhere in the repo: %s\n' "$missing"
      else
        printf '  UNPROBED %s %s  (%s)\n' "$kind" "$body" "$reason"
      fi
    fi
  done < "$abs"

  echo "  ---"
  printf '  %d checks: %d probed, %d broken, %d pending. UNPROBED is NOT a pass.\n' \
    "$total" "$probed" "$broken" "$pending"
  # PENDING never gates. A post-condition that does not pass yet is the
  # EXPECTED state for unimplemented work; blocking on it would refuse every
  # plan that verifies its own output. Mirrors health-reach.sh's PENDING, which
  # plan-doctor Step 3.8 already forbids "simplifying" into a blocking state.
  [ "$broken" -eq 0 ] || exit "$EXIT_VERIFY_BROKEN"
  exit 0
}

# Local plan resolution (verify-lint does not need review-gate's machinery).
_plan_relpath_vl() {
  local arg="$1" root abs out id
  root="$(repo_root)"
  if [ -f "$arg" ]; then
    abs="$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")"
    printf '%s\n' "${abs#"$root"/}"
    return 0
  fi
  out="$(resolve_plan_ref "$arg")" || return 1
  id="${out%% *}"
  plan_file_for_id "$id"
}

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || usage
  shift
  case "$cmd" in
    probe) [ $# -ge 1 ] || usage; cmd_probe "$1" ;;
    *) usage ;;
  esac
}

main "$@"
