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

**DEPRECATED.** This skill has been merged into `/mstack-code-review` (Step 4b,
the simplification pass). It is kept only so existing routing and old
invocations still resolve.

Do not run a simplification flow from here. Invoke `/mstack-code-review`
instead, passing through any scope argument (`$ARGUMENTS`) unchanged.
