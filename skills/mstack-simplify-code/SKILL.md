---
name: mstack-simplify-code
description: |
  DEPRECATED: merged into mstack-code-review (Step 4b). This skill is kept
  for backward compatibility but redirects to code-review. Use
  /mstack-code-review instead.
argument-hint: "[<scope: file path, commit range, or 'branch'>]"
allowed-tools:
  - Bash
  - Read
  - Edit
  - Glob
  - Grep
---

## Update check

Before any other work, run the shared, cooldown-aware check:

```bash
for _base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "${_base}/mstack-run" ] || continue
  _mstack_run="$(cd "${_base}/mstack-run" && pwd -P)"
  _mstack_root="$(cd "$_mstack_run/../.." && pwd -P)"
  bash "$_mstack_root/bin/mstack-update-check" 2>/dev/null || true
  break
done
```

**DEPRECATED.** This skill has been merged into `/mstack-code-review` (Step 4b,
the simplification pass). It is kept only so existing routing and old
invocations still resolve.

Do not run a simplification flow from here. Invoke `/mstack-code-review`
instead, passing through any scope argument (`$ARGUMENTS`) unchanged.
