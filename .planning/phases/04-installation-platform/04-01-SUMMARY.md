---
phase: 04-installation-platform
plan: 01
subsystem: infra
tags: [bash, installer, cli, docker-compose, wsl2]

# Dependency graph
requires:
  - phase: 01-docker-infrastructure
    provides: docker-compose.yml service topology, Dockerfiles, whitelist.json
  - phase: 02-call-validation
    provides: validator container with iptables enforcement
  - phase: 03-secret-redaction
    provides: proxy container with secret redaction and auth forwarding
provides:
  - install.sh installer script with dependency checks, auth setup, platform detection
  - bin/claude-secure CLI wrapper with launch/stop/status/update subcommands
  - ~/.claude-secure/ config directory structure convention
affects: [04-02-testing]

# Tech tracking
tech-stack:
  added: []
  patterns: [bash-installer-main-pattern, cli-wrapper-compose-file, source-guard-testability]

key-files:
  created: [install.sh, bin/claude-secure]
  modified: []

key-decisions:
  - "Source guard (BASH_SOURCE check) in install.sh enables test script to source individual functions"
  - "Whitelist symlink from app dir to config dir so docker-compose relative mounts read user's copy"
  - "set -a / set +a in CLI wrapper auto-exports .env vars for docker compose consumption"

patterns-established:
  - "Installer main() with source guard: wrap main invocation in BASH_SOURCE check for testability"
  - "CLI wrapper COMPOSE_FILE export: enables directory-independent docker compose commands"
  - "Config split: .env (chmod 600) for secrets, config.sh for non-sensitive settings"

requirements-completed: [INST-01, INST-02, INST-03, INST-04, INST-05, INST-06, PLAT-01, PLAT-02, PLAT-03]

# Metrics
duration: 2min
completed: 2026-04-09
---

# Phase 04 Plan 01: Installation & CLI Summary

**Bash installer with dependency preflight, WSL2/Docker Desktop detection, OAuth/API key auth, and CLI wrapper with four subcommands**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-08T23:35:10Z
- **Completed:** 2026-04-08T23:37:21Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Created install.sh with 7 core functions covering dependency checks, WSL2 detection, Docker Desktop warning, auth credential collection, workspace setup, image building, and CLI installation
- Created bin/claude-secure CLI wrapper with launch/stop/status/update subcommands that works from any directory via COMPOSE_FILE export
- Both scripts use strict mode (set -euo pipefail) and pass bash -n syntax validation

## Task Commits

Each task was committed atomically:

1. **Task 1: Create installer script (install.sh)** - `5d8e039` (feat)
2. **Task 2: Create CLI wrapper script (bin/claude-secure)** - `a6f3d50` (feat)

## Files Created/Modified
- `install.sh` - Main installer: dependency checks, platform detection, auth setup, workspace config, image building, CLI installation with source guard for testability
- `bin/claude-secure` - CLI wrapper: sources config.sh and .env, exports COMPOSE_FILE and WORKSPACE_PATH, dispatches stop/status/update/default subcommands

## Decisions Made
- Source guard pattern (BASH_SOURCE[0] == $0) added to install.sh bottom to allow test scripts to source individual functions without triggering main()
- Whitelist symlink strategy: copy default whitelist.json to ~/.claude-secure/ for user editing, symlink from app/config/whitelist.json back to it so docker-compose relative mounts work unchanged
- CLI wrapper uses set -a / set +a to auto-export all .env variables rather than explicit export statements, ensuring any secret env vars added to .env are automatically available to docker compose

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- install.sh and bin/claude-secure ready for integration testing in Plan 04-02
- Source guard enables test script to source install.sh functions individually
- Both scripts syntactically valid and cover all INST/PLAT requirements

---
*Phase: 04-installation-platform*
*Completed: 2026-04-09*
