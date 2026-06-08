---
id: 025
title: Harden handoff discovery and resume reliability
status: in-progress
blocked-by: []
priority: 25
goal: handoff-reliability
allows-migrations: false
needs-review: none
created: 2026-06-08
---

## Requirements

MStack handoff checkpoints are useful only if agents can reliably find them,
resume them, and stop autonomous loops with enough context when something goes
wrong. Today the behavior is mostly documented in skill prose, while discovery
across project `.mstack/handoffs/` directories and resume cleanup are manual and
easy to miss.

**Acceptance criteria**

- [ ] `mstack-handoff` can list handoff checkpoints for the current repo and, when invoked in all-projects mode, across known project roots without scanning `.git` or `node_modules`.
- [ ] Discovery follows symlinked project roots such as `/Users/matthew/_projects -> /Users/matthew/dev/projects`.
- [ ] Listing output shows each checkpoint path, age, short summary, and the exact `resume from handoff <summary>` command.
- [ ] Empty handoff directories are reported separately from projects that have no `.mstack/handoffs/` directory.
- [ ] Resume lookup is deterministic: no name resumes the newest checkpoint in the current repo; a provided short summary must match exactly one checkpoint or report the ambiguity.
- [ ] Resume mode prints the checkpoint context, deletes only the resumed checkpoint, and does not start work automatically.
- [ ] The anomaly checkpoint writer used by `mstack-run` is implemented as a shell helper with focused tests, not as a large inline heredoc in `SKILL.md`.
- [ ] The existing `[mstack] ANOMALY:` terminal signal and `.mstack/execution-manifest.json` preservation behavior remain unchanged.
- [ ] `skills/mstack-run/scripts/handoff.sh self-test` exercises discovery, resume deletion, ambiguity handling, and anomaly checkpoint creation using temporary fixtures.

## Design

Add a deterministic handoff helper script and make both `mstack-handoff` and
`mstack-run` call it instead of relying on hand-written shell snippets embedded
in skill prose. Keep the user-facing `/mstack-handoff` name unchanged.

The helper should support these operations:

- `list`: list current-repo checkpoints.
- `list --all-projects`: scan known project roots, following symlinks and
  pruning `.git`, `node_modules`, `.pnpm`, and obvious build output.
- `resolve [short-summary]`: return the checkpoint selected for resume, with
  clear non-zero exits for no match and ambiguous match.
- `resume [short-summary]`: print checkpoint contents and delete the selected
  file after a successful read.
- `write-anomaly`: write the anomaly checkpoint currently generated inline by
  `mstack-run`, preserving filename format and recovery suggestions.
- `prune`: delete stale handoff checkpoints older than 7 days.
- `self-test`: create temporary fixture repos and validate the helper behavior
  without touching real `.mstack/handoffs/` files.

Project-root discovery should prefer:

- Current git root.
- `$HOME/_projects` if present.
- `$HOME/dev/projects` if present.

It must deduplicate paths after resolving symlinks, so `_projects` and
`dev/projects` do not produce duplicate results.

**Files expected to change:**

- `skills/mstack-run/scripts/handoff.sh`: new deterministic helper for listing,
  resolving, resuming, pruning, anomaly checkpoint writing, and self-tests.
- `skills/mstack-handoff/SKILL.md`: replace inline list/resume/prune shell
  guidance with calls to the helper; document list mode and all-projects mode.
- `skills/mstack-run/SKILL.md`: replace the inline anomaly handoff writer with a
  call to `handoff.sh write-anomaly`.
- `skills/mstack-run/references/progress-format.md`: keep the anomaly signal
  documented if output text changes.
- `README.md`: document handoff discovery and resume behavior.

Testing approach: shell-only helper self-test plus existing shell syntax and
shellcheck gates.

**Out of scope:**

- Renaming `mstack-run` or any other skill.
- Changing the `/mstack-handoff` command name.
- Changing normal checkpoint behavior in `mstack-checkpoint`.
- Adding a new persistent registry of projects.

## Tasks

1. Add `skills/mstack-run/scripts/handoff.sh` with shell-safe subcommands for
   `list`, `resolve`, `resume`, `prune`, `write-anomaly`, and `self-test`.
2. Add fixture-style tests or smoke checks for:
   - listing a current-repo handoff,
   - all-project discovery with a symlinked root,
   - exact resume deletion,
   - ambiguous short-summary rejection,
   - anomaly handoff file creation and progress output.
3. Update `mstack-handoff` instructions to call the helper for prune, list, and
   resume paths.
4. Update `mstack-run` anomaly handling to call the helper and preserve the
   existing terminal output contract.
5. Update README documentation for handoff discovery and anomaly resume.

## Verification

Checks:

- [cmd] bash -n skills/mstack-run/scripts/*.sh bin/mstack-update-check setup
- [cmd] shellcheck skills/mstack-run/scripts/*.sh bin/mstack-update-check setup
- [assert] skills/mstack-run/scripts/handoff.sh --help | grep -E 'list|resume|write-anomaly'
- [cmd] skills/mstack-run/scripts/handoff.sh self-test
- [assert] rg -n "handoff.sh (list|resume|write-anomaly)" skills/mstack-handoff/SKILL.md skills/mstack-run/SKILL.md
- [assert] rg -n "ANOMALY:|resume from handoff|handoff discovery" README.md skills/mstack-run/references/progress-format.md
