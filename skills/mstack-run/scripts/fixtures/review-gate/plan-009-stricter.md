---
id: 009
title: Gmail per-account HTTP daemons
status: blocked
blocked-by: [006, 007, 008, 013, 015, 017]
goal: mcp-http-migration
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-09-18
# 2026-09-24: eng approval of 2026-09-18 withdrawn — spec amended by goal mcp-hardening-core-extraction
# (OAuth client via 0600 file, config injection from 017, path policy from 013). Re-review required.
reviews:
  - type=eng verdict=changes-requested date=2026-10-13 by=mstack-review
---

## Requirements

Fixture: the frontmatter of homelab-mcp-servers plan 009 on 2026-10-13, after
an independent re-review recorded the stricter verdict the hook refused to
commit. Body replaced by this stub.
