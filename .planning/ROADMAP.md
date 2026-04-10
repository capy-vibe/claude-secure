# Roadmap: claude-secure

## Overview

Build a four-layer security wrapper for Claude Code in five phases, following the dependency chain: Docker network isolation first (foundation everything else relies on), then the call validator (most self-contained service), then the secret-redacting proxy (needs network + config), then the installer and platform support (wraps a working system), and finally integration tests that verify all security claims end-to-end. Each phase delivers a verifiable layer of the defense-in-depth architecture.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Docker Infrastructure** - Isolated container topology with dual networks, hardened claude container, and whitelist config
- [ ] **Phase 2: Call Validation** - Hook scripts intercept tool calls, validator service gates network access via call-IDs and iptables
- [x] **Phase 3: Secret Redaction** - Buffered proxy redacts secrets from Anthropic-bound traffic and restores placeholders in responses (completed 2026-04-08)
- [ ] **Phase 4: Installation & Platform** - Installer script, CLI shortcut, and verified Linux/WSL2 support
- [ ] **Phase 5: Integration Testing** - End-to-end tests proving all security claims hold under real conditions
- [ ] **Phase 6: Service Logging** - Per-service logging (hook, proxy, iptables) with unified host-side log file

## Phase Details

### Phase 1: Docker Infrastructure
**Goal**: Claude Code runs inside a network-isolated Docker environment where it cannot directly reach the internet and cannot modify its own security configuration
**Depends on**: Nothing (first phase)
**Requirements**: DOCK-01, DOCK-02, DOCK-03, DOCK-04, DOCK-05, DOCK-06, WHIT-01, WHIT-02, WHIT-03
**Success Criteria** (what must be TRUE):
  1. Running `curl https://api.anthropic.com` from inside the claude container fails (no direct internet)
  2. Running `nslookup google.com` from inside the claude container fails (DNS exfiltration blocked)
  3. The proxy container can reach external URLs while the claude container cannot
  4. Hook scripts and whitelist config inside the claude container are root-owned and cannot be modified by the claude user
  5. A valid whitelist.json exists mapping secret placeholders to env var names and allowed domains, with a readonly_domains section
**Plans:** 2 plans

Plans:
- [x] 01-01-PLAN.md -- Docker infrastructure: whitelist config, Dockerfiles, docker-compose.yml, stub services, build and verify topology
- [x] 01-02-PLAN.md -- Integration tests: test script verifying all 9 requirements, run and confirm all pass

### Phase 2: Call Validation
**Goal**: Every outbound tool call from Claude Code is intercepted, checked against the domain allowlist, and only allowed through the network if registered with a valid single-use call-ID
**Depends on**: Phase 1
**Requirements**: CALL-01, CALL-02, CALL-03, CALL-04, CALL-05, CALL-06, CALL-07
**Success Criteria** (what must be TRUE):
  1. A Bash tool call containing `curl -X POST` to a non-whitelisted domain is blocked by the hook before execution
  2. A Bash tool call containing a GET request to a non-whitelisted domain is allowed without call-ID registration
  3. A whitelisted outbound call succeeds only after the hook registers a call-ID with the validator
  4. A call-ID that has already been used cannot be reused (single-use enforcement)
  5. Network traffic from the claude container without a valid call-ID registration is dropped by iptables
**Plans:** 3 plans

Plans:
- [x] 02-01-PLAN.md -- Docker Compose shared namespace + full validator service (SQLite, iptables)
- [x] 02-02-PLAN.md -- PreToolUse hook implementation (domain extraction, whitelist, call-ID registration)
- [x] 02-03-PLAN.md -- Integration tests for all CALL requirements

### Phase 3: Secret Redaction
**Goal**: Secrets in Claude's LLM context are never sent to Anthropic in cleartext, and Claude can still use real secret values in authorized tool calls
**Depends on**: Phase 1
**Requirements**: SECR-01, SECR-02, SECR-03, SECR-04, SECR-05
**Success Criteria** (what must be TRUE):
  1. When Claude sends a request containing a known secret value, the proxy replaces it with the configured placeholder before forwarding to Anthropic
  2. When Anthropic's response contains a placeholder, the proxy restores it to the real secret value (scoped to auth/controlled contexts only)
  3. The proxy correctly forwards API key or OAuth token authentication to Anthropic
  4. Changing the whitelist.json file takes effect on the next request without restarting any container
**Plans:** 2/2 plans complete

Plans:
- [x] 03-01-PLAN.md -- Implement secret-redacting proxy and configure auth env vars in docker-compose
- [x] 03-02-PLAN.md -- Integration tests for all SECR requirements

### Phase 4: Installation & Platform
**Goal**: A developer can install claude-secure with a single script and launch it with a single command on Linux or WSL2
**Depends on**: Phase 1, Phase 2, Phase 3
**Requirements**: INST-01, INST-02, INST-03, INST-04, INST-05, INST-06, PLAT-01, PLAT-02, PLAT-03
**Success Criteria** (what must be TRUE):
  1. Running the installer on a fresh Ubuntu 22.04+ system with Docker installed results in a working claude-secure environment
  2. The installer detects missing dependencies and reports clear error messages before proceeding
  3. Running `claude-secure` from the terminal launches the full Docker environment and drops the user into Claude Code
  4. The same installer and runtime work correctly on WSL2 with Docker (including iptables/nftables detection)
**Plans:** 2 plans

Plans:
- [x] 04-01-PLAN.md -- Installer script (install.sh) and CLI wrapper (bin/claude-secure)
- [x] 04-02-PLAN.md -- Integration tests for all INST and PLAT requirements

### Phase 5: Integration Testing
**Goal**: Every security claim made by claude-secure is verified by automated tests that run in the actual Docker environment
**Depends on**: Phase 2, Phase 3, Phase 4
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04, TEST-05
**Success Criteria** (what must be TRUE):
  1. A test suite exists that can be run with a single command and reports pass/fail for each security claim
  2. Tests verify both the "block" path (unauthorized calls fail) and the "allow" path (authorized calls succeed)
  3. Tests verify that secret values appear in proxy-to-Anthropic traffic only as placeholders, never as cleartext
  4. Tests can run in CI (no interactive input required)
**Plans:** 2 plans

Plans:
- [ ] 05-01-PLAN.md -- TBD
- [ ] 05-02-PLAN.md -- TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Docker Infrastructure | 0/2 | Planning complete | - |
| 2. Call Validation | 0/3 | Planning complete | - |
| 3. Secret Redaction | 2/2 | Complete   | 2026-04-08 |
| 4. Installation & Platform | 0/2 | Planning complete | - |
| 5. Integration Testing | 0/TBD | Not started | - |
| 6. Service Logging | 0/3 | Planning complete | - |

### Phase 6: Service Logging

**Goal:** The `claude-secure` CLI supports `log:hook`, `log:anthropic`, and `log:iptables` flags that enable per-service structured JSON logging to a unified host-side log directory
**Requirements**: LOG-01, LOG-02, LOG-03, LOG-04, LOG-05, LOG-06, LOG-07
**Depends on:** Phase 4
**Success Criteria** (what must be TRUE):
  1. Running `claude-secure log:hook` enables hook script logging to `~/.claude-secure/logs/hook.jsonl`
  2. Running `claude-secure log:anthropic` enables proxy logging to `~/.claude-secure/logs/anthropic.jsonl`
  3. Running `claude-secure log:iptables` enables validator logging to `~/.claude-secure/logs/iptables.jsonl`
  4. Log entries are structured JSON with ts, svc, level, and msg fields
  5. No log files are created when logging flags are not passed
  6. `claude-secure logs` tails all log files in real-time
**Plans:** 3 plans

Plans:
- [x] 06-01-PLAN.md -- Service logging: add structured JSON logging to hook, proxy, and validator with docker-compose env vars and volume mounts
- [x] 06-02-PLAN.md -- CLI integration: log flag parsing, LOG_DIR export, logs subcommand, installer log directory
- [x] 06-03-PLAN.md -- Integration tests for all LOG requirements

### Phase 7: Env-file strategy and secret loading for claude-secure

**Goal:** Docker Compose env_file directive replaces hardcoded secret env var names in docker-compose.yml, making secret loading fully dynamic -- adding a new secret requires editing only .env and whitelist.json
**Requirements**: ENV-01, ENV-02, ENV-03, ENV-04, ENV-05
**Depends on:** Phase 6
**Success Criteria** (what must be TRUE):
  1. Secrets from ~/.claude-secure/.env are available in the proxy container via env_file
  2. Adding a new secret to .env + whitelist.json works without editing docker-compose.yml
  3. Claude container does NOT have secret env vars (only auth tokens)
  4. Proxy still redacts secrets correctly with env_file loading
  5. System works when no optional secrets are configured (only auth)
**Plans:** 2 plans

Plans:
- [x] 07-01-PLAN.md -- Dynamic secret loading: env_file on proxy, SECRETS_FILE export, installer guidance
- [x] 07-02-PLAN.md -- Integration tests for all ENV requirements

### Phase 8: Container tooling -- full dev environment for claude-secure

**Goal:** Developer workflow tooling: Makefile command surface, docker-compose.dev.yml with hot-reload, unified test runner, and ShellCheck linting for all bash scripts
**Requirements**: TOOL-01, TOOL-02, TOOL-03, TOOL-04
**Depends on:** Phase 7
**Plans:** 2 plans

Plans:
- [ ] 08-01-PLAN.md -- Makefile and docker-compose.dev.yml (dev command surface and hot-reload)
- [ ] 08-02-PLAN.md -- Unified test runner and ShellCheck linting
