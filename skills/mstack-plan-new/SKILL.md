---
name: mstack-plan-new
description: Scaffold a new plan file in docs/plans/ (or plans/) from a one-line title
argument-hint: "<one-line title> [-- depends-on <ids|names>]"
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

You are scaffolding a new plan file for the `mstack-run` skill. Do exactly
this and nothing else. Do not implement the plan, do not commit.

**First, check it's plan-sized.** Not every change needs a plan, and being in
a plan-driven repo is not a reason to plan every edit. Scaffold only if the
work needs ordered steps, touches a risky seam, needs a review gate, or is
being deliberately *queued* for later autonomous execution. A typo, one-line
fix, doc correction, config value, rename, or missing test is an errand — say
"this looks small enough to just do; want me to make the change instead?" and
skip the scaffold unless the user still wants it queued. This is easiest to
get wrong right after a plan or goal completes, when follow-up polish gets
reflexively turned into the next plan id.

User input (the title, optionally followed by ` -- depends-on 042,043`):

```
$ARGUMENTS
```

## Steps

1. **Resolve the plans dir.** From the repo root, prefer `docs/plans/`
   (the existing convention in most repos). Fall back to `plans/` only if
   `docs/plans` doesn't exist and `plans/` does.
   ```bash
   REPO_ROOT="$(git rev-parse --show-toplevel)"
   if [ -d "$REPO_ROOT/docs/plans" ]; then
     PLANS_DIR="$REPO_ROOT/docs/plans"
   elif [ -d "$REPO_ROOT/plans" ]; then
     PLANS_DIR="$REPO_ROOT/plans"
   else
     PLANS_DIR="$REPO_ROOT/docs/plans"
     mkdir -p "$PLANS_DIR"
   fi
   ```

2. **Pick the next id.** Find the highest existing leading-number prefix in
   `$PLANS_DIR/*.md` **and** `$PLANS_DIR/archive/*.md` (any digit-width;
   repos use 2-digit `NN-` or 3-digit `NNN-` depending on history) and
   add 1. Default to `1` if empty. Match the digit-width of the highest
   existing file (don't re-pad). Scanning both directories prevents
   duplicate IDs after completed plans are archived.

3. **Parse the input.**
   - Everything before `-- depends-on` (or the whole string) is the title.
   - Anything after `-- depends-on` is a comma-separated list of plan
     references (e.g. `042,043`), captured below as `DEPENDS_RAW`. Default:
     `[]`. Each reference may be a numeric id (unchanged fast path) OR a
     name/slug/title fragment, resolved to its numeric id via the plan-031
     resolver:
     ```bash
     # DEPENDS_RAW = the comma-separated text captured after `-- depends-on`
     RUN_SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
     for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
       [ -d "$RUN_SKILL_DIR" ] && break
       [ -d "${_skill_base}/mstack-run" ] && RUN_SKILL_DIR="${_skill_base}/mstack-run"
     done
     source "$RUN_SKILL_DIR/scripts/lib.sh"
     for _dep in $(echo "$DEPENDS_RAW" | tr ',' ' '); do
       case "$_dep" in
         *[!0-9]*)
           ref_out="$(resolve_plan_ref "$_dep")"; ref_rc=$?
           # ref_rc 0: use the resolved bare id (first field of "id status").
           # ref_rc 21 (ambiguous) or 22 (not found): STOP scaffolding and
           # report the reference plus (for ambiguous) the printed
           # candidates — never guess a dependency id.
           ;;
         *) : ;;  # already numeric, unchanged
       esac
     done
     ```
     A dependency reference may resolve to an archived (already-done) plan —
     that's a normal, valid `blocked-by` target, not an error.
   - Slug = lowercase title, alphanumerics and `-` only, hyphens for spaces,
     trimmed to ~60 chars.
   - Filename: `$PLANS_DIR/NNN-slug.md`.

4. **Read the template** from
   the plan template (check `~/.config/skillshare/skills/mstack-run/plan-template.md`
   first, then `~/.agents/skills/mstack-run/plan-template.md`,
   `~/.codex/skills/mstack-run/plan-template.md`, and
   `~/.claude/skills/mstack-run/plan-template.md`) and write a new file
   with:
   - `id:` set to the new NNN
   - `title:` set to the parsed title (preserve original casing)
   - `status: pending`
   - `blocked-by:` = the parsed list (e.g. `[042, 043]` or `[]`)
   - `priority:` = left blank (optional, user sets if needed)
   - `allows-migrations: false`
   - `needs-review:` = assessed per Step 4a (see below)
   - `created:` = today (YYYY-MM-DD)
   - The Requirements / Design / Tasks / Verification sections left as
     instructional placeholders from the template. The user fills these in
     before running `/mstack-run`.

4a. **Assess review needs.** Based on the title, decide which reviews the
    plan should pass before `mstack-run` picks it up. Set `needs-review:`
    to a comma-separated combination of: `none`, `eng`, `design`, `ceo`.

    Heuristics:
    - **ceo**: scope-defining work, new product surfaces, strategic
      deliverables, anything that changes what the product is (vs how it
      works). Plans that will be shown to external stakeholders, partners,
      or press. Use `/plan-ceo-review`.
    - **eng**: non-trivial architecture decisions, new data flows, schema
      design, performance-sensitive paths, public API contracts, anything
      that will be hard to change once shipped. Use `/plan-eng-review`.
    - **design**: new UI patterns, user-facing copy/content pages, changes
      to core user flows, anything visible to end users where layout,
      hierarchy, or information design matters. Use `/plan-design-review`.
    - **none**: mechanical wiring, internal tooling, pure backend with no
      judgment calls, ports of existing proven logic.

    Plans can need multiple reviews (e.g. `ceo,eng` or `ceo,design`).
    Each reviewer removes their tag when done; `mstack-run` picks
    the plan up only when the field reads `none`.

    If a plan needs review, also set `status: blocked` so `mstack-run`
    won't pick it up until the review clears it (reviewer sets
    `needs-review: none` and `status: pending`).

5. **Print** the created plan ID, file path, the assessed review, and
   suggest scoped run commands:
   ```
   Created plan NNN: "<title>"
   File: $PLANS_DIR/NNN-slug.md (needs-review: <value>)
   Edit Requirements/Design/Tasks before running.
   Run with: /mstack-run NNN
   Or add to a batch: /goal complete mstack plans NNN, ...
   [If needs-review != none]: Run /plan-{ceo,eng,design}-review on this plan first.
   ```

   The output must always include the plan ID so the user can reference it
   in scoped execution commands without looking it up.

Do not stage or commit the file. Do not modify any other plan files.
