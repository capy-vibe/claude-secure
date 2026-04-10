---
phase: quick
plan: 260410-fjy
subsystem: docs
tags: [readme, logging, documentation]

# Dependency graph
requires:
  - phase: 06-service-logging
    provides: JSONL logging implementation for hook, proxy, validator
provides:
  - User-facing logging documentation in README.md
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns: []

key-files:
  created: []
  modified:
    - README.md

key-decisions:
  - "Placed Logging section between Configuration and Architecture Details for logical flow"
  - "Verified existing update/upgrade docs are adequate -- no changes needed"

# Metrics
duration: 1min
completed: 2026-04-10
---

# Quick Task 260410-fjy: Update README with Logging Features Summary

**Added comprehensive Logging section documenting JSONL structured logging, CLI log flags, logs subcommand, file locations, and security note**

## Performance

- **Duration:** 1 min
- **Started:** 2026-04-10T09:13:45Z
- **Completed:** 2026-04-10T09:14:13Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- Added "## Logging" section to README.md between Configuration and Architecture Details
- Documented all CLI log flags: log:hook, log:anthropic, log:iptables, log:all
- Included JSONL format example with four standard fields (ts, svc, level, msg)
- Documented logs subcommand (tail all, per-service, clear)
- Noted log file locations at ~/.claude-secure/logs/
- Added security note explaining proxy never logs bodies (pre-redaction secret safety)
- Verified existing update/upgrade instructions are clear and adequate

## Task Commits

1. **Task 1: Add logging section and verify update instructions** - `c332c78` (docs)

## Files Modified
- `README.md` - Added 61-line Logging section with overview, enabling, format, viewing, location, and security subsections

## Decisions Made
- Placed Logging section between Configuration and Architecture Details -- logical reading order (configure secrets, then configure logging, then deep-dive architecture)
- Existing update/upgrade descriptions verified sufficient -- no modifications needed

## Deviations from Plan

None - plan executed exactly as written.

## Known Stubs

None.

## Self-Check: PASSED
