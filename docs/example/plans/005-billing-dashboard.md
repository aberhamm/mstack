---
id: 5
title: Billing dashboard UI
status: done
blocked-by: [1, 3, 4]
needs-review: none
created: 2026-05-12
---

## Requirements

Organization admins need a billing page showing their current plan, usage metrics, invoice history, and a way to manage their subscription. This plan creates the billing dashboard as a Next.js page with server components.

**Acceptance criteria:**

- [x] Page at `/settings/billing` shows current subscription plan and status
- [x] Usage section displays current-period metrics with a bar chart (API calls, storage)
- [x] Invoice history table with download links (using plan 004's PDF endpoint)
- [x] "Manage Subscription" button opens Stripe Customer Portal via `stripe.billingPortal.sessions.create`
- [x] Page is server-rendered with streaming for the usage chart (Suspense boundary)
- [x] Handles edge cases: no subscription yet, past-due status with warning banner, canceled with end date
- [x] Responsive layout, usable on mobile
- [x] Unit tests for data fetching functions
- [x] E2E test: navigate to billing page, verify plan name and at least one invoice row

## Design

**Files expected to change:**

- `src/app/settings/billing/page.tsx`: NEW: billing dashboard page
- `src/app/settings/billing/components/`: NEW: UsageChart, InvoiceTable, PlanCard, StatusBanner
- `src/app/api/billing/portal/route.ts`: NEW: Stripe portal session endpoint
- `src/lib/billing/billing-queries.ts`: NEW: server-side data fetching
- `tests/billing/billing-queries.test.ts`: NEW: unit tests
- `tests/e2e/billing.spec.ts`: NEW: Playwright E2E test

**Approach:**

Server component page that fetches subscription, usage, and invoice data in parallel using `Promise.all`. The usage chart is wrapped in a Suspense boundary since aggregation queries may be slow. Invoice table renders download links pointing to `/api/invoices/[id]/pdf`. The portal endpoint creates a one-time Stripe session and redirects.

Status banner logic: active = green, trialing = blue with days remaining, past_due = red with retry info, canceled = yellow with end date.

**Out of scope:**

- Plan selection / pricing page (separate feature)
- Usage alerts or notifications
- Admin-level billing across all orgs

## Tasks

1. Create billing-queries.ts with parallel data fetching
2. Create PlanCard, StatusBanner, UsageChart, InvoiceTable components
3. Create the billing page with Suspense boundaries
4. Create Stripe portal endpoint
5. Write unit tests for billing-queries
6. Write E2E test for the billing page flow

## Verification

- [cmd] npm test -- --grep billing
- [cmd] npx playwright test tests/e2e/billing.spec.ts
- [assert] test -f src/app/settings/billing/page.tsx
- [assert] test -f tests/e2e/billing.spec.ts
- [assert] grep 'billingPortal' src/app/api/billing/portal/route.ts
- [assert] grep 'Suspense' src/app/settings/billing/page.tsx
