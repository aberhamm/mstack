# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- **Enforcement: a plan can no longer be marked done on unreviewed or
  uncommitted work.** This is the largest behavior change since 2.0.0 and it
  landed as one family (plans 034-039, with 043, 046, and 047 closing the gates
  that let a check pass without running). Layer by layer:
  - **Review records, written by the review skills** (plans 034-035): a plan's
    review state lives in its frontmatter (`review-required:` / `reviews:`),
    `review-gate.sh` is the only thing that writes it, and an absent
    `review-required:` fails closed instead of reading as "nothing required".
    Workers are explicitly forbidden from clearing or weakening a gate they are
    subject to, or from running a `needs-review` plan outside the picker.
  - **Completion fails closed on an open gate** (plan 036): Step 7a of
    `mstack-run` now calls `review-gate.sh assert-completable` as its first
    action. An open gate sends the plan back to `status: blocked` +
    `needs-review` — no `done`, no completion tag.
  - **Approved plans are always committed** (plan 037): a plan carrying a
    recorded verdict may not sit dirty against HEAD (`assert-committed`, exit
    25). plan-doctor commits the plan file right after recording an approval,
    and status/backlog/doctor detect and heal approved-but-uncommitted plans.
    Plans still being authored are exempt.
  - **A git-hook write barrier** (plan 038): tracked `.githooks/pre-commit` and
    `.githooks/pre-push` reject a staged pending→done transition that fails
    `assert-completable`, and reject review-field weakening that fails
    `assert-no-downgrade`. A startup guard (exit 26) refuses to run when the
    hooks are not installed, and `review-gate.sh audit` (exit 27) is the
    retroactive backstop for anything that got past them.
  - **Completion requires the work product committed** (plan 039): completion
    fails (exit 28) when plan-attributable dirt is still in the tree, measured
    against a baseline captured before the plan started. Nothing is
    auto-`git add`ed, and a missing baseline fails closed.
  - **The health gate can no longer silently no-op or be lied about** (plan
    043): the shell-tool detector globbed to a depth that missed mstack's own
    scripts, detected zero tools, crashed, and the worker — having no branch for
    a crashed gate — invented a passing verdict. Every plan through 039
    completed against a gate that never ran. Detection is now
    layout-independent, zero tools fails closed unless the repo declares `none`
    in tracked guidance, and a deterministic parser (`result-gate.sh
    assert-health-result`) rejects a pass carrying a missing or non-passing
    verdict.
  - **Verification checks are probed, not counted** (plan 046): the new
    `verify-lint.sh` runs a plan's declared `[cmd]`/`[assert]`/`[status]` checks
    against the repo as it actually is and reports OK / BROKEN / SUSPECT /
    UNPROBED / SKIP (exit 33 on BROKEN). A plan can no longer validate on a dead
    test oracle — a flag the CLI doesn't have, a selector that collects zero
    tests, a `test -f` on a path nothing creates.
  - **The gate must reach the tests a plan adds** (plan 047): a configured test
    command whose selector excluded the new code used to run, report green, and
    cover none of it. The gate now proves it ran the tests the plan declares it
    adds.

  **Upgrade note — updating mstack installs git hooks into your repo.**
  `mstack-init` (and `./setup` in the mstack source repo) now sets
  `core.hooksPath .githooks` in the target repo and writes tracked `pre-commit`
  and `pre-push` shims there. **These hooks can hard-block a commit or a push.**
  They chain to whatever hook was configured before mstack took over (captured
  as the `mstack.priorHooksPath` git config key), so a pre-existing global hook
  such as a secret scanner still runs. The honest residual, stated rather than
  papered over: this is a local, per-clone barrier and `git commit --no-verify`
  still bypasses it. It is a deterrent that leaves evidence, not an unbypassable
  gate — which is why the retroactive `audit` exists.
- **`/mstack-wrap-up`** — an end-of-session harvest that mines the session for
  what only it knows: scaffolding that should now be deleted, docs its changes
  made wrong, learnings never written down, decisions a future session would
  re-litigate (plans 040-042). It runs a recall pass plus a delegated mechanical
  scan (`wrapup-scan.sh`), merges both into one findings list, routes each
  finding to an existing sink, and renders a cleared-to-close verdict. It never
  deletes, pushes, or `git add .`s.
- **Plans can be referenced by name, not just by number** (plans 031-033): a
  shared resolver in `lib.sh` maps id ↔ title ↔ name, so `/mstack-run
  "plan-ref resolver"` or `name:webhook-retry` works. Ambiguous names exit 21
  with the candidate list instead of guessing, and archived-only names are
  rejected. Every user-facing surface now cites a plan as `ID: Title` rather
  than a bare number.
- **Four review-hardening rules, aimed at the two ways a defect cleared review
  anyway** (plans 088-091, from `docs/review-hardening-proposal.md`). The origin
  is a real batch: three plans cleared an eng review plus a cross-model pass —
  18 findings folded in, verdict "ENG CLEARED" — while still carrying two P1
  defects fatal to the first run. Neither escape was a shortage of review
  volume, so none of these rules adds a round; they aim the attention that was
  already being spent. Each ships with its own `rules.<key>` toggle, fails OPEN
  (only an explicit `false` disables), and prints
  `[mstack] rule <key>: enabled|disabled (config)` so a disabled run is legible
  as disabled rather than merely quiet.
  - **An uncited factual premise is a finding** (plan 088, Rule 1):
    `premise-lint.sh`, run per plan by plan-doctor Step 3.9, classifies every
    acceptance criterion as CITED-OK / CITED-UNRESOLVED / UNCITED / NO-PREMISE.
    The pipeline was verifying what a plan CITED and exempting what it ASSERTED
    — both P1s were the batch's only uncited premises. A citation that resolves
    nowhere blocks in the script (exit 37); an uncited premise is reported and
    made blocking by Step 4b, because the detector is a word list and a check
    that cries wolf gets bypassed. Disable with `rules.citation_or_finding`.
  - **A pane-dependent plan must attach a real capture** (plan 089, Rule 3):
    `fixture-lint.sh`, run by Step 3.10, emits one verdict per plan and blocks
    (exit 38) when a plan whose logic keys on terminal screen content declares
    no `tmux capture-pane` artifact, or declares one that is not on disk. The
    keyword list is two-tiered after the flat version was measured against the
    live backlog and fired on 9 of 41 plans with a 100% false-positive rate. Opt
    out per plan with `tui-fixture: n/a  # <reason>`; disable with
    `rules.tui_fixture`.
  - **Brief the outside voice to attack premises** (plan 090, Rule 4): the
    cross-model reviewer is now told *not* to sharpen the primary reviewer's
    findings but to attack the plan's premises, and "no tension" across a batch
    is logged as a smell that buys one more premise-directed pass instead of
    being cited as confirmation. Four shipped briefs changed; because the
    mechanism is prose, `brief-content-smoke.sh` asserts the directives — and
    the untouched invocation machinery — are still there. Disable with
    `rules.premise_brief`.
  - **A review's own fix gets one adversarial re-check** (plan 091, Rule 2): one
    of the two P1s was *created by the eng review's fix* and shipped unexamined,
    because the highest-churn text in the pipeline is the text reviews write and
    nothing reviewed it. The new `amendment-repass.sh` captures a pre-image plus
    a severity/trigger classification at each of plan-doctor's eight enumerated
    edit sites, hands one bounded adversarial pass the amendment **diff only**
    ("assume this fix introduced a new defect; find it"), and refuses `ready`
    (exit 39) for any P2-or-above amendment with no recorded re-check. Records
    live in gitignored `.mstack/amendments/` and are local and non-authoritative
    by construction — an amendment record is not a review verdict and touches
    no part of the completion gate. Honest residual, stated rather than
    discovered: this is an **honest-path check only**. It fires when the doctor
    calls `capture`; a plan edited outside plan-doctor leaves no record and
    passes. There is no write-time hook and no retroactive audit here. Disable
    with `rules.amendment_repass`.

### Changed
- **Wrap-up routes durable knowledge to committed docs**, not to the gitignored
  learnings store. Newly-discovered conventions and decisions become a proposed
  edit to the relevant tracked doc; `learned-patterns` is demoted to
  cross-project or transient hints, and host memory to genuinely personal
  preferences.
- **Wrap-up drives a disposition of uncommitted work before it closes.** On a
  dirty tree it asks one question (commit an explicit file list / stash /
  defer) instead of just reporting the dirt in its verdict. Clean trees stay
  silent.
- **E2E is a scored health category with a single source of truth for weights**
  (plan 065). The e2e category is now actually scored by `health-check.sh`
  (sharing the test category's pass/fail rubric on purpose, so there isn't a
  second rubric to keep honest), and every weight comes from `config.sh`'s
  `DEFAULT_CONFIG` rather than being restated per skill: typecheck 20, lint 15,
  test 25, e2e 20, deadcode 10, shell 10.
- **plan-doctor's status dashboard now carries a mandatory legend** explaining
  each state and what it means for execution, instead of assuming the reader
  knows mstack's lifecycle from emoji alone.
- **Not every change needs a plan.** The doctrine is now written where agents
  read it, with the actual test (ordered steps / risky seam / required review
  gate / deliberately queued); anything else is an errand to just do. Worker
  delegation for implementation is now mandated rather than implied.

### Fixed
- **Completion tags are annotated (`git tag -a`), so `--follow-tags` actually
  pushes them.** Step 7a created lightweight tags while Step 11 told you to push
  with `--follow-tags`, which only pushes annotated ones — so every completion
  tag silently stayed local. `mstack/plan-031-done` through `plan-042-done` were
  stranded on one machine before this was caught.
- **The enforcement hooks chain instead of shadowing.** `core.hooksPath` is
  single-valued, so mstack's repo-local `.githooks` silently disabled any prior
  global hook (a gitleaks secret scanner, for example) in every mstack repo.
  The prior path is captured at install time and chained to after mstack's gate
  passes, including in the fallback path when `review-gate.sh` is unreachable.
- **Helper scripts ship executable.** `review-gate.sh`, `result-gate.sh`, and
  two smoke suites were committed `100644`; wrap-up locates helpers with `[ -x ]`,
  so its `plan-authored` discriminator never ran and it fell through to a
  fail-open branch whose output was indistinguishable from success. Git hooks
  locate the same script with `[ -f ]`, so plan-038 enforcement was never
  impaired.
- **Wrap-up no longer treats an authored plan file as dirt, or silences an
  authored-but-unreviewed plan.** The scaffold-vs-authored discriminator also
  had an append-only hole: leaving every template placeholder intact while
  writing the real plan around them read as `scaffold` forever. It now requires
  both no missing template lines and no added substantive lines.
- **`/mstack-status`'s "Next ready" comes from `pick-next.sh`.** The dashboard
  reimplemented the walk in filename order, never read `priority:`, and
  hand-rolled `blocked-by` parsing without goal-qualified (`goal:id`) support —
  so on a prioritized backlog it named a different plan than the picker would
  actually run.
- **`/mstack-handoff` gave up the "wrap this up for now" trigger** to
  `/mstack-stash`, which owns the park-it sense; the two documents previously
  contradicted each other.

### Internal
- The source repo's `pre-commit` hook now runs mstack's own smoke suites
  (script-mode, review-gate, wrapup-scan, plan-ref, hook-chain) when a commit
  touches an executable surface, and refuses the commit on failure. Three
  defects shipped from this repo in a single day that a suite run would have
  caught; the suites passed the whole time because nobody ran them. Bypass with
  `MSTACK_SKIP_SMOKE=1`.
- Plan 030's manual spawn/close-self E2E was performed and recorded, closing the
  last gate on the cctrl spawn-and-handoff feature.
- The audit-remediation backlog (plans 054-087) was authored and then triaged
  twice against evidence, taking 31 pending plans down to 14 active, with
  implicit ordering encoded as `blocked-by`.

<!-- commits: 0347850, 7db6a7e, ff8da16, eeb702b, c47bc5a, 2e0515a, 1fe39c9, 18466c6, 763e4fc, 66901e8, 6ddc1db, 5133de9, 8dfcb53, 3cadb26, c0fbefb, 3b2bb6b, 99c007a, 57ca79f, 74e04dc, d0e46b4, 34a9af3, ba4e5b3, e793b0a, 2c889da, 7663abb, 34c52c4, 56020fe, 1840708, 6a289ad -->

## [2026-06-30]

### Added
- **Hardened autonomous plan validation** — `mstack-plan-doctor` now closes
  several gaps that let unvalidated assumptions reach execution (plans 026-029):
  - **Re-validation after auto-fix** (Step 4b): the doctor re-checks any plan it
    edited (content-hash tracked) in a bounded loop and refuses to mark a plan
    `ready` while blocking findings remain, so a defect introduced by a fix can
    no longer ship unvalidated.
  - **Adversarial cross-model audit** (Step 3.5): when `codex` is available, each
    plan is audited against the real source with a falsify-first rubric; genuine
    findings auto-trigger a fix, and the step skips cleanly when no external
    model is configured.
  - **Seam-contract verification** (Step 3.6): the doctor diffs each dependency
    edge for interface drift (a plan assuming a function signature, schema,
    endpoint, or flag that its upstream plan defines differently) and blocks on a
    mismatch.
  - **JIT seam re-validation at pickup**: `mstack-run` now re-checks a picked
    plan's upstream seam assumptions against the now-real codebase before
    implementing, blocking the plan and routing you to
    `/mstack-plan-doctor NNN` if an assumption went stale.
- **Spawn-and-handoff mode**: when running inside a cctrl-managed session,
  `/mstack-handoff` can now save a checkpoint, launch a fresh detached session
  seeded to resume it, and optionally close the current one — all after
  confirming the spawn came up.
- **`/mstack-changelog` commits for you**: approving the drafted entry now also
  commits the changelog file (the file only, no push), removing the manual
  commit step after every sync.

### Internal
- `mstack-run` now warns that `mstack/plan-*-done` completion tags are local-only
  and reminds you to push with `git push --follow-tags`, so the tags don't get
  stranded when you push the branch.

<!-- commits: 663789e, 32c08d8, b7ef5fc, a066361, 9a7e276, 1bee181 -->

## [2026-06-11]

### Added
- You can now run goal-based MStack plan sessions by goal slug instead of only
  numeric plan IDs. `plan-multi` stamps generated plans with a `goal:` field,
  suggests `/goal complete <slug> mstack plans`, and `mstack-run`/`pick-next.sh`
  resolve scoped candidates and dependencies by goal-aware plan identity.
- Completed plans now keep implementation notes before archival, including the
  summary, changed files, and implementation commit hash.
- `/mstack-handoff` can now list handoff checkpoints for the current repo or
  all known project roots, show exact `resume from handoff <summary>` commands,
  resume deterministically, and write anomaly handoffs through a tested shell
  helper.

### Fixed
- Scoped plan picking no longer fails when numeric scope IDs are normalized
  before the helper function is loaded.
- The shell health gate is clean across MStack helper scripts.

### Internal
- The Codex smoke test now asserts live smoke-run outcomes instead of only
  checking that the command starts.

<!-- commits: e1b02cc, c965a1f, 05a70c0, f86d248, a8ed5b2, 32b684b, 7c4340c, 9ff0797, 1d283c3, 1fab475, 98f3d37, 9823b88, 55953bd, 0461ab5, b1af810, 80cd18b, 39d3fa9, acf80bc, 6539e45 -->

## [2026-06-05]

### Added
- **Codex compatibility layer**: MStack now treats `AGENTS.md` as the
  canonical shared instruction file, keeps `CLAUDE.md` as an import shim, and
  includes Codex custom worker/reviewer agents for subagent workflows
- **Codex smoke test**: `bin/mstack-codex-smoke` creates a disposable repo to
  verify guidance discovery, MStack initialization, health detection, and plan
  picking; `--codex` attempts a live `codex exec` run when credits are available
- **Handoff checkpoints**: `/mstack-handoff` now offers "Save handoff checkpoint" alongside chat output. Checkpoints save to `.mstack/handoffs/` and you resume in a new session with `resume from handoff <name>` — no copy-paste needed. Files auto-delete on resume and auto-prune after 7 days
- **Completed plan auto-archiving**: finished plans automatically move to `docs/plans/archive/`, keeping the active backlog clean
- **Resilient plan execution**: three-layer defense for autonomous runs — upfront validation, execution manifest tracking, and anomaly detection with auto-handoff (plans 016-019):
  - **Distinct picker exit codes** (plan 016): `pick-next.sh` returns structured exit codes (10-14) for all-done, scoped-not-found, all-blocked, dependency-cycle, and duplicate-IDs, replacing generic error codes
  - **Execution manifest** (plan 017): `.mstack/execution-manifest.json` tracks scoped goal state across iterations — scope IDs, file path resolution, pick history, terminal states, and path divergence detection
  - **Anomaly detection** (plan 018): four anomaly checks (iteration bound, repeat pick, no progress, path divergence) fire after each iteration and halt the run before damage compounds
  - **Auto-handoff on anomaly** (plan 019): when an anomaly is detected, a handoff checkpoint is saved automatically so you can resume in a fresh session with `resume from handoff`

### Changed
- Skill instructions and helper scripts now read `AGENTS.md` first, fall back
  to `CLAUDE.md`, and resolve installed skills across Skillshare,
  `~/.agents/skills`, `~/.codex/skills`, and `~/.claude/skills`
- Install documentation now covers Skillshare, Codex-native, and Claude Code
  setup paths
- **Progressive disclosure for skills**: mstack-run (1,350→895 lines), plan-doctor (1,119→845 lines), plan-multi (504→305 lines), and mstack-ideate (409→251 lines) now load large conditional sections from `references/` on demand instead of holding everything inline. Reduces always-loaded context without losing capability
- Handoff now asks to commit uncommitted changes *before* generating the handoff document, so the summary reflects the actual repo state

### Fixed
- Goal-scoped plan picking now sanitizes goal slugs before using them in
  generated Bash variable names, so hyphenated goal names work correctly
- Cognitive frames path resolution now works correctly via skillshare
- Handoff no longer auto-starts work when loaded as context
- Deduplicated learnings search results across multiple queries in mstack-run

<!-- commits: 175d7ae, 28a7af5, 2be0c2e, aadea1b, e12c42b, e39cb82, f06e220, be1f9d8, 5e1aade, 0d50120, 054ae2c, 0159c29, 1e8db8f, 4604236, 04b3ddc, 621fb8f, d0a556e, c66a9b8, 62c2618, a3ded6d, 3624402, 111548c, b09dd4b, bcd7519 -->

## [2026-06-03]

### Added
- **`/mstack-ideate`**: brainstorm before committing to plans. Takes a problem statement, runs 3-5 isolated reasoning branches under different cognitive frames, scores ideas on novelty/viability/fit, and presents a ranked list with a "non-obvious pick" and provocation. Includes trap detection, clustering by approach angle, and structured handoff to `/mstack-plan-multi`
- **Cognitive frames library**: 11 reusable prompt blocks (8 review + 3 decomposition) that give plan-doctor, plan-multi, and mstack-ideate distinct evaluation perspectives (security, performance, SRE, end user, adversarial, cost, simplicity, maintainability, plus decomposition frames for coupling, parallelism, and simplicity)
- **Multi-frame review in plan-doctor**: each plan is now reviewed through 3 deterministically-selected cognitive frames. Critical findings deduct from autonomy-readiness; advisory findings are non-blocking. Auto-fix resolves addressable gaps
- **Trap resistance scoring**: 5th scoring dimension in plan-doctor (0-10). Detects premature abstractions, false economies, hidden coupling, won't-scale patterns, and scope creep magnets using an adversarial evaluation prompt. Plans below 4/10 get auto-fixed
- **Divergent decomposition in plan-multi**: choose "Explore" to generate 3 competing plan breakdowns from different angles (minimize coupling, maximize parallelism, simplest-thing-that-works), score them, and reconcile the winner. "Direct" preserves existing single-pass behavior
- **Stack-aware testing recommendations**: on first init, mstack detects your project stack and framework, runs a 5-tier testing audit, shows a confidence path (LOW/MEDIUM/HIGH), and optionally searches the web for stack-specific best practices. Offers to scaffold a testing plan as plan 001
- **Progress output during goal execution**: `[mstack]` prefixed status lines show which plan is running, health gate results, review findings, and commit messages. Tree-drawing characters show pipeline stage
- **Final cross-plan validation**: after all plans complete, runs a full-suite health check to catch regressions between plans, with git blame attribution for failures
- **Post-plan cleanup sweep**: scans files touched by the current plan for unused imports, dead functions, debug statements, and orphan files before code review
- **Pre-handoff artifact check**: mstack-handoff now scans for leftover temp files (*.tmp, *.bak, debug-*) before generating the handoff summary
- **Scoped plan execution**: pass specific plan IDs to `/mstack-run` or `/goal` (e.g., `/goal complete mstack plans 008, 009, 010, 011`) instead of "all pending". Plan-multi and plan-new now output scoped run commands
- **`[browse]` verification checks**: plans touching web-facing code can include `[browse]` checks that invoke gstack's headless browser for real E2E verification
- `/mstack-stash`: save unresolved conversation threads for later without committing to a formal plan
- `/mstack-backlog`: interactive backlog grooming with reprioritize, defer, drop, stash
- **Testing infrastructure audit**: plan-doctor now scans for 5 tiers of testing (static analysis, unit, integration, E2E/browser, API contracts) and reports walk-away confidence (HIGH/MEDIUM/LOW) with recommendations
- **E2E in health gate**: auto-detects Playwright, Cypress, and `test:e2e` scripts. Runs them as a scored category (20% default weight) alongside typecheck/lint/test

### Changed
- **Composite score formula**: plan-doctor now uses explicit weights (clarity 20%, testability 25%, scope-fit 20%, autonomy 25%, trap resistance 10%), configurable via `.mstack/config.json` key `health.weights.planning`
- **Testability scoring tightened**: plans with only grep/test-f verification checks are capped at 5/10 on testability. Web-facing plans missing E2E checks are flagged as errors
- **Plan-multi generates testing approach**: each generated plan now includes a "Testing approach" line (unit-only, E2E, or browser-based) in its Design section
- **Multi-model structural critique**: plan-multi now routes decompositions through Codex and Sonnet for independent structural review before finalizing
- **Status dashboard**: shows cold-start context for fresh sessions picking up mid-backlog
- **Adversarial code review mode**: add `review: adversarial` to plan frontmatter for a standard reviewer plus an adversarial reviewer hunting production failure modes
- Renamed `plan-backlog` to `plan-multi` for clarity
- Auto-update check wired into skill preambles
- **Mandatory verification**: plans without executable verification checks (`[cmd]`, `[assert]`, `[status]`) are now blocked by plan-doctor. Add `verification: health-only` to frontmatter for purely visual plans
- **Removed supervised mode**: the `autonomy` config/frontmatter field is gone. Execution is always fully autonomous; the plan is the contract
- **Learnings feed plan-doctor**: pitfalls and dependencies from previous executions now surface during plan validation, so the architect can adjust the design before walking away
- **Plan-doctor hardened**: posture selector retained (the architect controls scope strategy), but auto-fixes plans below 8/10 on autonomy-readiness without asking, auto-generates verification checks, auto-resets stale in-progress plans
- **Category-aware strike rule**: investigation now allows 3 strikes per distinct root cause category (max 3 categories = 9 total attempts), replacing the flat 3-strike limit
- **Configurable review depth**: default is 1 unified reviewer; add `review: thorough` to plan frontmatter for 3 blind reviewers with cross-model routing
- **Skill consolidation**: merged `mstack-simplify-code` into `mstack-code-review` (Step 4b); marked `mstack-checkpoint` as internal; marked `mstack-changelog` as utility
- **`/goal` owns the loop**: removed `loop.max_iterations` config and iteration counter. mstack-run does one plan per invocation; `/goal` decides when to stop
- Backlog execution uses Claude Code's native `/goal` command instead of `/loop`

### Fixed
- Worktree cleanup now runs at mstack-run startup and after each plan
- Dependency chain wiring for plans that modify the same skill file sequentially

<!-- commits: 292b084, 83ab19f, 2b7442f, c31475f, 99538cb, 49122e0, 0b97940, 10c7584, 43280d3, c1c1713, 90c5a26, 64bfa70, c9ee80d, c99e189, 76eaaeb, f00657b, 76476d2, a779977, 3fca88d, f04c36a, 10e4c15, caaf2b1, ae46543 -->

## [2.0.0] - 2026-05-20

### Added
- You can now decompose any goal into an ordered plan backlog with `/mstack-plan-multi`, or just say "create a plan for X" in natural language
- Plans are validated, scored on 4 dimensions (Clarity, Testability, Scope-fit, Autonomy-readiness), and reviewed with configurable postures (Expand, Selective, Hold, Reduce) via `/mstack-plan-doctor`
- Full autonomous execution loop: `/loop /mstack-run` picks plans, implements them, runs health checks, reviews code, commits, and moves to the next plan
- Health scoring system (0-10 composite across typecheck, lint, tests, dead code, shell lint) with regression detection and trend tracking
- Cross-model code review with blind scoring that routes one reviewer through Codex or Gemini when available
- Structured debugging with a hard 3-strike rule when health checks fail, with no infinite retry loops
- Crash recovery via checkpoints: if a session dies mid-plan, the next session resumes from facts, not stale reasoning
- Self-healing learnings knowledge base that prunes stale patterns and applies relevant knowledge to future plans
- Three autonomy levels (`full`, `checkpoint`, `supervised`) configurable globally or per-plan (removed in Unreleased)
- Auto-initialization on first use, with no manual setup step required
- Project configuration via `.mstack/config.json` for health commands, scoring weights, review providers, commit conventions, and ignored paths
- Read-only status dashboard (`/mstack-status`) showing backlog state, health trends, and session stats
- 8 bash scripts backing the skill layer for deterministic state operations (bash 3.2 compatible, macOS + Linux)
- Dual install support: `skillshare install aberhamm/mstack` or manual copy to `~/.claude/skills/`

<!-- commits: aa7896e, a08f3ef, 386cab8, 2f17c09, b28441a, 349811e, ca6d6f4, f273bb5, 6a8db20, fc80809, bd333a7, 1959e6f, 2ddcad3, f68aa77, 0211c1f -->
