---
id: 3
title: Usage metering service
status: done
blocked-by: [1, 2]
needs-review: none
created: 2026-05-12
---

## Requirements

Organizations need metered billing — they pay based on how many API calls, storage bytes, or compute minutes they use. This plan creates the service layer that records usage events, aggregates them per billing period, and reports totals to Stripe.

**Acceptance criteria:**

- [x] `UsageService` class with `record(orgId, metric, quantity)` method
- [x] Batch reporting: aggregates unreported UsageRecords per org per metric and sends to Stripe usage API
- [x] Reporting marks records as `reported: true` to prevent double-counting
- [x] Handles partial failures — if Stripe rejects one metric, others still report
- [x] Rate limiting: batches reports in groups of 100 to avoid Stripe API limits
- [x] Unit tests for recording, aggregation, and Stripe reporting
- [x] Integration test with test database verifying the full record-aggregate-report cycle

## Design

**Files expected to change:**

- `src/lib/billing/usage-service.ts` — NEW: usage recording and reporting
- `src/lib/billing/usage-aggregator.ts` — NEW: aggregation queries
- `tests/billing/usage-service.test.ts` — NEW: unit tests
- `tests/billing/usage-integration.test.ts` — NEW: integration test with test DB

**Approach:**

Recording is a simple Prisma insert. Aggregation uses a `GROUP BY orgId, metric` query on unreported records. Reporting iterates the aggregated results, calls `stripe.subscriptionItems.createUsageRecord` for each, and marks the source records as reported in a transaction. Partial failure handling: catch per-metric errors, log them, continue with remaining metrics, return a result object listing successes and failures.

Note: Prisma's `createMany` does not support `onConflict` (upsert) for this table structure due to the composite key. Use individual `create` calls wrapped in a transaction instead. (Discovered during plan 001 schema work.)

**Out of scope:**

- Usage display in the UI (plan 005)
- Invoice line item breakdown (plan 004)
- Real-time usage alerts

## Tasks

1. Create UsageService with record() method
2. Create aggregation queries in usage-aggregator.ts
3. Implement Stripe reporting with batch processing and partial failure handling
4. Write unit tests for each method
5. Write integration test with test database

## Verification

- [cmd] npm test -- --grep usage
- [assert] test -f src/lib/billing/usage-service.ts
- [assert] test -f tests/billing/usage-integration.test.ts
- [assert] grep 'createUsageRecord' src/lib/billing/usage-service.ts
- [assert] grep 'reported.*true' src/lib/billing/usage-aggregator.ts
