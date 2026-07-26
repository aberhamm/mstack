#!/usr/bin/env bash
# script-mode-smoke.sh — every shipped script is committed executable (100755).
#
# WHY THIS EXISTS. `review-gate.sh` was committed 100644. Consumers that locate
# helpers with an `[ -x ]` test could not resolve it, so `plan-authored` never
# ran and `mstack-wrap-up` fell through to its fail-safe "treat as authored"
# branch. Nothing errored. Nothing looked broken. The discriminator was simply
# never invoked — the shipped feature was dead on arrival for a whole day.
#
# That is the signature of this bug class: a missing execute bit is invisible in
# review (git shows the mode nowhere a human reads), invisible at runtime (the
# consumer degrades quietly), and re-introduced for free every time an agent
# creates a new script with a Write tool, which does not set the bit. It is
# caught by an assertion or it is not caught at all.
#
# The invariant is TOTAL — every tracked `*.sh` under scripts/, plus the
# repo's other entry points — deliberately, not "every script some consumer
# currently probes with -x". A rule scoped to today's call sites silently
# stops covering a file the moment a new consumer appears, which is the same
# class of gap it is meant to close.
#
# Consumers should ALSO not depend on the bit: a helper invoked as
# `bash "$HELPER"` needs `-r`, not `-x` (see mstack-wrap-up's resolution loop).
# Belt and braces — the mode is asserted here, and resolution does not rely on
# it either way.
#
# Usage: bash skills/mstack-run/scripts/script-mode-smoke.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || { echo "[script-mode-smoke] SKIP: not a git work tree" >&2; exit 0; }

fail() { echo "[script-mode-smoke] FAIL: $*" >&2; exit 1; }

checked=0
offenders=""

# Tracked files that must be executable: every *.sh under the skills tree, plus
# the repo's standalone entry points. `git ls-files -s` reports the mode git
# actually recorded, which is what ships — not the local filesystem bit, which
# can differ after a bad checkout or a mode-dropping copy.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  mode="${line%% *}"
  path="${line#*"$(printf '\t')"}"
  case "$path" in
    *.sh|bin/*|setup|.githooks/*) ;;
    *) continue ;;
  esac
  checked=$((checked + 1))
  [ "$mode" = "100755" ] || offenders="${offenders}  ${path} (mode ${mode})"$'\n'
done <<EOF
$(git -C "$ROOT" ls-files -s -- 'skills/**/*.sh' 'bin/*' 'setup' '.githooks/*' 2>/dev/null)
EOF

[ "$checked" -gt 0 ] || fail "matched zero scripts — the glob is wrong, and a vacuous pass is exactly the failure this asserts against"

if [ -n "$offenders" ]; then
  echo "[script-mode-smoke] FAIL: script(s) not committed executable:" >&2
  printf '%s' "$offenders" >&2
  echo "Fix: git update-index --chmod=+x <path>   (and chmod +x <path> on disk)" >&2
  exit 1
fi

echo "[script-mode-smoke] ok: all $checked shipped scripts are committed 100755"
