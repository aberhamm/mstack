#!/usr/bin/env bash
# mstack result gate (plan 043). Deterministically validate the health fields of
# a subagent's ---MSTACK-RESULT--- block before the orchestrator completes a plan.
#
# Why this exists: the health gate once crashed, the worker had no branch for
# "the command exited nonzero / printed no VERDICT", and it improvised
# `HEALTH_VERDICT: SKIP` — not even a legal value. Step 7a trusted it and marked
# the plan done. Patching that with more prose aimed at the LLM is the same
# material that already failed, so the parent parses the block instead of
# trusting it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

# The ONLY health verdicts that may accompany a STATUS: pass result.
#
# - PASS           the gate ran, scored, and passed.
# - NONE-DECLARED  the gate ran and found zero tools in a repo that explicitly
#                  declares it has none (`- none:` under `## Health Stack` in
#                  tracked guidance). Completable by design — this is the D4
#                  escape hatch, and it is the only non-PASS verdict admitted.
#
# Everything else is rejected, explicitly including: FAIL and REGRESSED (both
# are routed to the worker's failure path, so pairing either with STATUS: pass
# is incoherent), NO-TOOLS (undeclared zero tools — fail closed), SKIP (never a
# legal value), and any missing/garbled verdict.
HEALTH_VERDICT_OK="PASS NONE-DECLARED"

# Read one field from the result block. Takes the FIRST occurrence: the contract
# emits STATUS / HEALTH_VERDICT / HEALTH_COMPOSITE as fixed field lines at the
# top of the block, so the first match is the real one and free-text further
# down cannot shadow it.
result_field() {
  local block="$1" key="$2" val
  val="$(printf '%s\n' "$block" | grep -E "^[[:space:]]*${key}:" | head -1 || true)"
  [ -n "$val" ] || return 1
  val="${val#*:}"
  # trim surrounding whitespace
  val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$val" ] || return 1
  printf '%s' "$val"
}

# assert-health-result [file]  (reads stdin when no file is given)
#
# Exit 0  => the block's health fields are coherent with its STATUS.
# Exit 30 => reject. The orchestrator must NOT complete the plan.
cmd_assert_health_result() {
  local src="${1:-}" raw block
  if [ -n "$src" ]; then
    [ -f "$src" ] || die "result-gate: no such file: $src"
    raw="$(cat "$src")"
  else
    raw="$(cat)"
  fi

  # Narrow to the result block when the delimiters are present; otherwise treat
  # the whole input as the block (an agent may hand us just the fields).
  if printf '%s\n' "$raw" | grep -q -- '---MSTACK-RESULT---'; then
    block="$(printf '%s\n' "$raw" | sed -n '/---MSTACK-RESULT---/,/---END---/p')"
  else
    block="$raw"
  fi

  # Cut the block at SUMMARY:, the first free-text field. Every field this gate
  # reads is defined to appear above it, so the agent's own prose — which may
  # legitimately quote "HEALTH_VERDICT: PASS" while describing what it did —
  # can never be mistaken for the machine fields.
  block="$(printf '%s\n' "$block" | awk '/^[[:space:]]*SUMMARY:/ { exit } { print }')"

  local status
  if ! status="$(result_field "$block" STATUS)"; then
    echo "reject: result block has no STATUS field" >&2
    exit "$EXIT_RESULT_HEALTH_INVALID"
  fi

  # Only a claimed success asserts anything about health. fail/blocked results
  # are handled by Step 7b/3b and are not required to carry health fields.
  case "$status" in
    pass) ;;
    fail | blocked) exit 0 ;;
    *)
      echo "reject: unparseable STATUS '$status' (expected pass|fail|blocked)" >&2
      exit "$EXIT_RESULT_HEALTH_INVALID"
      ;;
  esac

  local verdict
  if ! verdict="$(result_field "$block" HEALTH_VERDICT)"; then
    echo "reject: STATUS: pass with no HEALTH_VERDICT field" >&2
    echo "hint: a crashed health gate is a hard failure, never a skip" >&2
    exit "$EXIT_RESULT_HEALTH_INVALID"
  fi

  local ok=false v
  for v in $HEALTH_VERDICT_OK; do
    [ "$verdict" = "$v" ] && ok=true
  done
  if [ "$ok" != true ]; then
    echo "reject: STATUS: pass with HEALTH_VERDICT '$verdict' (accepted: ${HEALTH_VERDICT_OK// /, })" >&2
    echo "hint: FAIL/REGRESSED route to the failure path; SKIP is not a legal value;" >&2
    echo "      NO-TOOLS means the health gate found nothing and the repo never declared it has none" >&2
    exit "$EXIT_RESULT_HEALTH_INVALID"
  fi

  local composite
  if ! composite="$(result_field "$block" HEALTH_COMPOSITE)"; then
    echo "reject: STATUS: pass with no HEALTH_COMPOSITE field" >&2
    exit "$EXIT_RESULT_HEALTH_INVALID"
  fi

  # PASS must carry a real score. NONE-DECLARED has nothing to score, and
  # health-check.sh emits the literal `n/a` for it — the only non-numeric
  # composite accepted anywhere, and only alongside NONE-DECLARED.
  if [ "$verdict" = "NONE-DECLARED" ] && [ "$composite" = "n/a" ]; then
    exit 0
  fi
  if ! printf '%s' "$composite" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
    echo "reject: HEALTH_COMPOSITE '$composite' is not a number" >&2
    exit "$EXIT_RESULT_HEALTH_INVALID"
  fi

  exit 0
}

case "${1:-}" in
  assert-health-result) shift; cmd_assert_health_result "${1:-}" ;;
  *) die "usage: result-gate.sh assert-health-result [result-block-file]" ;;
esac
