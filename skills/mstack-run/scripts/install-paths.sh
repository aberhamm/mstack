#!/usr/bin/env bash

_mstack_install_base="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

skill_dir() {
  local name="$1" base
  case "$name" in ''|*/*|..|.) return 2 ;; esac
  if [ -n "${MSTACK_SKILL_DIR:-}" ]; then
    [ -d "$MSTACK_SKILL_DIR/$name" ] || {
      printf 'mstack: missing %s in MSTACK_SKILL_DIR=%s\n' "$name" "$MSTACK_SKILL_DIR" >&2
      return 1
    }
    (cd "$MSTACK_SKILL_DIR/$name" && pwd -P)
    return
  fi
  case "$name" in
    mstack-*)
      [ -d "$_mstack_install_base/$name" ] || {
        printf 'mstack: missing sibling skill %s in %s\n' "$name" "$_mstack_install_base" >&2
        return 1
      }
      (cd "$_mstack_install_base/$name" && pwd -P)
      return ;;
  esac
  for base in "$_mstack_install_base" \
    "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" \
    "${HOME}/.codex/skills" "${HOME}/.claude/skills" \
    "${HOME}/.copilot/skills" "${HOME}/.cursor/skills" "${HOME}/.gemini/skills"; do
    [ -d "$base/$name" ] || continue
    (cd "$base/$name" && pwd -P)
    return
  done
  return 1
}

mstack_checkout() {
  local run candidate
  run="$(skill_dir mstack-run)" || return 1
  if [ -r "$run/.mstack-source-root" ]; then
    IFS= read -r candidate < "$run/.mstack-source-root"
  else
    candidate="$(cd "$run/../.." && pwd -P)"
  fi
  [ -r "$candidate/bin/mstack-update-check" ] &&
    [ -r "$candidate/skills/mstack-run/scripts/install-paths.sh" ] || return 1
  printf '%s\n' "$candidate"
}

mstack_update_check() {
  local checkout
  [ "${MSTACK_UPDATE_CHECK:-true}" != false ] || return 0
  if checkout="$(mstack_checkout)"; then
    MSTACK_DIR="$checkout" bash "$checkout/bin/mstack-update-check" || true
  else
    printf '%s\n' 'mstack: update notices unavailable (source checkout not found); installed skills remain usable.' >&2
  fi
}
