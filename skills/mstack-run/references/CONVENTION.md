# Progressive Disclosure CONVENTION

Reference files under `references/` contain detailed specifications that are
loaded on demand via explicit Read directives. This keeps the main SKILL.md
focused on routing and orchestration while preserving full specification
detail for each step.

## When to extract

- Section is >50 lines AND only executes in one code path
- Section is a reference specification (not directly executed by the main agent)
- Section is conditionally loaded (only needed in specific modes or steps)

## When to keep inline

- Section is <50 lines
- Section is the routing/decision logic (always executed)
- Section is hard rules or safety constraints (must always be visible)

## File naming

- `references/<descriptive-slug>.md`
- Use the step name or feature name, not step numbers (numbers change)

## Read directive format

```
> **Read** references/<file>.md before proceeding.
```

## Path resolution

All reference file reads use the SKILL_DIR resolution pattern so they work
in repos where mstack is installed via skillshare:

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
```

Then read via:
```
Read "$SKILL_DIR/references/<file>.md"
```

## Fallback behavior

If a reference file is missing, log a warning and skip the step.
Reference-based steps are additive (frame review, trap detection, etc.),
not blocking. Core routing logic stays inline and never depends on
reference files existing.

## Inventory

| File | Source | Content |
|------|--------|---------|
| `progress-format.md` | Step 2 preamble | All progress output line formats |
| `subagent-prompt.md` | Step 3d | Full prompt template for the implementation subagent |
| `implement-spec.md` | Step 4 | Implementation rules and sizing guidance |
| `health-gate-spec.md` | Step 5 | Health check execution and investigation protocol |
| `verification-spec.md` | Step 5b | Feature correctness verification checks |
| `cleanup-spec.md` | Step 5c | Post-verification cleanup sweep |
| `review-spec.md` | Step 6 | Code review execution and filtering |
| `final-validation.md` | Step 8 | Cross-plan regression detection at backlog completion |
