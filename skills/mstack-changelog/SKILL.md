---
name: mstack-changelog
description: |
  Utility skill (not part of the core plan execution pipeline). Syncs changelogs
  with git history. Reads existing CHANGELOG.md files, finds the last recorded
  entry, diffs against git log, classifies changes by type and app, and drafts
  new entries in Keep a Changelog format. Use after plan execution is complete,
  typically as part of the ship workflow. Use when asked to "update changelog",
  "sync changelog", "what shipped since last changelog", or "changelog catch-up".
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
---

# Changelog Sync

You are running the `/changelog` skill. Your job: compare git history against
existing changelogs and draft new entries for anything that shipped but isn't
recorded yet.

**Philosophy:** Present a draft, let the user approve. Changelog voice should be
user-facing ("You can now...") not developer-facing ("Refactored the...").

---

## Step 1: Discover changelogs and repo shape

```bash
# Find all CHANGELOG files
find . -maxdepth 3 -name "CHANGELOG*" -not -path "./.git/*" -not -path "./node_modules/*" 2>/dev/null | sort

# Detect monorepo (multiple apps/ or packages/ dirs)
ls -d apps/*/ packages/*/ 2>/dev/null | head -20

# Get current branch and remote
git branch --show-current 2>/dev/null
git remote get-url origin 2>/dev/null || echo "no remote"
```

**If no CHANGELOG exists:** Tell the user and ask whether to create one.
Use AskUserQuestion:
- A) Create CHANGELOG.md at the repo root
- B) Skip — don't create one yet

If the repo has multiple apps (monorepo), mention that entries will be grouped
under app headers within a single root CHANGELOG.

---

## Step 2: Find the last recorded entry

Read the existing CHANGELOG.md (if it exists). Find the most recent entry's date
or version. This is the "changelog horizon."

**Strategies to find the horizon (try in order):**
1. Parse the most recent `## [version]` or `## version` header — extract the date
2. Parse the most recent `## YYYY-MM-DD` or `### YYYY-MM-DD` header
3. If the file exists but has no parseable date, use the file's last git commit date:
   ```bash
   git log -1 --format=%aI -- CHANGELOG.md 2>/dev/null
   ```
4. If no CHANGELOG exists, use the repo's first commit (full history)

Print: `Changelog horizon: <date or "beginning of repo">`

---

## Step 3: Gather commits since the horizon

```bash
# All commits since the horizon, one line each
git log --since="<horizon-date>" --oneline --no-merges
```

```bash
# Stat summary to understand scope
git log --since="<horizon-date>" --stat --no-merges
```

If the commit count is very large (>100), narrow to the last 2 weeks or ask the
user for a date range.

### Deduplication gate

Before classifying, filter out commits already covered by the existing
CHANGELOG. For each candidate commit:

1. Extract its short description and affected files.
2. Search the existing CHANGELOG content for matching keywords — if the
   commit's subject (or a semantically equivalent phrase) already appears
   in a changelog entry, skip it.
3. Check commit SHAs: if the CHANGELOG contains a `<!-- commits: abc1234, def5678 -->`
   comment block (written in Step 7), skip any listed SHAs.

This ensures re-running `/mstack-changelog` after partial updates won't
duplicate entries. Only truly new, unrecorded changes proceed to Step 4.

---

## Step 4: Classify changes

For each commit, determine:

1. **Type** — map to Keep a Changelog categories:
   - `Added` — new features, new endpoints, new commands, new files
   - `Changed` — modifications to existing behavior, UI updates, refactors
   - `Fixed` — bug fixes
   - `Removed` — deleted features or deprecated functionality
   - `Security` — security-related changes

2. **App/scope** — in a monorepo, determine which app or package each commit
   primarily affects by looking at the changed file paths. Use the directory
   structure detected in Step 1 (e.g., `apps/web`, `apps/api`, `apps/lookbook`).
   Commits touching shared packages or multiple apps go under a "Shared" or
   "Infrastructure" header.

3. **User-facing?** — distinguish between user-facing changes (features, fixes,
   UI) and internal changes (refactors, tests, CI, deps). Internal changes go
   in a separate "### Internal" subsection or are omitted if minor.

**Skip these entirely:**
- Merge commits
- Pure whitespace/formatting changes
- Dependency bumps with no behavior change (unless security-related)
- CI-only changes (unless they affect the user's workflow)

---

## Step 5: Draft the changelog entry

Format using [Keep a Changelog](https://keepachangelog.com/) conventions:

```markdown
## [Unreleased] — YYYY-MM-DD

### App Name (if monorepo)

#### Added
- Description of what the user can now do

#### Changed
- Description of what changed from the user's perspective

#### Fixed
- Description of what was broken and is now fixed
```

**Voice rules:**
- Lead with what the user can DO, not what the developer DID
- "You can now export items as CSV" not "Added CSV export endpoint"
- "Search results now include fuzzy matching" not "Implemented pg_trgm trigram search"
- Group related commits into single entries when they're part of one feature
- Be specific: include the command, URL, or UI location when relevant
- Skip empty categories (don't include `#### Removed` if nothing was removed)

**Monorepo grouping:** Use `### App Name` headers to separate changes by app.
Put shared/infrastructure changes under `### Shared` or omit if trivial.

---

## Step 6: Present draft for approval

Show the full drafted entry to the user. Use AskUserQuestion:

- A) Looks good — write it (Recommended)
- B) Edit — I'll make changes (show the draft in a code block they can modify)
- C) Skip — don't update the changelog right now

**If A:** Proceed to Step 7.
**If B:** Ask the user what to change, apply their edits, and re-present.
**If C:** Exit cleanly.

---

## Step 7: Write the entry

**If CHANGELOG.md exists:**
Use the Edit tool to insert the new entry after the file header (title line and
any preamble) but before the previous entry. The newest entry should always be
at the top of the changelog body.

**If creating a new CHANGELOG.md:**
Write the full file with a standard header:

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased] — YYYY-MM-DD

...entries...
```

After the entry content, append a hidden HTML comment listing the commit SHAs
that were included in this entry (for deduplication on future runs):

```markdown
<!-- commits: abc1234, def5678, ghi9012 -->
```

After writing, print:
- How many entries were added
- Which categories had entries
- The date range covered

Do NOT commit. Do NOT push. Just write the file and let the user decide
what to do next.
