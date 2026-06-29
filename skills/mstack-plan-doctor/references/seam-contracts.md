# Seam-contract verification (plan-doctor Step 3.6)

This reference is the **single source of truth** for the seam-contract machinery
shared by two plans:

- **plan 028** (this doctor step) — the *authoring + diff* side. It extracts
  each plan's PRODUCED and ASSUMED contracts from prose, EMITS a normalized,
  machine-readable seam block into the plan file, and diffs every `blocked-by`
  edge to surface interface drift before the worker ever reaches the downstream
  plan.
- **plan 029** (execution-time consumer, future) — the *parse + verify* side. At
  plan pickup it parses the emitted block with POSIX shell (`awk`/`grep`) and
  verifies assumed entries against the real repository.

Because a shell parser and an LLM emitter must agree **byte-for-byte**, the
grammar, the field order, the sorting, and the verifiability rule below are a
HARD CONTRACT. Plan 029 obeys exactly what this file specifies; the doctor
emitter produces exactly what this file specifies. Do not let SKILL.md prose and
this file drift — this file wins.

The cross-plan consistency agent (SKILL.md Step 3) checks dependency ORDERING
and file overlap. The seam check is orthogonal: it checks interface
CONSISTENCY — whether plan B's assumptions about what an upstream plan A
*produces* (a function signature, a record shape, an endpoint verb+path, a CLI
flag, a file) actually match what A's spec *promises*. This is the dominant
source of cascade drift in long dependency chains.

---

## 1. The canonical `<!-- mstack:seam ... -->` block grammar

The contract lives in an HTML comment so it is invisible in rendered markdown,
greppable, and line-oriented (one entry per line) so `awk`/`grep` parse it
without a real parser.

### 1.1 Delimiters and block placement

- The block **opens** with a line that is exactly `<!-- mstack:seam` (no trailing
  whitespace) and **closes** with a line that is exactly `-->`.
- There is **at most one** seam block per plan file. On re-emit the doctor
  locates the existing block by these two marker lines and replaces the region
  between them **in place**. If no block exists, it is appended at the end of the
  file, preceded by exactly one blank line. Placement is therefore stable across
  re-emits.
- All lines use LF (`\n`) endings. There is no trailing blank line inside the
  block (the `-->` line is the last line of the block).

### 1.2 Sections

Inside the block, exactly two section headers appear, **always in this order**,
each on its own line with no leading whitespace:

```
produced:
assumed:
```

Both headers are **always emitted**, even when a section has zero entries (an
empty section is its header line followed immediately by the next header or the
closing `-->`). Always emitting both headers keeps the byte layout stable
regardless of which side is empty.

### 1.3 Entries

Each entry is one line beginning with `- ` (dash, single space), followed by an
ordered list of `key: value` pairs separated by `; ` (semicolon, single space).
The key/value separator is `: ` (colon, single space).

**Fields and their canonical order:**

| Field   | Section          | Required | Meaning |
|---------|------------------|----------|---------|
| `from`  | assumed only     | yes (assumed) | the upstream plan id this assumption is attributed to |
| `kind`  | both             | yes      | one of `symbol`, `endpoint`, `schema`, `flag`, `file` |
| `name`  | both             | yes      | the canonical artifact name (see normalization) |
| `shape` | both             | optional | the signature / field-list / verb+path token |
| `file`  | both             | optional | repo-relative path that carries the artifact |

Canonical field order on every line is exactly:
**`from`, `kind`, `name`, `shape`, `file`** — with `from` present only on
`assumed` entries, `kind` and `name` always present, and `shape` / `file`
omitted entirely when absent (no empty `shape: ;` placeholders).

`kind ∈ {symbol, endpoint, schema, flag, file}`. `name` is ALWAYS present.
`shape` and `file` are optional. **Verifiability is anchored on `file:`** (see
§4).

Produced entry example:

```
- kind: symbol; name: gate; shape: "gate(plan, ctx)"; file: skills/mstack-run/scripts/gate.sh
```

Assumed entry example:

```
- from: 026; kind: symbol; name: gate; shape: "gate(plan)"
```

### 1.4 Quoting and escaping

So a `; ` field separator inside a value never breaks the parse:

- A value is **double-quoted** iff it contains `;`, a `"`, or has leading/trailing
  whitespace. `shape` values are **always** double-quoted (signatures routinely
  contain commas, parentheses, and spaces), which also makes shape quoting
  deterministic.
- Inside a quoted value, a literal `"` is escaped as `\"` and a literal `\` as
  `\\`. No other escapes are defined.
- `kind`, `name`, `from`, and `file` are single tokens with no spaces or
  semicolons and are therefore emitted **unquoted** in practice; if a `name`
  legitimately needs a space (e.g. an endpoint `name`), it follows the same
  quote-iff-needed rule.

A POSIX parser reads a line by: strip the leading `- `, then split on `; ` at the
top level (i.e. not inside double quotes), then split each field on the first
`: `. The fixed field order means a parser may also positionally seek a known key.

### 1.5 Idempotent emission (byte-identical re-emit)

Re-emitting an UNCHANGED contract MUST produce a byte-identical block, so a no-op
re-emit does not change the plan's content hash and does not mark the plan
modified (no spurious churn in plan 026's Step 4b loop). Determinism rules:

1. **Fixed field order** per §1.3 (`from, kind, name, shape, file`).
2. **Canonical whitespace** per §1.3 (`- `, `; `, `: `, no trailing whitespace,
   LF endings, no blank line before `-->`).
3. **Stable entry sorting**, in the C/byte collation (`LC_ALL=C sort`):
   - `produced` entries sort by the tuple `(kind, name, shape)`.
   - `assumed` entries sort by the tuple `(from, kind, name, shape)`.
   A missing optional field sorts as the empty string. Sorting makes emission
   order independent of extraction order.
4. **Deterministic quoting** per §1.4 (quote iff needed; `shape` always quoted).
5. **Stable placement** per §1.1 (replace the existing block region in place).

Emission algorithm: build the produced and assumed entry lists, normalize each
field (§3.2), sort each list by its tuple, render each entry with the fixed
field order and canonical separators, and splice the assembled block into the
existing marker region (or append it). Given the same contract, this yields the
same bytes every time.

---

## 2. Heuristic PRODUCED / ASSUMED extraction (from prose)

Extraction is a HEURISTIC authoring task (an LLM/agent reads the plan prose); only
the emitted block is deterministic (see the caveat in §7). For each plan:

### 2.1 PRODUCED set — what this plan creates

Scan the plan's `**Files expected to change:**` list and `## Design` /
`## Tasks` prose for declarations that the plan **creates or defines** an
artifact:

- **symbol** — a function/class/method the plan adds, e.g. "adds `gate(plan,
  ctx)`", "introduces a `RankerOutput` type". `name` = the bare identifier;
  `shape` = the signature or field list when stated.
- **endpoint** — an HTTP route the plan serves, e.g. "`POST /dispatch/confirm`".
  `name` = `VERB /path`; `shape` = same when a body/response shape is stated.
- **schema** — a record/table/JSON shape, e.g. "`RankerOutput` with
  `confidence`, `rank`". `name` = the type name; `shape` = the field-name list.
- **flag** — a CLI flag the plan adds, e.g. "`--dry-run`". `name` = `--flag`.
- **file** — a file the plan creates whose existence other plans rely on.
  `name` = the repo-relative path; `file` = the same path.

Each PRODUCED entry SHOULD carry a `file:` (the repo path that will hold it),
taken from `**Files expected to change:**`, so downstream assumed entries can
inherit it (§4).

### 2.2 ASSUMED set — what this plan consumes from an ancestor

Scan the same prose for references to an artifact the plan **relies on but does
not itself create**, where the artifact is the kind of thing an upstream
`blocked-by` ancestor produces:

- "calls `gate()` from plan 026 with the plan id" → assumed symbol `gate`,
  `from: 026`, `shape: "gate(plan)"`.
- "POSTs to `/dispatch/confirm` defined in 031" → assumed endpoint.

### 2.3 Attribution (tying an ASSUMED entry to one ancestor)

Every assumed entry carries `from: <plan-id>` identifying the SINGLE upstream
ancestor responsible for it. Attribution order:

1. If the prose names the source plan explicitly ("from plan 026", "defined in
   031"), use that id.
2. Else attribute to the `blocked-by` ancestor whose PRODUCED set contains a
   name-matching entry (after normalization §3.2). If exactly one ancestor
   matches, attribute to it.
3. If no ancestor matches and the prose names no source, the entry is still
   recorded (with `from` set to the nearest `blocked-by` ancestor by id, or
   omitted if the plan has none) and will surface as `MISSING` or `UNVERIFIABLE`
   in the diff — never silently dropped.

---

## 3. The per-edge diff

### 3.1 Edge selection by scope

For a `blocked-by` edge **A → B** (B is blocked by A; A produces, B assumes):

- **all-plans scope:** diff every edge in the backlog.
- **single-plan scope** (`/mstack-plan-doctor NNN`): load NNN's `blocked-by`
  ancestors and diff only the edges **incident to NNN** (NNN as the assuming
  side). The seam check runs in BOTH scopes; it is NOT confined to the
  all-plans-only cross-plan consistency agent.

### 3.2 Normalization (apply to both sides before comparing)

- **name:** trim whitespace; for symbols, strip a trailing call/arg list so
  `gate(...)` → `gate`; case-sensitive for code identifiers.
- **symbol shape:** reduce to the ordered argument list with argument *names*
  only — strip type annotations, default values, and surrounding whitespace —
  yielding an arg tuple and an arg count.
- **endpoint:** `name`/`shape` = `VERB /path` with VERB upper-cased and a
  trailing `/` stripped from the path.
- **schema shape:** the **set** of field names (order-insensitive).
- **flag:** the canonical `--flag` form.

### 3.3 Name-first + shallow-shape diff

For each ASSUMED entry E in B with `from: A`:

1. **Name match** E.name against A.PRODUCED (normalized). If A.PRODUCED has **no**
   entry whose name equals E.name → **MISSING** (A produces nothing named X).
2. If a producer P matches by name **and both** E and P declare a `shape`,
   compare shapes shallowly (arg tuple/count for symbols; field set for schemas;
   verb+path for endpoints). If they differ → **SHAPE-DIVERGENT**.
   - If only one side declares a `shape`, the shape is NOT compared (no false
     positive from a plan that simply omitted the signature). Name match alone
     resolves the entry OK.
3. On a resolved name match, the emitter SHOULD copy `P.file` into `E.file` when P
   has a `file` and E lacks one, to maximize downstream verifiability (§4).

The diff is **name-first, shape-shallow**: shapes are compared ONLY where BOTH
sides state a shape. This deliberately avoids over-flagging prose that names a
symbol without restating its signature.

---

## 4. Verifiability — anchored on `file:` (the rule plan 029 obeys)

This is the canonical verifiability rule, stated **once** here as the single
source of truth that plan 029's parser obeys identically:

> An ASSUMED entry is **VERIFIABLE iff it carries a `file:` path.** When
> verifiable, existence is checked: the `file:` path must exist in the repo, and
> **if `shape:` is also present, the shape token is checked WITHIN that file**.
> An ASSUMED entry with **NO `file:`** (even though `name:` is always present) is
> **UNVERIFIABLE → noted, non-blocking, NEVER reported MISSING.** A bare `name:`
> is **NEVER grepped repo-wide** (too noisy to be a reliable stale signal).

To maximize verifiable coverage, the emitter SHOULD populate an assumed entry's
`file:` from the name-matched PRODUCED entry of the upstream plan when the edge
resolves (§3.3 step 3).

The two dimensions do not conflict:

- The **edge diff** (§3) compares B.ASSUMED-from-A against A.PRODUCED — a
  plan-to-plan comparison of promises. It yields `MISSING` / `SHAPE-DIVERGENT`.
  This is always available because both plans' seam blocks exist; it does not
  grep the repo.
- The **source verifiability** rule above governs checking an assumed entry
  against the actual repository (existence + in-file shape). The "no `file:` ⇒
  UNVERIFIABLE, never MISSING, never grep a bare name repo-wide" clause scopes
  this *source* dimension. It is what plan 029 consumes at pickup, and what the
  doctor MAY also apply when an entry already carries a `file:`.

---

## 5. Mismatch taxonomy and which findings BLOCK

| Finding           | Basis                                            | Verdict |
|-------------------|--------------------------------------------------|---------|
| `MISSING`         | B assumes X from A; A produces nothing named X — or a VERIFIABLE entry's `file:` does not exist in the repo | **BLOCKING** |
| `SHAPE-DIVERGENT` | name matches but both-stated shapes differ (signature / field set / verb+path) — or a VERIFIABLE entry's `shape` token is absent within its `file:` | **BLOCKING** |
| `UNVERIFIABLE`    | assumed entry has no `file:` and no upstream producer resolved a `file:` for it | **noted only, non-blocking** |

**MISSING and SHAPE-DIVERGENT are BLOCKING findings**: a SEAM MISSING or
SHAPE-DIVERGENT finding gates (blocks) the `ready` verdict — it is a blocking
finding in the exact set plan 026's Step 4b / Step 6 final-state gate uses.
**UNVERIFIABLE is noted only** and never blocks.

Because the diff is heuristic, the report names the edge + symbol so the
architect can confirm or override, but the **default is to block** — the worker
should not start B on a contract A never promised.

---

## 6. Report block format

Merge SEAM findings into the Step 4 report under the assuming plan, alongside the
ERRORS / WARNINGS / DEEP / FRAME / AUDIT lines. One line per finding:

```
SEAM   [<MISSING|SHAPE-DIVERGENT|UNVERIFIABLE>] <B-id> assumes <kind> `<name>` from <A-id> | <detail> (<blocking|noted>)
```

Example:

```
Plan 029, "Seam-contract execution gate"
  SEAM   [MISSING] 029 assumes symbol `gate` from 026 | 026 produces nothing named `gate` (blocking)
  SEAM   [SHAPE-DIVERGENT] 029 assumes symbol `gate` from 026 | assumed `gate(plan)` vs produced `gate(plan, ctx)`: arg count 1≠2 (blocking)
  SEAM   [UNVERIFIABLE] 029 assumes endpoint `POST /dispatch/confirm` from 031 | no file: anchor (noted)
```

Feed seam-triggered edits into the loop: emitting or repairing a seam block
changes the plan's content hash, so the plan enters `MODIFIED_PLANS` and plan
026's Step 4b re-runs the seam diff on that plan's incident edges. A no-op
re-emit (§1.5) is byte-identical, leaves the hash unchanged, and does NOT mark
the plan modified.

---

## 7. Worked end-to-end example

**Plan A (id 026)** Design says: *"adds `gate(plan, ctx)` to
`skills/mstack-run/scripts/gate.sh`"*, with that path in
`**Files expected to change:**`. Extraction → PRODUCED:

```
<!-- mstack:seam
produced:
- kind: symbol; name: gate; shape: "gate(plan, ctx)"; file: skills/mstack-run/scripts/gate.sh
assumed:
-->
```

**Plan B (id 029)**, `blocked-by: [026]`, Design says: *"calls `gate()` from
plan 026 with the plan id"*. Extraction → ASSUMED (attributed to 026 by the
explicit "from plan 026", §2.3):

```
<!-- mstack:seam
produced:
assumed:
- from: 026; kind: symbol; name: gate; shape: "gate(plan)"
-->
```

**Edge diff 026 → 029** (§3.3):

1. Name match: `gate` == `gate` → producer found.
2. Both sides declare a shape. Normalize: produced arg tuple `(plan, ctx)`
   (count 2); assumed arg tuple `(plan)` (count 1). They differ →
   **SHAPE-DIVERGENT** → **BLOCKING**.
3. Because the edge resolved on name, the emitter copies `P.file`
   (`skills/mstack-run/scripts/gate.sh`) into B's assumed entry, making it
   VERIFIABLE for plan 029 at pickup.

Report line:

```
SEAM   [SHAPE-DIVERGENT] 029 assumes symbol `gate` from 026 | assumed `gate(plan)` vs produced `gate(plan, ctx)`: arg count 1≠2 (blocking)
```

The architect either fixes plan 029's assumed signature (or plan 026's produced
one) — which re-emits the block, changes the hash, and re-runs this diff in Step
4b — or explicitly overrides. The `ready` verdict is blocked until the
SHAPE-DIVERGENT is resolved.

---

## 8. Caveats and future work

- **Prose extraction is heuristic.** Only the emitted `<!-- mstack:seam ... -->`
  block is deterministic. Two readings of the same loose prose can extract
  slightly different sets; that is why the block (not the prose) is the contract
  plan 029 parses, and why findings are surfaced for architect confirmation
  rather than silently mutating scope.
- **AST-level extraction is future work.** A deterministic AST/source parser that
  derives PRODUCED/ASSUMED from real code (instead of plan prose) would remove
  the heuristic step. Do not build it here.
- **Authoring-time pre-population** of seam blocks in `mstack-plan-multi` is also
  future work; today the doctor generates them.
