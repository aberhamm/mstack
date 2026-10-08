---
name: mstack-simplify-code
description: |
  DEPRECATED: merged into mstack-code-review (Step 1b). This skill is kept
  for backward compatibility but redirects to code-review. Use
  /mstack-code-review instead.
argument-hint: "[<scope: file path, commit range, or 'branch'>]"
allowed-tools: Bash Read Edit Glob Grep
---

## Runtime paths and update check

Set `MSTACK_SKILL_FILE` to the absolute path of **this loaded SKILL.md**,
supplied by the harness. Substitute that path below; do not use the project
directory or assume a personal installation. Install the full MStack skill
set so `mstack-run` is a sibling. In each fresh Bash invocation, repeat this
bootstrap before using `skill_dir` or the variables it defines. Pass the
resolved paths to delegated agents explicitly.

```bash
MSTACK_SKILL_FILE="/absolute/path/to/mstack-simplify-code/SKILL.md"
MSTACK_RESOLVER="$(cd "$(dirname "$MSTACK_SKILL_FILE")/../mstack-run/scripts" && pwd)/install-paths.sh"
source "$MSTACK_RESOLVER"
SKILL_DIR="$(skill_dir mstack-run)" || exit 1
SCRIPTS_DIR="$SKILL_DIR/scripts"
mstack_update_check
```
**DEPRECATED.** This skill has been merged into `/mstack-code-review` (Step 1b,
the simplification pass). It is kept only so existing routing and old
invocations still resolve.

Do not run a simplification flow from here. Invoke `/mstack-code-review`
instead, passing through any scope argument (`$ARGUMENTS`) unchanged.
