---
id: 100
title: Paperclip delivery adopts Matthew's priority and ready changes; plan tasks enter as backlog
status: pending
blocked-by: []
priority:
goal: paperclip-board-order
allows-migrations: false
needs-review: eng
review-required: eng,code
created: 2026-11-01
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
  separators=(',', ':'), ensure_ascii=False)`, UTF-8) of the full `GET /issues/{id}`
  object with the keys `status`, `priority`, `updatedAt` and every key in
  `BOARD_SIDE_EFFECT_FIELDS` removed. The status baseline stays `mapping['status']`
  and the time baseline stays `mapping['updated_at']`. They are not duplicated.
  `BOARD_SIDE_EFFECT_FIELDS` holds fields that Paperclip itself rewrites when
  priority or a `backlog`/`todo` status changes. It is empty unless Task 1 shows such
  a field in the Paperclip source (see Design).
- **When the snapshot is written:** at every point where `deliver()` writes a
  mapping from a full issue read. That means marker adoption, after creation, on a
  re-run whose marker already exists, and after a confirmed write. Each time it comes
  from the same issue object whose `status`/`updatedAt` go into the mapping.
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
      flips (1)–(5) to the new expectations in the same diff that changes the code, so
      the flips are reviewable.
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
      `status`/`priority`/`updatedAt` (and outside `BOARD_SIDE_EFFECT_FIELDS`). An
      allowed change combined with a disallowed one. A mapping whose `status` is
      `in_progress` while the board shows `todo`. Assignee and agent changes stay
      refused by `guard()` with their existing diagnostics.
- [ ] **Fail closed on a missing or unreadable baseline.** A mapping without
      `snapshot`, with `snapshot: null`, with `v != 1`, or with a malformed `rest`
      behaves exactly as today on any change: a priority-only change is a `conflict`.
      A mapping with an unchanged board still delivers. That is the pre-plan path, and
      it also writes a snapshot, so a legacy record gains a baseline on its first
      clean write.
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
      report then moves the task to `in_progress`.
- [ ] **A board `blocked` task with a new authored report.** Today the `remote`
      dict in `emit()` (`paperclip_lifecycle.py`) maps an authored draft, proposed,
      deferred or blocked plan to `blocked`, so such tasks are on the board now. The
      next authored report moves one to `backlog` through mstack's own PATCH. It is
      not a conflict, because the mapping's `status` is `blocked`, the same as the
      board, and `deliver()` sees no change. No bulk migration runs.
- [ ] **Marker adoption accepts `todo`.** A task found by marker with no mapping (not
      `uncertain`) whose status is `todo` is adopted like `backlog`. The rule at the
      `adopted issue state differs` check becomes `issue['status'] not in
      ADOPTABLE_STATUSES and event['outcome'] not in ('note', issue['status'])`. The
      `uncertain` creation branch (`uncertain creation was manually changed`) is
      unchanged.
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
  `snapshot_of(issue)`, `board_change(mapping, issue)` and
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
- `paperclip_adoption.py`: **unchanged.** Mappings it writes carry no snapshot, so
  they fail closed until mstack's first clean write stores one (Open question 3).

### Task 1 evidence (input, not output)

`rest` hashes every field, so the rule is only as good as knowing which fields
Paperclip rewrites by itself on a priority change or a `backlog`/`todo` change. A
field like that would make every such change look like a `rest` change. That fails
safe (a conflict, as today) but leaves the feature useless. Task 1 reads the Paperclip
2026.1005.0 issue-update handler, read-only, from source already on disk or the
image's source, with no board call. Task 1 records:

- the full field list of a `GET /api/issues/{id}` response, and
- the columns written besides `priority`/`status`/`updatedAt` on a priority-only or
  `backlog`↔`todo` update.

Task 1 writes the result to
`skills/mstack-run/scripts/fixtures/paperclip/issue-update-2026.1005.0.json`, an
illustrative issue object with the real field names and placeholder values, no live
ids or text. The sidecar `.meta` carries `capture-date:` and the source path and
version it was read from. Any side-effect column found goes into
`BOARD_SIDE_EFFECT_FIELDS`, with a comment that cites the source line. **If the
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
- `M.adopted` is informational. Nothing reads it for control flow. It makes "mstack
  took a board change" legible in the ledger (plan 045: a degraded or adopted path
  must be distinguishable from the plain one).

**Files expected to change:**

- `skills/mstack-run/scripts/paperclip.py`: `ADOPTABLE_STATUSES`,
  `BOARD_SIDE_EFFECT_FIELDS`, `snapshot_of`, `board_change`, `expected_status`;
  snapshot on every mapping write; the adoption branch; marker adoption accepts
  `todo`; the status payload and confirmation use `expected_status`.
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
- `paperclip_adoption.py`.
- Refusing `todo` in `task()`.
- Bulk-migrating existing `blocked` tasks.
- Any board write outside the test fake, any push, any change in `~/dev/homelab`.

## Tasks

1. Read the Paperclip 2026.1005.0 issue-update source, read-only, and write the
   evidence fixture and `.meta` (Design, "Task 1 evidence"). Stop and report if the
   source is unreadable.
2. Write `test_paperclip_board_order.py` characterization tests (1)–(4) against
   unmodified code. Run them and every existing `test_paperclip_*.py`; all must pass.
   Commit tests only: `test(paperclip): characterize manual-change conflicts`.
3. Implement `snapshot_of`, `board_change` and `expected_status` in `paperclip.py`,
   plus the contract-table unit tests.
4. Wire the snapshot into every mapping write, the adoption branch, marker adoption
   of `todo`, and the no-`status` authored-on-`todo` PATCH. Flip characterization
   tests (1)–(3) in this diff.
5. `paperclip_lifecycle.py`: authored maps to `backlog`, and `catch_up_plan` uses
   `board_change`. Flip (4) and the deferred expectation in
   `test_paperclip_lifecycle.py`.
6. Remaining behaviour tests: never-sends-priority, fail-closed baselines,
   existing-blocked to `backlog`, keyed-task adoption, the authored marker re-run.
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
- [manual] After homelab 236 and this plan are both deployed: Matthew sets a priority and `todo` on one harmless plan task. The next mstack report and the next daily catch-up show `delivered`, with no `conflict`, and the task keeps his priority.

## Open questions for Matthew (recommended defaults in bold)

1. **Hash every other field (stricter than homelab 236's 8-field list).** Or compare
   only `title, description, assigneeAgentId, assigneeUserId, projectId, parentId`,
   for exact parity. Default: **hash**. "Every other conflict rule stays as is" rules
   out a silent loosening on fields outside the list. The shared table gives the same
   answers either way.
2. A newer `updatedAt` with no field changed (for example a comment): **adopt**, or
   keep it a conflict?
3. Tasks adopted by `paperclip_adoption.py` before this plan have no snapshot.
   **They fail closed until the first clean mstack write**, with no backfill. A
   backfill cannot know what mstack last wrote.
4. `task()` (keyed, plan-less tasks) still accepts a caller-given `todo`. **Leave
   it.** The callers are homelab's approvals feed, which plan 234 stops, and `board.sh
   next` proves who set `todo` anyway.
5. An authored report for a locally `blocked`/`deferred` plan now shows `backlog` on
   the board. The local status stays in the comment's `Local source status:` line.
   **Accept**, per decision (b).
