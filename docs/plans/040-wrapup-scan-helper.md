---
id: 040
title: wrapup-scan.sh — deterministic read-only mechanical session scan
status: in-progress
blocked-by: []
priority:
goal: wrap-up-skill
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-14
reviews:
  - type=eng verdict=approved date=2026-07-14 by=mstack-review
---

## Requirements

The upcoming `mstack-wrap-up` skill (plans 041/042) needs a "Pass B" mechanical
scan: the deterministic, cold-runnable half of a session wrap-up that finds
leftover mess in the working tree(s). Today the only implementation of this
idea is inline prose in `mstack-handoff`'s "Pre-handoff artifact check"
(`skills/mstack-handoff/SKILL.md:236`), which each agent re-improvises from a
bullet list. That duplicates poorly and will drift the moment a second skill
(wrap-up) needs the same checks.

This plan extracts the scan into a shared deterministic helper,
`skills/mstack-run/scripts/wrapup-scan.sh`, per house style ("deterministic
shell scripts for behavior that should survive across agents"), and points
`mstack-handoff`'s artifact-check prose at it so the pattern list lives in
exactly one place.

**Acceptance criteria:**

- [ ] New `skills/mstack-run/scripts/wrapup-scan.sh` exists, sources `lib.sh`
      with the repo-root-relative `# shellcheck source=skills/mstack-run/scripts/lib.sh`
      directive, is **executable** (`chmod +x` — skills resolve helpers with
      `[ -x ]` checks, so a 0644 script silently fails resolution), and is
      strictly read-only (no command in the script mutates git state or the
      filesystem beyond mktemp-style scratch usage).
- [ ] Scans and reports these sections per repo: (1) uncommitted paths via
      `lib.sh porcelain_paths` (never a hand-rolled `awk '{print $2}'` parse);
      (2) likely artifacts among UNTRACKED files matching `*.tmp`, `*.bak`,
      `*.orig`, `test-*`, `debug-*`, `*.log` — note `porcelain_paths` strips
      the XY status prefix and emits paths only, so this section must do its
      own `git status --porcelain -uall -z` parse that PRESERVES the `??`
      status (same NUL-safe `read -r -d ''` style as `_porcelain_split` in
      `lib.sh`, never awk) to distinguish untracked from tracked-dirty;
      (3) `git stash list` entries;
      (4) local branches merged into the default branch but not deleted
      (excluding the default branch and current branch); (5) unpushed commits
      across ALL local branches (via `git for-each-ref` ahead counts for
      every branch with an upstream — not just the current branch, so
      side-branch work can't produce a false all-clear; a branch with no
      upstream is reported as `upstream=none`, not silently skipped).
- [ ] Accepts zero or more repo-path arguments; zero args means the current
      repo (`git rev-parse --show-toplevel` from `$PWD`). Every report line is
      attributable to a repo (a `repo=<path>` header precedes each repo's
      sections), so multi-repo output never mixes findings anonymously.
- [ ] An UNREADABLE git status (porcelain_paths nonzero, e.g. corrupt repo or
      permission failure) fails loud for that repo — a per-repo error line,
      never a "clean"/empty-findings print (same fail-closed doctrine as the
      non-git case and lib.sh's porcelain_paths contract).
- [ ] A non-git target path fails LOUD: prints
      `mechanical check unavailable: <path> is not a git repository` to stderr
      and exits with a dedicated exit code that does not collide with existing
      codes 10–19 (pick-next), 20 (seam-check), 21–22 (resolve_plan_ref),
      23–28 (review-gate). It must never print a "clean" result for a non-git
      target. With multiple targets, it still scans the valid ones, then exits
      with the error code.
- [ ] Machine-parseable output, contract PINNED (not worker-invented):
      per repo, a `repo=<path>` header; then one section header line per
      section in fixed order — `section=uncommitted count=<n>`,
      `section=artifacts count=<n>`, `section=stashes count=<n>`,
      `section=merged-branches count=<n>`, `section=unpushed count=<n>` —
      each followed by its entries as RAW values on their own
      two-space-indented lines (paths are never embedded in `key=value`
      pairs, so spaces/`=` in paths cannot break parsing); then a final
      `findings=<N>` line where N = total entry count across all sections.
      Branch-derived sections carry a `local-refs-only` marker (no fetch is
      ever performed). Exit 0 means "scan completed" whether or not findings
      exist (findings are data, not an error); on a multi-target run with an
      invalid target, stdout remains complete and valid for every scanned
      repo even though the exit code is nonzero — callers parse stdout
      regardless, exit code reflects input errors only.
- [ ] `mstack-handoff`'s "Pre-handoff artifact check" section is rewritten to
      invoke `wrapup-scan.sh` (resolved via the same four-path skill-base loop
      already used for `handoff.sh`) instead of restating the porcelain /
      pattern / stash steps inline. The reporting format shown to the user in
      the handoff flow is unchanged.
- [ ] A smoke script `skills/mstack-run/scripts/wrapup-scan-smoke.sh` (same
      pattern as `plan-ref-smoke.sh` / `review-gate-smoke.sh`) builds a
      throwaway git fixture (dirty file, `*.tmp` artifact, a stash, a merged
      branch) plus a non-git dir, and asserts section output and exit codes.
      The fixture also includes a local BARE repo wired as `origin` (push
      once, commit again) so the unpushed-commits count AND the
      `upstream=none` fallback are both exercised — no scan section ships
      unverified.
- [ ] `bash -n` and `shellcheck` pass on the new scripts (the canonical
      `shellcheck skills/mstack-run/scripts/*.sh` gate).

## Design

Single new script + one prose edit. The script is the deterministic floor the
wrap-up skill's subagent will run; it must be safe to run cold in any repo at
any time (no session context, no state files, no side effects).

```
args (repo paths, default $PWD's repo)
  │  per target, in order
  ▼
[not a git repo?] ──yes──▶ stderr "mechanical check unavailable" ─▶ mark exit=EXIT_SCAN_NOT_GIT
  │ no                                                              (keep scanning other targets)
  ▼
repo=<path>
  ├─ section=uncommitted      ◀─ porcelain_paths (paths only)
  ├─ section=artifacts        ◀─ own -z parse, ?? entries only, pattern match
  ├─ section=stashes          ◀─ git stash list
  ├─ section=merged-branches  ◀─ git branch --merged <default>   [local-refs-only]
  ├─ section=unpushed         ◀─ git for-each-ref ahead counts   [local-refs-only]
  └─ findings=<N>             (total entries; git-status read failure anywhere
                               ⇒ loud per-repo error, NEVER a "clean" print)
```

**Files expected to change:**

- `skills/mstack-run/scripts/wrapup-scan.sh`: new. Argument loop over repo
  paths; per-repo section emitters; sources `lib.sh` for `porcelain_paths`,
  `die`, and the exit-code constants.
- `skills/mstack-run/scripts/lib.sh`: add the new exit-code constant (e.g.
  `EXIT_SCAN_NOT_GIT=29`) next to the existing 23–28 block so the reserved
  ranges stay documented in one place.
- `skills/mstack-run/scripts/wrapup-scan-smoke.sh`: new smoke fixture script.
- `skills/mstack-handoff/SKILL.md`: "Pre-handoff artifact check" section
  becomes a call to `wrapup-scan.sh` + interpretation guidance; drop the
  now-duplicated inline pattern list.

Notes and edge cases:

- Two porcelain consumers, deliberately: the uncommitted-paths section reuses
  `porcelain_paths` (path set only); the artifact section needs the status
  prefix and parses the `-z` stream itself, keeping only `??` entries before
  pattern-matching. Do not "simplify" these into one path-only pass — that
  reintroduces the untracked/tracked ambiguity.
- Merged-branch detection: derive the default branch from
  `git symbolic-ref refs/remotes/origin/HEAD` falling back to `main`/`master`
  detection; `git branch --merged <default>` minus default and current branch.
  In a detached-HEAD or no-remote repo, degrade to reporting what is knowable
  rather than erroring.
- Unpushed commits: `git rev-list --count @{upstream}..HEAD` guarded for the
  no-upstream case. Report only — this script never pushes (wrap-up doctrine:
  the fleet manager sequences pushes).
- Artifact patterns apply to UNTRACKED files only (a tracked `debug-*.sh` is
  someone's deliberate file, not session litter). The patterns are advisory
  heuristics: the consuming layer (handoff prose / wrap-up subagent)
  classifies matches as litter vs deliberate, and NOTHING is ever
  auto-deleted — a false positive costs one report line, not a file.
- "Read-only" means: no command intentionally mutates repo state (no add/
  commit/fetch/push/stash mutations); incidental index refreshes by plain
  git queries are acceptable.
- The script is the single COMMITTABLE home of the pattern list; smoke
  assertions and prose necessarily reference it, so "one place" means one
  authoritative definition, not zero other mentions.
- bash 3.2 compatible (macOS default), like the rest of `scripts/`.
- Worktree paths are valid targets (porcelain works normally there);
  enumerating a repo's OTHER worktrees / submodules is out of scope.

Testing approach: unit-only

**Out of scope:** the `mstack-wrap-up` skill itself (041/042); any change to
`handoff.sh`; deleting/cleaning anything the scan finds (the scan only ever
reports); pushing or fetching; `cctrl-session-end` (external repo).

## Tasks

1. Add `EXIT_SCAN_NOT_GIT` to `lib.sh` beside the existing exit-code
   constants, with a comment noting the reserved ranges.
2. Write `wrapup-scan.sh`: arg parsing (0+ repo paths, default current repo),
   non-git detection, then per-repo emitters for uncommitted / artifacts /
   stashes / merged-branches / unpushed, each on the stable `key=value`
   format, ending with `findings=<N>`.
3. Write `wrapup-scan-smoke.sh` building the git fixture (incl. a local bare
   `origin`: push once, commit again — covers unpushed-count and
   `upstream=none`) + non-git dir and asserting: section lines present,
   artifact pattern matching (include an artifact filename CONTAINING A
   SPACE, e.g. `debug notes.log`, to prove the NUL-safe parse end-to-end),
   stash count, merged-branch listed, unpushed count, non-git exit code,
   exit 0 on a clean repo.
4. Rewrite `mstack-handoff` "Pre-handoff artifact check" to resolve and run
   `wrapup-scan.sh`, keeping the user-facing "Cleanup check:" output format.
5. Run `bash -n` + `shellcheck` on all touched scripts and the smoke script
   end-to-end.

## Verification

Checks:
- [cmd] bash -n skills/mstack-run/scripts/wrapup-scan.sh skills/mstack-run/scripts/wrapup-scan-smoke.sh
- [cmd] shellcheck skills/mstack-run/scripts/wrapup-scan.sh skills/mstack-run/scripts/wrapup-scan-smoke.sh
- [cmd] bash skills/mstack-run/scripts/wrapup-scan-smoke.sh
- [assert] bash skills/mstack-run/scripts/wrapup-scan.sh 2>&1 | grep -q 'findings=' — scan of this repo completes and emits a summary line
- [assert] bash skills/mstack-run/scripts/wrapup-scan.sh /tmp 2>&1; test $? -ne 0 && echo LOUD — non-git target exits nonzero (assert output contains LOUD)
- [assert] grep -q 'wrapup-scan.sh' skills/mstack-handoff/SKILL.md — handoff artifact check delegates to the shared script
- [assert] ! grep -qE '^\s*-\s*`\*\.tmp`' skills/mstack-handoff/SKILL.md || grep -q 'wrapup-scan.sh' skills/mstack-handoff/SKILL.md — inline pattern list no longer the source of truth

<!-- mstack:seam
produced:
- kind: file; name: skills/mstack-run/scripts/wrapup-scan-smoke.sh; file: skills/mstack-run/scripts/wrapup-scan-smoke.sh
- kind: file; name: skills/mstack-run/scripts/wrapup-scan.sh; file: skills/mstack-run/scripts/wrapup-scan.sh
- kind: symbol; name: EXIT_SCAN_NOT_GIT; file: skills/mstack-run/scripts/lib.sh
assumed:
- kind: symbol; name: porcelain_paths; file: skills/mstack-run/scripts/lib.sh
-->

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | ISSUES_FOUND (outside voice) | 15 raised → 3 adopted, 5 mechanical fixes, 7 rejected with rationale |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 3 issues, 0 critical gaps — all folded into plan |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **CODEX:** outside voice raised output-contract looseness, current-branch-only unpushed scan, and test-gap points — adopted (2A/3A/1A); premature-extraction and wrong-home critiques rejected (handoff dedup makes two real consumers; scripts/ location is documented repo convention).
- **CROSS-MODEL:** both reviewers agree the plan is implementable once the output contract is pinned; no unresolved tension.
- **VERDICT:** ENG CLEARED — ready to implement.

NO UNRESOLVED DECISIONS
