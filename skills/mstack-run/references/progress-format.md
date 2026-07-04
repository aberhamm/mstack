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
[mstack] └─ SKIPPED: blocked by failed plan <id>: <title>
[mstack] Final validation: running full test suite...
[mstack] Final validation: <score>/10 (PASS)
[mstack] Final validation: FAILED (<which categories failed>)
[mstack] WARNING: Cross-plan regression detected. Review the failures above before pushing.
[mstack] ANOMALY: <type> — <reason>. Handoff checkpoint saved.
[mstack] Handoff: .mstack/handoffs/<filename>
[mstack] To resume: resume from handoff anomaly-<type>
[mstack] Done. <N> completed, <N> failed, <N> skipped. Run /mstack-changelog to review.
```

### Plan citations

No line above prints a bare plan ID standing alone. Where `<id>: <title>`
appears (the `SKIPPED` line above, and anywhere else a plan is cited outside
its own header), build it via the `plan_label` helper in `lib.sh` (or an
already-known id/title pair) — see the convention in `AGENTS.md`. The
`Plan N/M: <title> (plan <id>)` line is not a gap: `<title>` already appears
earlier in that same line, so `(plan <id>)` there is a secondary
machine-style cross-reference, not a bare-ID-only surface.

### ANOMALY signal

The `[mstack] ANOMALY:` prefix is a **terminal signal** that stops `/goal`
from continuing. It is distinct from both normal completion ("Backlog clear.")
and normal failure ("plan N: failed:reason"). When `/goal` sees this prefix,
it should stop the loop immediately — the handoff checkpoint contains all
context needed to resume.

Anomaly types: `iteration_bound`, `repeat_pick`, `no_progress`, `path_divergence`.
Each triggers a handoff checkpoint written to `.mstack/handoffs/` with
recovery suggestions specific to the anomaly type. The execution manifest
is preserved (not deleted) for debugging.
