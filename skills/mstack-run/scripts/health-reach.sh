#!/usr/bin/env bash
# health-reach.sh — does the configured health-gate command actually EXECUTE the
# test files a plan declares it adds?
#
# THE DEFECT. Observed live: a repo's `.mstack/config.json` test command carried
# a `-k` filter that excluded `test_curl_cffi_impersonation_guard.py` entirely.
# The gate ran. It reported green. It covered none of the new code. Every
# per-plan validator passed, because none of them asks this question.
#
# Plan 043 established that a health gate which did not run is not a health gate
# that passed, and fixed the zero-tools case. This is the subtler sibling: tools
# ARE detected, the command DOES run, and its selector silently excludes the code
# under test. Same doctrine, one level down — a gate that runs over the wrong
# files is not a gate that passed.
#
# FOUR STATES, and the calibration between them is the whole design:
#   REACHABLE   file exists and the configured command collects it.
#   UNREACHABLE file exists and the command does NOT collect it. PROVEN defect,
#               blocking, exit EXIT_HEALTH_UNREACHABLE (34).
#   PENDING     file does not exist yet, so reachability cannot be assessed.
#               Reported, NOT blocking.
#   UNKNOWN     runner not recognized, or collection failed. Reported as NOT
#               VERIFIED, never as covered. NOT blocking.
#
# Why PENDING and UNKNOWN do not block, stated so it is not "simplified" later:
# blocking PENDING would fail every plan before implementation (a plan declares
# tests it has not written yet — that is what a plan IS), and blocking UNKNOWN
# would fail every non-pytest repo. Yesterday's verify-lint shipped with exactly
# that over-block and would have flagged all six new plans as broken. A check
# that cries wolf gets bypassed, and a bypassed check covers nothing — which is
# the very failure this file exists to prevent. Only a PROVEN exclusion blocks.
#
# Usage: health-reach.sh reach <plan-ref-or-path>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() { echo "usage: health-reach.sh reach <plan>" >&2; exit 1; }

# _declared_test_files <plan-file>: print repo-relative test-shaped paths from
# the plan's `**Files expected to change:**` block. Only backticked paths count,
# so prose mentioning a filename is not mistaken for a declaration.
_declared_test_files() {
  awk '
    /^\*\*Files expected to change:\*\*/ { in_block=1; next }
    in_block && /^\*\*/ { in_block=0 }
    in_block && /^## /  { in_block=0 }
    in_block {
      # `- `path/to/file`: description`  -> path/to/file
      if (match($0, /`[^`]+`/)) {
        p = substr($0, RSTART+1, RLENGTH-2)
        print p
      }
    }
  ' "$1" | while IFS= read -r p; do
    case "$p" in
      */test_*.py|test_*.py|*_test.py|*_test.go|*.test.ts|*.test.tsx|*.test.js|*_spec.rb|*_spec.js)
        printf '%s\n' "$p" ;;
      tests/*|test/*|spec/*)
        # A path under a test dir counts only if it looks like a test module.
        case "$p" in *.py|*.go|*.ts|*.tsx|*.js|*.rb) printf '%s\n' "$p" ;; esac ;;
    esac
  done
}

# _configured_test_cmd: the command the health gate would actually run for the
# `test` category — config first (the authoritative override), then the
# detector, mirroring health-check.sh's own precedence.
_configured_test_cmd() {
  local cmd
  cmd="$(bash "$SCRIPT_DIR/config.sh" get health.commands.test 2>/dev/null || true)"
  if [ -z "$cmd" ] && [ -x "$SCRIPT_DIR/health-check.sh" ]; then
    cmd="$(bash "$SCRIPT_DIR/health-check.sh" detect 2>/dev/null \
           | awk -F: '$1=="test"{sub(/^test:/,""); print; exit}')"
  fi
  printf '%s' "$cmd"
}

# _collect <command>: print the set of test files the command would execute, one
# per line, or nothing plus a nonzero return when the runner is unsupported.
# Deliberately NO fake support: an unrecognized runner returns UNKNOWN rather
# than a guess, because a wrong "REACHABLE" is worse than an admitted unknown.
_collect() {
  local cmd="$1" collect_cmd root out
  root="$(repo_root)"
  case "$cmd" in
    *pytest*)
      # A project may already set `addopts = -q` in pytest.ini, and the health
      # command itself often contains `-q`. Two quiet flags collapse
      # collect-only output to per-file counts, so the parser below sees no node
      # ids and falsely reports every existing test as unreachable. Remove only
      # standalone quiet flags from the configured command, override config
      # addopts, then request one quiet level explicitly.
      collect_cmd="$(printf '%s' "$cmd" | sed -E 's/(^|[[:space:]])(-q|--quiet)([[:space:]]|$)/ /g')"
      out="$( cd "$root" && eval "$collect_cmd --collect-only -o addopts='' -q" 2>/dev/null )" || true
      # ids look like `tests/test_x.py::test_x`; reduce to the file part.
      printf '%s\n' "$out" | awk -F'::' '/::/ {print $1}' | sort -u
      return 0 ;;
    *jest*)
      out="$( cd "$root" && eval "$cmd --listTests" 2>/dev/null )" || true
      printf '%s\n' "$out" | sed -E "s|^$root/||" | awk 'NF' | sort -u
      return 0 ;;
  esac
  return 1
}

cmd_reach() {
  local arg="$1" root rel abs cmd files collected f unreachable=0 pending=0 any=0
  root="$(repo_root)"
  if [ -f "$arg" ]; then
    abs="$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")"
    rel="${abs#"$root"/}"
  else
    local out id
    out="$(resolve_plan_ref "$arg")" || die "cannot resolve plan: $arg"
    id="${out%% *}"
    rel="$(plan_file_for_id "$id")" || die "cannot locate plan file for $arg"
    abs="$root/$rel"
  fi
  [ -r "$abs" ] || die "plan file not readable: $abs"

  echo "health-reach: $rel"

  files="$(_declared_test_files "$abs")"
  if [ -z "$files" ]; then
    echo "  no test files declared in 'Files expected to change' — nothing to assess"
    exit 0
  fi

  cmd="$(_configured_test_cmd)"
  if [ -z "$cmd" ]; then
    echo "  UNKNOWN  no test command configured or detected — reachability NOT VERIFIED"
    echo "  ---"
    echo "  Declare health.commands.test in .mstack/config.json to make this assessable."
    exit 0
  fi
  echo "  gate command: $cmd"

  if ! collected="$(_collect "$cmd")"; then
    echo "  UNKNOWN  runner not recognized (supported: pytest, jest)"
    echo "           reachability NOT VERIFIED for the declared test files:"
    while IFS= read -r f; do [ -n "$f" ] && echo "             $f"; done <<EOF
$files
EOF
    echo "  ---"
    echo "  Not verified is not covered. Add runner support or verify by hand."
    exit 0
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    any=1
    if [ ! -e "$root/$f" ]; then
      printf '  PENDING  %s\n' "$f"
      printf '           not created yet — reachability re-checked after implementation\n'
      pending=$((pending + 1))
      continue
    fi
    # Do not pipe a large collected set into `grep -q` under `pipefail`:
    # grep exits as soon as it finds an early match, the producer receives
    # SIGPIPE, and the pipeline is falsely treated as a non-match. Here-string
    # input keeps the exact-line check local and makes a collected test reachable.
    if grep -qxF -- "$f" <<< "$collected"; then
      printf '  REACHABLE %s\n' "$f"
    else
      printf '  UNREACHABLE %s\n' "$f"
      printf '           EXISTS but the gate command does not collect it — the gate\n'
      printf '           would report green over code it never executes.\n'
      printf '           excluding command: %s\n' "$cmd"
      unreachable=$((unreachable + 1))
    fi
  done <<EOF
$files
EOF

  echo "  ---"
  printf '  %d declared test file(s): %d unreachable, %d pending.\n' \
    "$( printf '%s\n' "$files" | awk 'NF' | wc -l | tr -d ' ' )" "$unreachable" "$pending"
  [ "$any" -eq 1 ] || exit 0
  [ "$unreachable" -eq 0 ] || exit "$EXIT_HEALTH_UNREACHABLE"
  exit 0
}

main() {
  local c="${1:-}"
  [ -n "$c" ] || usage
  shift
  case "$c" in
    reach) [ $# -ge 1 ] || usage; cmd_reach "$1" ;;
    *) usage ;;
  esac
}

main "$@"
