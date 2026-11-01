---
id: 100
title: Paperclip delivery adopts Matthew's priority and ready changes; plan tasks enter as backlog
status: done
blocked-by: []
priority:
goal: paperclip-board-order
allows-migrations: false
needs-review: none
review-required: eng,code
created: 2026-11-01
reviews:
  - type=eng verdict=approved date=2026-11-01 by=agent
  - type=code verdict=pass date=2026-11-01 by=mstack-code-review
completed: 2026-11-01
reviewed: false
qa: automated
---

## Plain-English Summary

Matthew now orders work on the Paperclip board: he sets a task's priority and marks it
ready by moving it from `backlog` to `todo`. Today mstack treats any change on a plan
task that it did not make itself as a hand edit. It stops updating that task, with
"issue manually changed; reconciliation required". So once Matthew starts ordering
work, every plan task he touches stops following its plan. Separately, mstack files a
new plan as `blocked` whenever the plan is still a draft, proposed, deferred or blocked
locally. That hides work Matthew could otherwise order.

This plan makes mstack accept exactly two kinds of board change as normal: a new
priority, and a status move between `backlog` and `todo`. Every other hand change is
still a conflict. It also makes mstack file every newly authored plan as `backlog`, and
mstack never marks a task `todo` itself: `todo` stays Matthew's "ready" mark.

**What changes in the code:** At each confirmed write, mstack keeps a small
fingerprint of the task: its status, its priority, and a hash of every other field.
Before its next write, mstack compares the board with that fingerprint. Before, any
newer timestamp counted as a hand edit. Now, if only the priority moved, or only the
status moved between `backlog` and `todo`, mstack takes the board's values as its new
baseline and goes on. An authored report never moves a `todo` task back to `backlog`.
The status mapping for authored plans becomes `backlog` in every case. A record that
has no fingerprint yet (everything written before this change), or whose fingerprint
cannot be read, behaves exactly as today. That is the fail-closed default.

Requested by orch-homelab for homelab plans 236 and 233 (approval
`mdec-1101-mstack-plan-233`). Homelab plan 235's orchestrator doctrine is not switched
on until this has shipped.

## Requirements

### Definitions (the contract this plan implements)

- **Baseline:** the per-plan mapping in `.git/mstack-paperclip/events.json`
  (`state['mappings'][plan_id]`, written by `deliver()` in
  `skills/mstack-run/scripts/paperclip.py`). Today it holds `issue_id`, `status`,
  `updated_at` and `sequence`, and nothing else about the task. This plan adds one key,
  `snapshot`:
  `{"v": 1, "priority": <issue.priority or null>, "rest": "<sha256 hex>"}`.
  `rest` is the SHA-256 of canonical JSON (`json.dumps(..., sort_keys=True,
  separators=(',', ':'), ensure_ascii=False)`, UTF-8) of the `GET /issues/{id}`
  object after `rest_view(issue)` has: removed `status`, `priority`, `updatedAt` and
  every key in `BOARD_SIDE_EFFECT_FIELDS`; removed every key in `PROJECTION_FIELDS`;
  replaced every key in `RELATION_FIELDS` with the sorted list of related ids;
  replaced every key in `DOCUMENT_FIELDS` with a sorted digest of the task's own
  documents, one `(key, id, latestRevisionId, latestRevisionNumber)` entry per
  document (never dropped: a document is this task's own content, amendment re-check
  P2-1); and replaced `goalId` with the token `inherited` when it equals the
  project's fallback goal (`project.goalId`, else `project.goalIds[0]`), the same
  test Paperclip's own `resolveNextIssueGoalId` uses to tell an inherited goal from
  an explicit one. **Every other key, including any key Paperclip adds later, is hashed in full**
  (fail closed: an unknown field that drifts is a false conflict, never a false
  adoption). Reason (eng review, 2026-11-01): the 2026.1005.0 `GET /issues/:id`
  handler (`@paperclipai/server` `dist/routes/issues.js` L5977-6052, response built
  at L6028) spreads the issue row and then adds ~20 joined or derived keys
  (`ancestors`, `goal`, `project`, `mentionedProjects`, `relatedWork`,
  `referencedIssueIdentifiers`, `blockedBy`, `blocks`, `workProducts`,
  `linkedCases`, `executionBlocker`,
  `activeRecoveryAction`, `scheduledRetry`, `successfulRunHandoff`,
  `currentExecutionWorkspace`, `externalChannelBinding`, per-viewer `archivedAt…`
  inbox fields, …). Those change when *other* rows change (another task mentions
  this one, the goal row is edited, a recovery action is revalidated on read). Hashed
  in full, any such drift between mstack's last write and Matthew's priority change
  would make his change a conflict, so the feature would fail on first real use
  while every fake-board test passed. `PROJECTION_FIELDS`, `RELATION_FIELDS` and
  `DOCUMENT_FIELDS` are fixed from Task 1's classification, each entry with a
  source-line comment. Three keys are decided here (amendment re-check P3-5), so
  that they cause no false conflict without hiding a real edit to the task itself:
  `blocks` is PROJECTION, because it is the inverse of *other* tasks' `blockedBy`
  and is written only by edits to those tasks (`syncBlockedByIssueIds`), while
  `blockedBy`, this task's own blockers, stays RELATION; the conditional keys
  `blockerAttention` and `reviewAttention`, present only when other tasks or review
  requests make them so, are PROJECTION whether present or absent; and `goalId` is
  hashed except when it is inherited from the project (above). Residual: a change of
  the project's default goal turns an issue row that inherited the old goal into an
  explicit-looking `goalId`, a false conflict (fail closed).
  The status baseline stays `mapping['status']`
  and the time baseline stays `mapping['updated_at']`. They are not duplicated.
  `BOARD_SIDE_EFFECT_FIELDS` holds fields that Paperclip itself rewrites when
  priority or a `backlog`/`todo` status changes. It is empty unless Task 1 shows such
  a field in the Paperclip source (see Design).
- **When the snapshot is written:** at every point where `deliver()` writes a
  mapping from a full issue read. That means marker adoption, after creation, on a
  re-run whose marker already exists, and after a confirmed write. Each time it comes
  from the same issue object whose `status`/`updatedAt` go into the mapping.
- **Seeding existing records (eng review, 2026-11-01):** the live ledger holds 21
  mappings (14 `backlog`, 5 `blocked`, 2 `done`), none with a snapshot. Without a
  seed, the first board edit on any of them is a conflict. The next mstack write on a
  pending plan is `claimed`, and under the new doctrine that comes only *after*
  Matthew marks the task `todo`. So no existing task could ever gain a baseline, and
  the feature would fail on every existing task. A backfill *can* know what mstack
  last wrote in exactly one case, the one today's own rule already trusts: the board
  issue still has `status == M.status` and `updatedAt == M.updated_at`. A new
  subcommand `paperclip.py seed-snapshots --repo <repo>` therefore reads the ledger
  under the `events.json` lock, releases it, and then, for each mapping with no valid
  snapshot whose `status` is not closed, does a `GET` of the issue and runs `guard()`
  (no lock is held across board reads; code review L2). If the issue is unchanged by
  that rule, it writes `snapshot = snapshot_of(issue)` (and nothing else). Otherwise it
  leaves the mapping alone and counts it as `changed`. A failed `GET` (offline, a
  404 or any other rejection, an unreadable answer, the deadline) or a `guard()`
  failure counts as `errors` and writes nothing for that task. The ledger is written
  once, atomically, at the end, under the lock taken again, holding only the
  `seeded` snapshots. Under that lock each seeded mapping is re-read and must equal
  the one the board was compared with; a mapping changed in between (a concurrent
  report) is not seeded and is reported as an `error` row, `local mapping changed
  during the seed; not seeded, rerun`. An unexpected local error before then writes
  nothing at all. It prints
  one JSON line, `{"seeded": n, "changed": n, "closed": n, "already": n, "errors": n,
  "tasks": [{"plan": id, "issue_id": id, "result": seeded|changed|closed|already|error,
  "diagnostic": text or null}, ...]}`, one `tasks` row per mapping, so a nonzero
  count names its tasks (amendment re-check P3-3/P3-4). It makes no board write (only
  GETs). It is idempotent in this sense: a second run reports every task the first
  run seeded as `already`, and every other count unchanged (P3-2). Each checkout has its own ledger in the
  git common dir (`config.binding_path(repo).parent`), so the seed runs once per
  checkout (Studio and MacBook) before Matthew starts ordering. That is a rollout
  step, see Verification.
- **"Only changes since mstack's last write":** the board issue `I` and the baseline
  `M` are compared as follows. "Unchanged" here is the exact pre-change condition:
  `I.status == M.status` and `I.updatedAt == M.updated_at`.
  - If `I` is unchanged, there is no adoption and nothing changes from today.
  - Otherwise, if `M.snapshot` is missing, is not a dict with `v == 1`, or `rest` is
    not a 64-character lowercase hex string, the result is `conflict`. The diagnostic
    is the unchanged string `issue manually changed; reconciliation required`. This
    is fail-closed: it is exactly today's behaviour for every record written before
    this plan.
  - Otherwise, compute the changed set `C` over {`priority`, `status`, `rest`}.
    `priority` is in `C` when `I.priority != M.snapshot.priority`. `status` is in `C`
    when `I.status != M.status`. `rest` is in `C` when the hash of `I` differs from
    `M.snapshot.rest`.
  - The change is **adoptable** when `rest ∉ C`, and either `status ∉ C`, or both
    `M.status` and `I.status` are in `ADOPTABLE_STATUSES = {backlog, todo}`. Any
    other change is a `conflict` with the unchanged diagnostic.
  - `C = ∅` with a newer `updatedAt` is adoptable. That is a touch that changed no
    field mstack reads, for example a comment, if the board bumps `updatedAt` for
    comments. See Open question 2.
- **"Adopt":** set `M.status = I.status`, `M.updated_at = I.updatedAt`, `M.snapshot`
  = the snapshot of `I`, and `M.adopted = {"fields": sorted(C), "updated_at":
  I.updatedAt}`. Then save. Delivery then continues on the same path as an unchanged
  task, so the terminal check, the `fresh != issue` re-read, the intent save and the
  PATCH all still run. After adoption mstack stays authoritative for the statuses it
  sends: a later `claimed` (`in_progress`), `review`, `blocked`, `failed` or `done`
  report overwrites `todo` as today. mstack **never sends `priority`** in any request,
  so Matthew's priority is never reset.
- **An authored report on a `todo` task:** an event whose outcome is `backlog` (the
  authored report) and whose task is in `todo` when the PATCH is prepared sends **no
  `status` key**. It sends the comment and assignee only. The task stays `todo`.
  `expected_status(outcome, current)` returns `todo` for (`backlog`, `todo`) and the
  outcome otherwise. It replaces the bare `issue['status'] != event['outcome']`
  comparisons used for marker-exists, PATCH payload and confirmation readback. mstack
  therefore never writes `todo` and never removes it, except through its own later
  execution outcomes.

### Acceptance criteria

- [ ] **Characterization first (lands before any behaviour change, in its own
      commit):** a new `skills/mstack-run/scripts/test_paperclip_board_order.py` pins
      today's behaviour on the transport fake board (same harness shape as
      `test_paperclip_transport.py`, `TransportTests.setUp`). It pins five things.
      (1) A priority-only board change gives `conflict` with diagnostic
      `issue manually changed; reconciliation required`. (2) `backlog`→`todo` gives
      the same. (3) A marker-found task in `todo` with no mapping gives `adopted issue
      state differs; inspect manually`. (4) Catch-up on a changed task (in
      `test_paperclip_lifecycle.py`, whose harness drives catch-up) skips with
      `task changed on the board since the last report; inspect manually`. (5) An
      authored report for a `deferred` plan gives board `blocked`. Test 5 is already
      pinned by `test_source_restrictions_and_archive_identity` in
      `test_paperclip_lifecycle.py`. Run against unmodified `paperclip.py` and
      `paperclip_lifecycle.py`, these pass. The commit that changes behaviour then
      flips (1), (2), (4) and (5) to the new expectations in the same diff that changes
      the code, so the flips are reviewable. (3) does not flip: the no-mapping `todo`
      conflict is kept (amendment re-check P2-2).
- [ ] **Adoptable changes go through.** These pass against the shared contract table
      (Design): a priority-only change; `backlog`→`todo`; `todo`→`backlog`; priority
      and `backlog`/`todo` together; a priority changed and then changed back. Each
      gives `delivered` on the next report, the report's own status is sent, and the
      mapping's `updated_at` equals the confirmed `updatedAt`.
- [ ] **Every other change is still a conflict.** These all give `conflict` with
      diagnostic `issue manually changed; reconciliation required`, and the board is
      left unchanged with no new comment. A status set by hand to `in_progress`,
      `blocked`, `in_review`, `done` or `cancelled` (from `backlog` or `todo`). A
      title change, a description change, or a change to any field outside
      `status`/`priority`/`updatedAt` (and outside `BOARD_SIDE_EFFECT_FIELDS` and
      `PROJECTION_FIELDS`), including a top-level key the fixture does not know. A
      change in the related-issue ids of a `RELATION_FIELDS` key. An
      allowed change combined with a disallowed one. A mapping whose `status` is
      `in_progress` while the board shows `todo`. Assignee and agent changes stay
      refused by `guard()` with their existing diagnostics.
- [ ] **Fail closed on a missing or unreadable baseline.** A mapping without
      `snapshot`, with `snapshot: null`, with `v != 1`, or with a malformed `rest`
      behaves exactly as today on any change: a priority-only change is a `conflict`.
      A mapping with an unchanged board still delivers. That is the pre-plan path, and
      it also writes a snapshot, so a legacy record gains a baseline on its first
      clean write.
- [ ] **Projection drift is not a hand change.** Starting from a snapshot, change
      the priority on the fake board and *also* change the value of each key in
      `PROJECTION_FIELDS` (for example the related-work, goal and ancestors keys,
      the inverse `blocks` list, and the conditional attention keys appearing), the
      summary content (not the ids) of a `RELATION_FIELDS` entry, a document's
      summary fields other than its id and revision, and an inherited goal id that
      follows the project's goal. The result is `adopt`. A new document revision, a
      new document, or an explicit goal id change, each combined with a priority
      change, is a `conflict`. The fake board's issue object is built from the Task 1 fixture's key
      set, so the test sees the real response shape, not a five-key toy.
- [ ] **`seed-snapshots` seeds only unchanged records.** On the fake board, with
      mappings lacking a snapshot: an unchanged issue gets a snapshot; an issue whose
      `updatedAt` or `status` differs from the mapping is left alone and counted
      `changed`, and a later priority-only change on it is still a `conflict`; a
      closed mapping is skipped; a mapping that already has a valid snapshot is not
      rewritten; a `guard()` failure, a 404 and an offline read each count as
      `errors` and write nothing for that task, while the other tasks of the same run
      are still seeded. Every mapping has one `tasks` row naming its result. No POST
      or PATCH appears in `fixture.calls`. A second run reports the tasks the first
      run seeded as `already`, and every other count unchanged. After seeding, a
      priority-only board change followed by a report is `delivered`.
- [ ] **mstack never sends `priority`.** A fake-board assertion over every recorded
      POST/PATCH body (`fixture.calls` bodies) finds no `priority` key, in every test
      in the new file.
- [ ] **The authored mapping becomes backlog.** In `emit()`
      (`paperclip_lifecycle.py`), an `authored` report gives remote outcome `backlog`
      for every allowed local status (`pending`, `blocked`, `deferred`, `draft`,
      `proposed`). The other mappings are unchanged: `claimed`→`in_progress`,
      `blocked`→`blocked`, `failed`→`blocked`, `review`→`in_review`,
      `continuation`→`note`, `done`→`done`. A test asserts that no lifecycle outcome
      maps to `todo`. `test_source_restrictions_and_archive_identity` is updated to
      expect `backlog` for the deferred authored report.
- [ ] **An authored report keeps `todo`.** With the task in `todo` (adopted), an
      authored report delivers a comment, sends no `status` key, and the task stays
      `todo`. A re-run that finds the event marker already present also gives
      `delivered`, not `marker exists but issue outcome changed`. A later `claimed`
      report then moves the task to `in_progress`. That relaxation (board `todo` for
      an authored `backlog` outcome) holds only while the mapping has a valid
      snapshot whose `rest` still matches the board, allowing only the assignee
      mstack's own lost write set; otherwise it stays a conflict (code review M1).
- [ ] **A board `blocked` task with a new authored report.** Today the `remote`
      dict in `emit()` (`paperclip_lifecycle.py`) maps an authored draft, proposed,
      deferred or blocked plan to `blocked`, so such tasks are on the board now. The
      next authored report moves one to `backlog` through mstack's own PATCH. It is
      not a conflict, because the mapping's `status` is `blocked`, the same as the
      board, and `deliver()` sees no change. No bulk migration runs.
- [ ] **Marker adoption with no mapping stays fail closed for `todo`.** A task found
      by marker with no mapping (not `uncertain`) whose status is `todo` is still the
      `adopted issue state differs; inspect manually` conflict, exactly as today, and
      nothing is written to the ledger for it. Reason (amendment re-check P2-2,
      option a): with no mapping there is no snapshot, so this path cannot tell an
      order-only change from a hand edit to anything else. A title check alone does
      not help: the description, which carries the hand-editable plan text, cannot be
      compared: `deliver()` in `skills/mstack-run/scripts/paperclip.py` writes it at
      creation from the first event's notes, which another checkout never saw. Adopting there would bake a hand edit into the new baseline (contract
      row 9) on one Mac while the other Mac refuses it. A `todo` task and a renamed
      `todo` task found by marker are both tested as conflicts with no write. The
      `backlog` adoption rule and the `uncertain` creation branch (`uncertain
      creation was manually changed`) are unchanged.
- [ ] **Catch-up uses the same rule.** `catch_up_plan()` in `paperclip_lifecycle.py`
      replaces its `issue['status'] != mapping.get('status') or ...updatedAt...`
      comparison with the shared `board_change()` helper. Catch-up of a done plan
      whose task Matthew moved to `todo` with a new priority reports `applied` and
      closes the task as `done`. A disallowed change still skips with the unchanged
      catch-up diagnostic.
- [ ] **Keyed tasks (`task()`) follow the same delivery rule**, because they share
      `deliver()`. A priority-only change on a keyed task is adopted. `task()` still
      accepts the caller-given status set `TASK_STATUSES` unchanged (out of scope; see
      Open question 4).
- [ ] **Docs.** In `docs/paperclip-migration.md`, the "Tasks without a plan" sentence
      "a closed or manually changed task is a conflict" and the plan-sync description
      gain one sentence: "a priority change, or a status move between `backlog` and
      `todo`, is not a hand change; any other change still is". The adoption sentence
      ("taken over when it is still in `backlog`…") gains "or `todo`".
      `skills/mstack-paperclip/SKILL.md` gets the same one-line note where it
      describes manual-state conflicts.
- [ ] **Existing suites stay green:** every `test_paperclip_*.py` in
      `skills/mstack-run/scripts/`.

## Design

### Shared contract table (copy verbatim into the test; homelab plan 236 holds the same table)

| # | baseline status | board status | other change | expected |
|---|---|---|---|---|
| 1 | backlog | backlog | priority | adopt |
| 2 | backlog | todo | none | adopt |
| 3 | todo | backlog | none | adopt |
| 4 | backlog | todo | priority | adopt |
| 5 | backlog | in_progress | none | conflict |
| 6 | todo | blocked | none | conflict |
| 7 | todo | done | none | conflict |
| 8 | backlog | backlog | title | conflict |
| 9 | backlog | todo | description | conflict |
| 10 | in_progress | todo | none | conflict |
| 11 | backlog (no snapshot) | backlog | priority | conflict |
| 12 | blocked | blocked | priority | adopt |

Row 12 is deliberate. The priority-only rule does not depend on status, as in plan
236: "priority (any value, including back to the old one)".

### Code

- `paperclip.py`. Add `ADOPTABLE_STATUSES`, `BOARD_SIDE_EFFECT_FIELDS`,
  `PROJECTION_FIELDS`, `RELATION_FIELDS`, `rest_view(issue)`, `snapshot_of(issue)`, `board_change(mapping, issue)` and
  `expected_status(outcome, current)`. `board_change` returns one of
  `('same', set())`, `('adopt', C)` or `('conflict', C)`. It is a pure function with
  no I/O, unit-tested over the table above. Every mapping write in `deliver()` adds
  `snapshot=snapshot_of(issue)`. That covers the adoption, creation, marker-exists
  and confirmed-write sites, which today build or update `{'issue_id', 'status',
  'updated_at', 'sequence'}`. The `issue manually changed` check becomes: same, go
  on; adopt, update the mapping as defined above, `save()`, and go on; conflict,
  raise the unchanged `DeliveryError`. The terminal-issue check stays after it.
  The status payload line (`if event['outcome'] != 'note': payload['status'] = ...`)
  sends status only when `expected_status(event['outcome'], issue['status']) ==
  event['outcome']`. The two confirmation comparisons use `expected_status` against
  the status read before the write.
- `paperclip_lifecycle.py`. In the `emit()` `remote` dict, `authored` maps to
  `'backlog'` unconditionally. In `catch_up_plan()`, use `paperclip.board_change`.
  An `adopt` there needs no separate save: `deliver()` repeats the comparison and
  saves the adopted mapping into the live ledger before its write.
- `paperclip.py` `seed-snapshots` subcommand (Definitions, "Seeding existing
  records"): add it to the `main()` command choices next to `reconcile`; it reuses
  `load_state`, `config.locked`, `config.atomic_write`, `full_issue`, `guard` and
  `snapshot_of`, and never calls a writing request.
- `paperclip_adoption.py`: **unchanged.** Mappings it writes carry no snapshot. They
  are seeded by `seed-snapshots` when unchanged, and otherwise fail closed until
  mstack's first clean write stores one (Open question 3).

### Task 1 evidence (input, not output)

`rest` hashes every field it does not classify, so the rule is only as good as
knowing which fields change *without* a hand edit to this issue's own fields. Such a
field would make every allowed change look like a `rest` change. That fails safe (a
conflict, as today) but leaves the feature useless. Task 1 reads Paperclip
2026.1005.0, read-only, with no board call. The source is on disk in the npm cache:
the `@paperclipai/server` and `@paperclipai/db` tarballs of version 2026.1005.0 under
`~/.npm/_cacache` (keys `make-fetch-happen:request-cache:https://registry.npmjs.org/
@paperclipai/server/-/server-2026.1005.0.tgz` and `.../db/-/db-2026.1005.0.tgz`).
Extract them into a scratch directory, never into the repo, and read them as data.
Task 1 records:

- every top-level key of the `GET /api/issues/{id}` response (`dist/routes/issues.js`
  L5977-6052; the row comes from `getIssueByUuid`, `dist/services/issues.js`
  L4222-4232, which adds `externalConversationState` and labels to the table
  columns of `@paperclipai/db` `dist/schema/issues.js`), each classified as **OWN**
  (an `issues` column or label of this issue: hashed in full), **RELATION**
  (`blockedBy`/`blocks`, or another list of related issues whose membership is a
  hand decision: hashed as sorted ids only) or **PROJECTION** (joined or derived
  data that changes when other rows change: dropped). A key that is not clearly
  PROJECTION stays OWN.
- the columns written besides `priority`/`status`/`updatedAt` on a priority-only or
  `backlog`↔`todo` update (`dist/services/issues.js` around L7050-7250). Leads the
  reviewer already found: `goalId` is recomputed by `resolveNextIssueGoalId` on every
  update (L7224). `completedAt`/`cancelledAt` and the execution-lock columns are
  nulled when the new status is not done/cancelled/in_progress, which is a no-op on a
  `backlog`/`todo` task. `statusVersion` is bumped only on an assignee change or a
  blocked reassert (L7237, L7246). Keep `goalId` OWN unless Task 1 shows it can
  differ from the value computed at mstack's own last PATCH.

Task 1 writes the result to
`skills/mstack-run/scripts/fixtures/paperclip/issue-update-2026.1005.0.json`, an
illustrative issue object with the real field names and placeholder values, no live
ids or text, and with every key tagged with its class. The sidecar `.meta` carries
`capture-date:` and the source path and version it was read from. Any side-effect
column found goes into `BOARD_SIDE_EFFECT_FIELDS`, and every PROJECTION or RELATION
key goes into `PROJECTION_FIELDS` or `RELATION_FIELDS`, each with a comment that
cites the source line. The fake board in `test_paperclip_board_order.py` builds its
issue objects from this fixture's key set. **If the
source cannot be read, stop and report.** Do not guess field names, and do not do a
live board read without an approval id.

### Edge cases decided here

- An adoption is saved before the PATCH, so a failed or uncertain PATCH leaves the
  adopted baseline. That is correct, because the board still matches it, and the
  next retry goes through the existing marker or uncertainty paths unchanged.
- Adoption depends on the board being in exactly the adopted state at write time.
  The existing `fresh != issue` re-read ("issue changed while preparing update")
  still guards the window between check and write.
- `ADOPTABLE_STATUSES` does not include `blocked`. A hand move from `blocked` to
  `todo` is a conflict, because an un-blocking by hand is a real state decision
  mstack must surface.
- Honest residuals, not closed here. (a) A hand edit made between mstack's `fresh`
  read and its PATCH is absorbed into the confirmed snapshot. That window already
  absorbs it today. (b) `PROJECTION_FIELDS` are trusted not to carry hand decisions.
  A Paperclip upgrade that moves a hand-editable field into a dropped key would
  loosen the rule silently, so re-run Task 1 on every Paperclip upgrade (the fixture
  name carries the version). (c) An existing board `blocked` task from an authored
  draft cannot be readied by hand (`blocked`→`todo` is a conflict) until a new
  authored report moves it to `backlog`, for example plan-doctor's report after a
  review. (d) The PATCH always sends `assigneeUserId`. On a task whose assignee is
  still `null` (only possible for `paperclip_adoption.py` tasks), an authored report
  after Matthew's `todo` sets the assignee, and homelab 233's `next` may then skip
  the task as changed by someone else. Matthew re-marks it. (e) Follow-up, outside
  this plan (code review L3): when `paperclip_adoption.py` rewrites a task's
  description it moves an existing mapping's `updated_at` forward
  (`paperclip_adoption.py` L190, L201-202) but leaves its `snapshot` stale, so the next
  order change on that task is a false conflict. It fails closed; refresh the
  snapshot there in a later change.
- **Renames (amendment re-check P3-1).** mstack sends a title only at creation, so
  a plan retitled in the repo never retitles its task; that is not a board change and
  changes nothing. A title edited on the board is an OWN-field change: with a
  snapshot it is a `rest` change, so a conflict (row 8), alone or combined with a
  priority or `backlog`/`todo` change. With no mapping a `todo` task is a conflict
  whatever its title (above). Fail closed in every case.
- **Residual of the fail-closed no-mapping rule.** On a checkout whose ledger lacks
  the mapping (typically the second Mac), the first report on a task Matthew has
  marked `todo` is a conflict. It is reported from the checkout that holds the
  mapping, or reconciled by hand. Importing mappings between checkouts is out of
  scope.
- `M.adopted` is informational. Nothing reads it for control flow. It makes "mstack
  took a board change" legible in the ledger (plan 045: a degraded or adopted path
  must be distinguishable from the plain one).

**Files expected to change:**

- `skills/mstack-run/scripts/paperclip.py`: `ADOPTABLE_STATUSES`,
  `BOARD_SIDE_EFFECT_FIELDS`, `PROJECTION_FIELDS`, `RELATION_FIELDS`,
  `DOCUMENT_FIELDS`, `rest_view`,
  `snapshot_of`, `board_change`, `expected_status`, the `seed-snapshots` command;
  snapshot on every mapping write; the adoption branch; the status payload and
  confirmation use `expected_status`.
- `skills/mstack-run/scripts/paperclip_lifecycle.py`: authored maps to `backlog`;
  `catch_up_plan` uses `board_change`.
- `skills/mstack-run/scripts/test_paperclip_board_order.py`: new (characterization
  first, then the contract table and behaviour tests).
- `skills/mstack-run/scripts/test_paperclip_lifecycle.py`: the deferred authored
  expectation becomes `backlog`; a no-`todo`-outcome assertion.
- `skills/mstack-run/scripts/fixtures/paperclip/issue-update-2026.1005.0.json` and
  `.meta`: the Task 1 evidence.
- `docs/paperclip-migration.md`, `skills/mstack-paperclip/SKILL.md`: the contract
  sentence.

**Out of scope:**

- `board.sh next` and any activity-feed proof that Matthew himself set `todo`
  (homelab 233).
- Any change to `guard()`, to the `uncertain` creation and update rules, or to the
  terminal-issue rule.
- `paperclip_adoption.py`, including its stale snapshot after a description rewrite
  (residual (e); code review L3 follow-up).
- Refusing `todo` in `task()`.
- Bulk-migrating existing `blocked` tasks.
- Any board write outside the test fake, any push, any change in `~/dev/homelab`.

## Tasks

1. Read the Paperclip 2026.1005.0 server and db source from the npm cache, read-only,
   classify every GET key, and write the evidence fixture and `.meta` (Design, "Task
   1 evidence"). Stop and report if the source is unreadable.
2. Write `test_paperclip_board_order.py` characterization tests (1)–(4) against
   unmodified code. Run them and every existing `test_paperclip_*.py`; all must pass.
   Commit tests only: `test(paperclip): characterize manual-change conflicts`.
3. Implement `snapshot_of`, `board_change` and `expected_status` in `paperclip.py`,
   plus the contract-table unit tests.
4. Wire the snapshot into every mapping write, the adoption branch, and the
   no-`status` authored-on-`todo` PATCH; marker adoption of `todo` stays a conflict.
   Flip characterization tests (1) and (2) in this diff; (3) stays as pinned.
5. `paperclip_lifecycle.py`: authored maps to `backlog`, and `catch_up_plan` uses
   `board_change`. Flip (4) and the deferred expectation in
   `test_paperclip_lifecycle.py`.
6. Remaining behaviour tests: never-sends-priority, fail-closed baselines,
   projection drift, the no-mapping `todo` conflict, existing-blocked to `backlog`,
   keyed-task adoption, the authored marker re-run.
6a. `seed-snapshots` and its tests.
7. Docs sentence in `docs/paperclip-migration.md` and
   `skills/mstack-paperclip/SKILL.md`.
8. Run every Verification `[cmd]`. Stop for independent code review.

This repo's Paperclip reporting runs inside `mstack-run` itself, through the `claimed`
and `done` reports. So execute this plan in a scoped, manual `mstack-run` invocation
(one plan, watched), and re-run the Paperclip suites by hand after the commit lands.

## Verification

- [cmd] python3 -m unittest skills/mstack-run/scripts/test_paperclip_board_order.py -v
- [cmd] python3 -m unittest skills/mstack-run/scripts/test_paperclip_transport.py -v
- [cmd] python3 -m unittest skills/mstack-run/scripts/test_paperclip_lifecycle.py -v
- [cmd] python3 -m unittest skills/mstack-run/scripts/test_paperclip_lifecycle_characterization.py skills/mstack-run/scripts/test_paperclip_migration.py skills/mstack-run/scripts/test_paperclip_config.py skills/mstack-run/scripts/test_paperclip_onboarding.py -v
- [cmd] grep -q "'authored': 'backlog'," skills/mstack-run/scripts/paperclip_lifecycle.py
- [cmd] grep -q "issue manually changed; reconciliation required" skills/mstack-run/scripts/paperclip.py
- [cmd] grep -q "seed-snapshots" skills/mstack-run/scripts/paperclip.py
- [manual] **[approval id needed: board reads]** Before Matthew orders anything, run `python3 skills/mstack-run/scripts/paperclip.py seed-snapshots --repo <repo>` once in each checkout that reports to the board (Studio and MacBook) and record the JSON counts. A nonzero `changed` count lists the tasks that will still conflict on his first edit. Homelab 235 stays off until this has run.
- [manual] After homelab 236 and this plan are both deployed: Matthew sets a priority and `todo` on one harmless plan task. The next mstack report and the next daily catch-up show `delivered`, with no `conflict`, and the task keeps his priority.

## Open questions for Matthew (recommended defaults in bold)

1. **Hash every other field (stricter than homelab 236's 8-field list).** Or compare
   only `title, description, assigneeAgentId, assigneeUserId, projectId, parentId`,
   for exact parity. Default: **hash the issue's own fields and relation ids; drop the
   classified PROJECTION keys** (eng review). "Every other conflict rule stays as is"
   rules out a silent loosening on fields outside the list, and hashing the raw GET
   projection would make the feature fail on drift in joined data. The shared table
   gives the same answers either way.
2. A newer `updatedAt` with no field changed (for example a comment): **adopt**, or
   keep it a conflict?
3. Records written before this plan, including `paperclip_adoption.py` ones, have no
   snapshot. **`seed-snapshots` gives a record a snapshot when the board is
   unchanged since mstack's last write** (same `status` and `updatedAt`, which is
   today's own proof). Every other record fails closed. (Eng review: the author's
   original "no backfill" default would have left every existing task permanently
   conflicting, because its next write comes only after Matthew's `todo`.)
4. `task()` (keyed, plan-less tasks) still accepts a caller-given `todo`. **Leave
   it.** The callers are homelab's approvals feed, which plan 234 stops, and `board.sh
   next` proves who set `todo` anyway.
5. An authored report for a locally `blocked`/`deferred` plan now shows `backlog` on
   the board. The local status stays in the comment's `Local source status:` line.
   **Accept**, per decision (b).

## Implementation Notes

Paperclip delivery now adopts a board priority change and a `backlog`/`todo` move
against a stored per-task snapshot; every other hand change stays a conflict. Authored
plan tasks are created as `backlog` and mstack never sets `todo` on a plan task.
`seed-snapshots` gives pre-plan-100 records a snapshot when the board is unchanged
since mstack's last write. Code-review fixes (533de03): a lost-response retry adopts
board `todo` only when the rest of the task is unchanged since the snapshot (M1);
`labelIds` are hashed sorted (L1); `seed-snapshots` reads the board without the ledger
lock and skips any mapping changed meanwhile (L2). L3 is residual (e).

**Files changed:**

- `docs/paperclip-migration.md` (modified)
- `docs/plans/100-paperclip-adopts-board-order-changes.md` (modified)
- `skills/mstack-paperclip/SKILL.md` (modified)
- `skills/mstack-run/scripts/paperclip.py` (modified)
- `skills/mstack-run/scripts/paperclip_lifecycle.py` (modified)
- `skills/mstack-run/scripts/test_paperclip_lifecycle.py` (modified)
- `skills/mstack-run/scripts/fixtures/paperclip/issue-update-2026.1005.0.json` (created)
- `skills/mstack-run/scripts/fixtures/paperclip/issue-update-2026.1005.0.json.meta` (created)
- `skills/mstack-run/scripts/test_paperclip_board_order.py` (created)

**Commits:** `ab49ecf` (characterization), `f8f24f4` (feature), `d5c1b70` (code
review record), `533de03` (review fixes). The work was committed before completion,
so there is no placeholder hash to backfill.

**Verification:** all 7 `[cmd]` checks pass (184 Paperclip python tests). Health gate
`VERDICT:PASS`, composite 10.0 (shell only; the python tests are not in the health
stack and were run separately).

**Pending rollout steps (not run; they need the live board):**

1. `[manual]` Before Matthew orders anything, run `python3
   skills/mstack-run/scripts/paperclip.py seed-snapshots --repo <repo>` once in each
   reporting checkout (Studio and MacBook) and record the JSON counts. Needs an
   approval id for board reads. Homelab 235 stays off until this has run.
2. `[manual]` After homelab 236 and this plan are deployed, Matthew sets a priority
   and `todo` on one harmless plan task; the next report and the next daily catch-up
   show `delivered` with no `conflict`, and the task keeps his priority.
3. The Step 7a step 9b `done` lifecycle report to Paperclip was not emitted (no
   board calls in this completion); the next catch-up or a manual emit covers it.

**Known residual (low, fails closed):** the lost-first-response allowance in
`own_retry` (board `rest` equal to the snapshot with `assigneeUserId=None`) does not
fire against the real board, because Paperclip bumps `statusVersion` (an OWN field)
on an assignee change. Such a retry is a conflict, not an adoption; the fake board
does not model `statusVersion`, so `test_lost_first_response_then_todo_is_delivered`
passes only there.
