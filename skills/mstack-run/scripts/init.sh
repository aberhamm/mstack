#!/usr/bin/env bash
# mstack project bootstrap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/mstack-run/scripts/lib.sh
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

  # 6. Enforcement git hooks (plan 038): install the tracked .githooks/ dir and
  # point git at it via core.hooksPath. This is the ONLY way the pre-commit /
  # pre-push barriers exist in a freshly cloned repo (git's default .git/hooks
  # is not cloned). Idempotent: hooks are refreshed from the shipped source
  # every run; core.hooksPath is only rewritten when it is not already the
  # tracked path.
  local hooks_src hooks_dst hp h
  hooks_src="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)/hooks"
  hooks_dst="$ROOT/.githooks"
  if [ -d "$hooks_src" ]; then
    mkdir -p "$hooks_dst"
    for h in pre-commit pre-push; do
      if [ -f "$hooks_src/$h" ]; then
        cp "$hooks_src/$h" "$hooks_dst/$h"
        chmod +x "$hooks_dst/$h"
      fi
    done
    # Capture the hooksPath active BEFORE mstack takes over, so the enforcement
    # hooks can CHAIN to a pre-existing global/enterprise hook (e.g. a gitleaks
    # secret scanner) instead of silently shadowing it — git's core.hooksPath
    # is single-valued, so once it points at .githooks git looks ONLY there.
    # Precedence for "prior": a genuine repo-local override predating mstack,
    # else the global/system value. Never store our own .githooks (would
    # recurse). Re-runnable: on a repeat init the local value is already
    # .githooks, so we fall through to global/system and still recover the
    # operator's real prior hook, backfilling installs made before this fix.
    local prior_local prior
    prior_local="$(git -C "$ROOT" config --local --get core.hooksPath 2>/dev/null || true)"
    if [ -n "$prior_local" ] && [ "$prior_local" != ".githooks" ]; then
      prior="$prior_local"
    else
      prior="$(git -C "$ROOT" config --global --get core.hooksPath 2>/dev/null || true)"
      [ -n "$prior" ] || prior="$(git -C "$ROOT" config --system --get core.hooksPath 2>/dev/null || true)"
    fi
    if [ -n "$prior" ] && [ "$prior" != ".githooks" ]; then
      git -C "$ROOT" config mstack.priorHooksPath "$prior"
      info "captured prior hooksPath for chaining: mstack.priorHooksPath=$prior"
    fi

    hp="$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || true)"
    if [ "$hp" != ".githooks" ]; then
      git -C "$ROOT" config core.hooksPath .githooks
      info "set core.hooksPath=.githooks (mstack enforcement hooks installed)"
    else
      info "core.hooksPath already .githooks (enforcement hooks refreshed)"
    fi
  else
    warn "enforcement hooks source not found at $hooks_src — skipping hook install"
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
