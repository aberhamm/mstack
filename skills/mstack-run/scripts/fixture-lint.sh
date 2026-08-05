#!/usr/bin/env bash
# fixture-lint.sh — a pane-dependent plan must attach a real capture
# (Rule 3, plan 089).
#
# THE PROBLEM. A plan whose logic keys on terminal screen content ("when the
# pane shows X, do Y") is writing a parser against an undocumented, unversioned
# external interface. Nobody writes a parser for a third-party API from memory —
# they save a real response and code against it. The capture is that saved
# response, and the cctrl track record is unambiguous: every shipped detector bug
# there (ASCII `>` vs the real prompt glyph, an "Allow command" string matching
# no real modal, the 2026-08-05 picker premise) lived in the gap between what an
# author REMEMBERED a screen saying and what it actually says.
#
# WHAT THIS DOES. Emits exactly ONE verdict line per plan:
#
#   NOT-APPLICABLE   no pane-mechanism keyword (the STRONG tier below), or a
#                    declared `tui-fixture: n/a` exemption with a stated reason.
#                    Exit 0.
#   FIXTURE-OK       a declared capture exists and carries provenance. Exit 0.
#   FIXTURE-UNDATED  a declared capture exists but its `.meta` sidecar is
#                    missing or incomplete. REPORTED, never blocking. Exit 0.
#   FIXTURE-MISSING  pane-dependent with no capture declared, or with one
#                    declared that is not in the working tree. BLOCKING,
#                    exit EXIT_TUI_FIXTURE_MISSING (38).
#
# THE OUTPUT CONTRACT is the FIRST WHITESPACE-DELIMITED TOKEN of that line, and
# the vocabulary is exactly those four. Everything after the token is
# human-readable detail — a reason, the matched keyword, a path — so detail can
# be improved forever without ever introducing a fifth verdict. Continuation
# lines are prefixed with `|` so a quoted plan line can never be mistaken for a
# second verdict line, even when the plan being linted quotes this vocabulary.
#
# The verdict line is UNCONDITIONAL, including for the overwhelmingly common
# NOT-APPLICABLE case. A silent run is indistinguishable from a lint that never
# executed — plan 045's "a fail-safe default hides a dead feature", exactly.
# What NOT-APPLICABLE produces no more of is FINDINGS, not output.
#
# CALIBRATION, AND WHERE IT DELIBERATELY DEPARTS FROM PLANS 046/047. Two
# blocking cases, one reported. The departure is the second blocking case — a
# capture that is declared but absent. verify-lint.sh (33) and health-reach.sh
# (34) defer on a plan's OUTPUT, because blocking a plan for not having written
# its own test yet is how a lint earns a permanent bypass. A capture is an
# INPUT: evidence the author had to hold BEFORE writing the detector. Rule 3's
# text is "must attach", present tense. A plan promising to capture the screen
# later is precisely the plan that writes its detector from memory first. Do NOT
# "simplify" this into the PENDING shape by analogy — the analogy is what is
# wrong.
#
# PROVENANCE IS A SIDECAR, never a header inside the capture. Rule 3 requires an
# unedited `tmux capture-pane -p` dump, and prepending a header edits it. For a
# capture at <path>, provenance lives at <path>.meta:
#
#   capture-date: 2026-08-05
#   agent-cli-version: claude-code 2.1.4
#
# The parse is deliberately weak — presence of both keys, `capture-date` shaped
# YYYY-MM-DD. A strict parse would reject real captures for cosmetic reasons and
# earn itself a bypass.
#
# Gated on `rule_enabled tui_fixture`; prints its mode either way.
#
# Usage: fixture-lint.sh lint <plan-ref-or-path>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
# shellcheck disable=SC1091  # resolved at runtime; lib.sh ships alongside
. "$SCRIPT_DIR/lib.sh"

RULE_KEY="tui_fixture"

usage() { echo "usage: fixture-lint.sh lint <plan>" >&2; exit 1; }

# --- The pane/TUI vocabulary -------------------------------------------------
# TWO TIERS, and the split is calibration, not tidiness.
#
# STRONG keywords name the MECHANISM of reading a screen. They are unambiguous:
# a plan that says `tmux` or `capture-pane` is scraping a pane, in any repo.
# Each matches on its own.
#
# WEAK keywords name a screen ARTIFACT and are ambiguous across domains. They
# match ONLY when at least one STRONG keyword is also present somewhere in the
# plan. Alone, they mean nothing.
#
# THE EVIDENCE FOR THE SPLIT, because it was measured, not guessed. The
# un-tiered list — with `modal` and `picker` matching on their own — fired on 9
# of 41 live plans in THIS repo and every single one was a false positive:
# "picker" here means `pick-next.sh`, the plan picker, which draws no screen at
# all. A check whose only observed firings are all wrong is exactly the profile
# AGENTS.md says earns a permanent bypass, and a bypassed check covers nothing.
# Six of those nine were pending plans the doctor would have blocked.
#
# REAL PANE WORK LOSES NO COVERAGE, which is what makes the tiering safe rather
# than merely quieter: a plan that scrapes a pane must say how it reads the pane,
# so it says `tmux` or `capture-pane` by necessity. The cctrl picker plan that
# motivated Rule 3 says both, repeatedly. The weak tier still earns its keep —
# once a plan is known to be pane work, "the modal" and "the picker" are exactly
# the lines worth quoting back to the architect.
#
# Both lists are here, at the top, so they are TUNABLE without reading the
# matcher. Add words to the tier that matches their ambiguity; do not add a
# second detection mechanism beside them.
TUI_KEYWORDS_STRONG=(
  "capture-pane"
  "send-keys"
  "tmux"
  "pane shows"
  "pane content"
  "screen scrape"
  "screen-scrape"
)

TUI_KEYWORDS_WEAK=(
  "modal"
  "picker"
)

MATCHED_KW=""
MATCHED_LINE=""

# _section <plan-abs> <heading...>: the body of the named `## ` sections, in
# document order, stopping each at the next `## `. Scoped to Requirements,
# Design, and Tasks — the prose that states what the plan DOES. Verification is
# read separately (below) for fixture DECLARATIONS only: a grep against a
# capture path in a check is evidence the plan attaches one, but the check text
# is not where a plan asserts pane behavior.
_prose() {
  awk '
    /^## / {
      inb = ($0 ~ /^## (Requirements|Design|Tasks)([[:space:]]|$)/)
      next
    }
    inb
  ' "$1" 2>/dev/null
}

# _verification <plan-abs>: the `## Verification` body.
_verification() {
  awk '
    /^## / { inb = ($0 ~ /^## Verification([[:space:]]|$)/); next }
    inb
  ' "$1" 2>/dev/null
}

# _declared_block <plan-abs>: the plan's `**Files expected to change:**` block.
#
# The anchor is the FULL BOLD HEADING at line start, matching health-reach.sh and
# premise-lint.sh — NOT a loose substring. A plan whose prose DISCUSSES the
# declaration mechanism matches the loose form inside its own body, and the block
# then swallows everything below it. That exact bug was observed on plan 088.
_declared_block() {
  awk '
    /^\*\*Files expected to change:\*\*/ { f=1; next }
    f && /^\*\*/ { exit }
    f && /^## /  { exit }
    f
  ' "$1" 2>/dev/null
}

# _exemption <plan-abs>: print the stated reason when the plan carries a HONORED
# `tui-fixture: n/a  # <reason>` declaration; return 1 otherwise.
#
# The reason is REQUIRED, and that is the whole design of the escape hatch. A
# bare `tui-fixture: n/a` is a keyword an author can type reflexively; a stated
# reason is a claim review can read and reject. Same doctrine as the health
# gate's `- none:` declaration: explicit, in the TRACKED plan file, never
# derivable from gitignored local state.
_exemption() {
  local raw val reason
  raw="$(awk '
    /^---[[:space:]]*$/ { fm++; next }
    fm==1 && /^tui-fixture:/ { print; exit }
    fm==2 { exit }
  ' "$1" 2>/dev/null)"
  [ -n "$raw" ] || return 1
  raw="${raw#tui-fixture:}"
  case "$raw" in
    *"#"*)
      val="${raw%%#*}"
      reason="${raw#*#}"
      ;;
    *)
      val="$raw"
      reason=""
      ;;
  esac
  # trim both
  val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
  reason="${reason#"${reason%%[![:space:]]*}"}"; reason="${reason%"${reason##*[![:space:]]}"}"
  [ "$val" = "n/a" ] || return 1
  [ -n "$reason" ] || return 1
  printf '%s' "$reason"
}

# _kw_regex <keyword>: the whole-word pattern for one keyword.
#
# Boundaries are spelled out rather than using `\b`, a GNU extension BSD/macOS
# grep does not portably honor. `[^[:alpha:]]` and not `[^[:alnum:]]`: the
# keywords are hyphenated words sitting in backticks and prose punctuation, and
# only a letter on either side means the match landed inside a longer word
# ("modality", "nitpicker").
_kw_regex() { printf '(^|[^[:alpha:]])(%s)([^[:alpha:]]|$)' "$1"; }

# _alt <keyword...>: the alternation body for a set of keywords.
_alt() {
  local kw out=""
  for kw in "$@"; do out="${out}${out:+|}${kw}"; done
  printf '%s' "$out"
}

# _match_keyword <text>: decide whether the text is pane-dependent, and if so set
# MATCHED_LINE to the FIRST line carrying an effective keyword and MATCHED_KW to
# the keyword that fired on it. Returns 1 when the text is not pane-dependent.
#
# THE TIER GATE IS FIRST: with no STRONG keyword anywhere in the text, the weak
# tier is not consulted at all and the plan is not pane work. See the tier
# comment at the top for the measured evidence.
#
# The reported line is first in DOCUMENT order, not first in list order: the
# earliest line where a plan reveals pane dependency is almost always in
# Requirements, and that is the line the architect needs quoted to confirm or
# dismiss the finding. Once the strong gate has opened, weak keywords ARE
# eligible to be the quoted line — on a genuine pane plan "when the picker is on
# screen" is a better quote than an incidental mention of tmux three sections
# later.
#
# One alternation pass finds the line, then the keywords are re-tried against
# that single line to name the one that fired — a grep per keyword per line over
# a whole plan is thousands of subprocesses for an answer one pass already has.
_match_keyword() {
  local text="$1" kw
  MATCHED_KW=""; MATCHED_LINE=""

  # The tier gate.
  printf '%s\n' "$text" \
    | grep -qiE "$(_kw_regex "$(_alt "${TUI_KEYWORDS_STRONG[@]}")")" || return 1

  local effective=("${TUI_KEYWORDS_STRONG[@]}" "${TUI_KEYWORDS_WEAK[@]}")
  MATCHED_LINE="$(printf '%s\n' "$text" \
    | grep -iE "$(_kw_regex "$(_alt "${effective[@]}")")" \
    | head -1)"
  # Unreachable unless the gate matched: the strong set is a subset of the
  # effective set. Fail CLOSED to pane-dependent rather than returning 1 — a
  # desynchronized edit must not silently turn the rule off.
  [ -n "$MATCHED_LINE" ] || MATCHED_LINE="(no line captured)"

  for kw in "${effective[@]}"; do
    if printf '%s' "$MATCHED_LINE" | grep -qiE "$(_kw_regex "$kw")"; then
      MATCHED_KW="$kw"
      return 0
    fi
  done
  # Same class: the alternation and the per-keyword patterns are built from the
  # same lists. Named rather than left empty so a future edit that desynchronizes
  # them produces a legible finding instead of `keyword ""`.
  MATCHED_KW="(unnamed)"
  return 0
}

# _fixture_paths <text>: every path-shaped token containing a `fixtures/`
# segment, one per line.
#
# A BROADER MATCH THAN THE PROPOSAL'S `tests/fixtures/`, on purpose and on the
# record: mstack keeps no `tests/` root and consumer repos vary, so any
# `fixtures/` segment counts. At least one character must follow the segment — a
# bare `tests/fixtures/` names a directory, not the capture the rule is about.
_fixture_paths() {
  printf '%s\n' "$1" \
    | grep -oE '[A-Za-z0-9._/-]*fixtures/[A-Za-z0-9._/-]+' \
    | sed -E 's/[.,;:]+$//' \
    | awk 'NF' | sort -u
}

# _trim <text>
_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# _excerpt <text>: a short single-line rendering for the quoted finding.
_excerpt() {
  local s
  s="$(_trim "$1")"
  if [ "${#s}" -gt 96 ]; then
    printf '%s...' "${s:0:93}"
  else
    printf '%s' "$s"
  fi
}

# _sidecar_ok <fixture-abs>: 0 when <fixture>.meta exists and carries both keys,
# with capture-date shaped YYYY-MM-DD. Weak by design — see the header.
_sidecar_ok() {
  local meta="$1.meta"
  [ -r "$meta" ] || return 1
  grep -qE '^[[:space:]]*capture-date:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$' "$meta" || return 1
  grep -qE '^[[:space:]]*agent-cli-version:[[:space:]]*[^[:space:]]' "$meta" || return 1
  return 0
}

# Local plan resolution (same shape as premise-lint.sh's / verify-lint.sh's).
_plan_relpath_fl() {
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

cmd_lint() {
  local arg="$1" root rel abs

  # The gate and its mode line come FIRST, before any work: a disabled run must
  # be legible as disabled, and must not spend effort producing findings it will
  # then discard.
  if ! rule_mode_line "$RULE_KEY"; then
    echo "fixture-lint: rule disabled — no findings emitted"
    exit 0
  fi

  root="$(repo_root)"
  rel="$(_plan_relpath_fl "$arg")" || die "cannot resolve plan: $arg"
  case "$rel" in /*) abs="$rel" ;; *) abs="$root/$rel" ;; esac
  [ -r "$abs" ] || die "plan file not readable: $abs"

  echo "fixture-lint: $rel"

  # --- 1. The declared exemption ------------------------------------------
  local reason
  if reason="$(_exemption "$abs")"; then
    printf 'NOT-APPLICABLE  (declared: %s)\n' "$reason"
    exit 0
  fi

  # --- 2. Is this plan pane-dependent at all? ------------------------------
  local prose
  prose="$(_prose "$abs")"
  if ! _match_keyword "$prose"; then
    printf 'NOT-APPLICABLE  no pane-mechanism keyword (tmux/capture-pane/send-keys/...) in Requirements/Design/Tasks\n'
    exit 0
  fi

  # --- 3. Does it declare a capture? ---------------------------------------
  # Two declaration sites, because a plan can attach a capture either way: the
  # `**Files expected to change:**` block (it commits the file), or a
  # Verification check that greps the capture (it demonstrates the detector
  # against it, which is the half of Rule 3 that makes the capture load-bearing
  # rather than decorative).
  local declared paths
  declared="$(_declared_block "$abs")
$(_verification "$abs")"
  paths="$(_fixture_paths "$declared")"

  if [ -z "$paths" ]; then
    printf 'FIXTURE-MISSING  pane-dependent (keyword "%s") but no capture is declared under a fixtures/ path\n' "$MATCHED_KW"
    printf '    | %s\n' "$(_excerpt "$MATCHED_LINE")"
    # shellcheck disable=SC2016  # the backticks are literal markdown, not substitution
    printf '    | attach an unedited `tmux capture-pane -p` dump, or declare the exemption:\n'
    printf '    |   tui-fixture: n/a  # <why this plan scrapes no pane>\n'
    exit "$EXIT_TUI_FIXTURE_MISSING"
  fi

  # --- 4. Do the declared captures exist, and do they carry provenance? -----
  local p abs_p absent="" undated=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in /*) abs_p="$p" ;; *) abs_p="$root/$p" ;; esac
    if [ ! -e "$abs_p" ]; then
      absent="${absent}${p} "
      continue
    fi
    _sidecar_ok "$abs_p" || undated="${undated}${p} "
  done <<EOF
$paths
EOF

  if [ -n "$absent" ]; then
    # BLOCKING, and this is the calibration departure from 046/047. See header.
    printf 'FIXTURE-MISSING  declared but absent: %s\n' "$(_trim "$absent")"
    printf '    | pane-dependent (keyword "%s"); a capture is an INPUT the author already holds,\n' "$MATCHED_KW"
    printf '    | not an output this plan will produce later — capture it before the detector.\n'
    printf '    | %s\n' "$(_excerpt "$MATCHED_LINE")"
    exit "$EXIT_TUI_FIXTURE_MISSING"
  fi

  if [ -n "$undated" ]; then
    # REPORTED, never blocking: a strict provenance parse rejects real captures
    # for cosmetic reasons and earns itself a bypass.
    printf 'FIXTURE-UNDATED  capture present, provenance missing: %s\n' "$(_trim "$undated")"
    for p in $undated; do
      printf '    | write %s.meta with: capture-date: YYYY-MM-DD / agent-cli-version: <string>\n' "$p"
    done
    printf '    | reported, not blocking — re-capture on agent CLI upgrades.\n'
    exit 0
  fi

  printf 'FIXTURE-OK  capture(s) present with provenance: %s\n' "$(printf '%s' "$paths" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
  exit 0
}

main() {
  local c="${1:-}"
  [ -n "$c" ] || usage
  shift
  case "$c" in
    lint) [ $# -ge 1 ] || usage; cmd_lint "$1" ;;
    *) usage ;;
  esac
}

main "$@"
