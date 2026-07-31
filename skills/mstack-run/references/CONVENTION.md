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

**This is THE resolution idiom.** All reference file reads (and any other
read of a file shipped inside a skill) use the 4-path SKILL_DIR resolution
pattern so they work in repos where mstack is installed via Skillshare,
Agents, Codex, or Claude. The search order is fixed:
skillshare → agents → codex → claude.

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/<skill-name>"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/<skill-name>" ] && SKILL_DIR="${_skill_base}/<skill-name>"
done
```

Substitute the skill being resolved for `<skill-name>` (`mstack-run` for
shared scripts and references, `mstack-plan-doctor` for doctor's own
references, and so on). When only the scripts directory is needed, the same
shape applies with `/scripts` appended to both the seed and the probe.

Then read via:
```
Read "$SKILL_DIR/references/<file>.md"
```

### Competing variants (converge on the above)

Two other shapes are in the tree today. Both work; neither is the blessed
form, and new code must not add more of them. Converging them is follow-up
work, not part of any single skill's edit:

1. **Skillshare-inside-the-loop.** Seeds the loop with all four bases
   (`for _skill_base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" ...`)
   instead of seeding `SKILL_DIR` from skillshare and looping over the other
   three. Present in `mstack-run`, `mstack-plan-multi`, `mstack-handoff`, and
   `mstack-wrap-up`.
2. **Single-path gstack probes.** Availability checks for optional gstack
   skills (`plan-eng-review`, `plan-ceo-review`, `plan-design-review`,
   `browse`, `codex`, `investigate`) test only
   `~/.config/skillshare/skills/<skill>/SKILL.md` with no fallback, so they
   report "unavailable" on agents/codex/claude installs. Present in
   `mstack-plan-doctor`, `mstack-plan-multi`, `mstack-code-review`,
   `mstack-investigate`, and `mstack-run/references/verification-spec.md`.
   These fail open (the skill degrades gracefully), which is why they are
   tolerated rather than urgent.

## Fallback behavior

If a reference file is missing, log a warning and skip the step.
Reference-based steps are additive (frame review, trap detection, etc.),
not blocking. Core routing logic stays inline and never depends on
reference files existing.

## Inventory

Every skill that ships a `references/` directory is listed here. Adding a
reference file means adding a row.

### `mstack-run/references/`

| File | Source | Content |
|------|--------|---------|
| `CONVENTION.md` | (this file) | The extraction, path-resolution, and inventory rules |
| `progress-format.md` | Step 2 preamble | All progress output line formats |
| `subagent-prompt.md` | Step 3d | Full prompt template for the implementation subagent |
| `implement-spec.md` | Step 4 | Implementation rules and sizing guidance |
| `health-gate-spec.md` | Step 5 | Health check execution and investigation protocol |
| `verification-spec.md` | Step 5b | Feature correctness verification checks |
| `cleanup-spec.md` | Step 5c | Post-verification cleanup sweep |
| `review-spec.md` | Step 6 | Code review execution and filtering |
| `final-validation.md` | Step 8 | Cross-plan regression detection at backlog completion |

### `mstack-plan-doctor/references/`

| File | Source | Content |
|------|--------|---------|
| `adversarial-audit.md` | Adversarial audit pass | Attacks on a plan's stated guarantees |
| `frame-review.md` | Frame review pass | Cognitive-frame review of a plan |
| `seam-contracts.md` | Seam validation | Contract checks across plan boundaries |
| `testing-audit.md` | Testing audit | Verification-coverage gaps in a plan |
| `trap-resistance.md` | Trap scoring | Known plan traps and resistance scoring |

### `mstack-plan-multi/references/`

| File | Source | Content |
|------|--------|---------|
| `divergent-decomposition.md` | Decomposition step | Alternative decompositions before committing |
| `structural-critique.md` | Critique step | Multi-model structural critique of the backlog |

### `mstack-ideate/references/`

| File | Source | Content |
|------|--------|---------|
| `clustering.md` | Clustering step | Grouping and ranking generated ideas |
| `critic-and-traps.md` | Critic step | Trap checks against candidate ideas |
| `handoff.md` | Handoff step | Structured handoff into plan-multi |
