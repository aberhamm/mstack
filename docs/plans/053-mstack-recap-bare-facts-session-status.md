---
id: 053
title: mstack recap — answer four questions about this session in plain language
status: pending
blocked-by: []
priority: 35
goal: mstack-session-legibility
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-30
---

## Requirements

When Matthew has been working in one session for hours, or comes back to it cold,
he needs four facts and nothing else:

1. **What are we working on?**
2. **What did we accomplish?**
3. **What's left?**
4. **Is this session done — is it safe to close?**

He asked for this in his own words: *"sometimes Claude speaks complexly and I
don't understand. I really just need the bare facts."* That sentence is the
acceptance criterion for the output format, not a stylistic aside.

Nothing today answers those four questions about **this session**.
`/mstack-status` reports on the *backlog* — plan states, health trends, open
reviews — which is a different question. `/mstack-handoff` produces the right
content but is terminal and expensive: it is designed for leaving, not for
orienting mid-flight. `/mstack-checkpoint` is post-plan facts for crash recovery.
`/mstack-stash` parks an unresolved thread. Four adjacent artifacts, none of which
a person can run mid-session to get their bearings in five seconds.

### The simplification that makes this cheap

An earlier design had sessions persisting a JSON "status card" that readers would
consume. **This plan does not need that**, and the distinction is load-bearing:

- A session answering questions **about itself** already has the answers in its
  own context. No storage, no schema, no hook, no staleness problem.
- Persistence is only required to let *another* process read a session **without
  waking it** — which is a fleet-view requirement, not this one.

So `mstack recap` is live and in-session, and it ships without any new state.
If the fleet reader is built later it can reuse the four questions; it does not
need to exist first, and this plan must not grow a dependency on it.

## Design

`/mstack-recap` (aliases: `recap`, `status report`) prints a fixed-shape report.

```
RECAP — cctrl fleet manager
Working in ~/dev/cctrl for about 6 hours.

WORKING ON
  Reviewing cctrl plans 035-037 and checking all 23 sessions.

DONE
  - Pushed 4 commits to cctrl
  - Re-reviewed plans 035/036/037 (all sent back with changes)
  - Inspected all 23 sessions

LEFT
  - npm token needs rotating (yours)
  - KLAC buy decision before 15:30
  - radar repo exposure undecided

READY TO CLOSE?  No
  Would lose: 12 open decisions that aren't written down anywhere.

MACHINE CHECK
  Uncommitted: 2 files   Unpushed: 1 commit   Context: 62%   Tests: not run
```

**Plain language is enforced by the format, not requested in prose.** The skill
imposes hard limits, because an instruction to "be concise" reliably loses to a
model's default verbosity:

- Each bullet is **one line, ≤ 100 characters**. No sub-bullets, ever.
- **Maximum 5 bullets** per section. If there are more, the 5 that matter and a
  `(+N more)` counter — deciding what matters is the work.
- `WORKING ON` is **one sentence**.
- No jargon, no internal codenames, no `file.ts:42` citations, no metrics, no
  hedging clauses. A reader who was not present must understand every line.
- The whole report fits on one screen. If it does not, it is wrong.

**Two halves, different trust levels.** Everything above `MACHINE CHECK` is the
session's own account of itself. `MACHINE CHECK` is measured. They are visually
separated because the session's account can be sincerely wrong — on 2026-07-28 a
session that deleted 44 GB against an explicit prohibition would have accurately
written "reclaimed 44 GB of caches" while omitting that nobody authorized it.

**`READY TO CLOSE?` must state what would be lost.** That is the only question
that decides it, and it is answered from the conversation, not from git. On
2026-07-28 a clean tree plus a confident label would have closed a session
holding the only copy of a generated passphrase, and another holding an
unplaced real-money order spec. Both were saved only because someone read the
thread. Permitted answers: `Yes`, `No`, or `Blocked on you` — and `Yes` requires
the `Would lose:` line to say `nothing — everything is written down`.

**Contradiction is surfaced, not smoothed.** If the session claims
`READY TO CLOSE? Yes` while the machine check shows uncommitted files, unpushed
commits, or context above 80%, the report prints a `DISAGREEMENT` line naming the
conflict. The reader is not allowed to resolve it silently in either direction.

**Machine check** is cheap and local: `git status --short` and unpushed count
(skipped with `not a git repo` where there is none — the Obsidian vault is not a
repo, and a session once "recovered" deleted content from git history that did not
exist), context percentage, and whether the project's test command has been run
this session. It shells out to `cctrl` for session-level facts **only if cctrl is
present**, and degrades silently otherwise; mstack must not hard-depend on it.

## Tasks

1. Author `skills/mstack-recap/SKILL.md`: the four questions, the fixed output
   shape, and the hard limits above stated as rules the skill must obey.
2. Machine-check helper script: git state, unpushed count, non-repo handling,
   context percentage, test-run detection. Pure read-only.
3. Contradiction rules: the exact conditions that emit `DISAGREEMENT`.
4. Register `recap` / `status report` phrasings in the routing rules so the user
   does not have to remember a slash command.
5. Add one line to `/mstack-status` and `/mstack-handoff` pointing at recap for
   the "where am I right now" question, so the four skills stop overlapping by
   accident.

## Verification

- `[cmd]` Output-shape test against a fixture: all four sections present, no
  bullet over 100 chars, no section over 5 bullets, no nested bullets.
- `[cmd]` A fixture with 9 completed items renders exactly 5 plus `(+4 more)`.
- `[cmd]` `READY TO CLOSE? Yes` with a dirty tree emits `DISAGREEMENT`; with a
  clean tree it does not. Both asserted.
- `[cmd]` `READY TO CLOSE? Yes` with `Would lose:` anything other than the
  nothing-is-at-risk form fails validation.
- `[cmd]` In a directory that is not a git repo, the machine check reports
  `not a git repo` and the command still succeeds.
- `[cmd]` With `cctrl` absent from `PATH`, recap still runs.
- `[manual]` Run it in a session at >300k context that has been going for hours,
  and confirm a reader who was not present can state the four answers back. This
  is the real test and it cannot be automated: the failure mode is a report that
  is accurate and still incomprehensible.

## Notes

Honest limitation, recorded so it is not rediscovered as a bug: **"what did we
accomplish" is the softest field and always will be.** A session can measure
commits and files touched; it cannot measure whether the work was *wanted*. Any
close decision resting on that field inherits the softness — which is exactly why
`READY TO CLOSE?` requires the `Would lose:` line and why `DISAGREEMENT` exists.

Deferred deliberately: the persisted status card and the `cctrl fleet status`
reader that would consume it. The case for those rests on a single unusual night
(24 sessions, two frozen on dialogs, one 44 GB deletion, a credential scan that
silently returned false-clean twice). That is a rich sample but one sample. Ship
recap, use it for a week, and let the evidence decide whether reading 24 cards
without waking anyone is a real need or a monument to one Tuesday.

Related: cctrl plan 038 enforces session policy at the tool boundary. Independent
of this plan; do not couple them.
