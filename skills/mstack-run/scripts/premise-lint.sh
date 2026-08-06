#!/usr/bin/env bash
# premise-lint.sh — an uncited factual premise is a finding (Rule 1, plan 088).
#
# THE PROBLEM. The plan pipeline verifies what a plan CITES and exempts what it
# ASSERTS, and that asymmetry is backwards. In the cctrl 051-053 batch two P1
# defects cleared an eng review AND a cross-model pass; both were the batch's
# only uncited premises about existing code ("the picker is a modal, so
# `_session_rich_state` should report `blocked-dialog`" cited nothing), while
# every cited claim in the same plans — line refs, JSON key counts, measured
# timings — had been checked. Decorating a claim with a citation ATTRACTED
# verification; omitting one BOUGHT EXEMPTION.
#
# WHAT THIS DOES. Reads a plan's `## Requirements` acceptance criteria and puts
# each one in exactly one of four classes, one line per AC:
#
#   CITED-OK          cites an identifier that resolves (or is a declared
#                     forward reference).
#   CITED-UNRESOLVED  cites an identifier that resolves NOWHERE and that no plan
#                     declares it will create. BLOCKING, exit 37.
#   UNCITED           carries a premise signal about existing code and cites no
#                     identifier at all. Reported, NEVER blocking here.
#   NO-PREMISE        asserts nothing about existing code.
#
# CALIBRATION IS THE WHOLE DESIGN, and it is split by whether a class is
# PROVABLE. This repo shipped an over-blocking lint once already: verify-lint.sh
# conflated PENDING with BROKEN and flagged six well-formed plans as dead. So:
#   * CITED-UNRESOLVED is provable from the repo — the identifier is not there
#     and no plan declares it will be. It blocks, in this script, exit 37.
#   * UNCITED is a heuristic over prose. It never sets the exit code. The
#     DOCTOR turns it into a blocking Step 4b finding only after its own auto-fix
#     attempt fails, the same discipline Step 3.5 applies to a GENUINE
#     adversarial-audit finding. The deterministic layer stays honest and the
#     judgment sits where judgment belongs. A check that cries wolf gets
#     bypassed, and a bypassed check covers nothing.
#
# SEARCH SURFACE — git's own view of the working tree, `git ls-files` UNION
# `git ls-files --others --exclude-standard`. Not a `find` walk (it would
# include ignored build output) and not tracked-only (a plan authored in the
# same session that created a file must see that file). Plan 043 established
# this exact rule for the health detector, for the identical reason.
#
# ...MINUS THE PLANS DIRECTORY, for SYMBOL content search only, and this
# exclusion is load-bearing rather than an optimization. The symbol is being
# read OUT OF a plan file, so a repo-wide content search always finds it in the
# very plan under lint: every unresolvable citation would resolve and the
# blocking class would be unreachable by construction — the plan-045 failure
# mode where a check that cannot fail is indistinguishable from a check that
# passes. PATH citations keep the full surface (plan files included), because a
# path that exists is evidence regardless of which directory it lives in: a plan
# citing `docs/plans/087-....md` is citing a real artifact.
# premise-lint-smoke.sh case 2 is the case that would pass if the exclusion were
# dropped; do not "simplify" it away.
#
# FORWARD REFERENCES ARE NOT DEFECTS. Two exemptions, and they are NOT the same
# rule:
#   * SELF — a symbol or path this plan's own `**Files expected to change:**`
#     declares it will create. New to this lint; the Step 3.5 audit classifier
#     has no precedent for it, because that classifier audits claims about the
#     EXISTING repo, not a plan's forward reference to its own output.
#   * ANCESTOR — a symbol a not-yet-`done` `blocked-by` ancestor declares it will
#     produce. This is the rule Step 3.5's classifier already states
#     (`references/adversarial-audit.md`); reused verbatim, not reinvented.
# Both yield CITED-OK.
#
# CITATION ELIGIBILITY — NOT EVERY BACKTICKED TOKEN IS A CITATION. Measured on
# this repo's live backlog after shipping: the blocking class fired 4 times
# across the 14 pending plans and ALL FOUR were false positives — a 100%
# false-positive rate, the same profile the Rule 3 tiering was built to remove.
# Nothing was cited wrong; the tokens were never citations. Three exclusions,
# applied before a token can be CITED-UNRESOLVED:
#   * SHELL SYNTAX — a token carrying `${`, `$(`, `#`, `|`, `&`, `;`, a quote,
#     or a bracket is code being PROPOSED or DEMONSTRATED (`${var#"$root"/}` as
#     a suggested fix, `$(touch "$d/marker")` as an injection payload), not a
#     repo identifier being CITED.
#   * SHELL KEYWORDS — `if`, `fi`, `do`, `done`, `case`, `esac`, ... and the
#     slash-joined pairs prose writes them in. `if/fi` reads as a two-segment
#     path and resolves nowhere, correctly and uselessly.
#   * IMPLAUSIBLE PATHS — a path-shaped token whose FIRST segment is not a real
#     top-level entry of this repo. `tests/test_x.py` / `other/tests/test_x.py`
#     were invented to EXPLAIN a substring-matching bug; no `tests/` or
#     `other/` exists here. The allowed set is derived at runtime in
#     _build_surfaces, never hardcoded.
# The plausibility test is asked only of a path that already failed to resolve —
# see the ORDER MATTERS note in cmd_lint.
#
# SIGNAL MATCHING IGNORES CODE SPANS. The premise vocabulary is matched against
# the AC with every backticked span blanked out, so an AC that QUOTES the word
# "should" as a term of art is not mistaken for one that ASSERTS with it.
#
# Gated on `rule_enabled citation_or_finding`; prints its mode either way.
#
# Exit: 0 when no AC is CITED-UNRESOLVED (UNCITED findings do not affect it);
# EXIT_PREMISE_UNCITED (37) when at least one is.
#
# Usage: premise-lint.sh lint <plan-ref-or-path>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
# shellcheck disable=SC1091  # resolved at runtime; lib.sh ships alongside
. "$SCRIPT_DIR/lib.sh"

RULE_KEY="citation_or_finding"

usage() { echo "usage: premise-lint.sh lint <plan>" >&2; exit 1; }

# --- The premise-signal vocabulary ------------------------------------------
# A single explicit list, deliberately in one place at the top of the script so
# it is TUNABLE without reading the classifier. It is a WORD LIST and therefore
# both over- and under-matches: it will flag narrative prose that asserts
# nothing, and it will miss a premise phrased without any of these words
# ("the picker returns the pane title"). That residual is why UNCITED reports
# instead of blocking. Add words here; do not add a second mechanism.
PREMISE_SIGNALS=(
  "should"
  "presumably"
  "by construction"
  "assumes"
  "already"
  "existing"
  "current"
  "currently"
  "since"
  "because"
  "so that it reports"
  "will report"
)

WT_LIST=""
CONTENT_LIST=""
SELF_DECL=""
ANCESTOR_DECL=""
PLAUSIBLE_ROOTS=""

# --- Shell keywords ----------------------------------------------------------
# A backticked `if/fi` is a KEYWORD PAIR named in prose ("converted to `if/fi`"),
# not a two-segment repo path. See the CITATION ELIGIBILITY note in the header.
SHELL_KEYWORDS="if fi then else elif do done case esac while until for in"

# Invoked indirectly, by the EXIT trap below.
# shellcheck disable=SC2329
_cleanup() {
  [ -n "$WT_LIST" ] && rm -f "$WT_LIST"
  [ -n "$CONTENT_LIST" ] && rm -f "$CONTENT_LIST"
  return 0
}
trap _cleanup EXIT

# _build_surfaces: materialize the resolution surfaces once per run.
#   WT_LIST         — every working-tree path (tracked + untracked-not-ignored).
#                     Used for PATH citations.
#   CONTENT_LIST    — WT_LIST minus the plans directory (which contains
#                     archive/). Used for SYMBOL content search. See the header.
#   PLAUSIBLE_ROOTS — every real top-level entry of the repo. Used to reject
#                     invented example paths. DERIVED AT RUNTIME, never
#                     hardcoded: a hardcoded list rots the moment a top-level
#                     directory is added, and it rots silently — the failure is
#                     a new false positive, which is the exact bug this filter
#                     was added to remove.
_build_surfaces() {
  local root pdir pdir_rel
  root="$(repo_root)"
  # NOTE: the mktemp template MUST end in X's — BSD/macOS rejects a suffix with
  # a misleading "File exists". That exact bug killed plan-doctor's codex audit.
  WT_LIST="$(mktemp "${TMPDIR:-/tmp}/mstack-premise-wt-XXXXXX")" || die "mktemp failed"
  CONTENT_LIST="$(mktemp "${TMPDIR:-/tmp}/mstack-premise-ct-XXXXXX")" || die "mktemp failed"
  {
    git -C "$root" ls-files 2>/dev/null
    git -C "$root" ls-files --others --exclude-standard 2>/dev/null
  } | awk 'NF' | sort -u > "$WT_LIST"

  pdir="$(plans_dir 2>/dev/null || true)"
  if [ -n "$pdir" ]; then
    pdir_rel="${pdir#"$root"/}"
    grep -v "^${pdir_rel}/" "$WT_LIST" > "$CONTENT_LIST" 2>/dev/null || true
  else
    cp "$WT_LIST" "$CONTENT_LIST"
  fi

  # Both halves matter. `ls -A` alone would miss nothing on a full checkout but
  # WT_LIST's first segments are the authoritative "git knows about this"
  # answer; `ls -A` adds the top-level entries git does not track (`.mstack/`
  # is gitignored yet is a real directory plans legitimately cite).
  PLAUSIBLE_ROOTS="$(
    {
      awk -F/ 'NF { print $1 }' "$WT_LIST"
      ls -A "$root" 2>/dev/null
    } | awk 'NF' | sort -u
  )"
}

# _plausible_root <path>: 0 when the path's FIRST segment is a real top-level
# entry of this repo. An invented illustrative path (`tests/test_x.py`,
# `other/tests/test_x.py`) fails here, and so does a shell fragment that only
# LOOKS path-shaped because it contains a slash (`$d/marker`).
#
# A token with NO slash is always plausible. Its only segment is the filename
# itself, so testing it against the top-level set would demand that every bare
# filename citation (`checkpoint.sh`, `health-reach.sh` — the form these plans
# use constantly) sit at the repo root. Those resolve by substring today; the
# ones that DON'T resolve are genuine misses, and excluding them would delete
# coverage the four measured false positives never asked for.
_plausible_root() {
  local first
  case "$1" in
    */*) first="${1%%/*}" ;;
    *)   return 0 ;;
  esac
  [ -n "$first" ] || return 1
  printf '%s\n' "$PLAUSIBLE_ROOTS" | grep -qxF -- "$first"
}

# _declared_block <plan-abs>: the plan's `**Files expected to change:**` block.
#
# The anchor is the FULL BOLD HEADING at line start, matching health-reach.sh —
# NOT a loose `/Files expected to change/` substring. A plan whose Requirements
# discuss the declaration mechanism ("...that the plan's `**Files expected to
# change:**` never declares it will create") matches the loose form inside its
# own acceptance criteria, so the block starts at the AC and swallows every
# criterion below it. Every identifier the plan CITES then reads as one the plan
# DECLARES, the forward-reference exemption fires universally, and
# CITED-UNRESOLVED becomes unreachable. Observed on plan 088 itself.
_declared_block() {
  awk '
    /^\*\*Files expected to change:\*\*/ { f=1; next }
    f && /^\*\*/ { exit }
    f && /^## /  { exit }
    f
  ' "$1" 2>/dev/null
}

# _build_exemptions <plan-abs>: fill SELF_DECL (this plan's declared block) and
# ANCESTOR_DECL (the declared blocks of every not-yet-done blocked-by ancestor).
# A `done` ancestor is excluded on purpose: its output should already EXIST, so
# citing it must resolve against the repo, not against a promise.
_build_exemptions() {
  local abs="$1" root bb a af astatus
  root="$(repo_root)"
  SELF_DECL="$(_declared_block "$abs")"
  ANCESTOR_DECL=""
  bb="$(fm_get "$abs" blocked-by 2>/dev/null || true)"
  for a in $(printf '%s' "$bb" | tr -cs '0-9' ' '); do
    af="$(plan_file_for_id "$a" 2>/dev/null || true)"
    [ -n "$af" ] || continue
    astatus="$(fm_get "$root/$af" status 2>/dev/null || true)"
    [ "$astatus" = "done" ] && continue
    ANCESTOR_DECL="${ANCESTOR_DECL}
$(_declared_block "$root/$af")"
  done
}

# _exempt <identifier>: 0 when this plan, or a not-yet-done ancestor, declares
# it will produce the identifier. Substring match against the declared block, so
# `- \`src/new.py\`: adds \`brand_new_helper\`` covers both the path and the symbol.
_exempt() {
  local ident="$1"
  printf '%s' "$SELF_DECL" | grep -qF -- "$ident" && return 0
  if [ -n "$ANCESTOR_DECL" ]; then
    printf '%s' "$ANCESTOR_DECL" | grep -qF -- "$ident" && return 0
  fi
  return 1
}

# _path_resolves <path>: the path exists on disk, or appears in the working-tree
# path set. Substring against the set on purpose, so a directory fragment
# (`archive/`) resolves via the files under it.
_path_resolves() {
  local p="$1" root
  root="$(repo_root)"
  [ -e "$root/$p" ] && return 0
  grep -qF -- "$p" "$WT_LIST" && return 0
  return 1
}

# _symbol_resolves <symbol>: the symbol appears in the CONTENT of at least one
# non-plan working-tree file. `-I` skips binaries; `-F` is a literal match (a
# symbol is not a regex, and `.`/`*` in one must not widen the search).
_symbol_resolves() {
  local sym="$1" hit root
  root="$(repo_root)"
  hit="$(cd "$root" && tr '\n' '\0' < "$CONTENT_LIST" \
          | xargs -0 grep -IlF -e "$sym" -- 2>/dev/null | head -1)"
  [ -n "$hit" ]
}

# _normalize_ident <span>: reduce a backticked span to the single identifier it
# is citing, or to something _shape rejects.
#
# Only the FIRST whitespace-delimited token is considered: a span is routinely a
# usage line (`premise-lint.sh lint <plan>`, `rule_enabled <key>`) whose head is
# the citation and whose tail is a placeholder. Taking the whole span would
# reject both; taking every token would turn `<key>` into a phantom citation.
_normalize_ident() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"      # ltrim
  s="${s%%[[:space:]]*}"              # first token
  s="${s%%=*}"                        # `EXIT_PREMISE_UNCITED=37` -> the name
  s="${s%%(*}"                        # `rule_enabled(` -> the name
  s="${s%%)*}"
  # A trailing `:NNN` / `:NNN-MMM` is a LINE ANCHOR on a path citation
  # (`references/adversarial-audit.md:160-163`), not part of the path. Left on,
  # it makes every line-anchored citation — the most precise kind a plan can
  # write — unresolvable, penalising exactly the authors who cited best.
  local tail_seg
  case "$s" in
    *:[0-9]*)
      tail_seg="${s##*:}"
      case "$tail_seg" in
        *[![:digit:]-]*) ;;
        *) s="${s%:*}" ;;
      esac ;;
  esac
  # Trailing punctuation, stripped via parameter expansion rather than `case`:
  # a `;` inside a case-pattern bracket expression is a bash parse error.
  local prev=""
  while [ "$s" != "$prev" ]; do
    prev="$s"
    s="${s%[.,;:]}"
  done
  printf '%s' "$s"
}

# _is_shell_keyword <word>: membership in SHELL_KEYWORDS.
_is_shell_keyword() {
  case " $SHELL_KEYWORDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# _all_segments_shell_keywords <token>: 0 when every `/`-joined segment is a
# shell keyword. Requiring EVERY segment (not any) keeps a real path whose
# directory happens to be named `do` or `case` citable.
_all_segments_shell_keywords() {
  local s="$1" seg rest
  [ -n "$s" ] || return 1
  rest="$s"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    _is_shell_keyword "$seg" || return 1
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *)   rest="" ;;
    esac
  done
  return 0
}

# _shape <identifier>: path | symbol | none.
# A SYMBOL is snake_case (contains an underscore) or camelCase (starts lower,
# contains an upper). Deliberately narrow: a single lowercase English word and
# an ALL-CAPS word are not citations, and treating them as such would make every
# prose emphasis a phantom finding.
_shape() {
  local s="$1"
  [ -n "$s" ] || { echo none; return; }
  # A leading `/` or `~` is NOT a repo-relative path. `/plan-eng-review` and
  # `/mstack-plan-doctor` are skill invocations, `~/.claude/skills/...` is an
  # install location outside the tree — none of them can resolve against the
  # working tree, so classifying them as paths manufactures a guaranteed
  # CITED-UNRESOLVED for every plan that names the skill it wires into.
  case "$s" in
    /*|~*) echo none; return ;;
  esac
  # A token carrying `<...>` or `*` is a TEMPLATE or a GLOB, not a citation:
  # `.mstack/amendments/plan-<id>.jsonl` and `.mstack/reviews/*.json` name a
  # shape, not an artifact, and cannot resolve by construction. Flagging them
  # would make the blocking class fire on every plan that describes a file
  # naming scheme, which is noise with a guaranteed false-positive rate of 1.
  case "$s" in
    *'<'*|*'>'*|*'*'*) echo none; return ;;
  esac
  # A token carrying SHELL SYNTAX is code being PROPOSED or DEMONSTRATED, not a
  # repo identifier being CITED. `${var#"$root"/}` is the fix an AC suggests;
  # `$(touch "$d/marker")` is an injection-test payload. Neither can resolve
  # against a working tree by construction, so classifying them as citations
  # manufactures a guaranteed CITED-UNRESOLVED — the same false-positive-rate-1
  # shape as the template/glob case above. Measured: 3 of the 4 live blocking
  # firings on this repo's backlog were tokens in this class or the next two.
  # shellcheck disable=SC2016  # these are literal shell metacharacters to MATCH, not to expand
  case "$s" in
    *'${'*|*'$('*|*'#'*|*'|'*|*'&'*|*';'*|*'"'*|*"'"*|*'['*|*']'*|*'{'*|*'}'*|*'('*|*')'*)
      echo none; return ;;
  esac
  # SHELL KEYWORDS, including the slash-joined pairs prose writes them in
  # (`if/fi`, `case/esac`). A bare keyword is already `none` — it is one
  # lowercase word — but `if/fi` reads as a two-segment path and resolved
  # nowhere, which is exactly right and exactly useless.
  if _all_segments_shell_keywords "$s"; then echo none; return; fi
  case "$s" in
    */*) echo path; return ;;
    *.md|*.sh|*.json|*.py|*.ts|*.tsx|*.js|*.yml|*.yaml|*.toml|*.txt|*.go|*.rb)
      echo path; return ;;
  esac
  # POSIX character classes, never `[a-z]`/`[A-Z]` ranges. Under the common
  # en_US.UTF-8 collation a bracket RANGE is collation-ordered (aAbBcC...), so
  # `[a-z]*` matches `UNDETERMINED` and every ALL-CAPS word in every plan was
  # classified as camelCase and then reported CITED-UNRESOLVED. Observed on plan
  # 087. `[[:lower:]]` is locale-correct and means what it says.
  case "$s" in
    *[![:alnum:]_]*) echo none; return ;;
    *_*) echo symbol; return ;;
    [[:lower:]]*) case "$s" in *[[:upper:]]*) echo symbol; return ;; esac ;;
  esac
  echo none
}

# _strip_code <text>: blank every backticked span. Signal matching runs on this,
# so an AC that QUOTES "should" as vocabulary is not read as asserting with it.
# shellcheck disable=SC2016  # the backticks are literal markdown, not substitution
_strip_code() { printf '%s' "$1" | sed -E 's/`[^`]*`/ /g'; }

# _has_premise_signal <text>: whole-word, case-insensitive match against the
# vocabulary. Word boundaries are spelled out rather than using `\b`, which is a
# GNU extension BSD/macOS grep does not portably honor.
_has_premise_signal() {
  local text w
  text="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for w in "${PREMISE_SIGNALS[@]}"; do
    if printf '%s' "$text" | grep -qE "(^|[^[:alpha:]])${w}([^[:alpha:]]|$)"; then
      printf '%s' "$w"
      return 0
    fi
  done
  return 1
}

# _acs <plan-abs>: one acceptance criterion per line, continuation lines folded
# in. Only the `## Requirements` section counts — scanning the whole plan would
# turn every checklist-shaped line in Design or Verification into a phantom AC.
_acs() {
  awk '
    /^## Requirements/ { inreq=1; next }
    inreq && /^## / { if (buf != "") { print buf; buf="" } inreq=0 }
    !inreq { next }
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^-[[:space:]]*\[[ xX]\]/) {
        if (buf != "") print buf
        sub(/^-[[:space:]]*\[[ xX]\][[:space:]]*/, "", line)
        buf = line
        next
      }
      if (buf != "") {
        if (line == "") { print buf; buf=""; next }
        buf = buf " " line
      }
    }
    END { if (buf != "") print buf }
  ' "$1"
}

# _spans <ac>: every backticked span in an AC, one per line.
_spans() {
  # shellcheck disable=SC2016  # the backticks are literal markdown, not substitution
  printf '%s\n' "$1" | grep -oE '`[^`]+`' | sed -e 's/^`//' -e 's/`$//'
}

# _excerpt <ac>: a short, single-line rendering for the report.
_excerpt() {
  local s="$1"
  if [ "${#s}" -gt 78 ]; then
    printf '%s...' "${s:0:75}"
  else
    printf '%s' "$s"
  fi
}

# Local plan resolution (same shape as verify-lint.sh's).
_plan_relpath_pl() {
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
    echo "premise-lint: rule disabled — no findings emitted"
    exit 0
  fi

  root="$(repo_root)"
  rel="$(_plan_relpath_pl "$arg")" || die "cannot resolve plan: $arg"
  case "$rel" in /*) abs="$rel" ;; *) abs="$root/$rel" ;; esac
  [ -r "$abs" ] || die "plan file not readable: $abs"

  _build_surfaces
  _build_exemptions "$abs"

  echo "premise-lint: $rel"

  local ac n=0 unresolved_total=0 uncited=0 cited_ok=0 no_premise=0
  local span ident shape cites bad sig
  while IFS= read -r ac; do
    [ -n "$ac" ] || continue
    n=$((n + 1))
    cites=0
    bad=""

    while IFS= read -r span; do
      [ -n "$span" ] || continue
      ident="$(_normalize_ident "$span")"
      shape="$(_shape "$ident")"
      case "$shape" in
        path)
          # ORDER MATTERS, and it is not the order the exclusion is stated in.
          # Plausibility is asked ONLY of a path that failed to resolve. A path
          # that resolves is a citation whatever its first segment: this repo's
          # plans routinely cite a real file by its tail (`scripts/lib.sh`,
          # `mstack-wrap-up/SKILL.md`), which _path_resolves matches as a
          # substring of the full working-tree path. Filtering before
          # resolution would demote every one of those from CITED-OK — 6 of the
          # 38 cited-ok ACs on the live backlog — which is a real loss of
          # coverage traded for nothing.
          if _path_resolves "$ident" || _exempt "$ident"; then
            cites=$((cites + 1))
          elif _plausible_root "$ident"; then
            cites=$((cites + 1))
            bad="${bad}${ident} "
          fi
          # else: an invented illustrative path or a shell fragment. Not a
          # citation at all, so it neither blocks nor counts toward `cites`.
          ;;
        symbol)
          cites=$((cites + 1))
          _symbol_resolves "$ident" || _exempt "$ident" || bad="${bad}${ident} "
          ;;
      esac
    done <<EOF
$(_spans "$ac")
EOF

    if [ -n "$bad" ]; then
      printf '  CITED-UNRESOLVED  AC%d  %s\n' "$n" "$(_excerpt "$ac")"
      printf '                    resolves nowhere in the working tree and no plan declares it: %s\n' "${bad% }"
      unresolved_total=$((unresolved_total + 1))
    elif [ "$cites" -gt 0 ]; then
      printf '  CITED-OK          AC%d  %s\n' "$n" "$(_excerpt "$ac")"
      cited_ok=$((cited_ok + 1))
    elif sig="$(_has_premise_signal "$(_strip_code "$ac")")"; then
      printf '  UNCITED           AC%d  %s\n' "$n" "$(_excerpt "$ac")"
      printf '                    premise signal "%s" with no citation — add the citation, or\n' "$sig"
      printf '                    rewrite the AC so it asserts nothing about existing code\n'
      uncited=$((uncited + 1))
    else
      printf '  NO-PREMISE        AC%d  %s\n' "$n" "$(_excerpt "$ac")"
      no_premise=$((no_premise + 1))
    fi
  done <<EOF
$(_acs "$abs")
EOF

  echo "  ---"
  if [ "$n" -eq 0 ]; then
    echo "  no acceptance criteria found under '## Requirements' — nothing to lint"
    exit 0
  fi
  printf '  %d AC(s): %d cited-ok, %d cited-unresolved, %d uncited, %d no-premise.\n' \
    "$n" "$cited_ok" "$unresolved_total" "$uncited" "$no_premise"
  # UNCITED never gates here. It is a word-list match over prose; the doctor's
  # Step 4b decides after its auto-fix round, exactly as it does for a GENUINE
  # adversarial-audit finding.
  if [ "$uncited" -gt 0 ]; then
    printf '  UNCITED is reported, not blocking here — plan-doctor Step 4b resolves it.\n'
  fi
  [ "$unresolved_total" -eq 0 ] || exit "$EXIT_PREMISE_UNCITED"
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
