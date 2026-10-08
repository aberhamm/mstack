#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/mstack-install-paths-XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
export HOME="$FIXTURE/home"
mkdir -p "$HOME"
unset MSTACK_SKILL_DIR

for skill_file in "$SOURCE_ROOT"/skills/mstack-*/SKILL.md; do
  awk '
    /^```bash$/ { active=1; next }
    active && /^```$/ { exit }
    active && /^MSTACK_SKILL_FILE=/ { print "MSTACK_SKILL_FILE=\"$1\""; next }
    active { print }
  ' "$skill_file" > "$FIXTURE/bootstrap.sh"
  MSTACK_UPDATE_CHECK=false bash -eu "$FIXTURE/bootstrap.sh" "$skill_file"
done

for scope in .github .agents .claude .copilot .cursor .gemini; do
  base="$FIXTURE/$scope/skills"
  mkdir -p "$base"
  cp -R "$SOURCE_ROOT/skills/mstack-run" "$base/"
  cp -R "$SOURCE_ROOT/skills/mstack-shared" "$base/"
  bash -eu -c '
    source "$1/mstack-run/scripts/install-paths.sh"
    base="$1"
    FIXTURE="$2"
    [ "$(skill_dir mstack-run)" = "$(cd "$base/mstack-run" && pwd -P)" ]
    [ -r "$(skill_dir mstack-shared)/cognitive-frames.md" ]
    if mstack_checkout; then exit 1; fi
    mstack_update_check 2> "$FIXTURE/update.err"
    grep -q "source checkout not found" "$FIXTURE/update.err"
  ' _ "$base" "$FIXTURE"
done

mkdir -p "$FIXTURE/linked"
ln -s "$SOURCE_ROOT/skills/mstack-run" "$FIXTURE/linked/mstack-run"
bash -eu -c '
  FIXTURE="$1"
  SOURCE_ROOT="$2"
  source "$1/linked/mstack-run/scripts/install-paths.sh"
  [ "$(mstack_checkout)" = "$SOURCE_ROOT" ]
  [ -r "$(skill_dir mstack-shared)/cognitive-frames.md" ]
  MSTACK_SKILL_DIR="$FIXTURE/.github/skills"
  [ "$(skill_dir mstack-run)" = "$(cd "$MSTACK_SKILL_DIR/mstack-run" && pwd -P)" ]
  MSTACK_SKILL_DIR="$FIXTURE/missing"
  if skill_dir mstack-run 2>/dev/null; then exit 1; fi
' _ "$FIXTURE" "$SOURCE_ROOT"

for host in codex copilot-vscode copilot-visual-studio; do
  project="$FIXTURE/project $host"
  mkdir -p "$project"
  bash "$SOURCE_ROOT/bin/mstack-install-agents" --host "$host" --project "$project" > /dev/null
  bash "$SOURCE_ROOT/bin/mstack-install-agents" --host "$host" --project "$project" > /dev/null
  case "$host" in
    codex) target="$project/.codex/agents/mstack-worker.toml" ;;
    *) target="$project/.github/agents/mstack-worker.agent.md" ;;
  esac
  printf '\ncustom change\n' >> "$target"
  if bash "$SOURCE_ROOT/bin/mstack-install-agents" --host "$host" --project "$project" > /dev/null 2>&1; then exit 1; fi
  grep -q 'custom change' "$target"
done

for scope in .github .agents .claude .copilot .cursor .gemini; do
  project="$FIXTURE/hook $scope"
  mkdir -p "$project"
  git -C "$project" init -q
  base="$FIXTURE/$scope/skills"
  (
    cd "$project"
    bash "$base/mstack-run/scripts/init.sh" bootstrap >/dev/null
    [ "$(git config --get mstack.skillDir)" = "$(cd "$base" && pwd -P)" ]
    printf '#!/usr/bin/env bash\nexit 43\n' > "$base/mstack-run/scripts/review-gate.sh"
    for hook in pre-commit pre-push; do
      result=0
      bash ".githooks/$hook" origin example </dev/null >"$FIXTURE/hook.log" 2>&1 || result=$?
      [ "$result" -eq 43 ]
    done
  )
done
echo '[install-paths] copy, symlink, explicit target, missing source, adapters, and hook lookup: ok'
