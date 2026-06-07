#!/usr/bin/env bash
# mstack project bootstrap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT="$(repo_root)"

cmd_bootstrap() {
  local with_agent_docs=false
  for arg in "$@"; do
    case "$arg" in
      --with-agent-docs|--with-claude-md) with_agent_docs=true ;;
    esac
  done

  # 1. Plans directory
  local pdir
  if [ -d "$ROOT/docs/plans" ]; then
    pdir="$ROOT/docs/plans"
    info "plans directory exists: $pdir"
  elif [ -d "$ROOT/plans" ]; then
    pdir="$ROOT/plans"
    info "plans directory exists: $pdir"
  else
    pdir="$ROOT/docs/plans"
    mkdir -p "$pdir"
    info "created: $pdir"
  fi

  # 1b. Archive directory for completed plans
  mkdir -p "$pdir/archive"
  info "ensured: $pdir/archive/"

  # 2. .mstack directory + gitignore
  ensure_mstack_dir
  info "ensured: .mstack/"

  # 3. Add .mstack-* to gitignore
  if [ -f "$ROOT/.gitignore" ]; then
    grep -q "^\.mstack-" "$ROOT/.gitignore" 2>/dev/null || echo ".mstack-*" >> "$ROOT/.gitignore"
  fi

  # 4. Default config
  bash "$SCRIPT_DIR/config.sh" init > /dev/null
  info "ensured: .mstack/config.json"

  # 5. Agent guidance health stack (optional)
  if [ "$with_agent_docs" = "true" ]; then
    local guidance_file=""
    if [ -f "$ROOT/AGENTS.md" ]; then
      guidance_file="$ROOT/AGENTS.md"
    elif [ -f "$ROOT/CLAUDE.md" ]; then
      guidance_file="$ROOT/CLAUDE.md"
    else
      guidance_file="$ROOT/AGENTS.md"
      {
        echo "# Project Agent Guide"
        echo ""
      } > "$guidance_file"
      info "created: AGENTS.md"
    fi

    if ! grep -q "## Health Stack" "$guidance_file" 2>/dev/null; then
      local detected
      detected="$(bash "$SCRIPT_DIR/health-check.sh" detect 2>/dev/null || true)"
      if [ -n "$detected" ]; then
        {
          echo ""
          echo "## Health Stack"
          echo ""
          echo "$detected" | while IFS=: read -r cat cmd; do
            echo "- $cat: $cmd"
          done
        } >> "$guidance_file"
        info "appended Health Stack to ${guidance_file#"$ROOT"/}"
      fi
    else
      info "${guidance_file#"$ROOT"/} already has Health Stack section"
    fi
  fi

  echo ""
  echo "mstack initialized:"
  echo "  plans:      $pdir"
  echo "  config:     $ROOT/.mstack/config.json"
  echo "  learnings:  $ROOT/.mstack/learnings.jsonl (created on first run)"
  echo "  health:     $ROOT/.mstack/health-history.jsonl (created on first run)"
  echo "  checkpoints: $ROOT/.mstack/checkpoints/ (created on first run)"
  echo ""
  echo "Next: /mstack-plan-multi \"<your goal>\""
}

case "${1:-bootstrap}" in
  bootstrap) shift 2>/dev/null || true; cmd_bootstrap "$@" ;;
  *)         die "usage: init.sh bootstrap [--with-agent-docs|--with-claude-md]" ;;
esac
