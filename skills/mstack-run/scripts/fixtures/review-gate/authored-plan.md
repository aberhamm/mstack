<!--
plan-045 fixture: a plan someone actually WROTE. Carries no recorded `reviews:`
entry, exactly like a fresh scaffold — the two states are indistinguishable to
`assert-committed`, which is the whole reason `plan-authored` exists. Every
instructional line from plan-template.md has been replaced with real content, so
`plan-authored` must return AUTHORED (exit 0), never scaffold.

Modeled on the real incident: a fully-authored plan sat untracked at session
close and mstack-wrap-up said nothing about it.
-->

---
id: 952
title: Encrypt stored social account credentials at rest
status: pending
blocked-by: []
priority:
goal:
allows-migrations: true
needs-review: eng
review-required: eng
created: 2026-07-26
---

## Requirements

Social account passwords are stored as plaintext in `accounts_socialaccount`,
so anyone with a database dump or a read replica has every scraper login. The
scraper worker is the only consumer, and it reads them on every session start.

**Acceptance criteria**

- [ ] New and updated credentials are written encrypted with a key read from
      `SOCIAL_CRED_KEY`; no plaintext value ever reaches the column again.
- [ ] The worker decrypts transparently, so no call site changes.
- [ ] A management command re-encrypts existing rows, and is idempotent.

## Design

A `EncryptedCharField` wraps Fernet and is swapped in for the plaintext column.
The key comes from the environment and never from settings-in-git. Rows are
migrated in batches so a large table does not lock.

**Files expected to change:**

- `accounts/fields.py`: new `EncryptedCharField`
- `accounts/models.py`: swap the password column onto the new field
- `accounts/management/commands/reencrypt_credentials.py`: batch re-encryption

**Out of scope:** rotating the key, and the proxy credentials table (a separate
store with different consumers).

## Tasks

1. Add the field type and its round-trip tests.
2. Swap the model column and generate the migration.
3. Write the re-encryption command and run it against a dump.

## Verification

Checks:

- [cmd] `python manage.py test accounts.tests.test_encrypted_field`
- [assert] `python manage.py shell -c "..."` prints `gAAAA` for a stored value
