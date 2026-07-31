---
name: mstack-config
description: |
  Project settings for mstack. Initializes or edits .mstack/config.json.
  Configures health commands, scoring weights, review provider preferences,
  commit conventions, and ignored paths. Falls back to
  AGENTS.md/CLAUDE.md and built-in defaults when no config exists.
argument-hint: "[init | show | set <key> <value> | reset]"
allowed-tools:
  - Bash
  - Read
---

You manage mstack project configuration. Settings live in
`.mstack/config.json` and affect how mstack-run, mstack-code-health,
mstack-code-review, and other skills behave.

User input:

```
$ARGUMENTS
```

## Scripts

All config read/write logic lives in `config.sh`. Resolve the scripts
directory:

```bash
SCRIPTS_DIR="${HOME}/.config/skillshare/skills/mstack-run/scripts"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SCRIPTS_DIR" ] && break
  [ -d "${_skill_base}/mstack-run/scripts" ] && SCRIPTS_DIR="${_skill_base}/mstack-run/scripts"
done
```

### Available commands

| Command | What it does |
|---------|-------------|
| `bash "$SCRIPTS_DIR/config.sh" init` | Create config with defaults (no-op if exists) |
| `bash "$SCRIPTS_DIR/config.sh" show` | Pretty-print current config (or defaults) |
| `bash "$SCRIPTS_DIR/config.sh" get <dotpath>` | Get a single value (e.g., `health.weights.test`) |
| `bash "$SCRIPTS_DIR/config.sh" set <dotpath> <value>` | Set a single value with validation |
| `bash "$SCRIPTS_DIR/config.sh" reset` | Overwrite config with defaults |

The script validates values automatically:
- `review.provider` must be: auto, codex, gemini, claude-only
- `health.weights.*` must be numbers
- `commit.conventional` and `commit.trailer` must be true/false

## Modes

### `init`: create config with defaults

Run `bash "$SCRIPTS_DIR/config.sh" init`. Print: "Config initialized at
.mstack/config.json" (or note that it already exists).

### `show`: display current config (default when no argument)

Run `bash "$SCRIPTS_DIR/config.sh" show`. Present the JSON output to the
user. For each section, note whether values are from config or built-in
defaults:

```
MSTACK CONFIG
=============
Source: .mstack/config.json

health.commands:
  typecheck:  pnpm -r typecheck  (config)
  lint:       pnpm -r lint       (config)
  test:       pnpm test          (config)
  e2e:        (auto-detected)
  deadcode:   (auto-detected)
  shell:      (auto-detected)

health.weights:
  typecheck: 20  lint: 15  test: 25  e2e: 20  deadcode: 10  shell: 10  (defaults)

review.provider:  auto
commit:           conventional=true, trailer=true
ignored_paths:    (none)
```

### `set <key> <value>`: update a specific setting

Run `bash "$SCRIPTS_DIR/config.sh" set <key> <value>`. The script handles
validation and reports errors. Examples:

```
/mstack-config set review.provider codex
/mstack-config set health.weights.test 40
```

### `reset`: restore defaults

Confirm with the user first: "This will reset all mstack config to defaults.
Current config will be lost." Then run `bash "$SCRIPTS_DIR/config.sh" reset`.

## Default config

When no config exists, mstack uses these defaults:

```json
{
  "health": {
    "commands": {},
    "weights": {
      "typecheck": 20,
      "lint": 15,
      "test": 25,
      "e2e": 20,
      "deadcode": 10,
      "shell": 10
    }
  },
  "review": {
    "provider": "auto"
  },
  "commit": {
    "conventional": true,
    "trailer": true
  },
  "ignored_paths": []
}
```

## Config schema reference

### `health.commands`: override tool auto-detection

Empty string or `null` for a key means skip that tool. Omitted keys use
auto-detection.

### `health.weights`: scoring weights (must sum to 100)

The six categories above are the complete set, and the block above is the ONLY
place default weights are defined: `health-check.sh` reads every weight through
`config.sh get health.weights.<category>` and carries no fallback literals of
its own. If a weight cannot be read the gate fails closed with
`FAILURES:config-unreadable` (exit 36) rather than scoring against an
improvised set.

Weights are relative, not absolute: a category with no detected tool is
`SKIPPED` and its weight is redistributed across the categories that did run.
A repo with no e2e framework is therefore scored out of 10 over the tools it
has, not capped at 8 for lacking Playwright.

### `review.provider`: cross-model review preference

- `"auto"`: discover best available (codex > gemini > claude-only)
- `"codex"`: always use Codex CLI if available
- `"gemini"`: always use Gemini CLI if available
- `"claude-only"`: never use external models

### `commit.conventional`: use `type(scope): subject` format

### `commit.trailer`: add a `Refs: <plans-dir>/<file>` trailer

### `ignored_paths`: paths the worker should never edit

Advisory, not enforced: `mstack-run` reads this list and instructs the worker to
leave those paths alone. No hook blocks a write to them.

## Integration with other skills

Skills read config via the script at startup:

```bash
bash "$SCRIPTS_DIR/config.sh" get review.provider
bash "$SCRIPTS_DIR/config.sh" get health.weights.test
```

If no config file exists, the script falls back to built-in defaults.
Config is optional; mstack works without it.
