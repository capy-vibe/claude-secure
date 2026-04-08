---
phase: 01-docker-infrastructure
plan: 01
subsystem: infra
tags: [docker, docker-compose, network-isolation, container-hardening, whitelist]

# Dependency graph
requires: []
provides:
  - "Docker Compose dual-network topology (claude-internal with internal:true, claude-external)"
  - "Three container stubs (claude, proxy, validator) with correct network placement"
  - "Whitelist config schema (secrets array + readonly_domains)"
  - "File permission hardening (root-owned hooks 555, settings 444, whitelist :ro mount)"
  - "DNS exfiltration prevention (dns: 127.0.0.1)"
  - "Capability dropping (cap_drop ALL, no-new-privileges)"
  - "Stub proxy (pass-through), stub validator (accept-all), stub hook (exit 0)"
affects: [02-hook-validator, 03-proxy-redaction, 04-installer-cli, 05-integration-tests]

# Tech tracking
tech-stack:
  added: [docker-compose, node:22-slim, python:3.11-slim, iptables]
  patterns: [dual-network-isolation, immutable-security-config, dns-exfiltration-blocking, non-root-container-user]

key-files:
  created:
    - docker-compose.yml
    - claude/Dockerfile
    - claude/settings.json
    - claude/hooks/pre-tool-use.sh
    - proxy/Dockerfile
    - proxy/proxy.js
    - validator/Dockerfile
    - validator/validator.py
    - config/whitelist.json
  modified:
    - CLAUDE.md

key-decisions:
  - "Used node:22-slim instead of node:20-slim (Node.js 20 EOL April 2026)"
  - "Added non-root 'claude' user in Dockerfile (Claude Code refuses --dangerously-skip-permissions as root)"
  - "Default command set to 'sleep infinity' for Phase 1 (Claude Code requires real auth + proxy to function)"
  - "Settings.json placed at /etc/claude-secure/ with symlink to ~/.claude/ to avoid volume shadowing"
  - "Whitelist.json bind-mounted with :ro flag (host ownership preserved, read-only enforced at mount level)"

patterns-established:
  - "Dual-network isolation: claude-internal (internal:true) + claude-external for proxy bridging"
  - "Immutable security files: baked into image via COPY + chmod, not bind-mounted for hooks/settings"
  - "Non-root execution: claude container runs as 'claude' user with cap_drop ALL"
  - "DNS blocking: dns: ['127.0.0.1'] prevents external resolution while Docker embedded DNS resolves container names"

requirements-completed: [DOCK-01, DOCK-02, DOCK-03, DOCK-04, DOCK-05, DOCK-06, WHIT-01, WHIT-02, WHIT-03]

# Metrics
duration: 4min
completed: 2026-04-08
---

# Phase 01 Plan 01: Docker Infrastructure Summary

**Dual-network Docker topology with 3 container stubs, DNS exfiltration blocking, capability dropping, and root-owned immutable security configuration**

## Performance

- **Duration:** 4 min
- **Started:** 2026-04-08T20:02:00Z
- **Completed:** 2026-04-08T20:06:16Z
- **Tasks:** 3
- **Files modified:** 10

## Accomplishments
- Docker Compose with dual-network topology (internal:true isolates claude + validator from internet)
- All 3 containers build and start successfully with correct network placement verified
- Security hardening: cap_drop ALL, no-new-privileges, DNS blocking, root-owned hooks/settings
- Whitelist configuration schema with secrets-to-domain mapping and readonly_domains

## Task Commits

Each task was committed atomically:

1. **Task 1: Create whitelist config and stub service files** - `18232d3` (feat)
2. **Task 2: Create Dockerfiles, docker-compose.yml, update CLAUDE.md** - `9caf023` (feat)
3. **Task 3: Build containers and verify topology** - `5c17671` (fix: non-root user + sleep command)

## Files Created/Modified
- `docker-compose.yml` - 3-service orchestration with dual networks, security hardening
- `claude/Dockerfile` - Node.js 22, claude-code CLI, non-root user, hook/settings hardening
- `claude/settings.json` - PreToolUse hook configuration for Bash|WebFetch|WebSearch
- `claude/hooks/pre-tool-use.sh` - Phase 1 stub (exit 0, allows all calls)
- `proxy/Dockerfile` - Node.js 22 slim image for proxy service
- `proxy/proxy.js` - Stub pass-through HTTP-to-HTTPS proxy
- `validator/Dockerfile` - Python 3.11 slim with iptables installed
- `validator/validator.py` - Stub HTTP server with /register, /health, /validate endpoints
- `config/whitelist.json` - Secret-to-domain mapping with readonly_domains
- `CLAUDE.md` - Updated Node.js version from 20 LTS to 22 LTS

## Decisions Made
- **Node.js 22 LTS:** Node.js 20 reached EOL April 2026; updated to 22 LTS (active until April 2027)
- **Non-root user:** Claude Code refuses `--dangerously-skip-permissions` when run as root; added `claude` user in Dockerfile
- **Sleep infinity command:** Claude Code cannot function in Phase 1 (no real auth, proxy is stub); default command set to `sleep infinity` for infrastructure verification
- **Settings.json placement:** Stored at `/etc/claude-secure/settings.json` with symlink to `~/.claude/settings.json` to prevent volume mount shadowing
- **No hooks bind-mount:** Hooks baked into image via COPY + chmod 555 (bind-mount would override root ownership)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Claude Code refuses to run as root**
- **Found during:** Task 3 (Build containers and verify topology)
- **Issue:** Claude Code exits with "cannot be used with root/sudo privileges for security reasons" when run as root inside the container
- **Fix:** Added non-root `claude` user in Dockerfile, updated settings.json symlink to `/home/claude/.claude/settings.json`, set USER claude
- **Files modified:** claude/Dockerfile
- **Verification:** Container starts and stays running
- **Committed in:** 5c17671

**2. [Rule 3 - Blocking] Claude Code cannot connect to API in isolated container**
- **Found during:** Task 3 (Build containers and verify topology)
- **Issue:** Claude Code tries to connect to Anthropic API on startup but the container is network-isolated (by design) and the proxy stub has no real upstream auth; container exits immediately
- **Fix:** Changed default command from `["claude", "--dangerously-skip-permissions"]` to `["sleep", "infinity"]` for Phase 1 infrastructure verification
- **Files modified:** docker-compose.yml
- **Verification:** All 3 containers start and stay running; all topology verification checks pass
- **Committed in:** 5c17671

---

**Total deviations:** 2 auto-fixed (1 bug, 1 blocking)
**Impact on plan:** Both fixes necessary for infrastructure verification to succeed. The actual Claude Code command will be configured in the installer (Phase 4) when real auth is available.

## Issues Encountered
- Whitelist.json bind-mount shows host UID ownership (node:644) instead of root:444 inside container. This is inherent to Docker bind mounts. The `:ro` flag enforces read-only at the mount level, and `cap_drop: ALL` prevents DAC_OVERRIDE. Security requirement is met.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All containers running with correct network topology
- Stub services ready to be replaced with real implementations
- Phase 2 (hook + validator) can build on hook skeleton and validator stub
- Phase 3 (proxy + redaction) can build on proxy stub
- Containers left running for Plan 02 integration tests

---
*Phase: 01-docker-infrastructure*
*Completed: 2026-04-08*
