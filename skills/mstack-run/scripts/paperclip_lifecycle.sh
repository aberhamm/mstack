#!/usr/bin/env bash
# Disabled/unconfigured tracking must not start Python or discover credentials.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${PWD}"
ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
  if [[ "${ARGS[i]}" == --repo ]]; then REPO="${ARGS[i+1]}"; fi
done
COMMON="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
BINDING="$COMMON/mstack-paperclip/binding.json"
if [[ ! -f "$BINDING" ]] || ! grep -Eq '"mode"[[:space:]]*:[[:space:]]*"enabled"' "$BINDING"; then
  printf '%s\n' '{"delivery":"disabled","event_id":null,"diagnostic":null}'
  exit 0
fi
exec python3 "$SCRIPT_DIR/paperclip_lifecycle.py" "$@"
