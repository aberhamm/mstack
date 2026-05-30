---
id: 2
title: Stripe webhook integration
status: done
blocked-by: [1]
needs-review: none
created: 2026-05-12
---

## Requirements

The billing schema exists but nothing connects it to Stripe. When a customer subscribes, upgrades, or payment fails, we need to update our database to reflect the current state. This plan wires Stripe webhooks to our subscription model.

**Acceptance criteria:**

- [x] Next.js API route at `/api/webhooks/stripe` handles incoming Stripe events
- [x] Webhook signature verification using `stripe.webhooks.constructEvent`
- [x] Handles events: `checkout.session.completed`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.payment_failed`
- [x] Each event handler updates the corresponding Subscription record via Prisma
- [x] Idempotent: processing the same event twice produces the same result
- [x] Returns 200 for handled events, 400 for signature failures, 200 for unrecognized events (Stripe best practice)
- [x] Unit tests for each event handler with mocked Stripe payloads

## Design

**Files expected to change:**

- `src/app/api/webhooks/stripe/route.ts`: NEW: webhook endpoint
- `src/lib/billing/webhook-handlers.ts`: NEW: per-event handler functions
- `src/lib/billing/stripe.ts`: NEW: Stripe client initialization
- `tests/billing/webhook-handlers.test.ts`: NEW: unit tests with mocked payloads

**Approach:**

Separate the route (signature verification, event dispatch) from the handlers (database updates). Each handler is a pure function that takes a Stripe event and a Prisma client, making them independently testable. The Stripe client is initialized once with the secret key from env.

**Out of scope:**

- Checkout session creation (handled by frontend in plan 005)
- Usage reporting to Stripe (plan 003)
- Invoice PDF generation (plan 004)

## Tasks

1. Create src/lib/billing/stripe.ts with Stripe client initialization
2. Create webhook handlers for each event type in src/lib/billing/webhook-handlers.ts
3. Create the API route with signature verification
4. Write unit tests with mocked Stripe event payloads
5. Add STRIPE_WEBHOOK_SECRET to .env.example

## Verification

- [cmd] npm test -- --grep webhook
- [assert] test -f src/app/api/webhooks/stripe/route.ts
- [assert] test -f tests/billing/webhook-handlers.test.ts
- [assert] grep 'constructEvent' src/app/api/webhooks/stripe/route.ts
- [assert] grep 'STRIPE_WEBHOOK_SECRET' .env.example
