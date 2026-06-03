---
id: 10
title: Enforce minimum testing standards with E2E requirements and /browse integration
status: in-progress
blocked-by: [9]
needs-review: none
created: 2026-06-03
---

## Requirements

Plans currently pass validation with grep-based verification checks ("does the
file exist?", "does the string appear?") and no real end-to-end testing. A plan
that creates an API endpoint but only verifies the file was created shouldn't
score well on testability. The planning pipeline needs to enforce a minimum
testing bar, generate E2E test tasks proactively, and use browser-based
verification when gstack's /browse skill is available.

This plan strengthens testing across three points in the pipeline: plan-doctor
(validation), plan-multi (generation), and mstack-run (execution).

**Acceptance criteria:**

Plan-doctor enforcement:

- [ ] Plans that touch user-facing code (UI components, API endpoints, pages, routes) must include at least one `[cmd]` or `[status]` verification check that exercises the running application, not just file existence checks. Plans missing this are flagged as a testability error, not a warning.
- [ ] Plans that touch web-facing code (pages, components, CSS, templates) must include at least one browser-testable verification check (`[browse]` or `[e2e]` tag in the verification section). If the project has no E2E framework detected and gstack's /browse is unavailable, downgrade to a warning instead of an error.
- [ ] Plan-doctor's testability scoring penalizes verification sections that consist only of `grep` and `test -f` checks: max testability score of 5/10 when all checks are file-existence or string-matching only.
- [ ] Plan-doctor's "what would make it a 10" output explicitly suggests E2E checks when the plan touches web-facing code: "Testability: add a [browse] or [e2e] check that verifies the feature works in a browser"
- [ ] Plan-doctor auto-fix for testability: when a plan scores below 7/10 on testability and touches web-facing files, automatically generate a `[browse]` check from the acceptance criteria (e.g., acceptance criterion "page shows billing dashboard" becomes `[browse] navigate to /settings/billing, verify 'Current Plan' text is visible`)

Plan-multi generation:

- [ ] When plan-multi decomposes a goal that involves UI or API endpoints, at least one plan in the generated backlog must include E2E verification (not just unit-level checks)
- [ ] For goals involving web UI, plan-multi generates verification checks that reference `/browse` when gstack is detected, or Playwright/Cypress when E2E frameworks are detected in the project
- [ ] Plan-multi's generated plans include a "Testing approach" line in the Design section stating whether verification is unit-only, E2E, or browser-based, making the decision explicit

mstack-run /browse integration:

- [ ] When mstack-run encounters a `[browse]` verification check during plan execution, it invokes gstack's `/browse` skill to verify the check
- [ ] Before attempting `[browse]` checks, mstack-run detects whether gstack is installed: check for `~/.claude/skills/gstack/browse/SKILL.md` or `~/.config/skillshare/skills/browse/SKILL.md`
- [ ] If gstack is not installed, `[browse]` checks are skipped with a warning: "Skipped [browse] check: gstack not installed. Install gstack for browser-based verification."
- [ ] `[browse]` checks follow a simple format: `[browse] <url-or-path> <assertion>` where the assertion is a natural language description of what to verify (e.g., `[browse] /settings/billing verify 'Current Plan' heading is visible and shows a plan name`)
- [ ] mstack-run starts the dev server (if not already running) before executing `[browse]` checks, using the project's start command from CLAUDE.md or package.json
- [ ] `[browse]` check failures are treated the same as `[cmd]` failures: the plan enters investigation

## Design

**Files expected to change:**

- `skills/mstack-plan-doctor/SKILL.md`: add testability enforcement rules, auto-fix for E2E checks, scoring penalty for grep-only verification
- `skills/mstack-plan-multi/SKILL.md`: add E2E verification generation rules, testing approach line in Design template
- `skills/mstack-run/SKILL.md`: add `[browse]` check execution, gstack detection, dev server management
- `skills/mstack-run/plan-template.md`: add `[browse]` check format documentation to the verification section

**Approach:**

**Plan-doctor changes (Step 2 scoring + Step 3 validation):**

Add a new rule to testability scoring in Step 2:

```
Testability scoring additions:
- If ALL verification checks are file-existence (test -f) or string-matching
  (grep) only: cap testability at 5/10 regardless of how many checks exist.
  These checks prove the worker wrote files, not that the feature works.
- If plan touches web-facing files (detect from "Files expected to change":
  pages/, components/, routes/, templates/, *.tsx, *.vue, *.html, *.css) AND
  has no [browse], [e2e], [cmd] with curl/httpie, or [status] check: flag as
  testability error.
- Auto-fix: generate a [browse] check from the first user-facing acceptance
  criterion. Format: [browse] <likely-route> verify '<key text from criterion>'
```

Add to the "what would make it a 10" output:
```
If testability < 8 and plan touches web-facing files:
  "Testability: add a [browse] or [e2e] check that verifies the feature
   works in a browser, not just that files exist"
```

**Plan-multi changes (plan generation):**

Add to Step 3 (plan authoring) or the equivalent generation step:

```
Testing approach rule:
- For each generated plan, add a "Testing approach:" line to the Design section
  stating: unit-only, E2E, or browser-based.
- Default to "browser-based" for plans touching pages/components/routes.
- Default to "E2E" for plans touching API endpoints.
- Default to "unit-only" for plans touching only internal logic/utilities.

Verification generation rule:
- When generating verification for web-facing plans:
  1. Check if gstack is installed (browse skill available)
  2. If yes: generate [browse] checks referencing the page/route
  3. If no: check for Playwright/Cypress in the project
  4. If E2E framework exists: generate [cmd] checks using the framework
  5. If neither: generate [cmd] curl checks for API endpoints, or
     flag that the plan needs manual verification setup
```

**mstack-run changes (verification execution):**

Add to Step 4 (verification) or the equivalent execution step:

```
[browse] check execution:
1. Detect gstack: test -f ~/.claude/skills/gstack/browse/SKILL.md or
   test -f ~/.config/skillshare/skills/browse/SKILL.md
2. If not found: print warning, skip [browse] checks, continue
3. If found: ensure dev server is running
   - Read CLAUDE.md for start command, or check package.json "dev"/"start"
   - Start if not running, wait for ready (poll health endpoint or port)
4. For each [browse] check:
   - Parse: [browse] <path> <assertion>
   - Invoke /browse skill with: navigate to <path>, verify <assertion>
   - Treat failure like any other verification failure (enter investigation)
5. After all [browse] checks complete, stop dev server if we started it
```

**Out of scope:**

- Writing actual E2E test files (that's the worker's job during implementation)
- Modifying the health gate scoring weights for E2E
- Adding /browse as a required dependency for mstack
- Changing existing plans in the backlog to add [browse] checks retroactively

## Tasks

1. Add testability scoring rules to plan-doctor SKILL.md: cap at 5/10 for grep-only verification, flag missing E2E for web-facing plans
2. Add testability auto-fix to plan-doctor: generate [browse] checks from acceptance criteria when testability is low and plan is web-facing
3. Add "what would make it a 10" E2E suggestion to plan-doctor output
4. Add testing approach line requirement to plan-multi's plan generation instructions
5. Add verification generation rules to plan-multi: detect gstack/E2E frameworks, generate appropriate check types
6. Add [browse] check format documentation to plan-template.md
7. Add [browse] execution logic to mstack-run SKILL.md: gstack detection, dev server management, check parsing, failure handling

## Verification

- [assert] grep -i 'cap.*5/10\|max.*5.*grep\|file-existence.*cap' skills/mstack-plan-doctor/SKILL.md
- [assert] grep -i '\[browse\]' skills/mstack-plan-doctor/SKILL.md
- [assert] grep -i 'testing approach\|test.*approach' skills/mstack-plan-multi/SKILL.md
- [assert] grep -i '\[browse\].*check\|\[browse\].*execution\|\[browse\].*format' skills/mstack-run/SKILL.md
- [assert] grep -i 'gstack.*detect\|browse.*SKILL.md\|gstack.*install' skills/mstack-run/SKILL.md
- [assert] grep -i '\[browse\]' skills/mstack-run/plan-template.md
- [assert] grep -i 'dev server\|start.*server\|server.*running' skills/mstack-run/SKILL.md
