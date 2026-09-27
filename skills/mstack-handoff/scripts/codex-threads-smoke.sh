#!/usr/bin/env bash
# codex-threads-smoke.sh — runs the codex_threads.py unittest suite.
#
# codex_threads.py backs mstack-handoff's "from codex" mode: listing Codex
# CLI threads for a repo and condensing a rollout into a handoff-ready
# transcript. It is read-only against ~/.codex (never writes there); the
# suite it runs here uses synthetic fixtures and a temp sqlite db only.
#
# Usage: bash skills/mstack-handoff/scripts/codex-threads-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PYTHON_BIN="${PYTHON_BIN:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "[codex-threads-smoke] FAIL: $PYTHON_BIN not found" >&2
  exit 1
fi

"$PYTHON_BIN" "$SCRIPT_DIR/codex_threads_test.py" -v
status=$?

if [ "$status" -eq 0 ]; then
  echo "[codex-threads-smoke] ok: codex_threads.py test suite passed"
else
  echo "[codex-threads-smoke] FAIL: codex_threads.py test suite failed" >&2
fi
exit "$status"
