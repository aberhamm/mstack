---
id: 4
title: Invoice generation with PDF export
status: done
blocked-by: [2, 3]
needs-review: none
created: 2026-05-12
---

## Requirements

Customers need to download invoices as PDFs. Stripe generates invoice objects but our app needs to render them in a branded PDF format with line-item breakdowns from our usage data. This plan creates the invoice rendering pipeline.

**Acceptance criteria:**

- [x] `InvoiceService` fetches invoice data from Stripe and enriches it with local usage breakdowns
- [x] PDF generation using `@react-pdf/renderer` with company branding (logo, colors, footer)
- [x] API route `GET /api/invoices/[id]/pdf` returns the PDF as a downloadable file
- [x] Invoice includes: org name, billing period, line items with quantities, subtotal, tax, total
- [x] Handles missing usage data gracefully (shows Stripe line items only)
- [x] Unit tests for invoice data assembly
- [x] Snapshot test for PDF output structure

## Design

**Files expected to change:**

- `src/lib/billing/invoice-service.ts`: NEW: fetch and enrich invoice data
- `src/lib/billing/invoice-pdf.tsx`: NEW: React PDF template
- `src/app/api/invoices/[id]/pdf/route.ts`: NEW: PDF download endpoint
- `tests/billing/invoice-service.test.ts`: NEW: unit tests
- `tests/billing/invoice-pdf.test.ts`: NEW: snapshot test

**Approach:**

Fetch the Stripe invoice, query local UsageRecords for the same billing period to get metric breakdowns, merge them into a unified invoice data structure. The PDF template is a React component using `@react-pdf/renderer` that renders server-side, streaming the buffer as a response with `Content-Type: application/pdf`.

Auth: the endpoint checks that the requesting user belongs to the org that owns the invoice. Returns 404 (not 403) for unauthorized access to avoid leaking invoice existence.

**Out of scope:**

- Email delivery of invoices
- Invoice history UI (plan 005 covers the dashboard link)
- Tax calculation (uses Stripe's built-in tax)

## Tasks

1. Create InvoiceService with fetch and enrichment logic
2. Create React PDF template with branding
3. Create API route with auth check and PDF streaming
4. Write unit tests for data assembly
5. Write snapshot test for PDF structure
6. Add @react-pdf/renderer to dependencies

## Verification

- [cmd] npm test -- --grep invoice
- [assert] test -f src/lib/billing/invoice-pdf.tsx
- [assert] test -f src/app/api/invoices/[id]/pdf/route.ts
- [assert] grep '@react-pdf/renderer' package.json
- [assert] grep 'application/pdf' src/app/api/invoices/[id]/pdf/route.ts
