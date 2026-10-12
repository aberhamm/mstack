# Native Paperclip tracking

Mstack detects an enabled repository binding and reports desktop/CLI work through
Paperclip by default. Connect with `/mstack-config paperclip connect`; status,
reconnect and disable use the same command family. Interactive startup offers
connection once. Headless execution keeps working without setup or an outage.
Local plans, dependencies, health and reviews remain authoritative. Hosting,
databases and backup responsibility remain with the infrastructure repository.

## Reviewed installation

Install from a clean detached checkout at the reviewed commit. Transfer that commit
with a local Git bundle when needed; do not create a named branch or pull a pinned
checkout. Detached installations suppress update fetches and pull suggestions.
Use distinct source checkouts and independent official login stores per machine.

```bash
MSTACK_SKIP_SKILLSHARE_SYNC=1 /absolute/reviewed/source/setup --without-gstack --skip-hooks --replace-paperclip-prototype --backup-dir /absolute/private/rollback
```

Set MSTACK_SKILL_DIR explicitly if the intended skill directory is not automatically
selected. The backup directory must be new and outside source/target directories.
The installer snapshots prior directories and symlinks, skips unrelated ordinary
skill directories, replaces only the explicitly chosen Paperclip prototype, and
rolls back partial installation failures. Repeating the same installation is a
no-op; changed user targets are refused. Existing hook files/configuration stay
untouched with --skip-hooks. Run Skillshare sync separately only after validating
links; it is necessary when introducing the new skill directory.

Restore with `SOURCE/setup --restore-manifest /absolute/private/rollback/manifest.json`.
Restore refuses edited installed targets rather than discarding user changes.
Backups contain skill source, never credentials. Retain every installer-chain manifest until both machines'
external-session lifecycle checks pass.

## Adoption and source ownership

The rollout manifest is operator input, not a product default. Supply an explicit
profile and company on an unconfigured repository:

```bash
python3 SOURCE/skills/mstack-run/scripts/paperclip_lifecycle.py adopt --repo REPO --sources MANIFEST --profile PROFILE --company COMPANY
```

Default is read-only. Every issue is fetched fully and matched by its exact original
`paperclip-source` marker, computed from original repository name and source identity.
Repeated markers within one description count as one issue. Unique archive filename
fallback preserves historical identities; actual frontmatter IDs, not filenames,
become native plan identities when unique. Duplicate local plan IDs remain independently
adopted by exact source markers with a visible collision diagnostic and no lifecycle
plan mapping; local lifecycle identity validation refuses those IDs. TODO-only source
records remain independent. Missing
or ambiguous markers, missing plan identity, malformed source blocks or conflicting
bindings prevent apply; no records are deleted or recreated.

Refresh dry-run immediately before explicit `--apply`. Apply changes only the bounded
source-status description block and private Git integration state; status, ownership,
human notes and historical markers are retained. Save the report and compare record
and project counts with the input. Partial failures require inspection and another
read-only parity check before continuing; do not blindly resend uncertain writes.
Local rollback snapshots live in each common Git integration directory as
`adoption-backup.json`. Before any remote refresh, `adoption-remote-backup.json`
durably retains only each original bounded source-status block (null when absent),
including interrupted partial runs; retries preserve the first originals. Human
text outside the managed block is never copied into these snapshots. Restoring a
block must preserve the current surrounding human text; credential-like material
inside the managed block refuses adoption.
Credentials are excluded. The `restore_source_block(current_description, original_block)` helper changes only
the owned block and preserves current surrounding human notes. Restoring source blocks requires fresh full-record reads
and verification that no later writer or human edit would be overwritten.

After verified parity, stop the former source-description writer. Mark its source
manifest as owned by native mstack through the documented handoff file beside the
manifest; the old writer must refuse --apply while that file names native mstack.
Rollback removes that handoff only after restoring/inspecting native state and
ensuring native source refresh is disabled. Never run both source-status writers.
Select exactly one source-status writer machine. Other machines use explicit
`adopt ... --mappings-only` for dry-run, then `--apply --mappings-only` to establish
verified local bindings and mappings without any remote PATCH or source-block refresh.
Missing local plans remain source-only with diagnostics, independently of remote
marker ambiguity, and become eligible after future source updates and re-adoption.
Never let an older checkout downgrade the source-status block. Native adoption owns the same bounded block; it remains separate from issue status
and comments. Re-running native dry-run/apply refreshes descriptions conservatively.

## Report metadata

`paperclip_lifecycle.sh emit` takes its metadata on the command line: `--session`,
`--worktree` and `--note`, plus `--review-evidence`, `--test-evidence`,
`--health-result` and `--completion-tag-sha` where a report needs them. Nothing is
written into the checkout, so sessions sharing a checkout or working in separate
worktrees of one repository do not overwrite each other. A report made while another
one for the same repository is in flight waits for it, up to 45 seconds; a reporter
killed mid-report leaves its lock directories behind, and later reports then wait
that long and answer `conflict` until the locks are removed as described under
Recovery. Pass each value as `--flag="$VALUE"` so a value
that starts with a dash is still read as a value. The earlier
`--json FILE` form still works for an installation that has not updated; a call
uses one form or the other, not both. The evidence a `done` report must carry is
unchanged.

## Tasks without a plan

`paperclip.sh task --repo REPO --project ID --key TEXT --title TEXT --status STATUS
[--note TEXT] [--dry-run]` creates or updates one board task that has no plan behind
it. The checkout supplies only the board connection; the project and the key identify
the task, and the key is kept as a hidden marker in the task text, never in clear.
The first call creates the task; later calls with the same key set the status and add
the note as a comment. Title and note pass the credential filter, and a refused text
(`"delivery": "refused"`) stops the call before any request. The plan-sync rules
apply unchanged: intent is saved first, an uncertain write is never blindly repeated,
a closed or manually changed task is a conflict rather than an overwrite, and nothing
is ever deleted. `--dry-run` only reads and reports `create`, `update` or `none`.
The answer is one line of JSON carrying `delivery` and `issue_id`. Task state is kept
per project beside the plan ledger and never mixes with it.

`--project` is the board's project id, always in the same form, and `--key` is used
exactly as given: the marker is `<!-- mstack-plan:H -->` with
`H = sha256("task:" + PROJECT + "\n" + "task-" + sha256(KEY)[:40])`, both digests in
lowercase hex over UTF-8. The formula is fixed, so another tool may mark an existing
task for a key. The note of the creating call becomes the task text and later notes
become comments; the title is used only at creation. Repeating the latest call sends
nothing. A call answered `pending` is retried by making it again; queued calls for a
key are delivered in the order they were made, so a queued call that closes a task
makes a later queued call that reopens it a conflict. A call the board rejected stays
`pending` with a diagnostic and is not resent; the per-project `tasks-*.json` file
beside the plan ledger must then be inspected by hand, since `reconcile` and `status`
cover plans only. A task found only by its marker
(another checkout, lost local state, or marked by another tool) is taken over when it
is still in `backlog` or already has the requested status; otherwise the call is a
conflict to inspect by hand, and that key stays held until it is resolved.

## Recovery and acceptance

`paperclip_lifecycle.sh status` shows queued/conflicting delivery; `reconcile` is
bounded to ten events. Inspect ownership and manual states before resolving conflicts.
Uncertain create/comment writes are never blindly repeated. A crashed local lock may
need ownership-aware manual removal after confirming its writer is gone.

On each machine, use one disposable task through an authenticated external session:
claim, verification/review, local committed archive and annotated tag, then done.
Confirm readback, human assignment, separate credentials, primary/worktree binding
identity, and zero container-agent wakeups. Also check unconfigured/declined no-op
behavior and offline pending delivery. Preserve reports and rollback manifests.
