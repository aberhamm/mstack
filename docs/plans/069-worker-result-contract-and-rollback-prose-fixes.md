---
id: 069
title: Worker result-contract and rollback prose fixes
status: pending
blocked-by: []
priority: 11
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

The worker prompt (`skills/mstack-run/references/subagent-prompt.md`) and the
orchestrator (`skills/mstack-run/SKILL.md`) contradict each other in ways that
convert correct worker behavior into wrong outcomes. Worst case: the prompt
tells the worker to "Print RESULT:BLOCKED / RESULT:FAIL and stop" (lines 47,
79, 87, 103, 111), but the ONLY contract the orchestrator parses is the
`---MSTACK-RESULT---` block (lines 160-173), and SKILL.md lines 759-761 treat
a missing result block as `status: failed` + `failed-reason: agent-error` — so
an obedient worker stopping early converts a BLOCKED plan into a FAILED one.
Alongside that: rollback recipes that cannot restore deleted files, stale step
numbering, a hard rule that contradicts the sanctioned amend, residual
"3-strike" phrasing from before the 9-strike model, and an advertised review
mode that never runs on the autonomous path.

**Acceptance criteria**

- [ ] Every `RESULT:BLOCKED` / `RESULT:FAIL` shorthand in subagent-prompt.md
      (lines 47, 79, 87, 103, 111) is replaced with "emit the full
      `---MSTACK-RESULT---` block with `STATUS: blocked` (or `STATUS: fail`
      plus `FAILED_REASON`) and stop".
- [ ] DELETED-file rollback: both revert recipes — subagent-prompt.md STEP C
      (lines 76-77: `git checkout HEAD -- <MODIFIED minus PRE_DIRTY>` /
      `rm -f <CREATED>`) and SKILL.md Step 7b (lines 1078-1082) — gain
      `git checkout HEAD -- <DELETED>` so files a plan deleted are restored.
- [ ] SKILL.md Step 7a line 942 `status: pending` → `status: done` becomes
      `status: in-progress` → `status: done` (the plan was claimed in-progress
      at Step 2, lines 494-496).
- [ ] The "Full linear order" summary (SKILL.md lines 789-799) is renumbered:
      today it runs 0,1,2,3,4,5,6,6b,8,9 — skipping 7 — and must match the
      detailed step list without gaps.
- [ ] Hard rule at SKILL.md lines 56-57 ("Never amend or rebase prior commits.
      Each iteration is a single forward commit") is rephrased to permit
      exactly the sanctioned hash-backfill `git commit --amend --no-edit` of
      the just-created commit (lines 996-998), and nothing else.
- [ ] Residual "3-strike" phrasing is normalized to the category-aware model:
      SKILL.md line 53 ("3-strike rule"), health-gate-spec.md line 85
      ("3 strikes exhausted"), mstack-investigate/SKILL.md line 61 ("all 3
      strikes are exhausted") and line 221 (`Strikes used: <N/3>` →
      `<N/9 (M/3 categories)>`)
- [ ] Step 3d blocked branch (SKILL.md lines 744-745) "continue to Step 8
      (next plan, don't stop the loop)" no longer contradicts the
      one-plan-per-iteration rule (lines 39-41) — reworded to "signal Step 8;
      `/goal` picks the next plan in a fresh iteration".
- [ ] All three exit-10 sites (SKILL.md table row 393, case arm 407-410, prose
      467-469) mention the final validation pass that Step 8 requires (lines
      1200-1204), not just "simplify pass + completion notification".
- [ ] `review: adversarial` (defined by mstack-code-review SKILL.md lines
      84-137) gains a branch in subagent-prompt.md STEP D (lines 151-153,
      today only standard/thorough) and references/review-spec.md (lines
      18-24), so the mode actually runs on the autonomous path.

## Design

Pure prose edits; no scripts change. Each edit is pinned by the current
wording quoted above — verify the quote is still at the cited line before
editing (the files are actively worked). The adversarial branch in
subagent-prompt/review-spec should summarize mstack-code-review's own
definition (standard reviewer + blind adversarial reviewer, external-model
routing when available) rather than restating the full prompt.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/references/subagent-prompt.md`: result-block wording,
  DELETED rollback, adversarial branch
- `skills/mstack-run/SKILL.md`: 7b rollback, 7a transition, linear order,
  amend rule, strike phrasing, Step 3d, exit-10 sites
- `skills/mstack-run/references/health-gate-spec.md`: strike phrasing
- `skills/mstack-run/references/review-spec.md`: adversarial branch
- `skills/mstack-investigate/SKILL.md`: strike phrasing

**Out of scope:** changing the result-block schema or the orchestrator's
parser (`result-gate.sh`); changing mstack-code-review itself; renumbering
SKILL.md's actual step headings (only the summary list is wrong).

## Tasks

1. Replace the five RESULT:X shorthands in subagent-prompt.md.
2. Add DELETED handling to both revert recipes (STEP C, Step 7b).
3. Fix the Step 7a status transition and renumber the Full linear order.
4. Rephrase the never-amend hard rule to carve out the hash-backfill amend.
5. Normalize the four residual 3-strike mentions to the 9-strike model.
6. Reword Step 3d's blocked branch and add final-validation to the three
   exit-10 sites.
7. Add the `review: adversarial` branch to STEP D and review-spec.md.

## Verification

Checks:

- [cmd] `! grep -n 'RESULT:BLOCKED\|RESULT:FAIL' skills/mstack-run/references/subagent-prompt.md`
- [cmd] `awk '/^STEP C: /,/^STEP C2:/' skills/mstack-run/references/subagent-prompt.md | grep -q 'DELETED'`
- [cmd] `grep -q 'DELETED' skills/mstack-run/SKILL.md && awk '/### 7b/,/^---$/' skills/mstack-run/SKILL.md | grep -q 'DELETED'`
- [cmd] `grep -q 'in-progress.*→.*done\|in-progress. → .status: done' skills/mstack-run/SKILL.md`
- [cmd] `! grep -n '3-strike rule' skills/mstack-run/SKILL.md`
- [cmd] `! grep -n 'all 3 strikes' skills/mstack-investigate/SKILL.md`
- [cmd] `grep -q 'adversarial' skills/mstack-run/references/review-spec.md`
- [cmd] `grep -q 'adversarial' skills/mstack-run/references/subagent-prompt.md`
- [cmd] `! grep -n "don't stop the loop" skills/mstack-run/SKILL.md`

## Backlog amendment (2026-07-31)

This plan now ABSORBS plan 071 (routing and stale-prose cleanup),
which is skipped as folded. Both are prose-only sweeps over skill files with
no scripts and no execution risk; running them as one pass avoids a second
full gate-review-commit-tag cycle for twelve one-site edits.

Carry over from 071, highest value first:
- `mstack-plan-multi/SKILL.md:347` reads "Never suggest `all pending mstack
  plans are done or failed`" — that is the framework flagship command per
  `README.md:41`. Delete the prohibition.
- "review the backlog" is a declared trigger in BOTH
  `mstack-plan-doctor/SKILL.md:12` and `mstack-backlog/SKILL.md:10` while
  `AGENTS.md:37` routes it to backlog. Resolve the collision.
- `mstack-stash` derives `NEXT_NUM` from `wc -l` of the stash directory, so
  it overwrites an existing stash after any delete. This is data loss, not
  prose.
- `mstack-simplify-code/SKILL.md` is described DEPRECATED but is 193 lines of
  fully operational legacy flow.
- `plan-template.md:3,12` still says `plans/NNN-slug.md` and "becomes branch
  name and PR title" in a workflow with no branches and no PRs.
- `mstack-status` update check probes a path that does not exist under
  skillshare per-skill layout, and swallows the failure with `|| true`.
