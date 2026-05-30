# Changelog

## [Unreleased]

### Added
- Per-org billing schema with Organization, Subscription, and UsageRecord models (plan 001)
- Stripe webhook integration handling subscription lifecycle and payment failures (plan 002)
- Usage metering service with batch reporting and partial failure handling (plan 003)
- Invoice PDF generation with branded templates using @react-pdf/renderer (plan 004)
- Billing dashboard at /settings/billing with usage charts, invoice history, and Stripe portal (plan 005)

### Changed
- Existing users migrated to a default "Personal" organization (plan 001)
- Added Suspense boundary for usage chart to prevent blocking page load (plan 005)

### Fixed
- Prisma composite key limitation worked around with transactional individual creates (plan 001, 003)
