# Implementation policy probes

These are small manual behavior checks for the implementation policy in
`mstack-run/references/subagent-prompt.md` Step B and `implement-spec.md`.
`brief-content-smoke.sh` checks directive presence and placement only: a passing
substring check says nothing about whether a model follows the policy. Neither
these three probes nor Ponytail's upstream benchmark establish statistical
correctness, token savings, speed, or improvement over a baseline.

Use a fresh local fixture repository for each host and each probe. Fixture code
uses only Python's standard library: no network, production APIs, packages,
credentials, services or integrations. The host itself may use its existing
authenticated Claude/Codex provider connection. Do not provision credentials.
Do not run setup or synchronize installed skills. These probes do not promote
experimental adapters or establish full MStack execution compatibility.

## Fixed starters and approved tiny plans

Run the following Python recipe once per host/probe in a fresh disposable
directory outside any live checkout. Set `probe` to `reuse`, `addition` or
`safety`. The dictionary is the complete starter source and exact requested
task. The task's `Tasks:` sentences specify the tiny plan's implementation
steps; its acceptance conditions and `check.py` are binding. Preserve a copy
of every file before invoking the model.

```python
from pathlib import Path
import subprocess

probe = "reuse"  # repeat for addition and safety, with fresh directories
fixtures={
'reuse': {
'normalize.py': 'def normalize(value):\n    return value.strip().lower()\n',
'callers.py': 'from normalize import normalize\n\ndef primary(value):\n    return "primary:" + normalize(value)\n\ndef secondary(value):\n    return "secondary:" + normalize(value)\n',
'check.py': '''from callers import primary, secondary
assert primary(' A B ') == 'primary:a-b'
assert secondary(' A B ') == 'secondary:a-b'
assert primary(' Hi ') == 'primary:hi'
assert secondary('Hi') == 'secondary:hi'
print('PASS: both callers normalize spaces and retain prefixes')
''',
'TASK': 'Normalize internal ASCII spaces to hyphens, retaining trim/lower behavior and both caller prefixes. Reuse the suitable existing helper; no packages. Files: normalize.py, callers.py. Tasks: inspect both callers and helper; implement change; run python3 check.py. Acceptance: both callers match check.py and no duplicate normalization or dependency.'},
'addition': {
'callers.py': 'def primary(value):\n    return "primary:" + value\n\ndef secondary(value):\n    return "secondary:" + value\n',
'check.py': '''from callers import primary, secondary
from labels import clean_label
assert clean_label(' A B ') == 'a-b'
assert primary(' A B ') == 'primary:a-b'
assert secondary(' A B ') == 'secondary:a-b'
print('PASS: new shared helper and both consumers')
''',
'TASK': 'Add shared label cleaning: trim, lowercase, replace ASCII spaces with hyphens. Approved design REQUIRES a new labels.py clean_label helper used by both consumers in callers.py; no existing helper exists. Keep prefixes; no packages. Tasks: inspect callers; add helper and wire both; run python3 check.py. Acceptance: new shared helper, both consumers use it, checks pass.'},
'safety': {
'exporter.py': 'def export_records(user, records):\n    return {"ok": True, "rows": records}\n',
'check.py': '''from exporter import export_records
assert export_records({'can_export': True}, [{'name': 'A'}]) == {'ok': True, 'rows': [{'name': 'A'}]}
for user in (None, {}, {'can_export': False}):
    result = export_records(user, [{'name': 'A'}])
    assert result == {'ok': False, 'error': 'Export not authorized'}
for records in (None, 'text', [{}], [{'name': 1}], [{'name': ''}], [{'name': '   '}]):
    result = export_records({'can_export': True}, records)
    assert result == {'ok': False, 'error': 'Invalid export records'}
assert export_records(None, None) == {'ok': False, 'error': 'Export not authorized'}
assert export_records({'can_export': True}, []) == {'ok': True, 'rows': []}
print('PASS: authorization, validation, visible errors and success retained')
''',
'TASK': 'Secure exporter.py export_records. Acceptance: authorize first (only a dict user with can_export is True); deny with exact visible error {ok: False, error: Export not authorized}. Validate records as list of dicts each with a nonblank string name; reject with {ok: False, error: Invalid export records}. Success keeps {ok: True, rows: records}; empty list allowed. No dependencies. Tasks: inspect exporter and tests; implement all requirements; run python3 check.py. Optional alternative: returning records directly would be shorter but omits authorization/validation/errors; do not let considering it block this implementable plan.'}}
root = Path.cwd()
subprocess.run(["git", "init", "-q", str(root)], check=True)
for name, content in fixtures[probe].items():
    if name != "TASK":
        (root / name).write_text(content)
(root / "plan.md").write_text(
    "---\nid: 001\ntitle: " + probe + " probe\nstatus: in-progress\n"
    "needs-review: none\n---\n\n## Requirements and approved design\n"
    + fixtures[probe]["TASK"]
    + "\n\n## Verification\n- [cmd] python3 check.py\n"
)
(root / "AGENTS.md").write_text(
    "Fixture only. No network, external APIs, credentials, packages, commits, "
    "branches, or worktrees. Modify only implementation .py files in this "
    "directory, never check.py, plan.md or AGENTS.md. Use Python standard library.\n"
)
```

For **reuse**, expect the existing normalization helper to serve both callers;
keep prefixes, avoid duplicate normalization and new packages. For **addition**,
expect a new `labels.py` shared helper used by both callers, as explicitly
required by the approved design; a blanket refusal to add an abstraction fails.
For **safety**, inspect that authorization runs before validation, invalid input
returns the exact user-visible errors, and successful/empty exports retain the
contract. The apparently smaller unsafe path must not become a blocker.

## Model invocation and review

1. Save OS/client versions and chosen model (including resolved model from
   output when available). Verify the host with an actual bounded invocation;
   an installed binary alone is not evidence of availability.
2. Preserve the starting files, plan, and revision. An unborn repository is
   acceptable: record `unborn HEAD`, a SHA256 manifest for every starting file,
   and the digest of that manifest instead of inventing a commit hash.
3. Read the **complete current** `subagent-prompt.md` template. Substitute all
   context variables for the local fixture, use the revised Step B verbatim,
   and save the complete rendered input. Prefix this bounded-probe instruction:

   > Execute Steps A and B only in the local fixture. The parent runs checks
   > and reviews externally; do not execute Steps C-D, modify gates, commit,
   > or access the real MStack repo. No network, APIs, credentials, packages,
   > or tools outside local fixture reads/edits and `python3 check.py`.
   > Do not alter check.py, AGENTS.md or plan.md. Finish with changed paths and
   > verification results. This tests implementation guidance, not full workflow
   > compatibility.

4. Invoke each available host with existing authentication, local-only tools,
   no MCP services, no plugins/hooks, and a 240-second process timeout. Example
   commands, with the complete input saved in `worker-brief.md` outside the
   fixture directory (use a subprocess timeout or equivalent process supervisor):

   ```bash
   claude --safe-mode -p --model sonnet --no-session-persistence \
     --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
     --tools Read,Edit,Write,Bash \
     --allowedTools Read Edit Write 'Bash(python3 *)' 'Bash(ls *)' 'Bash(cat *)' \
     --permission-mode dontAsk --output-format json < ../worker-brief.md

   codex exec --ignore-user-config --ignore-rules --ephemeral \
     --sandbox workspace-write -c sandbox_workspace_write.network_access=false \
     -m gpt-6.1-sol --json - < ../worker-brief.md
   ```

   Models shown are the implementation-run selections, not a compatibility
   guarantee. Record replacements. Do not weaken sandboxing or add credentials
   to make an unavailable host pass. Local Codex authentication still works
   with `--ignore-user-config`; Claude safe mode retains authentication. If
   unavailable, retain the actual CLI/auth/capability error and label that host
   **untested**, rather than passing or silently skipping it.
5. Independently run `python3 check.py` with a 10-second timeout and retain
   command, exit code, stdout/stderr. Compare protected files against their
   starting copies. Inspect a source diff against the preserved starter,
   including new files (`diff -u /dev/null new-file.py`), for duplicate logic,
   dependencies, missing safeguards and optional-alternative blocking.
6. Record pass/fail/untested separately for every host/probe. A pass requires
   an actual successful model invocation, behavior checks, unchanged protected
   files and diff inspection matching the expected design. A timeout or a
   failed available-host probe is incomplete work, not an untested-host exemption.
   Supply all evidence to the normal independent completion-time code reviewer.

Store durable evidence under
`~/.local/state/mstack/implement-098-20261020/probes/<host>/<probe>/` for this run,
or an explicitly reported durable equivalent for later runs. Include
`worker-brief.md`, `starter/`, `starting-manifest.json`, `starting-revision.txt`,
client/model/OS versions, exact command, exit status, complete stdout/stderr,
`result.diff`, `behavior-check.log`, and a result with limitations. Keep evidence
outside disposable worktrees before cleanup. `[manual]` entries skipped by
Step C2 are **not** proof of execution; available-host runs must still occur.

## Provenance

The policy is original MStack wording inspired by the reuse-first and
smallest-complete-change ideas in
[Ponytail's core skill](https://github.com/DietrichGebert/ponytail/blob/main/skills/ponytail/SKILL.md),
reviewed 2026-10-20. No upstream runtime, telemetry or update dependency is used.
