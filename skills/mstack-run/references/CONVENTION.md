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

Resolve assets through `mstack-run/scripts/install-paths.sh`. The entry skill
bootstraps it relative to the loaded SKILL.md, so personal, repository-local,
symlink, and copied installs use the same contract. Pass the absolute resolver
path to delegated agents and source it again in each fresh shell.

```bash
source "$MSTACK_RESOLVER"
SKILL_DIR="$(skill_dir mstack-plan-doctor)" || exit 1
```

Read references from the returned skill directory. Resolve `mstack-shared`
the same way; never infer a source checkout by walking `../..`. Only
`mstack_checkout` may locate the optional source checkout for update notices.

`MSTACK_SKILL_DIR` explicitly selects an installation and fails if a requested
skill is missing there. Otherwise sibling skills take precedence over personal
compatibility locations. This keeps resources aligned with the selected skill.

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
| `harness-compatibility.md` | Harness preflight | Delegation prerequisites and unsupported-host behavior |
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

### `mstack-code-review/references/`

| File | Source | Content |
|------|--------|---------|
| `simplifier-brief.md` | Anthropic code-simplifier 1.0.0, adapted | Provider-neutral behavior-preserving simplification contract |
| `LICENSE-anthropic-code-simplifier` | Anthropic code-simplifier 1.0.0 | Apache License 2.0 covering the adapted brief |

### `mstack-ideate/references/`

| File | Source | Content |
|------|--------|---------|
| `clustering.md` | Clustering step | Grouping and ranking generated ideas |
| `critic-and-traps.md` | Critic step | Trap checks against candidate ideas |
| `handoff.md` | Handoff step | Structured handoff into plan-multi |
