#!/usr/bin/env bash
# seam-check.sh — JIT seam re-validation at plan pickup (mstack plan 029).
#
# Given a plan file, parse its `<!-- mstack:seam ... -->` block (the
# machine-readable contract emitted by plan-doctor, grammar fixed in
# skills/mstack-plan-doctor/references/seam-contracts.md) and verify each
# `assumed:` entry against the REAL repository.
#
# Verifiability rule (identical to seam-contracts.md §4): an assumed entry is
# VERIFIABLE iff it carries a `file:` path. When verifiable, the file must exist
# (`test -f`) and, if a `shape:` is present, the shape token must appear WITHIN
# that file (`grep -qF`). An entry with NO `file:` is UNVERIFIABLE -> skipped,
# never blocks. A bare `name:` is NEVER grepped repo-wide.
#
# Exit codes (this script's own contract, distinct from pick-next.sh's 10-19):
#   0  = clean, OR no seam block, OR all assumed entries UNVERIFIABLE
#   20 = confirmed stale seam (verifiable file missing or shape token absent),
#        with a one-line stderr diagnostic
#
# Usage: seam-check.sh <plan-file>

set -euo pipefail

EXIT_STALE_SEAM=20

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  echo "seam-check: usage: seam-check.sh <plan-file>" >&2
  exit 2
fi

PLAN_FILE="$1"

if [ ! -f "$PLAN_FILE" ]; then
  echo "seam-check: plan file not found: $PLAN_FILE" >&2
  exit 2
fi

# Repo root for resolving `file:` paths (mirror lib.sh fallback behavior).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"

# Plan id: prefer the frontmatter `id:` field, fall back to a leading numeric
# prefix in the filename, else the basename.
PLAN_ID="$(awk -F': ' '/^id:[[:space:]]*/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$PLAN_FILE")"
if [ -z "$PLAN_ID" ]; then
  PLAN_ID="$(basename "$PLAN_FILE" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')"
fi
[ -n "$PLAN_ID" ] || PLAN_ID="$(basename "$PLAN_FILE")"

# Extract VERIFIABLE assumed entries (those carrying a `file:`) as tab-separated
# records: name<TAB>file<TAB>shape. The awk walks the seam block, isolates the
# `assumed:` section, and parses each entry line respecting `; ` field
# separators at the top level (i.e. not inside double-quoted values).
ENTRIES="$(awk '
  function parse(line,    i, c, n, fld, esc, inq, fields, k, kv, key, val) {
    sub(/^- /, "", line)
    n = 0; fld = ""; inq = 0; esc = 0
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (esc) { fld = fld c; esc = 0; continue }
      if (c == "\\" && inq) { fld = fld c; esc = 1; continue }
      if (c == "\"") { inq = !inq; fld = fld c; continue }
      if (!inq && c == ";" && substr(line, i + 1, 1) == " ") {
        fields[++n] = fld; fld = ""; i++; continue
      }
      fld = fld c
    }
    fields[++n] = fld
    name = ""; file = ""; shape = ""
    for (k = 1; k <= n; k++) {
      kv = fields[k]
      key = kv; sub(/: .*$/, "", key)
      val = kv; sub(/^[^:]*: /, "", val)
      if (key == "name") name = val
      else if (key == "file") file = val
      else if (key == "shape") shape = unquote(val)
    }
  }
  function unquote(v,    inner) {
    if (substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") {
      inner = substr(v, 2, length(v) - 2)
      gsub(/\\"/, "\"", inner)
      gsub(/\\\\/, "\\", inner)
      return inner
    }
    return v
  }
  $0 == "<!-- mstack:seam" { inblock = 1; next }
  inblock && $0 == "-->" { inblock = 0; inass = 0; next }
  inblock && $0 == "produced:" { inass = 0; next }
  inblock && $0 == "assumed:" { inass = 1; next }
  inass && substr($0, 1, 2) == "- " {
    parse($0)
    if (file != "") printf "%s\t%s\t%s\n", name, file, shape
  }
' "$PLAN_FILE")"

# No verifiable assumed entries (no block, empty assumed section, or all
# UNVERIFIABLE) -> clean.
if [ -z "$ENTRIES" ]; then
  exit 0
fi

while IFS=$'\t' read -r name file shape; do
  [ -n "$file" ] || continue
  abs="$file"
  case "$file" in
    /*) abs="$file" ;;
    *)  abs="$REPO_ROOT/$file" ;;
  esac
  if [ ! -f "$abs" ]; then
    echo "seam-check: plan ${PLAN_ID}: stale seam — assumed ${name:-?} file '${file}' not found" >&2
    exit "$EXIT_STALE_SEAM"
  fi
  if [ -n "$shape" ]; then
    if ! grep -qF -- "$shape" "$abs"; then
      echo "seam-check: plan ${PLAN_ID}: stale seam — assumed ${name:-?} shape '${shape}' absent from '${file}'" >&2
      exit "$EXIT_STALE_SEAM"
    fi
  fi
done <<< "$ENTRIES"

exit 0
