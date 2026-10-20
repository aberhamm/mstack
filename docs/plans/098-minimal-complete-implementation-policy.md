---
id: 098
title: Add reuse-first guidance to implementation workers
status: pending
blocked-by: []
goal: minimal-complete-implementation
allows-migrations: false
needs-review: none
review-required: eng,code
created: 2026-10-20
reviews:
  - type=eng verdict=approved date=2026-10-20 by=mstack-review
---

## Plain-English Summary

MStack checks for unnecessary complexity after implementation, but its workers
also need clear guidance before they start writing code. This change asks them
to inspect affected callers, reuse what the project provides, and implement the
smallest complete solution. The approved requirements remain binding: simpler
code must still deliver every requested behavior and preserve operational safety.

**What changes in the code:** Add a compact implementation policy to the worker
instructions and their detailed specification, then check that both carry the
same essential safeguards. Keep the existing cleanup, simplification, review,
and verification sequence; installing Ponytail is unnecessary.

## Requirements

For Matthew and other MStack users, prevent avoidable dependencies, speculative
options and abstractions during implementation without encouraging workers to
omit requirements, bypass checks, or stop to debate an implementable plan.

**Acceptance criteria**:

- [ ] Before editing, the worker is instructed to trace affected callers,
  interfaces, tests, fixtures, configuration and exports as applicable, and
  identify project conventions and suitable reusable implementations. This is a
  new required instruction, not a claim that workers perform this reliably today.
- [ ] The worker prefers suitable project helpers and conventions, then suitable
  platform/standard-library facilities and installed dependencies, before adding
  code or dependencies. This is a preference, not a ban: new helpers,
  abstractions and dependencies remain allowed when requirements justify them.
- [ ] Every approved acceptance criterion remains binding. The worker may simplify
  how the plan is implemented only within its approved design constraints; it
  cannot omit behavior, tests or required verification to reduce code size.
- [ ] Guidance explicitly preserves readability, useful architectural boundaries,
  trust-boundary validation, data-loss prevention, error handling, security,
  accessibility and required operational safeguards. No line-count target or
  automatic preference for one-liners is introduced.
- [ ] An optional simpler alternative does not block execution of an implementable
  approved plan. Only a genuine unaccounted design decision uses the architectural
  blocker path in `skills/mstack-run/references/implement-spec.md`.
- [ ] The policy reaches the actual injected Step B in
  `skills/mstack-run/references/subagent-prompt.md` and agrees with the detailed
  implementation rules in `skills/mstack-run/references/implement-spec.md`.
  Claude and Codex receive it through the full parent-supplied worker brief;
  adapter discovery is not presented as proof of live compatibility.
- [ ] Normalized directive checks guard both instruction surfaces and detect
  removal of the scope-preservation safeguard. They are documented as presence
  checks, not evidence that a model obeys the instructions.
- [ ] Three bounded manual behavior probes have reproducible fixtures, expected
  outcomes and honest evidence records. Any unrun host is labeled untested;
  no model-performance, token-saving or correctness improvement is claimed
  from substring checks or Ponytail's upstream benchmark.
- [ ] No Ponytail plugin, automatic hook, metrics collection, new execution stage,
  new configuration toggle or change to the result/review/health contracts is
  introduced.

## Design

### Placement and existing flow

`skills/mstack-run/SKILL.md` Step 3d requires reading and embedding the complete
`references/subagent-prompt.md` template in the worker invocation. Its later
Steps 4-6 section calls the detailed reference files authoritative specifications
and the prompt template the executable version. Update both implementation
surfaces consistently; modifying only the detailed spec would miss the brief
actually sent to the worker.

`skills/mstack-run/references/subagent-prompt.md` Step C4 and
`skills/mstack-code-review/references/simplifier-brief.md` already protect exact
behavior, clarity and useful abstractions during simplification. Keep that
existing stage, ordering, review independence, gate reruns and rollback behavior.
There is no second Ponytail review pass.

### Policy content

Add one short, agent-neutral section before implementation in each surface:

1. Inspect the affected flow and what already exists before choosing a solution.
2. Reuse suitable house patterns first; use suitable platform features,
   standard-library facilities and installed packages before adding dependencies.
3. Choose the smallest complete implementation satisfying all acceptance criteria
   and approved design constraints. Avoid unrequested options, wrappers,
   conversions and abstractions; add them when the actual task needs them.
4. Favor readable code and useful boundaries over fewer lines. Preserve required
   safety, accessibility, error handling, tests and operational protections.
5. Continue with an implementable approved plan even if another approach looks
   smaller. Record material alternatives/deviations in the existing result
   summary; do not change the result schema or create an approval round.
   A genuine architectural blocker follows the existing failure contract.

Do not copy the full upstream persona, modes, forced reply footer, mandatory
shortcut comments or unconditional test-per-branch rule. Existing project test
requirements and MStack gates continue to determine verification obligations.

### Reachability and adapters

Inspect `.codex/agents/mstack-worker.toml` and the worker adapters under
`adapters/` to confirm that they defer to the complete parent brief. Keep them
thin; do not paste the policy into every adapter or global AGENTS.md. If an
adapter actually bypasses the parent brief, report that concrete gap during
engineering review instead of quietly expanding this plan into a harness rewrite.
This plan does not promote experimental or unverified hosts.

### Verification scope and limits

Extend `skills/mstack-run/scripts/brief-content-smoke.sh`, reusing its
whitespace-normalized checks, with short safeguard phrases for the policy's
placement, reuse preference, full scope and readability/safety requirements.
Scope the new assertions to Step B (ending at Step C) and the corresponding
implementation-policy section in the detailed spec; matching phrases elsewhere
must not hide a missing directive at the injection site.
Avoid matching whole paragraphs. Validate a reflowed copy still passes and a
throwaway fixture with the scope-preservation directive independently removed
from each surface fails, even if the phrase survives elsewhere in the file. Use
the same assertion logic for real files and fixture copies. Run the reflow and
negative-fixture cases inside this executable smoke suite so Step C2 cannot
skip them as manual checks. Preserve all pre-existing smoke coverage, with one
known-baseline repair: the existing no-serial assertion expects the obsolete
phrase "never turn the group into serial tool calls", but the current doctor
correctly supports a single-question-tool fallback. Replace that stale literal
with checks for both the multi-question-host batching rule and the explicit
single-question-UI fallback in the current policy. Do not change the workflow
policy merely to satisfy the stale assertion. Restore
fixtures afterward; never mutate an installed skill or shared checkout as a test.
These checks only establish that the directive survives distribution and editing.

Document three manual probes, using fresh disposable local fixture repositories
with an explicit tiny plan, no network/production credentials, and fixed starter
files. Each probe must state the exact task, starter code and expected behavior:

- **Reuse:** two callers plus a shared normalization helper; request a small
  behavior change that the helper can support. Expect the helper to be reused,
  both callers to retain the required behavior, and no duplicate implementation
  or new package.
- **Necessary addition:** a task with two consumers and a new shared behavior
  absent from the starter code, with the approved design explicitly requiring
  a shared helper. Expect the new helper and complete behavior, rather than
  duplication or refusal to add an abstraction.
- **Safety and scope:** an export task explicitly requiring validation,
  authorization and user-visible error handling. Offer an apparently smaller
  path that omits one safeguard. Expect all requirements and checks retained;
  the optional alternative must not become a blocker.

Manual review must examine the resulting diff and execute the fixture's expected
behavior checks. Record client/model versions, starting revision, task, observed
outcome and limitations. Run on available Claude/Codex hosts; mark unavailable
hosts untested without treating a capability gap as policy success. Do not build
a benchmark harness or call production/business services from the fixtures.
Fixtures require no network access or service credentials. The host may use its
existing authenticated Claude/Codex provider connection to run the model probe;
do not add new credentials or integrations. Store durable probe evidence outside
a disposable checkout before cleanup.

Step C2 skips `[manual]` verification entries, so a skipped manual entry is not
evidence that these probes ran. Task 4 must run all three probes on each available
Claude/Codex host, retain the complete supplied worker brief, starting files and
plan, resulting diff, behavior-check commands/output, and a pass/fail/untested
result per probe and host in the documented evidence location. The independent
completion-time code reviewer must inspect those records: an available-host probe
that was not run, a failed behavior check, or missing evidence is incomplete work,
not an untested-host exemption. If neither host can run, document the actual
capability/auth error and the limitation; claim directive coverage only. No
statistical comparison or baseline performance improvement is claimed.

**Testing approach: unit-only.** Deterministic directive checks plus explicitly
manual model-behavior probes; no UI, API or runtime pipeline is added.

**Files expected to change:**

- `skills/mstack-run/references/implement-spec.md`: detailed implementation policy.
- `skills/mstack-run/references/subagent-prompt.md`: equivalent Step B worker policy.
- `skills/mstack-run/scripts/brief-content-smoke.sh`: bounded directive checks.
- `docs/implementation-policy-probes.md`: new manual probe recipes and evidence
  rubric, including limits of presence checks.

**Provenance:** Inspired by the reuse-first and smallest-complete-change
principles in [Ponytail's core skill](https://github.com/DietrichGebert/ponytail/blob/main/skills/ponytail/SKILL.md),
reviewed 2026-10-20. Write concise MStack-specific guidance. If implementation
copies upstream text instead, retain the upstream MIT attribution/license for
that copied material. No upstream runtime or automatic update dependency.

**Out of scope:** Installing/distributing Ponytail, new plugins or skills,
planning scope reduction, new review stages, mode switching, telemetry, cost
claims, broad doctrine deduplication, global instruction edits, deployment or
skill synchronization on either Mac.

## Tasks

1. Recheck the two instruction surfaces, existing simplifier contract and
   parent-brief adapter paths; confirm no pending plan duplicates this change.
2. Add the compact policy to the detailed implementation specification and
   injected Step B, preserving all completion and failure contracts.
3. Extend the existing directive smoke suite with normalized checks for both
   surfaces; prove reflow tolerance and missing-safeguard failure in disposable
   fixtures as executable cases in that suite. Reconcile the known stale
   no-serial assertion with current batching and single-question-host semantics,
   preserving its intended coverage. Do not turn prose matching into a claim
   of model compliance.
4. Write the three fixed manual probe recipes and run available-host probes,
   recording results or explicit untested-host limitations with preserved evidence.
5. Run required repository checks, inspect the scoped diff for contract changes,
   and obtain the normal independent code review before completion.

## Verification

- [cmd] `bash skills/mstack-run/scripts/brief-content-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `ruby bin/mstack-metadata-check`
- [cmd] `git diff --check`
- [manual] Inspect the executable smoke output for passing reflow cases and
  independently rejected missing-scope directives in both surfaces, including
  decoy phrases outside the checked sections.
- [manual] Run the three documented probes on available Claude/Codex hosts;
  inspect diffs and actual fixture behavior, record versions and outcomes, and
  identify unavailable hosts explicitly.
- [manual] Inspect the diff: no stage/order changes, weakened health/review gates,
  altered result schema, duplicated adapter policy or global plugin installation.

Because this plan edits a file under scripts/, implementation must also run the
full required smoke-suite set listed in AGENTS.md, plus shell syntax/lint checks.
The presence checks above do not replace those required checks.

## Authoring Notes

Pending plan 085 may later consolidate doctrine, but does not block this change.
Keep the current two-surface contract; any later consolidation must preserve the
injection-site checks.

Structural critique completed on 2026-10-20 through a read-only Codex CLI
review and an independent reviewer subagent. Both supported a single plan;
clarifications about optional alternatives, section-scoped directive checks,
necessary additions and the limits of behavior evidence are incorporated above.
These critiques are not an engineering approval or a code-review verdict.


## Engineering Review

Reviewed 2026-10-20 by `plan-eng-review`, scope held. The policy is a preference
within the approved plan, not a promise of better model output. The two source
surfaces currently lack this pre-implementation guidance; adapter files only
instruct workers to follow the complete parent brief. Those facts justify the
chosen placement without proving Claude/Codex compliance.

### What already exists

- `skills/mstack-run/SKILL.md` Step 3d embeds the complete worker prompt; Steps
  4-6 name the detailed spec authoritative. Both surfaces are reused.
- `subagent-prompt.md` Step C4 and `simplifier-brief.md` preserve behavior, clarity
  and useful boundaries after implementation. Their flow stays intact.
- `brief-content-smoke.sh` normalizes whitespace and checks short directives.
  Extend that mechanism rather than introduce another checker.
- `.codex/agents/mstack-worker.toml` and
  `adapters/copilot-vscode/mstack-worker.agent.md` both defer to the parent brief.
  No adapter edit is required by the reviewed source.

### NOT in scope

- Plugin hooks, metrics and benchmark infrastructure: unnecessary to deliver the
  policy and would require new contracts.
- Global skill installation/synchronization: separate operational rollout, not
  evidence of correctness of these repository edits.
- Redesigning question routing: only its stale smoke expectation is repaired.
- Statistical A/B evaluation or token savings: three task probes cannot support
  those claims.

### Test coverage and failure modes

```text
parent complete brief -> Step B policy -> implementation -> existing C/C2/C4/D
                           |                  |
                           |                  +-> 3 fixture probes [EVAL]
                           |                       reuse / necessary addition /
                           |                       safety + scope
                           +-> scoped directive smoke [presence only]
                                +-> both real sections present: pass
                                +-> whitespace reflow: pass
                                +-> Step B scope directive absent: fail
                                +-> spec scope directive absent: fail
                                +-> phrase outside section: still fail
                                +-> section/file absent: fail
existing batching policy -> smoke expectation
                                +-> multi-question batching present: pass
                                +-> single-question fallback present: pass
                                +-> either directive missing: fail
probe evidence -> independent code reviewer -> ordinary completion gate
```

All new deterministic cases belong in `brief-content-smoke.sh`; they must report
failure with a nonzero exit rather than silently skipping a missing source or
section. The documentation must provide exact starter inputs and commands before
model runs. No UI routes or deployed services are affected.

| Failure | Coverage and handling | Visible result |
|---------|-----------------------|----------------|
| Policy moved outside injected Step B | Scoped checks and outside-section decoy fixture | Failing smoke check |
| Scope safeguard lost in either surface | Independent negative fixture for each surface | Failing smoke check |
| Reflow causes a false failure | Reflowed copy through the same checker | Passing positive fixture |
| Stale batching assertion prevents completion | Assert current batching plus fallback semantics | Baseline failure resolved without workflow change |
| Worker duplicates code or refuses a required helper | Reuse and necessary-addition probes with actual behavior checks | Evidence records show failure |
| Worker removes safety or stalls for an optional alternative | Safety/scope probe, diff inspection and behavior checks | Evidence records show failure |
| Model host unavailable or evidence skipped | Record actual error; reviewer checks host/probe matrix | Untested limitation or incomplete task, not success |

**Baseline:** Doctor's pre-change run of `brief-content-smoke.sh` failed 1 of 49
assertions: the stale no-serial literal described above. Script-mode and metadata
checks passed. Do not describe the baseline suite as green.

### Section verdicts and implementation tasks

Architecture: no structural issues; four files, no new runtime or dependency.
Code quality: no new issues; keep two required instruction surfaces consistent
with section-scoped checks. Tests: three clarifications folded into Tasks 3-5:
execute mutation cases inside the smoke suite, distinguish fixture isolation from
host provider calls, and require reviewable probe evidence despite manual-check
skipping. Performance: no runtime or caching change; no performance claim.

- [ ] **T1 (P2, human: ~30 min / agent: ~5 min)**: implement the executable reflow,
  negative/decoy and missing-section cases with shared assertion logic; repair
  the stale batching assertion against the existing routing policy. Verify with
  `brief-content-smoke.sh` and required repository suites. Source: test review.
- [ ] **T2 (P2, human: ~1 h / agent: ~15 min)**: document exact probe fixtures and
  run the available-host matrix; preserve briefs, diffs and behavior-check
  results for the independent reviewer. Source: test review's manual-skip and
  provider-connection contradictions.

Sequential implementation, no parallelization opportunity. No new TODO items;
no critical failure gap remains unaddressed. No durable learnings this session.


<!-- mstack:seam
produced:
- kind: file; name: docs/implementation-policy-probes.md; file: docs/implementation-policy-probes.md
assumed:
-->

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | Not required | Scope held |
| Codex Review | Doctor read-only audit | Independent premise challenge | 1 | Clear | No actionable source-backed premise findings; parent rechecks amended plan |
| Eng Review | `/plan-eng-review` | Architecture & tests | 1 | Clear | 3 verification issues resolved; 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | Not required | No UI changes |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | Not required | Existing worker flow retained |

**VERDICT:** ENG CLEARED for implementation. Doctor amendment re-pass and
approval commit remain with the parent. Code review remains required at completion.

NO UNRESOLVED DECISIONS
