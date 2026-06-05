---
id: 018
title: Hard iteration bound and anomaly detection
status: done
blocked-by: [017]
allows-migrations: false
needs-review: none
created: 2026-06-05
completed: 2026-06-05
reviewed: false
qa: automated
---

## Requirements

Even with distinct exit codes and a manifest, the /goal loop can still run
indefinitely if the picker keeps returning plans that never reach a terminal
state, or if unexpected conditions arise that no single exit code covers.

Add a hard iteration bound and anomaly classification layer that consumes
manifest state and picker exit codes to guarantee the loop terminates.

**Acceptance criteria:**

- [ ] If iteration_count exceeds scope_size + 1 (where scope_size = number of scoped IDs), execution stops with anomaly
- [ ] If the same plan ID appears consecutively in picked_history without becoming terminal between picks, execution stops with anomaly
- [ ] If iteration_count increased but terminal_ids set size did not grow (no progress), execution stops with anomaly
- [ ] Each anomaly produces a structured reason string: type, affected plan ID(s), iteration count, manifest snapshot
- [ ] Anomaly check runs after manifest update, before starting the next iteration
- [ ] Anomaly detection is a function/script that returns 0 (clear) or non-zero (anomaly with reason on stdout)
- [ ] SKILL.md Step 2 wired to call anomaly check after manifest update

## Design

**Anomaly types:**

| Type | Trigger | Reason string |
|------|---------|---------------|
| `iteration_bound` | iteration_count > scope_size + 1 | "iteration N exceeds bound (scope has M plans)" |
| `repeat_pick` | picked_history[-1] == picked_history[-2] AND plan not in terminal_ids | "plan NNN picked twice without reaching terminal state" |
| `no_progress` | iteration_count increased but len(terminal_ids) unchanged since last iteration | "no plan reached terminal state in iteration N" |
| `path_divergence` | manifest.sh update reported a file path change for a non-terminal plan | "plan NNN file moved mid-execution: old -> new" |

**"No progress" defined precisely:** Compare terminal_ids set size before and
after the current iteration. If the size didn't grow (no new done/failed plan),
that's a no-progress anomaly. This is distinct from a normal plan failure because
a failed plan DOES grow terminal_ids (status: failed is terminal). No-progress
means the plan was picked but somehow didn't reach any terminal state.

**Implementation:** Add an `anomaly-check.sh` script (or extend manifest.sh with
a `check` subcommand) that reads the manifest and returns:
- Exit 0: no anomaly
- Exit 1: anomaly detected, reason on stdout

**Files expected to change:**

- `skills/mstack-run/scripts/manifest.sh`: add `check` subcommand for anomaly detection
- `skills/mstack-run/SKILL.md`: wire anomaly check after manifest update in Step 2

**Out of scope:** What happens when an anomaly is detected (plan 019 handles
the auto-handoff response). This plan detects and classifies; 019 responds.

Testing approach: unit-only

## Tasks

1. Add `check` subcommand to manifest.sh that reads the current manifest and evaluates all anomaly conditions
2. Implement iteration_bound check: compare iteration_count to length of scope_ids + 1
3. Implement repeat_pick check: compare last two entries in picked_history, verify the plan is not in terminal_ids
4. Implement no_progress check: store previous terminal_ids count in manifest (add `prev_terminal_count` field), compare after update
5. Implement path_divergence check: flag if any non-terminal plan's file path changed since manifest creation
6. Wire SKILL.md Step 2: after `manifest.sh update`, run `manifest.sh check`; if non-zero, capture reason and insert a TODO stub: `# ANOMALY DETECTED — plan 019 adds the auto-handoff handler here. For now, print the reason to stderr and exit the iteration.` This ensures SKILL.md is functional (exits cleanly on anomaly) even before plan 019 adds the full handoff handler

## Verification

Checks:
- [assert] grep -cE "iteration_bound|repeat_pick|no_progress|path_divergence" skills/mstack-run/scripts/manifest.sh | awk '{print ($1 >= 4) ? "PASS" : "FAIL"}' | grep PASS
- [cmd] grep -qE "manifest.sh check|anomaly" skills/mstack-run/SKILL.md
