---
id: 1
title: Add per-org billing schema
status: done
blocked-by: []
needs-review: none
created: 2026-05-12
---

## Requirements

The application currently has a single-tenant data model. All billing state lives in a `users` table with no concept of organizations. Multi-tenant billing requires a new schema layer: organizations own subscriptions, subscriptions track plans and status, and usage records tie metered events to orgs.

**Acceptance criteria:**

- [x] Prisma schema has `Organization`, `Subscription`, `UsageRecord` models with proper relations
- [x] `Organization` has: id, name, stripeCustomerId, createdAt
- [x] `Subscription` has: id, orgId, stripePriceId, status (enum: active/past_due/canceled/trialing), currentPeriodEnd
- [x] `UsageRecord` has: id, orgId, metric (string), quantity (int), timestamp, reported (boolean)
- [x] Migration runs cleanly on existing database with seed data
- [x] Existing users are assigned to a default organization via data migration

## Design

**Files expected to change:**

- `prisma/schema.prisma` — new models and relations
- `prisma/migrations/20260512_billing_schema/` — NEW: generated migration
- `prisma/seed.ts` — update to create default org and assign existing users
- `src/lib/db/types.ts` — re-export generated types for billing models

**Approach:**

Add the three models to the Prisma schema with proper indexes (orgId on Subscription, orgId+metric+timestamp on UsageRecord). Generate and apply the migration. Update the seed script to create a default "Personal" organization and migrate all existing users to it.

**Out of scope:**

- Stripe API integration (plan 002)
- Usage tracking logic (plan 003)
- Any UI changes

## Tasks

1. Add Organization, Subscription, UsageRecord models to prisma/schema.prisma
2. Add enum for subscription status
3. Generate migration with `npx prisma migrate dev`
4. Update seed.ts to create default org and assign users
5. Re-export billing types from src/lib/db/types.ts

## Verification

- [cmd] npx prisma migrate status
- [assert] npx prisma validate 2>&1 | grep -q 'valid'
- [cmd] npx tsx prisma/seed.ts
- [assert] grep 'Organization' prisma/schema.prisma
- [assert] grep 'UsageRecord' prisma/schema.prisma
