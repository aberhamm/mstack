#!/usr/bin/env bash
# Exercise fixture suites under the actual repository variables Git gives hooks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Protect the caller even when this regression is invoked by an old hook.
while IFS= read -r git_variable; do unset "$git_variable"; done < <(git rev-parse --local-env-vars)
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/hook-env-smoke-XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
outer="$FIXTURE/outer"
mkdir -p "$outer/skills/mstack-run/scripts" "$outer/.githooks"
git init -q "$outer"
git -C "$outer" config user.name Fixture
git -C "$outer" config user.email fixture@example.invalid
cp "${1:-$SCRIPT_DIR/../hooks/pre-commit}" "$outer/.githooks/pre-commit"
cat > "$outer/skills/mstack-run/scripts/script-mode-smoke.sh" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$TEST_FIXTURE_ROOT/inner"
git init -q "$TEST_FIXTURE_ROOT/inner"
git -C "$TEST_FIXTURE_ROOT/inner" -c user.name=Inner -c user.email=inner@example.invalid commit --allow-empty -qm inner
INNER
chmod +x "$outer/skills/mstack-run/scripts/script-mode-smoke.sh"
git -C "$outer" add .
git -C "$outer" -c core.hooksPath=/dev/null commit -qm baseline
baseline="$(git -C "$outer" rev-parse HEAD)"
cp "$outer/.git/index" "$FIXTURE/index.before"
cp "$outer/.git/config" "$FIXTURE/config.before"
printf '\n# staged shell change\n' >> "$outer/skills/mstack-run/scripts/script-mode-smoke.sh"
git -C "$outer" add skills/mstack-run/scripts/script-mode-smoke.sh
cp "$outer/.git/index" "$FIXTURE/index.before"
(cd "$outer" && TEST_FIXTURE_ROOT="$FIXTURE" GIT_DIR="$outer/.git" GIT_WORK_TREE="$outer" GIT_INDEX_FILE="$outer/.git/index" bash .githooks/pre-commit)
[ "$(git -C "$outer" rev-parse HEAD)" = "$baseline" ]
cmp "$outer/.git/index" "$FIXTURE/index.before"
cmp "$outer/.git/config" "$FIXTURE/config.before"
[ "$(git -C "$FIXTURE/inner" log -1 --format=%s)" = inner ]
echo '[hook-env-smoke] pass: hook fixture preserved outer HEAD/index/config'
