# Requirements: claude-secure

**Defined:** 2026-04-08
**Core Value:** No secret ever leaves the isolated environment uncontrolled — every outbound call is validated, every secret in LLM context is redacted, and Claude Code cannot bypass the security layers.

## v1 Requirements

### Docker Isolation

- [ ] **DOCK-01**: Claude container runs on an internal Docker network with no direct internet access
- [ ] **DOCK-02**: Only the proxy container has access to the external network (internet)
- [ ] **DOCK-03**: Docker Compose orchestrates all containers with correct network assignments and dependencies
- [ ] **DOCK-04**: DNS queries from the claude container are blocked or routed to a controlled resolver to prevent DNS exfiltration
- [ ] **DOCK-05**: Hook scripts, settings.json, and whitelist.json are root-owned and read-only (chmod 444/555) inside the claude container
- [ ] **DOCK-06**: Claude container drops all capabilities (`cap_drop: ALL`) and sets `no-new-privileges`

### Secret Redaction

- [ ] **SECR-01**: Proxy intercepts all Claude-to-Anthropic API traffic via ANTHROPIC_BASE_URL override
- [ ] **SECR-02**: Proxy replaces known secret values in outbound request bodies with configured placeholders
- [ ] **SECR-03**: Proxy restores placeholders to real secret values in Anthropic response bodies
- [ ] **SECR-04**: Proxy reads secret mappings fresh from whitelist config on each request (hot-reload, no restart needed)
- [ ] **SECR-05**: Proxy forwards authentication credentials (API key or OAuth token) correctly to Anthropic

### Call Validation

- [ ] **CALL-01**: PreToolUse hook intercepts all Bash, WebFetch, and WebSearch tool calls before execution
- [ ] **CALL-02**: Hook extracts target URLs/domains from tool call payloads (curl, wget commands, direct URL arguments)
- [ ] **CALL-03**: Hook blocks outbound payloads (POST/PUT/PATCH, request bodies, auth headers) to non-whitelisted domains
- [ ] **CALL-04**: Hook allows read-only GET requests to non-whitelisted domains without registration
- [ ] **CALL-05**: Hook generates a unique call-ID and registers it with the validator before allowing whitelisted calls
- [ ] **CALL-06**: Validator stores call-IDs in SQLite with domain, expiry timestamp, and single-use flag
- [ ] **CALL-07**: iptables rules on the claude container block all outbound traffic except to proxy and validator services

### Whitelist Configuration

- [ ] **WHIT-01**: Whitelist is a JSON file mapping secret placeholders to environment variable names and allowed domains
- [ ] **WHIT-02**: Whitelist supports a readonly_domains list for domains that allow GET but no secret injection
- [ ] **WHIT-03**: Whitelist file is root-owned and read-only, mounted into containers that need it

### Installation

- [ ] **INST-01**: Installer script checks for required dependencies (docker, docker compose, curl, jq, uuidgen)
- [ ] **INST-02**: Installer detects platform (native Linux vs WSL2) and handles differences
- [ ] **INST-03**: Installer prompts for authentication method (API key or OAuth token) with OAuth as primary
- [ ] **INST-04**: Installer configures workspace path and creates directory structure
- [ ] **INST-05**: Installer builds Docker images and sets correct file permissions
- [ ] **INST-06**: Installer creates `claude-secure` CLI shortcut for launching the environment

### Testing

- [ ] **TEST-01**: Integration test verifies that direct outbound connections from the claude container are blocked
- [ ] **TEST-02**: Integration test verifies that traffic through the proxy reaches Anthropic successfully
- [ ] **TEST-03**: Integration test verifies that known secrets are redacted from proxy outbound traffic
- [ ] **TEST-04**: Integration test verifies that calls without valid call-ID registration are blocked by iptables
- [ ] **TEST-05**: Integration test verifies that the PreToolUse hook blocks payloads to non-whitelisted domains

### Platform Support

- [ ] **PLAT-01**: All containers build and run correctly on native Linux (Ubuntu 22.04+)
- [ ] **PLAT-02**: All containers build and run correctly on WSL2 with Docker
- [ ] **PLAT-03**: iptables rules function correctly on both Linux and WSL2 (with nftables backend detection)

## v2 Requirements

### Streaming

- **STRM-01**: Proxy handles Anthropic SSE streaming responses with chunk-aware secret redaction
- **STRM-02**: Proxy handles streaming without buffering entire response in memory

### Enhanced Security

- **ESEC-01**: Hook scans file contents referenced via `@file` for known secret patterns before allowing tool calls
- **ESEC-02**: Proxy redacts base64-encoded and URL-encoded variants of secrets
- **ESEC-03**: Single-use time-limited call-IDs (10s expiry, anti-replay)

### Observability

- **OBSV-01**: Structured JSON audit logging for all tool call decisions (allow/deny/redact)
- **OBSV-02**: `claude-secure status` command showing container health and recent activity

## Out of Scope

| Feature | Reason |
|---------|--------|
| macOS support | Different Docker networking model (no iptables), doubles test matrix |
| NFQUEUE kernel-level packet inspection | WSL2 lacks reliable support; iptables + HTTP validator achieves same goal |
| Automatic secret detection/scanning | Heuristic detection produces false positives/negatives; explicit registration is more reliable |
| GUI/web dashboard | Expands attack surface; CLI-first with jq-queryable logs |
| Multi-tenant/multi-user | Solo developer tool; multi-user adds unnecessary complexity |
| Automatic updates | Auto-update in security tools is itself an attack vector |
| Browser-based secret entry | Expands attack surface; JSON config file is simpler and auditable |
| OAuth token auto-refresh | Acceptable to refresh manually for MVP; Phase 3 comfort feature |
| `claude-secure config` CLI | Editing JSON directly is fine for technical users; Phase 3 |
| Multi-project/workspace support | One project at a time for MVP; Phase 3 |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| | | |

**Coverage:**
- v1 requirements: 28 total
- Mapped to phases: 0
- Unmapped: 28

---
*Requirements defined: 2026-04-08*
*Last updated: 2026-04-08 after initial definition*
