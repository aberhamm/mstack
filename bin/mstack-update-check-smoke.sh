#!/usr/bin/env bash
# Smoke test for the shared, cooldown-aware MStack update checker.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mstack-update-check.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Every shipped, invokable skill must carry the common preamble. This is what
# makes the one shared cooldown effective across Claude Code, Codex, and other
# hosts, rather than only the core planning loop.
for skill_file in "$ROOT"/skills/mstack-*/SKILL.md; do
  grep -Fq 'shared, cooldown-aware check' "$skill_file"
done

REMOTE="$TMP_ROOT/remote.git"
INSTALL="$TMP_ROOT/install"
STATE="$TMP_ROOT/state"
git init --bare --quiet "$REMOTE"
git clone --quiet "$REMOTE" "$INSTALL"
INSTALL="$(cd "$INSTALL" && pwd -P)"
git -C "$INSTALL" config user.email smoke@example.invalid
git -C "$INSTALL" config user.name smoke
printf 'initial\n' > "$INSTALL/README.md"
git -C "$INSTALL" add README.md
git -C "$INSTALL" commit --quiet -m initial
git -C "$INSTALL" branch -M main
git -C "$INSTALL" push --quiet -u origin main
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main

mkdir -p "$INSTALL/bin" "$INSTALL/skills/example" "$INSTALL/skills/mstack-run" "$TMP_ROOT/host/skills"
cp "$ROOT/bin/mstack-update-check" "$INSTALL/bin/mstack-update-check"
chmod +x "$INSTALL/bin/mstack-update-check"
printf '%s\n' '---' 'name: example' '---' > "$INSTALL/skills/example/SKILL.md"
ln -s "$INSTALL/skills/mstack-run" "$TMP_ROOT/host/skills/mstack-run"

# Skillshare targets are symlinks. Canonicalize the skill directory before
# walking to the checkout root; `mstack-run/../..` alone resolves too early.
linked_run="$(cd "$TMP_ROOT/host/skills/mstack-run" && pwd -P)"
[ "$(cd "$linked_run/../.." && pwd -P)" = "$INSTALL" ]

run_check() {
  MSTACK_DIR="$INSTALL" MSTACK_STATE_DIR="$STATE" "$INSTALL/bin/mstack-update-check"
}

# The first result is current and creates a shared cache with no result line.
run_check
[ -f "$STATE/last-update-check" ]
[ -z "$(sed -n '2p' "$STATE/last-update-check")" ]

# Make origin newer. The fresh current cache must suppress a second fetch.
git clone --quiet "$REMOTE" "$TMP_ROOT/publisher"
git -C "$TMP_ROOT/publisher" config user.email smoke@example.invalid
git -C "$TMP_ROOT/publisher" config user.name smoke
printf 'updated\n' > "$TMP_ROOT/publisher/CHANGELOG.md"
git -C "$TMP_ROOT/publisher" add CHANGELOG.md
git -C "$TMP_ROOT/publisher" commit --quiet -m update
git -C "$TMP_ROOT/publisher" push --quiet origin main
run_check

# Expire the current cache and verify both the update result and its longer
# cooldown are replayed without touching the remote again.
printf '0\n\n' > "$STATE/last-update-check"
set +e
first_output="$(run_check)"
first_rc=$?
second_output="$(run_check)"
second_rc=$?
set -e
[ "$first_rc" -eq 1 ] && [ "$second_rc" -eq 1 ]
case "$first_output" in UPDATE_AVAILABLE:*) ;; *) exit 1 ;; esac
[ "$first_output" = "$second_output" ]

# A shared state directory also supports an explicit opt-out.
MSTACK_DIR="$INSTALL" MSTACK_STATE_DIR="$STATE" MSTACK_UPDATE_CHECK=false "$INSTALL/bin/mstack-update-check"
echo "mstack-update-check smoke: PASS"
