# Progress Output Format

All progress output uses the `[mstack]` prefix so it is visually distinct
from the agent's working output (file reads, edits, tool calls). Progress
lines are plain text printed to the user, never written to files.

**Format rules:**
- Prefix every progress line with `[mstack]`
- Use tree-drawing characters to show milestone structure within a plan:
  - `├─` for intermediate milestones (more steps follow)
  - `└─` for the final milestone of a plan (success, failure, or skip)
- Backlog summary and plan header lines have no tree prefix (they are
  top-level, not nested under a plan)

**Reference of all progress lines (see inline instructions at each step):**

```
[mstack] Backlog: N pending, M blocked, K done, J failed
[mstack] Plan N/M: <title> (plan <id>)
[mstack] ├─ Implementing...
[mstack] ├─ Health gate: <score>/10 (<verdict>)
[mstack] ├─ Cleanup: <summary>
[mstack] ├─ Code review: <N> findings, <N> fixed
[mstack] └─ Committed: <commit message first line>
[mstack] └─ FAILED: <one-line reason>
[mstack] └─ SKIPPED: blocked by failed plan <id>
[mstack] Final validation: running full test suite...
[mstack] Final validation: <score>/10 (PASS)
[mstack] Final validation: FAILED (<which categories failed>)
[mstack] WARNING: Cross-plan regression detected. Review the failures above before pushing.
[mstack] Done. <N> completed, <N> failed, <N> skipped. Run /mstack-changelog to review.
```
