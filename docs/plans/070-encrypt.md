---
id: 070
title: guard curl_cffi impersonation
status: pending
blocked-by: []
needs-review: none
created: 2026-07-30
---

## Design

**Files expected to change:**

- `scraper/impersonation.py`: add the guard
- `tests/test_curl_cffi_impersonation_guard.py`: cover the guard

## Verification

Checks:
- [cmd] `pytest tests/test_curl_cffi_impersonation_guard.py`
