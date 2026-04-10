---
phase: 06-service-logging
plan: 01
subsystem: infra
tags: [logging, jsonl, docker-compose, observability]

# Dependency graph
requires:
  - phase: 01-docker-infrastructure
    provides: docker-compose.yml service definitions, hook script, proxy, validator
provides:
  - Structured JSONL logging for all three services (hook, proxy, validator)
  - LOG_HOOK, LOG_ANTHROPIC, LOG_IPTABLES environment variable toggles
  - Shared /var/log/claude-secure volume mount across all containers
affects: [06-service-logging]

# Tech tracking
tech-stack:
  added: []
  patterns: [JSONL structured logging with env-var toggle, jq -nc for shell JSON, logging.Handler subclass for Python]

key-files:
  created: []
  modified:
    - docker-compose.yml
    - claude/hooks/pre-tool-use.sh
    - proxy/proxy.js
    - validator/validator.py

key-decisions:
  - "Used jq -nc with --arg for JSON escaping in hook (prevents injection via shell interpolation)"
  - "Proxy logs metadata only (method, path, status, duration) -- never bodies (pre-redaction security)"
  - "Validator uses Python logging.Handler subclass so existing logger calls auto-emit to JSONL"

patterns-established:
  - "JSONL logging pattern: each service writes to /var/log/claude-secure/{service}.jsonl with ts, svc, level, msg fields"
  - "Env-var gating: LOG_{SERVICE}=1 enables logging, default 0 (off)"
  - "Silent failure: all log writes wrapped in try/catch or || true to never crash the service"

requirements-completed: [LOG-01, LOG-02, LOG-03, LOG-04, LOG-05, LOG-06]

# Metrics
duration: 3min
completed: 2026-04-10
---

# Phase 06 Plan 01: Service Logging Summary

**Structured JSONL logging for hook, proxy, and validator services, toggled by LOG_* env vars via docker-compose volume mounts**

## Performance

- **Duration:** 3 min
- **Started:** 2026-04-10T07:03:37Z
- **Completed:** 2026-04-10T07:06:15Z
- **Tasks:** 3
- **Files modified:** 4

## Accomplishments
- All three services write structured JSON log entries to /var/log/claude-secure/*.jsonl when enabled
- Logging is fully opt-in via LOG_HOOK, LOG_ANTHROPIC, LOG_IPTABLES environment variables (default: off)
- Log entries consistently include ts, svc, level, and msg fields across all services (LOG-05 compliance)
- Proxy explicitly excludes request/response bodies from logs to prevent secret leakage

## Task Commits

Each task was committed atomically:

1. **Task 1: Add log env vars, volume mounts, and structured hook logging** - `c403055` (feat)
2. **Task 2: Add structured JSON logging to proxy service** - `d0972d0` (feat)
3. **Task 3: Add structured JSON logging to validator service** - `e58812d` (feat)

## Files Created/Modified
- `docker-compose.yml` - Added LOG_* env vars and /var/log/claude-secure volume mount to all three services
- `claude/hooks/pre-tool-use.sh` - Added log_json() function using jq -nc; calls in deny(), allow(), register_call_id()
- `proxy/proxy.js` - Added logJson() function with fs.appendFileSync; calls for block, forward, error, CONNECT events
- `validator/validator.py` - Added JsonFileHandler(logging.Handler) class; conditionally attached in __main__

## Decisions Made
- Used jq -nc with --arg for JSON escaping in hook script (prevents injection via shell string interpolation)
- Proxy logs only metadata (method, path, status, duration_ms, redaction count) -- never bodies (bodies contain secrets pre-redaction)
- Validator leverages Python logging.Handler subclass so all existing logger.info/warning/error calls automatically flow to JSONL file without modifying call sites

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Known Stubs
None - all logging paths are fully wired.

## Next Phase Readiness
- Logging infrastructure complete; ready for log rotation/aggregation plans if needed
- All three services can be debugged via `LOG_HOOK=1 LOG_ANTHROPIC=1 LOG_IPTABLES=1` flags

---
*Phase: 06-service-logging*
*Completed: 2026-04-10*
