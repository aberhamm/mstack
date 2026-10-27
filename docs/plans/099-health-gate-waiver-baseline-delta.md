---
id: 099
title: Add a human-approved health-gate waiver with baseline-delta mode
status: in-progress
blocked-by: []
priority:
goal: health-gate-waiver-baseline-delta
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-10-26
qa: automated
reviews:
  - type=eng verdict=approved date=2026-10-27 by=mstack-review
---

## Plain-English Summary

The health gate can only pass or fail. When a repo is failing for reasons a
plan did not cause, a correctly scoped plan can never finish, and the only way
out is hand-editing `status: done`, which the completion gate and the git hooks
(plan 038) exist to stop. This plan adds a sanctioned waiver: per plan, per
health category, approved by a person listed in a committed approvers file.

Two rules make a waiver count, and both are checked against git history, not
against anything an agent says:

1. **The approver is on the committed list as of a commit before the waiver.**
   An agent cannot add itself to the list and use it in the same commit.
2. **The waiver sits in a commit strictly before the plan's claim commit**, so
   it exists in history before any of the work it excuses. A waiver written
   during or after the run is ignored.

The preferred waiver is **baseline-delta**: "the plan adds no new failures of
this kind". A baseline of known failures is captured once on a clean checkout
and committed with the waiver; the category is then WAIVED (left out of the
score) only if every failure it sees is already in that baseline. If the
comparison finds a new failure, or cannot read the output, the waiver does not
apply: the category is scored normally, exactly as if it had no waiver, and the
finding is named in `FAILURES` — it does not force `FAIL` on its own, so a
composite that still clears the threshold can pass. A **blanket** waiver ("ignore this
category for this plan") is the fallback, and it must say why the delta mode
was not used. A waived category is reported as `WAIVED`, never as a score, and
a plan that only passed because of a waiver reports `PASS-WAIVED`, never `PASS`.

There are no signatures. An agent with a shell can still author both commits
itself. What this buys is that a waiver is deliberate, visible in history, and
checkable afterwards, which is the same deterrent-plus-detectable posture as
plan 038.

**What changes in the code:** a new `waiver.sh` script owns the waiver format,
the git-history checks, baseline capture and the delta comparison;
`health-check.sh` asks it about each failing category and reports `WAIVED` /
`PASS-WAIVED`; `result-gate.sh` accepts `PASS-WAIVED` only after re-checking
the waivers itself; the pre-commit hook refuses a done commit carrying a waiver
that fails the history checks; `review-gate.sh audit` flags done plans whose
waivers fail them and lists every plan completed under a waiver.

## Requirements

Real case: next-chat-umbrella-app plan 039 (eval-only harness) is
`status: blocked` (claim `beb6e36`, then `096edea` "blocked, health gate fails
at baseline"; its work is commit `3258057`, off `main`) because the repo fails
the health gate at baseline. EVERY category that runs there fails: the
`plan_id:"039"` rows of that repo's `.mstack/health-history.jsonl` read
`typecheck:4 lint:0 test:0 e2e:0 deadcode:null shell:4`, composite 1.2
(root `npx tsc --noEmit`, `eslint .`, `vitest` needing local Supabase,
`playwright test`, shellcheck on `dev.sh`). Its own scoped checks pass. So the
waiver design must let a plan complete when every category that ran is waived,
provided at least one was waived by a baseline-delta comparison that was
actually measured (see the WAIVED criterion).
There is no sanctioned override. Matthew approved building this plan on
2026-10-26 and chose the trust model (committed approvers file + waiver in an
earlier commit, no signatures) on 2026-10-27 (fleet approval record
`mdec-1027-orch-mstack-099`). Completing 039 is a separate step after this ships.

### Facts about the existing code this plan builds on

These are cited so the acceptance criteria below do not rest on memory:

- Health is enforced only by `skills/mstack-run/scripts/result-gate.sh`
  (`cmd_assert_health_result`, accepted set `HEALTH_VERDICT_OK="PASS
  NONE-DECLARED"`), called at `skills/mstack-run/SKILL.md` Step 7a item 0.
  `skills/mstack-run/scripts/review-gate.sh` (`_completable_check`,
  `cmd_hook_pre_commit`, `cmd_hook_pre_push`) reads review records only and
  never reads a health result.
- `skills/mstack-run/scripts/health-check.sh` `cmd_run` pipes every tool's
  output through `tail -50` before scoring, decides the verdict from the
  composite and from any category scoring 0 (`any_zero`), and excludes a
  `SKIPPED` category from `active_weight`.
- `.mstack/` is gitignored (`.gitignore`), so nothing under it can be a trusted
  declaration (AGENTS.md, plan 043 `- none:` rule).
- `skills/mstack-run/scripts/lib.sh` defines exit codes up to
  `EXIT_AMENDMENT_UNCHECKED=39`; 35 is reserved for pending plan 087.
- No smoke suite covers `result-gate.sh` today (no `*smoke*.sh` under
  `skills/mstack-run/scripts/` references it).
- The `claim` commit is made at `skills/mstack-run/SKILL.md` Step 2
  (`chore(plan ${PLAN_ID}): claim, in progress`), before any work starts; the
  work and the `status: done` write land later in Step 7a.

### Acceptance criteria

- [ ] **Characterization first.** A new `skills/mstack-run/scripts/result-gate-smoke.sh`
      pins the behavior of `cmd_assert_health_result` in
      `skills/mstack-run/scripts/result-gate.sh` (PASS, NONE-DECLARED + `n/a`,
      FAIL/REGRESSED/NO-TOOLS/SKIP rejected, missing fields rejected,
      `STATUS: fail` accepted, prose below `SUMMARY:` ignored) and is committed
      and green BEFORE any change to `result-gate.sh`, `health-check.sh` or
      `review-gate.sh`. Workers never commit, so a single `mstack-run` cannot
      do this: the orchestrator lands the suite as its own commit (an errand,
      AGENTS.md "Not Every Change Needs a Plan") BEFORE claiming 099, and the
      worker re-runs it green against the unmodified scripts as its first
      action and quotes that output in the result block.
- [ ] **Approvers file.** The approver allowlist is the tracked file
      `<plans dir>/waivers/APPROVERS` (resolved through `plans_dir` in
      `skills/mstack-run/scripts/lib.sh`, so `docs/plans/waivers/APPROVERS`
      here). Format: one approver token per line, `#` comments, tokens matching
      `^[a-z][a-z0-9._-]*$`. The tokens `agent` and anything starting with
      `mstack-` are never valid approvers even if listed. Nothing is read from
      the gitignored mstack config file (config.json under .mstack/).
- [ ] **Waiver record.** A `waivers:` frontmatter block, one entry per line in
      the `key=value` style of `reviews:` (values contain no spaces), with
      required keys `category` (typecheck, lint, test, e2e, deadcode, shell),
      `mode` (`baseline-delta` or `blanket`), `approver`, `date` and `expires`
      (both `YYYY-MM-DD`), `ref` (where the approval is recorded, e.g. an
      approvals-file id) and `reason`; `fallback` is required when and only
      when `mode=blanket`. Any missing, unknown-valued or duplicate-category
      entry is invalid (fail closed). Waivers are never written into
      `reviews:` and never touch `review-required` or `needs-review`.
- [ ] **History rule, deterministic.** `waiver.sh check <plan> <category>`
      exits 0 only when ALL hold, and exits 40 (new `EXIT_WAIVER_INVALID` in
      `lib.sh`) naming the first failed rule otherwise:
      (a) the repository is not shallow (`git rev-parse --is-shallow-repository`
      prints `false`) and the plan's file history (`git log --follow`) is
      readable;
      (b) the entry line is byte-identical in the tip content and in every
      commit from its introducing commit W to the tip, where W is the newest
      commit in the plan file's history whose content contains the line while
      its predecessor in that history does not;
      (c) W is not a merge commit and is not a root commit;
      (d) the approver is listed in `git show W^:<plans dir>/waivers/APPROVERS`
      AND in the approvers file at the tip (so removal revokes);
      (e) C, the plan's latest claim commit (newest commit in the plan file
      history whose `status` is `in-progress` while its predecessor's is not),
      exists, and W is a strict ancestor of C (`git merge-base --is-ancestor W C`
      and W != C);
      (f) `expires` is on or after the evaluation date (today UTC for live
      checks; the done commit's committer date for the audit).
      For `baseline-delta`, additionally (g) the baseline file exists at W and
      is unchanged at the tip, its `base-commit` is an ancestor of W^, and its
      `extractor` matches the extractor the script ships for that category.
- [ ] **Live checks read committed waivers only.** `health-check.sh` and
      `result-gate.sh` evaluate entries from `git show HEAD:<plan>`; an entry
      present only in the working tree, or differing between the working tree
      and `HEAD`, is not honored.
- [ ] **Baseline capture.** `waiver.sh capture-baseline <plan> <category>`
      refuses unless the working tree is clean (empty `porcelain_paths` from
      `lib.sh`), runs the category's resolved command once through a new
      `health-check.sh raw <category>` subcommand (full output, no `tail`
      truncation, no history write), and writes
      `<plans dir>/waivers/<id>-<category>.baseline` with header lines
      `base-commit: <HEAD sha>`, `category:`, `extractor:` and one
      `<identity>\t<count>` line per failure identity. It refuses when the
      command exits nonzero and zero identities parse (unrecognized format).
- [ ] **Failure identity, only where it is feasible.** Extractors ship for two
      categories only:
      `typecheck` = `tsc-v1`, identity `<file>|TS<code>` from lines matching
      tsc's `file(line,col): error TSnnnn:` or `file:line:col - error TSnnnn:`
      forms; `shell` = `shellcheck-v1`, identity `<file>|SC<code>` from the
      default shellcheck format (`In <file> line <n>:` then `SC<code>` markers).
      Line numbers are ignored. Comparison is a multiset: the category passes
      the delta only if every head identity's count is <= its baseline count,
      so one extra instance of a known error is a regression. `lint`, `test`,
      `e2e` and `deadcode` have no extractor: `baseline-delta` is invalid for
      them (`waive` refuses it, `check` fails it) and only `blanket` applies.
- [ ] **Head run uses the full output, scoring does not change.** In
      `health-check.sh` `cmd_run`, each category's untruncated output is also
      written to a private temp file (`tee` before the `tail -50`) used only
      for the delta comparison. Scores for every non-waived category are
      identical to before; `skills/mstack-run/scripts/health-score-smoke.sh`
      passes unchanged.
- [ ] **WAIVED state and verdict.** When `PLAN_ID` is set and a category exits
      nonzero, `health-check.sh` asks `waiver.sh evaluate`; a valid blanket
      waiver, or a valid baseline-delta waiver whose comparison finds no new
      identity, makes that category `WAIVED`. A `WAIVED` category is excluded
      from `active_weight`, the composite and `any_zero` exactly like
      `SKIPPED` (it is not scored 10). A delta that finds new identities, or
      output that cannot be compared, leaves the category scored normally and
      appends `waiver-delta-regressed:<cat>` or `waiver-noncomparable:<cat>` to
      `FAILURES`. The verdict is `PASS-WAIVED` when the remaining categories
      pass and at least one is `WAIVED`. A category WAIVED by a passing
      baseline-delta comparison counts as MEASURED (the comparison ran and
      found no new failure); a blanket-WAIVED category does not. If every
      category that ran is `WAIVED` and none of them by baseline-delta, the
      verdict is `FAIL` with `FAILURES:all-categories-waived` (nothing was
      measured). If every category that ran is `WAIVED` and at least one by
      baseline-delta, the verdict is `PASS-WAIVED` with `COMPOSITE:n/a` (no
      category is left to score; this is the next-chat-umbrella-app 039
      shape). Both all-waived checks run BEFORE the existing
      `internal-no-active-weight` branch, which must not fire for them. The
      REGRESSED comparison applies to `PASS-WAIVED` exactly as to `PASS`
      when the composite is numeric and is skipped when it is `n/a`. Output
      gains `<CAT>:WAIVED` lines and a `WAIVED:<cat>:<mode>,...` line
      (`WAIVED:none` otherwise); the history entry records waived categories
      as `null`, `score` as `null` when the composite is `n/a` (never the
      bare string, which is not JSON), plus a `waived` field. Without
      `PLAN_ID` no waiver is consulted.
- [ ] **Result gate parses, does not trust.** `result-gate.sh
      assert-health-result [file] [--plan <ref>]` accepts `PASS-WAIVED` only
      when `--plan` is given, `HEALTH_WAIVED:` lists at least one `cat:mode`,
      `HEALTH_COMPOSITE` is numeric (never `n/a`), each listed waiver passes
      `waiver.sh check` against `HEAD`, and each `baseline-delta` category has
      a `.mstack/waivers/plan-<id>-<cat>.delta` evidence file recording
      `result=no-new-failures` and the `HEAD` sha. The single exception to
      "numeric": `HEALTH_COMPOSITE: n/a` is accepted with `PASS-WAIVED` only
      when every listed waiver is valid AND at least one listed entry is
      `baseline-delta` (the delta-only case in the WAIVED criterion); `n/a`
      with only `blanket` entries is rejected. Every behavior pinned by
      `result-gate-smoke.sh` is unchanged (`n/a` stays rejected with `PASS`);
      without `--plan`, `PASS-WAIVED` is rejected (exit 30).
- [ ] **Write-time check.** `review-gate.sh` `cmd_hook_pre_commit`, on a
      staged done-transition of a plan that has a `waivers:` block, runs
      `waiver.sh hook-check` and rejects the commit when any entry fails the
      history rule with `HEAD` as the tip (an entry not present in `HEAD`
      fails rule (b) by definition). **Renames and the archive commit:**
      the hook's existing loop treats Step 7a's archive commit (`git mv` into
      `archive/`) as a done-transition, because the new path has no `HEAD`
      blob (`head_status` is empty), and `git log --follow` on that new path
      at `HEAD` returns no commits. So for each staged path the hook first
      maps a staged rename to its `HEAD` source
      (`git diff --cached -M --name-status --diff-filter=R`); when that
      source already has `status: done` in `HEAD` AND its `waivers:` block is
      byte-identical between the `HEAD` source and the staged content, the
      path is NOT a done-transition for the waiver check (it was checked when
      the done commit was made); a rename that also adds or alters a waiver
      entry is checked like any done-transition (and so fails rule (b));
      otherwise `hook-check` evaluates history on the
      `HEAD` source path. If `waiver.sh` cannot be found, a
      done-transition carrying `waivers:` is refused; all other commits keep
      the plan 038 fail-open behavior. `cmd_hook_pre_push` is unchanged.
- [ ] **Audit.** `review-gate.sh audit` additionally reports, for each
      done/archived plan with a `waivers:` block, (i) as an offender (exit 27)
      any entry failing the history rule evaluated at that plan's done commit,
      including "cannot verify" on a shallow clone, and (ii) as an
      informational, non-failing section `completed under waiver:` listing
      `NNN: Title — <cat>:<mode> approver=<a> ref=<r>` for every waived plan,
      suffixed `re-claimed` when W postdates an EARLIER claim commit of the
      same plan (claimed, stopped, waived, claimed again — the legitimate 039
      path, and also the path an agent would use to launder a waiver
      mid-run, so it is always shown).
- [ ] **`waive` helper.** `waiver.sh waive <plan> <category> <mode> <approver>
      <expires> <ref> <reason> [fallback]` writes one well-formed entry into
      the working-tree plan and never commits. Fewer arguments is a usage
      error that writes nothing. It refuses an approver not in the approvers
      file at `HEAD`, `baseline-delta` for a category without an extractor or
      without a committed baseline file, and `blanket` without `fallback`. It
      prints that the waiver counts only after it is committed and the plan is
      then claimed. There is no TTY requirement (see Design).
- [ ] **Docs.** `skills/mstack-run/references/health-gate-spec.md`,
      `skills/mstack-run/references/subagent-prompt.md` (legal verdicts gain
      `PASS-WAIVED`, routed to the same continue branch as `PASS`; result
      block gains `HEALTH_WAIVED`, placed above `SUMMARY:` because
      `result-gate.sh` cuts the block there),
      `skills/mstack-run/SKILL.md` (Step 7a item 0 passes `--plan "$NEXT"`;
      Implementation Notes record waived categories),
      `skills/mstack-code-health/SKILL.md`, `skills/mstack-run/plan-template.md`
      (commented `waivers:` example) and a short AGENTS.md section document
      the waiver, its trust model and its residual.
- [ ] **Tests.** A new `skills/mstack-run/scripts/waiver-smoke.sh` covers, in
      throwaway git repos: parsing and every structural rejection; each history
      rule (a)-(g) failing on its own; the approver added in the waiver commit
      itself (rejected); the waiver added in the claim commit (rejected); the
      waiver added after the claim (rejected); approver later removed from the
      file (rejected); both extractors on recorded sample output, including a
      swapped and a duplicated identity; `health-check.sh` producing `WAIVED`,
      `PASS-WAIVED`, `all-categories-waived` (all blanket) and the
      delta-only `PASS-WAIVED` + `COMPOSITE:n/a` case (every category failing
      at baseline, mixed blanket and baseline-delta, the 039 shape); the
      pre-commit hook accepting a done commit with a valid waiver, rejecting
      one whose waiver entry first appears in the done commit, and ACCEPTING
      the following `git mv` archive commit of that waived done plan, and
      REJECTING an archive rename that also edits a waiver entry; and
      the audit's `re-claimed` suffix. Both new suites are
      registered in `skills/mstack-run/hooks/pre-commit` (copied to
      `.githooks/pre-commit`) and in the AGENTS.md smoke list, and both new
      scripts are committed mode `100755`.

## Design

### Trust model

Matthew's choice, implemented exactly: **a committed approvers file, and a
waiver counts only if it sits in an earlier commit than the change it waives.
No signatures, no crypto.**

- **Why `<plans dir>/waivers/APPROVERS`.** It must be tracked (the plan 043
  rule: a declaration under gitignored `.mstack/` is per-checkout and invisible
  to review). Putting it beside the plans it governs keeps waiver artifacts in
  one reviewed place, works for both `docs/plans/` and `plans/` layouts via
  `plans_dir`, and stays out of every existing plan scan: the scanners glob
  `*.md` and `archive/*.md`, and the file and baselines have no `.md`
  extension, so the `docs/plans/*.md` case in `cmd_hook_pre_commit` never
  treats them as plans.
- **"Earlier commit" made precise.** The thing being waived is the plan's
  work, and all of it lands after the claim commit (SKILL Step 2 claims before
  any work; workers never commit). So the anchor is the latest claim commit C,
  and the waiver's introducing commit W must be a strict ancestor of C. The
  approvers file is read at W's parent, so the approver was on the list before
  the waiver existed. Re-checking the approver at the tip makes removal from
  the file a revocation. Every input is a git object; there is no clock or
  author identity in the rule except the `expires` date.
- **What was dropped and why.** The `.mstack/config.json` allowlist (gitignored,
  so not committed, and the "config no-downgrade audit" it relied on cannot
  exist). The approver-vs-commit-author rule (agents commit as Matthew, so it
  would have rejected plan 039 itself; the earlier-commit rule replaces it).
  The TTY gate on `waive` (Matthew approves through fleet-manager questions and
  an agent then records the waiver, so a TTY requirement would block the real
  workflow, and hand-editing the frontmatter bypasses it anyway; the history
  rule binds whoever writes the entry). The "removing a waiver is a downgrade"
  check (wrong direction: removing a waiver makes the gate stricter).
- **Broadening is handled by the history rule, not by no-downgrade.** Adding a
  waiver, switching `baseline-delta` to `blanket`, pushing `expires` out or
  editing a baseline all create a new W (or change the baseline after W). If
  that happens at or after the claim, the waiver is not honored. No
  `assert-no-downgrade` change is needed, and none is made.
- **Honest residual.** An agent with a shell can add itself to APPROVERS in
  commit 1, add the waiver in commit 2, and claim in commit 3. Nothing here
  stops that; signing is the only thing that would, and Matthew declined it.
  The same residual covers re-claiming: because the anchor is the LATEST
  claim, a run that fails the gate, is blocked, gets a waiver committed and is
  claimed again honors that waiver (this is exactly how 039 will complete, and
  also how an agent would launder one mid-run), so the audit marks every such
  plan `re-claimed`. The `.mstack/waivers/*.delta` evidence `result-gate.sh`
  reads is written by the same run's `health-check.sh` and is gitignored;
  `result-gate.sh` re-checks the waiver's provenance, not the delta itself.
  What the rule guarantees is that this takes three separate, deliberate
  commits that sit in history, that `review-gate.sh audit` lists every plan
  completed under a waiver with its approver and `ref`, and that a waiver
  smuggled into the claim or done commit is refused at write time and flagged
  afterwards. Like plan 038, `--no-verify` skips the hook; the audit is the
  backstop, and unlike uncommitted work (plan 039) waiver provenance *is*
  recoverable from history, so this audit claim is real.
- **Where the check runs.** Honest path: `health-check.sh` (WAIVED) and
  `result-gate.sh` (independent re-check at Step 7a). Write time: the
  pre-commit hook on a done-transition. Retroactive: `audit`. The pre-push hook
  is not changed; it already gates done tags on the review record only.

### Record format

```
waivers:
  - category=lint mode=blanket approver=matthew date=2026-10-27 expires=2026-11-10 ref=mdec-1027-example reason=757_pre-existing_warnings fallback=no-lint-extractor
  - category=shell mode=baseline-delta approver=matthew date=2026-10-27 expires=2026-11-10 ref=mdec-1027-example reason=dev.sh_pre-existing
```

`expires` is its own key (the earlier `scope=expires=...` form put `=` inside
a value and broke `kv_get` parsing). One entry per category; a duplicate is
invalid rather than "last wins". `waiver.sh` has its own block reader modelled
on `review_entries` in `lib.sh`; `review_entries` itself is not modified.

### Baseline-delta without a second checkout

The first draft ran the category twice, at the base commit and at the plan
head, in a throwaway worktree. That cannot work: the head commit does not
exist when the gate runs (workers commit only after it), a fresh worktree has
no installed dependencies (`node_modules`, virtualenvs), and the scored output
is truncated to 50 lines. Instead the baseline is **captured once, on a clean
checkout that has its dependencies, and committed with the waiver** (so the
history rule covers it, and anyone can re-derive it by running the same
command at `base-commit`). At gate time the head side is the normal health run
in the worker's tree, using the untruncated copy of its output. No worktree is
created by this plan.

The extractor version tag (`tsc-v1`, `shellcheck-v1`) is stored in the
baseline; a baseline written by a different extractor version is
non-comparable and fails closed, so improving an extractor later cannot
silently change what an old baseline means.

### Composite and verdict

`WAIVED` is treated like `SKIPPED` in the weight redistribution, which is the
only honest option: scoring a waived category 10 would inflate the composite
with a number nobody measured. Excluding waived categories means the
real target (next-chat-umbrella-app 039, where every category that runs
fails) can leave nothing to score; the distinction that keeps that case
honest is MEASURED vs not: a passing baseline-delta comparison is a
measurement, a blanket waiver is not. All-blanket is `FAIL
all-categories-waived`; all-waived with at least one delta is `PASS-WAIVED`
with `COMPOSITE:n/a`, and `result-gate.sh` admits that `n/a` only alongside a
baseline-delta entry (the same narrow-exception shape as `n/a` with
`NONE-DECLARED`). The plan 043 closed verdict set gains exactly
one value, `PASS-WAIVED`. The REGRESSED comparison against the previous
history entry is unchanged; if the waived set differs from the previous run's,
composites cover different categories and a large drop still reports
REGRESSED, which errs strict.

### Exit codes

`EXIT_WAIVER_INVALID=40` in `lib.sh`, with the same "35 stays reserved for
pending plan 087" comment the neighboring codes carry. No existing code is
reused: pick-next 10-15, seam 20, ref 21-22, review gate 23-28, scan 29,
result 30, health 31/34/36, scaffold 32, verify 33, premise 37, fixture 38,
amendment 39.

### This plan modifies the machinery that runs it

It edits `health-check.sh`, `result-gate.sh` and `review-gate.sh`, so per
AGENTS.md it must be executed in a scoped, watched, manual `mstack-run` of this
plan only, with every smoke suite re-run by hand in a separate invocation after
the commit lands. The `result-gate-smoke.sh` characterization suite is Task 1
and lands before any of those three files change. A plan with no `waivers:`
block takes none of the new paths, so rollback is reverting the commit, and
rollout needs no flag.

**Files expected to change:**

- `skills/mstack-run/scripts/result-gate-smoke.sh` (new, characterization, Task 1)
- `skills/mstack-run/scripts/waiver.sh` (new): `check`, `evaluate`, `waive`,
  `capture-baseline`, `hook-check`, `audit`; block reader; `tsc-v1` and
  `shellcheck-v1` extractors; multiset compare; delta evidence under
  `.mstack/waivers/`
- `skills/mstack-run/scripts/waiver-smoke.sh` (new)
- `skills/mstack-run/scripts/lib.sh`: `EXIT_WAIVER_INVALID=40` only
- `skills/mstack-run/scripts/health-check.sh`: full-output `tee`, `WAIVED`
  state, weight exclusion, `PASS-WAIVED`, `all-categories-waived`, `WAIVED:`
  line, history `waived` field, `raw <category>` subcommand
- `skills/mstack-run/scripts/result-gate.sh`: `--plan`, `PASS-WAIVED`,
  `HEALTH_WAIVED`, re-check via `waiver.sh`
- `skills/mstack-run/scripts/review-gate.sh`: `cmd_hook_pre_commit` calls
  `waiver.sh hook-check` on waived done-transitions; `cmd_audit` adds the
  waiver offender and informational sections
- `skills/mstack-run/hooks/pre-commit` and `.githooks/pre-commit`: register the
  two new suites in the dev smoke list (edit the shipped source, then `cp`)
- `skills/mstack-run/SKILL.md`, `skills/mstack-run/references/health-gate-spec.md`,
  `skills/mstack-run/references/subagent-prompt.md`,
  `skills/mstack-code-health/SKILL.md`, `skills/mstack-run/plan-template.md`,
  `AGENTS.md`: docs
- `docs/plans/waivers/APPROVERS` (new): this repo's own approvers file, listing
  `matthew`

**Out of scope (deferred, say so in the wrap):**

- Paperclip report and `mstack-changelog` rendering of waived categories
  (`skills/mstack-run/scripts/paperclip_lifecycle.py`,
  `skills/mstack-changelog/SKILL.md`). Step 7a's Implementation Notes record
  the waived categories, which is the input a later rendering plan needs.
- Extractors for `lint`, `test`, `e2e`, `deadcode` (blanket only for now).
- `mstack-status` display of waivers.
- Signed commits or tags; any cryptographic proof of approval.
- Waiving review gates (eng/design/ceo/code); waivers never touch `reviews:`.
- Changing scoring thresholds or the `tail -50` scoring input.
- Anything in next-chat-umbrella-app, including its APPROVERS file and
  completing its plan 039.
- Installing skills, running `./setup`.

## Tasks

1. `result-gate-smoke.sh` is landed by the orchestrator as its own commit
   (mode 100755) before 099 is claimed (workers never commit); the worker's
   first action is to run it green against the unmodified `result-gate.sh`
   and quote the output before touching any gate script.
2. Add `EXIT_WAIVER_INVALID=40` to `lib.sh`.
3. Write `waiver.sh`: block reader and structural validation; history rule
   (a)-(g) with `--tip` defaulting to `HEAD`; `capture-baseline`; extractors
   and multiset compare; `evaluate` with delta evidence; `waive`;
   `hook-check`; `audit`. `chmod +x` and `git update-index --chmod=+x`.
4. Add `docs/plans/waivers/APPROVERS` listing `matthew`.
5. `health-check.sh`: `tee` full output, `raw` subcommand, `WAIVED` exclusion,
   `PASS-WAIVED` / `all-categories-waived`, output and history fields. Confirm
   `health-score-smoke.sh` is unchanged and green.
6. `result-gate.sh`: `--plan`, `PASS-WAIVED`, `HEALTH_WAIVED`, re-check; extend
   `result-gate-smoke.sh` with the new cases, keeping every Task 1 case.
7. `review-gate.sh`: hook-check call on waived done-transitions; audit sections.
8. `waiver-smoke.sh` covering every case in the Tests criterion.
9. Register both suites in `hooks/pre-commit`, copy to `.githooks/pre-commit`,
   add them to the AGENTS.md list.
10. Docs: SKILL Step 7a item 0 and Implementation Notes, health-gate-spec,
    subagent-prompt, code-health SKILL, plan-template, AGENTS.md section.

## Verification

Checks:

- [cmd] `bash skills/mstack-run/scripts/result-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/waiver-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/health-score-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash -n skills/mstack-run/scripts/waiver.sh skills/mstack-run/scripts/health-check.sh skills/mstack-run/scripts/result-gate.sh skills/mstack-run/scripts/review-gate.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/waiver.sh skills/mstack-run/scripts/health-check.sh skills/mstack-run/scripts/result-gate.sh skills/mstack-run/scripts/review-gate.sh`
- [assert] `grep -o PASS-WAIVED skills/mstack-run/references/health-gate-spec.md` output contains PASS-WAIVED
- [assert] `grep -o PASS-WAIVED skills/mstack-run/references/subagent-prompt.md` output contains PASS-WAIVED
- [cmd] `git diff --check`
- [manual] Because this plan edits gate scripts, run the full AGENTS.md smoke
  list by hand in a separate invocation after the commit lands; the health
  gate's verdict on its own change is not independent evidence.
- [manual] Dry run on a scratch copy of next-chat-umbrella-app (never the real
  repo): commit an APPROVERS file, capture a `shell` baseline, commit a waiver,
  claim, and confirm `health-check.sh` reports `SHELL:WAIVED` and that adding
  one new shellcheck finding turns it into `waiver-delta-regressed:shell`.

## Authoring Notes

Rewritten on 2026-10-27 after the eng review recorded `changes-requested`
(commit b351a9a). That review's points, recovered from the reviewing session's
summary, and how this version answers them:

1. Gates ignore health: `assert-completable` and the hooks never read health;
   the real check is `result-gate.sh`, which accepts only PASS/NONE-DECLARED.
   Now: `result-gate.sh` is where PASS-WAIVED is accepted, with its own
   re-check; the hook only checks waiver provenance on done-transitions.
2. `.mstack/config.json` is gitignored, so the approver allowlist and its
   no-downgrade audit could not exist. Now: tracked `waivers/APPROVERS`.
3. Baseline-delta infeasible (`tail -50`, head commit absent at gate time,
   base worktree has no dependencies). Now: committed baseline captured on a
   clean checkout; head side uses an untruncated `tee` copy; no worktree.
4. Same-commit/author rule would reject plan 039 (agents commit as Matthew).
   Now: replaced by the earlier-than-claim history rule.
5. No-downgrade pointed the wrong way (removal vs broadening). Now: removal is
   allowed; broadening is caught by the history rule.

Further points from this rewrite: the `scope=expires=` value broke `kv_get`;
there was no `result-gate.sh` characterization suite; the exit code was
unassigned; scoring a waived category was unspecified for the
all-categories-waived case; failure identity was claimed for categories with
no parseable format; and Paperclip/changelog rendering was trimmed to keep the
plan to one execution.
