# Cognitive Frames

Reusable prompt blocks for plan review and decomposition. Each frame defines a distinct
perspective with its own vocabulary, biases, and blind spots it uniquely covers.

**Design principle:** Frames use behavioral instructions ("Check for X, flag Y, assume Z"),
never identity claims ("You are an expert X"). Per USC research (arXiv:2603.18507), persona
prompting degrades accuracy on knowledge tasks; behavior-first instructions preserve accuracy
while still shaping review focus. Frame names are human-readable labels only.

---

## Review Frames

### Security Review

**Review checklist:**
- Unvalidated inputs and missing sanitization
- Missing auth checks on new endpoints or routes
- Data exposure risks and trust boundary violations
- Injection vectors (SQL, command, prompt, path traversal)
- Privilege escalation paths and role-check gaps
- Secrets or credentials in code, config, or logs

**Behavioral bias:** Assume every input is hostile. Assume attackers will find every shortcut.
Flag anything that handles user data without explicit sanitization. Treat missing auth as a
blocking finding, not a nice-to-have.

**What this catches that other frames miss:** Trust boundaries and data flow risks that
functional reviewers overlook because they think about happy paths.

**Keywords:** auth, security, tokens, passwords, uploads, user data, API, endpoints, secrets,
credentials, sanitize, validate, permissions, roles, CORS, CSP, encryption

**Example findings:**
- "Plan creates a new API endpoint but does not specify auth middleware"
- "File upload handler does not mention size limits or type validation"
- "Environment variable containing a secret is logged during debug mode"

---

### Performance and Scaling Review

**Review checklist:**
- Unbounded queries (missing LIMIT, no pagination)
- N+1 query patterns or unnecessary sequential I/O
- Missing indexes on columns used in WHERE or JOIN clauses
- Large payload serialization without streaming
- Hot paths without caching strategy
- Memory allocation in tight loops

**Behavioral bias:** Assume the dataset is 100x larger than the current one. Flag any
operation that scales worse than O(n log n) without justification. Treat "it works for
now" as a yellow flag when the plan touches data paths.

**What this catches that other frames miss:** Latency cliffs and resource exhaustion that
only appear at scale, invisible in development with small datasets.

**Keywords:** database, query, index, cache, latency, throughput, pagination, batch,
streaming, memory, CPU, connection pool, rate limit, concurrent, scaling

**Example findings:**
- "Plan loads all records into memory for filtering instead of using a database query"
- "New database table has no index strategy despite being queried by three endpoints"
- "Webhook handler processes events synchronously with no queue or backpressure"

---

### On-Call and Operability Review

**Review checklist:**
- Missing or insufficient error handling and recovery paths
- Silent failures (caught exceptions with no logging or alerting)
- Missing health checks, readiness probes, or liveness signals
- No runbook or troubleshooting guidance for new failure modes
- Missing metrics, logs, or traces for diagnosing production issues
- Deployment rollback strategy not addressed

**Behavioral bias:** Assume this code will break at 3am and you are the one who gets paged.
Flag anything that would make diagnosis harder: silent failures, missing context in error
messages, no way to distinguish "broken" from "slow." Prefer loud failures over silent
data corruption.

**What this catches that other frames miss:** Operability gaps that make incidents longer
and harder to diagnose, invisible during development but critical in production.

**Keywords:** monitoring, alerting, logging, error handling, retry, timeout, circuit breaker,
health check, rollback, deploy, observability, metrics, traces, incident, on-call

**Example findings:**
- "New service has no health check endpoint; orchestrator cannot detect failures"
- "Error handler catches all exceptions and returns a generic 500 with no log context"
- "Plan adds a new external dependency but does not specify timeout or retry behavior"

---

### End User and Product Review

**Review checklist:**
- User-visible error messages that expose internals or are unhelpful
- Missing loading states, empty states, or error states in UI flows
- Accessibility gaps (no labels, missing keyboard navigation, color-only indicators)
- Broken or confusing user flows after the change
- Missing or misleading feedback for user actions
- Data loss risks from user perspective (unsaved changes, no confirmation)

**Behavioral bias:** Assume the user has never seen this product before and is on a slow
connection. Flag anything where the user would not know what happened, what went wrong,
or what to do next. Treat "the developer knows how to use it" as insufficient.

**What this catches that other frames miss:** UX friction and confusion that developers
overlook because they understand the system internals.

**Keywords:** UI, UX, user, frontend, component, page, form, button, modal, toast,
notification, accessibility, a11y, responsive, mobile, error message, loading, empty state

**Example findings:**
- "Form submission has no loading indicator; users will click submit multiple times"
- "Error state shows a raw error code instead of a human-readable message"
- "Destructive action has no confirmation dialog; one click deletes data permanently"

---

### Adversarial Testing Review

**Review checklist:**
- Edge cases not covered by tests (empty inputs, nulls, max-length, unicode, special chars)
- Race conditions and concurrent access patterns
- State corruption from partial failures or interrupted operations
- Boundary conditions (off-by-one, integer overflow, empty collections)
- Dependency failures (network down, disk full, third-party API errors)
- Assumptions about input ordering or timing

**Behavioral bias:** Assume every boundary will be hit and every race condition will fire.
Specifically look for inputs the developer did not think to test. Flag any assumption about
ordering, timing, or availability that is not enforced by code.

**What this catches that other frames miss:** Failure modes that only appear with unusual
inputs or timing, missed by happy-path testing and code review focused on logic.

**Keywords:** edge case, boundary, race condition, concurrent, null, empty, overflow,
timeout, retry, idempotent, test, mock, fixture, fuzzing, invariant

**Example findings:**
- "Handler assumes array is non-empty but no guard prevents an empty array from reaching it"
- "Two concurrent requests can both read-then-write the same counter, causing a lost update"
- "Test suite only covers the success path; no test for what happens when the API returns 429"

---

### Cost and Budget Review

**Review checklist:**
- Unbounded API calls to paid services (LLM tokens, cloud functions, third-party APIs)
- Missing cost controls (rate limits, budget caps, usage alerts)
- Expensive operations in hot paths (per-request LLM calls, per-row external lookups)
- Storage growth without retention or cleanup policy
- Resource provisioning without cost estimates
- Duplicate work that could be cached or batched

**Behavioral bias:** Assume the feature will be used 10x more than expected and every API
call costs money. Flag any path where cost scales linearly (or worse) with usage without
an explicit budget control. Treat "we will optimize later" as a finding.

**What this catches that other frames miss:** Runaway costs that accumulate gradually and
only become visible on the monthly bill, not during development or testing.

**Keywords:** cost, budget, billing, API calls, tokens, usage, quota, rate limit, cloud,
storage, compute, pricing, credits, metering, LLM, inference

**Example findings:**
- "Each user action triggers an LLM call with no caching; 1000 users means 1000 API calls"
- "Log storage grows unbounded with no retention policy; estimated 50GB per month at scale"
- "Plan provisions a GPU instance for a batch job but does not specify auto-shutdown"

---

### Simplicity Advocate Review

**Review checklist:**
- Premature abstractions (interfaces with one implementation, generic frameworks for one use case)
- Unnecessary indirection layers that obscure control flow
- Features or configuration options that have no current user
- Complex solutions where a simpler alternative exists
- Code that optimizes for flexibility over readability
- Dependencies added when stdlib or existing code would suffice

**Behavioral bias:** Assume every abstraction, dependency, and configuration option must
justify its existence with a concrete current need. Flag anything built for a future
requirement that is not in the current plan. Prefer inline code over indirection,
fewer files over more, and deletion over deprecation.

**What this catches that other frames miss:** Over-engineering and accidental complexity
that passes functional review because the code "works" but makes the codebase harder to
understand and maintain.

**Keywords:** abstraction, interface, factory, wrapper, config, options, plugin, framework,
dependency, library, indirection, layer, generic, flexible, extensible

**Example findings:**
- "Plan introduces a plugin system for a feature that currently has one implementation"
- "New utility module wraps a stdlib function with identical behavior and no added value"
- "Configuration file supports 12 options but the plan only uses 2; the rest are speculative"

---

### Future Maintainer Review

**Review checklist:**
- Missing or misleading comments on non-obvious logic
- Implicit conventions not documented anywhere
- Magic numbers and unexplained constants
- Coupling between modules that makes isolated changes impossible
- Missing type definitions or overly broad types (any, unknown, object)
- Test coverage gaps on critical paths
- File or function names that do not describe what they actually do

**Behavioral bias:** Assume the next person to touch this code has no context about why
decisions were made. Flag anything where understanding requires reading the git blame or
asking the original author. Prefer explicit over clever, boring over elegant, and
self-documenting names over comments that explain bad names.

**What this catches that other frames miss:** Maintenance burden and knowledge silos that
make future changes slow, risky, and dependent on tribal knowledge.

**Keywords:** documentation, comments, naming, types, coupling, cohesion, modularity,
test coverage, refactor, technical debt, convention, migration, deprecation

**Example findings:**
- "Function named `process` takes 6 parameters with no documentation on what they control"
- "Magic number 86400 appears in three files; should be a named constant (SECONDS_PER_DAY)"
- "Module imports from 4 other modules' internals; changing any of them requires updating this file"

---

## Decomposition Frames

### Minimize Coupling

**Decomposition checklist:**
- Each plan touches files in at most one module or domain area
- Cross-plan data contracts are defined explicitly (shared types, API schemas)
- No plan requires reading another plan's uncommitted code to compile or test
- Shared dependencies are extracted into their own plan, ordered first
- Plans can be implemented by someone who has not read the other plans

**Behavioral bias:** Assume each plan will be implemented in isolation with no communication
between runs. Flag any plan that implicitly depends on another plan's internal choices
(file layout, variable names, implementation approach). Prefer duplication over coupling
when the shared code is small.

**What this catches that other frames miss:** Hidden dependencies between plans that cause
cascading failures when one plan's implementation differs from what another plan assumed.

**Keywords:** dependency, import, shared, interface, contract, coupling, isolation, module,
boundary, API, schema, type

**Example findings:**
- "Plan 3 imports a helper from plan 2, but plan 2 could implement it differently than expected"
- "Plans 4 and 5 both modify the same config file; execution order determines the final state"
- "Plan 6 assumes plan 3 exports a specific function name, but plan 3 does not specify its API"

---

### Maximize Parallelism

**Decomposition checklist:**
- Plans that can run concurrently have no blocked-by relationship
- The critical path (longest chain of sequential dependencies) is minimized
- Independent features are separate plans, not bundled into one large plan
- Shared infrastructure plans are extracted early so dependents can start sooner
- No plan blocks more than 2 other plans (fan-out is preferred over serial chains)

**Behavioral bias:** Assume execution resources are abundant but wall-clock time is the
constraint. Flag any unnecessary sequential dependency. Prefer splitting a large plan
into two independent ones over keeping it as one, even if the total work increases slightly.

**What this catches that other frames miss:** Unnecessary serialization that doubles
total execution time when plans could run concurrently.

**Keywords:** parallel, concurrent, dependency, blocked-by, critical path, fan-out,
independent, sequential, chain, bottleneck

**Example findings:**
- "Plans 3, 4, and 5 form a serial chain but 4 and 5 do not actually depend on each other"
- "All plans depend on plan 1, but plan 1 includes setup work that only plan 3 needs"
- "Frontend and backend changes are in one plan; splitting them would allow parallel execution"

---

### Simplest Thing That Works

**Decomposition checklist:**
- Each plan delivers one verifiable outcome, not multiple bundled features
- Plan scope can be described in one sentence without conjunctions
- No plan includes "stretch goals" or "nice-to-haves" mixed with requirements
- Verification checks are achievable with the plan's scope alone (no external dependencies)
- If a plan feels large, it can be split further without losing coherence

**Behavioral bias:** Assume every additional requirement in a plan doubles the risk of
failure. Flag plans where removing one task would still leave a useful, shippable result.
Prefer two small plans that each work over one ambitious plan that might not.

**What this catches that other frames miss:** Scope creep within individual plans that
increases failure probability and makes root cause diagnosis harder when things break.

**Keywords:** scope, minimal, MVP, single responsibility, split, decompose, simple,
small, focused, atomic, incremental

**Example findings:**
- "Plan includes both the data model and the API endpoints; the model alone is shippable"
- "Acceptance criteria mix a required feature with an optimization that could be a follow-up"
- "Plan has 8 tasks; the first 4 deliver a working feature and the last 4 add polish"

---

## Selection Rules

Given a plan's metadata (files touched, keywords in title and description, domain areas),
select exactly 3 frames for review using this deterministic algorithm:

**Step 1: Mandatory frame.**
Always include **Simplicity Advocate Review**. This frame catches over-engineering,
unnecessary complexity, and speculative features. It applies to every plan regardless
of domain.

**Step 2: Domain match.**
Scan the plan's file paths and text for domain-specific signals. Apply the first matching
rule from this ordered list (at most one domain match):

| Signal | Frame |
|---|---|
| Plan touches `auth/`, `security/`, or mentions tokens, passwords, credentials, encryption, CORS | Security Review |
| Plan touches `db/`, `migrations/`, performance-sensitive paths, or mentions query, index, cache, latency, scaling | Performance and Scaling Review |
| Plan touches user-facing files (`components/`, `pages/`, `views/`, `templates/`) or mentions UI, UX, form, button, modal, accessibility | End User and Product Review |
| Plan touches `deploy/`, `infra/`, `k8s/`, `docker/`, or mentions monitoring, alerting, health check, rollback, incident | On-Call and Operability Review |
| Plan mentions cost, budget, billing, API calls, tokens, usage, LLM, pricing, metering | Cost and Budget Review |

If no domain signal matches, skip this step (the remaining two slots are filled in Step 3).

**Step 3: Fill remaining slots.**
From all review frames not yet selected, score each by counting keyword matches against
the plan's title, description, file paths, and task list. Each frame's **Keywords** field
defines its matching terms (case-insensitive, partial word matches allowed).

Rank unselected frames by match count (descending). Break ties by frame index in this
document (earlier frames win). Select the top frame(s) needed to reach exactly 3 total.

**Frame index (for tiebreaking):**

1. Security Review
2. Performance and Scaling Review
3. On-Call and Operability Review
4. End User and Product Review
5. Adversarial Testing Review
6. Cost and Budget Review
7. Simplicity Advocate Review
8. Future Maintainer Review

**Notes:**

- Decomposition frames are not selected by this algorithm. They are used during plan
  generation (plan-multi), not plan review.
- The algorithm is deterministic: the same plan metadata always produces the same 3 frames.
- If a plan has no keyword matches for any non-mandatory frame, fall back to frame index
  order (Security Review and Performance and Scaling Review fill the remaining slots).
