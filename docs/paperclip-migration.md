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
