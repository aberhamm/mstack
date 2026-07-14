---
id: 043
title: health gate must never silently no-op — fix the detector and the missing crash branch
status: in-progress
blocked-by: []
priority:
goal:
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-14
reviews:
  - type=eng verdict=approved date=2026-07-14 by=mstack-review
---

## Requirements

The health gate has never run in this repository, and when it crashed, the worker
reported success anyway. Both halves matter; the second is the real bug.

**What actually happened, verified against source** (an earlier draft misdiagnosed
this; the adversarial audit refuted the original causal story):

1. **The detector finds nothing.** The `shell` detector globs
   `find "$ROOT" -maxdepth 3 -name '*.sh'` (`health-check.sh:129`), but mstack keeps
   its scripts at depth 4 (`skills/mstack-run/scripts/`). It matches zero files.
2. **So `cmd_run` dies.** With no tools detected it calls
   `die "no health check tools detected"` (`health-check.sh:143`), exiting 1
   (`lib.sh:612`) having printed **no `VERDICT` line at all**.
3. **And the worker invents a passing verdict.** `subagent-prompt.md:56-67` tells the
   worker to parse `VERDICT`/`COMPOSITE` and gives it exactly two branches: `PASS` →
   continue, `FAIL`/`REGRESSED` → investigate. **There is no branch for "the command
   exited nonzero / emitted no VERDICT."** Faced with a crash and no branch to take,
   the LLM worker improvised `HEALTH_VERDICT: SKIP` — not even a legal value — and
   Step 7a accepted the plan as passing. `.mstack/health-history.jsonl` begins at
   `plan_id: "040"`, confirming no plan before it ever scored.

**The generalizable defect is (3), not (1).** A missing error branch means *any*
health-check crash — a missing binary, malformed config, a syntax error in a tool
command — gets papered over by a worker improvising success. The `-maxdepth` bug is
merely what tripped it. Fixing only the detector leaves the swallow-the-crash path
armed for the next cause.

**And the fix for (3) must not itself be prose.** The bug is "an LLM improvised around
an unhandled state." Patching it with *more instructions to the LLM* is the same
material that already failed. The parent (`mstack-run`) must **deterministically**
reject a malformed or non-passing health result, so a worker that improvises again is
caught by a parser rather than trusted.

**Acceptance criteria:**

- [ ] **The orchestrator deterministically rejects a bad health result.** `mstack-run`
      Step 7a must refuse to complete a plan whose result block carries a missing,
      unparseable, or non-`PASS` `HEALTH_VERDICT`, or a missing/unparseable
      `HEALTH_COMPOSITE`. `STATUS: pass` + anything other than `HEALTH_VERDICT: PASS`
      is incoherent and is rejected. **Note `REGRESSED` is NOT acceptable for success**
      — `subagent-prompt.md:60` routes it to the failure path, so admitting it at Step
      7a would contradict the worker's own contract. This check is the plan's spine:
      it is the only fix that does not depend on an LLM choosing to obey prose.
- [ ] **A crashed health gate is a hard failure, never a skip.** `subagent-prompt.md`
      Step C grows an explicit third branch: nonzero exit OR no parseable `VERDICT`
      ⇒ hard fail, revert, `RESULT:FAIL` with reason `health-gate-unavailable`. `SKIP`
      is explicitly not a legal `HEALTH_VERDICT` value. (Prose — but now backstopped by
      the deterministic check above, which is what actually enforces it.)
- [ ] **The `shell` detector finds this repo's own scripts.** With no `health.commands`
      configured, detection reports a `shell:` command covering
      `skills/mstack-run/scripts/*.sh` from this repo root.
- [ ] **Detection is layout-independent, and covers UNTRACKED files.** Raising
      `-maxdepth 3` to `4` fixes this repo and leaves the next one broken. But the naive
      `git ls-files '*.sh'` replacement is ALSO wrong: **workers never commit before the
      health gate runs** (`subagent-prompt.md:19-20`), so a `.sh` file the plan just
      CREATED is untracked and would evade shellcheck entirely — the gate would skip
      exactly the code under test. Detection must cover tracked AND untracked-but-present
      scripts (e.g. `git ls-files` unioned with `--others --exclude-standard`, or a
      depth-unbounded `find`).
- [ ] **The prune policy is defined, not inherited by accident.** A depth-unbounded scan
      must not start shellchecking `.git/`, build output, vendored code, submodules, or
      dependency directories not named `node_modules`. State what belongs to the repo's
      health surface. (Using git's own file list gets `.gitignore` semantics for free,
      which is a strong argument for it over `find`.)
- [ ] **Kill the `eval`, don't outquote it.** The detected file list is spliced into a
      command string later run through `eval` (`health-check.sh:166`), so any path with a
      space or shell metacharacter breaks or misexecutes. Quoting a generated list well
      enough to survive `eval` is brittle by construction. Run the detected shell files
      through an **argv array** (or make `shell` a dedicated runner path) instead of
      splicing filenames into a string. Prove it with a fixture whose filename has a space.
- [ ] **Zero-tools policy: BLOCK UNLESS DECLARED (eng review, D2 + D4).** Zero tools
      across ALL categories is **NOT completable** — unless the repo **explicitly declares
      it has none**, via a `- none:` entry in the **tracked** `## Health Stack` section of
      `AGENTS.md`/`CLAUDE.md`. Absent declaration reads as "not yet declared," never as
      "nothing required," and fails closed. An explicit declaration is honored and allows
      completion.

      **The declaration MUST live in tracked project guidance, NOT `.mstack/config.json`**
      — `.mstack/` is gitignored (`.gitignore:6`), so a declaration there is invisible,
      per-checkout, and vanishes on a fresh clone. That would make "explicit declaration"
      mean "whatever happened on this machine," which is the same invisible-state class the
      plan abolishes. `health-check.sh:80-93` **already parses** `## Health Stack` from
      `AGENTS.md`/`CLAUDE.md` as config source #2, so this reuses an existing reader rather
      than inventing a mechanism.

      **Rationale (record in AGENTS.md):** this mirrors the review-gate doctrine already in
      force — "ABSENT `review-required` ≠ empty required set... non-completable until
      backfilled." Config absence means undeclared, not empty. One rule, not two.
- [ ] **Exactly one key, one semantics.** Name the declaration key precisely and implement
      the reader for it; do not leave prose saying `health: none` while checks assert some
      other shape. `config.sh` has no such key today — add it or define the guidance-file
      form as the only form.
- [ ] **"Zero tools" ≠ "one empty category."** The alarming state is zero tools across ALL
      categories. A JS/TS repo detecting typecheck+lint+test must NOT signal no-tools merely
      because it has no `.sh` files.
- [ ] **Remove the `head -20` cap (eng review, D3).** `health-check.sh:129` truncates the
      file list to 20, so a repo with 21+ shell scripts silently lints only the first 20 and
      still reports PASS — the same bug class (success reported over work not done), merely
      partial rather than total. Drop it, or make any retained limit explicit and loud.
- [ ] Any new exit code avoids the reserved ranges: 10-19 (pick-next), 20 (seam-check),
      21-22 (resolve_plan_ref), 23-28 (review-gate), 29 (wrapup-scan) — `lib.sh:5-59`.
- [ ] `bash -n` and `shellcheck skills/mstack-run/scripts/*.sh` pass.

## Design

```
health-check.sh run
  │
  ├─ detect()  ──▶ config.health.commands
  │                └─▶ AGENTS.md ## Health Stack   ◀── `- none:` declaration lives HERE (tracked)
  │                    └─▶ auto-detect (layout-independent; tracked + untracked; no cap)
  │
  ├─ zero tools across ALL categories?
  │     ├─ declared `none` in guidance ──▶ warn, VERDICT:NONE-DECLARED, completable
  │     └─ NOT declared               ──▶ VERDICT:NO-TOOLS, NOT completable   (fail closed)
  │
  ├─ tools ran, crashed              ──▶ nonzero exit, no VERDICT
  │                                        └─▶ worker: hard fail (health-gate-unavailable)
  └─ tools ran, scored               ──▶ VERDICT:PASS | FAIL | REGRESSED
                                             │
             mstack-run Step 7a (DETERMINISTIC PARSE, the real enforcement) ◀────┘
               STATUS: pass  requires  HEALTH_VERDICT == PASS  and a parseable COMPOSITE.
               Anything else (missing, SKIP, NO-TOOLS, REGRESSED, garbage) ⇒ REJECT.
```

**Files expected to change:**

- `skills/mstack-run/SKILL.md`: Step 7a deterministic health-result validation (the spine);
  Step 5 surfaces the no-tools state.
- `skills/mstack-run/references/subagent-prompt.md`: the crashed-gate branch; `SKIP` illegal.
- `skills/mstack-run/scripts/health-check.sh`: layout-independent detection (tracked +
  untracked, no cap, defined prunes); argv array instead of `eval`-spliced string; the
  NO-TOOLS / NONE-DECLARED verdicts replacing the bare `die`.
- `AGENTS.md`: the `## Health Stack` `none:` declaration form, the zero-tools policy, and
  the rationale tying it to the review-required doctrine.

Notes and edge cases:

- **This repo currently MASKS the bug** via explicit `health.commands` in its gitignored
  `.mstack/config.json` (written during plan 040). Any verification of the DETECTOR must
  neutralize or bypass that config, or the detector path is never exercised and the fix
  cannot be proven. **This is the single most likely way for a worker to produce a false
  pass on this plan.**
- Do NOT "fix" this by writing `health.commands` into a committed config. That papers over
  the detector for one repo and leaves the swallow-the-crash class intact everywhere.
- A verification check that only greps for a string proves the string exists, not that the
  behavior happens. Where behavior is executable, assert the **exit code** and the actual
  state, not the presence of text.

Testing approach: unit-only

**Out of scope:** health WEIGHTS and scoring math; new tool categories; the `-maxdepth 1`
globs in the typecheck/lint/e2e detectors (those legitimately expect root-level config
files); retrofitting health scores onto archived plans 031-039.

## Tasks

1. Reproduce both failures in a scratch fixture: a repo whose scripts sit deeper than 3
   levels detects zero tools; the resulting nonzero exit has no branch in Step C.
2. **Add the deterministic Step 7a health-result validation to `mstack-run`** (reject
   missing/unparseable/non-`PASS` verdict on a `pass` result). Do this FIRST — it is the
   enforcement that does not depend on prose.
3. Add the crashed-gate branch to `subagent-prompt.md` Step C; make `SKIP` explicitly illegal.
4. Replace the `shell` detector: layout-independent, covers tracked AND untracked scripts,
   defined prune policy, no `head` cap.
5. Replace the `eval`-spliced command string with an argv array for the shell runner.
6. Replace the bare `die` with `VERDICT:NO-TOOLS` (not completable) and
   `VERDICT:NONE-DECLARED` (declared, completable), gated on zero-across-ALL-categories, with
   the declaration read from the tracked `## Health Stack` guidance section.
7. Document the policy, the declaration form, and the rationale in AGENTS.md.
8. Verify against fixtures: deep-nested untracked script; spaced filename; 25 scripts;
   zero-tools undeclared; zero-tools declared; partial-categories.

## Verification

Checks:
- [cmd] bash -n skills/mstack-run/scripts/health-check.sh
- [cmd] shellcheck skills/mstack-run/scripts/*.sh
- [assert] grep -qiE 'exits? nonzero|no parseable VERDICT|health-gate-unavailable' skills/mstack-run/references/subagent-prompt.md — the crashed-gate branch exists
- [assert] ! grep -q 'HEALTH_VERDICT: SKIP' skills/mstack-run/references/subagent-prompt.md — SKIP is not a legal verdict
- [assert] grep -qiE 'HEALTH_VERDICT' skills/mstack-run/SKILL.md && grep -qiE 'reject|refuse' skills/mstack-run/SKILL.md — Step 7a deterministically validates the health result (the spine)
- [cmd] d=$(mktemp -d); cd "$d" && git init -q . && mkdir -p a/b/c/d && printf '#!/bin/bash\ntrue\n' > a/b/c/d/deep.sh && bash "$OLDPWD/skills/mstack-run/scripts/health-check.sh" detect 2>&1 | grep -q 'deep.sh' — a script nested 4+ levels deep AND UNTRACKED is detected (covers the depth bug and the git-ls-files trap in one)
- [cmd] d=$(mktemp -d); cd "$d" && git init -q . && printf '#!/bin/bash\ntrue\n' > 'my script.sh' && bash "$OLDPWD/skills/mstack-run/scripts/health-check.sh" run >/dev/null 2>&1; test $? -ne 127 — a filename containing a space does not break the runner (proves the eval/array fix)
- [cmd] d=$(mktemp -d); cd "$d" && git init -q . && for i in $(seq 1 25); do printf '#!/bin/bash\ntrue\n' > "s$i.sh"; done && bash "$OLDPWD/skills/mstack-run/scripts/health-check.sh" detect 2>&1 | grep -q 's25.sh' — with 25 scripts the 25th is still detected (the head -20 cap is gone)
- [cmd] d=$(mktemp -d); cd "$d" && git init -q . && printf 'x\n' > README.md && bash "$OLDPWD/skills/mstack-run/scripts/health-check.sh" run >/dev/null 2>&1; test $? -ne 0 — D2 fail-closed: zero tools with NO declaration EXITS NONZERO (asserts the exit code, not the presence of a string)
- [cmd] d=$(mktemp -d); cd "$d" && git init -q . && printf '# P\n\n## Health Stack\n\n- none: no automated health tools\n' > AGENTS.md && bash "$OLDPWD/skills/mstack-run/scripts/health-check.sh" run >/dev/null 2>&1; test $? -eq 0 — D4 escape hatch: the same zero-tool repo WITH a tracked `none:` declaration EXITS ZERO (declared and undeclared must not be conflated — this is the check that proves the hatch escapes)
- [assert] bash skills/mstack-run/scripts/health-check.sh run 2>&1 | grep -q 'VERDICT:PASS' — this repo still scores PASS after the change
- [manual] Confirm AGENTS.md records the zero-tools policy, the `none:` declaration form, and the review-required doctrine it mirrors.
- [manual] The crashed-gate branch in `subagent-prompt.md` is an LLM PROMPT and can only be grep-verified — a prompt is not unit-testable. This is why Task 2's deterministic Step 7a check is the spine: the executable checks above cover what actually enforces the rule.

<!-- mstack:seam
produced:
assumed:
-->

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 2 | ISSUES_FOUND | 16 raised → 16 adopted (6 refuted the plan's own claims) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 3 decisions (D2/D3/D4), 3 test gaps closed, 0 unresolved |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **CODEX:** Two passes. The first REFUTED the plan's original causal story (it claimed
  `mstack-run` treats `die` as a skip; in fact there is no branch at all and the LLM worker
  improvised `SKIP`) — the plan was rewritten around the real defect. The second KILLED D2's
  original mechanism: the declaration was to live in `.mstack/config.json`, which is
  gitignored (`.gitignore:6`), so "committed, greppable, reviewable" was false. Also caught:
  `REGRESSED` wrongly admitted as a passing verdict, two bogus verification checks (one wrote
  JSON to `/dev/null`), `eval` accepted rather than removed, and an undefined prune policy.
- **CROSS-MODEL:** One tension, resolved by the user (D4): the declaration moves to the
  tracked `## Health Stack` section of AGENTS.md, which `health-check.sh:80-93` already
  parses. The eng review's own recommendation was wrong and the outside voice's was adopted.
- **VERDICT:** ENG CLEARED — ready to implement.

NO UNRESOLVED DECISIONS
