# Example: Multi-tenant billing for a Next.js SaaS app

This is a fabricated but realistic example showing what mstack produces when you decompose a goal, validate it, and run the backlog autonomously.

The scenario: a solo developer adding multi-tenant billing to a Next.js 15 application with Prisma and Stripe.

## What's here

```
plans/
  001-billing-schema.md          Plan file — database schema for per-org billing
  002-stripe-webhooks.md         Plan file — Stripe webhook integration
  003-usage-metering.md          Plan file — usage tracking service
  004-invoice-generation.md      Plan file — invoice PDF generation
  005-billing-dashboard.md       Plan file — tenant billing UI

.mstack/
  health-history.jsonl           Health scores across all 5 plan executions
  learnings.jsonl                Patterns discovered during execution

CHANGELOG.md                     What the developer reads when they come back
```

## The sequence

1. Developer ran `/mstack-plan-multi "add multi-tenant billing with Stripe"` — got 5 ordered plans
2. Ran `/mstack-plan-doctor` — all plans scored 9+ on autonomy-readiness, walk-away confidence HIGH
3. Ran `/goal all pending mstack plans are done or failed` — closed the laptop
4. Came back, ran `/mstack-changelog` — read this changelog

## What to notice

- **Health scores improve** — plan 001 scores 7.8 (new dead code from scaffolding), plan 005 scores 9.4 (cleanup happened along the way)
- **Learnings accumulate** — the Prisma upsert pitfall from plan 001 surfaces as a constraint in plan 003 when it touches the same tables
- **Plans reference each other** — `blocked-by: [1, 2]` means plan 003 waits for the schema and webhooks to land first
- **Verification is executable** — every plan has `[cmd]` and `[assert]` checks, not prose descriptions
