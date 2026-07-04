---
id: 901
title: Legacy plan with needs-review but no review-required
status: pending
blocked-by: []
needs-review: eng
created: 2026-07-04
---

## Requirements

Fixture: a legacy plan flagged `needs-review: eng` with NO `review-required`
field and NO reviews record. `assert-completable` MUST fail closed (nonzero)
rather than treating the absent field as "nothing required".
