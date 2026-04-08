# claude-secure

## What This Is

An installable security wrapper for Claude Code that runs it in a fully network-isolated Docker environment. It prevents API keys and secrets from leaking to Anthropic or arbitrary external URLs through a four-layer architecture: Docker isolation, PreToolUse hook validation, an Anthropic proxy with secret redaction, and an iptables-based call validator with SQLite registration. Built for solo developers who want to use Claude Code on projects with real API keys without risking secret exfiltration.

## Core Value

No secret ever leaves the isolated environment uncontrolled — every outbound call is validated, every secret in LLM context is redacted, and Claude Code cannot bypass the security layers.

## Requirements

### Validated

- [x] Docker Compose setup with three containers (claude, proxy, validator) on isolated internal network — *Validated in Phase 01: docker-infrastructure*
- [x] Whitelist configuration (JSON) mapping secrets to placeholder names, environment variables, and allowed domains — *Validated in Phase 01: docker-infrastructure*
- [x] File permissions model: hooks and config are root-owned and read-only, workspace is user-writable — *Validated in Phase 01: docker-infrastructure*
- [x] Anthropic proxy that intercepts all Claude-to-Anthropic traffic, redacts known secret values, and replaces them with placeholders — *Validated in Phase 03: secret-redaction*
- [x] Proxy restores placeholders to real values in Anthropic responses so Claude can use them in tool calls — *Validated in Phase 03: secret-redaction*

### Active


- [ ] PreToolUse hook that intercepts Bash/WebFetch/WebSearch tool calls, checks domains against whitelist, blocks payloads to non-whitelisted domains
- [ ] Hook generates unique call-ID and registers it with the validator before allowing whitelisted calls
- [ ] SQLite-based call validator with HTTP registration endpoint and iptables integration for network-level enforcement
- [ ] Call-IDs are single-use and time-limited (10-second expiry)

- [ ] Installer script with dependency checking, auth setup (API key or OAuth token), workspace configuration, and CLI shortcut

- [ ] OAuth token authentication as primary auth method
- [ ] Support for Linux (native) and WSL2
- [ ] Integration tests that verify blocked/allowed call scenarios end-to-end in Docker

### Out of Scope

- Streaming SSE support in Anthropic proxy — Phase 2, buffered mode sufficient for MVP
- `@file` content scanning for secrets in hook — Phase 2 enhancement
- WSL2 NFQUEUE kernel-level packet inspection — using iptables + HTTP validator instead
- `claude-secure config` CLI tool — Phase 3 comfort feature
- Automatic OAuth token refresh — Phase 3
- Multi-project/workspace support — Phase 3
- Audit log dashboard — Phase 3
- macOS support — not in scope for this milestone
- Secret detection in indirect file references Claude sends via `@file` to Anthropic — documented known gap, accepted risk

## Context

- Claude Code runs as a normal user process with full network access. If it reads `.env` files or configs, secrets enter the LLM context and get sent to Anthropic. Tool calls like `Bash(curl ...)` can exfiltrate secrets to arbitrary URLs.
- The four-layer architecture provides defense in depth: Docker network isolation prevents direct internet access, the hook validates and signs each outbound call, the proxy redacts secrets from LLM traffic, and the validator enforces that only hook-signed calls reach the network.
- The validator uses SQLite for call registration (HTTP endpoint) combined with iptables rules for network enforcement — no NFQUEUE/scapy dependency, which avoids WSL2 kernel compatibility issues.
- The proxy reads secrets fresh from config on each request, so whitelist changes don't require container restarts.
- All code, comments, and documentation will be in English.

## Constraints

- **Platform**: Must work on Linux (native) and WSL2 — no macOS Docker Desktop support needed
- **Dependencies**: Docker, Docker Compose, curl, jq, uuidgen must be available on host
- **Security**: Hook scripts, settings, and whitelist must be root-owned and immutable by the Claude process
- **Architecture**: Proxy uses buffered request/response (no streaming) for Phase 1
- **Auth**: OAuth token (via `claude setup-token`) is primary; API key supported as fallback
- **No NFQUEUE**: Validator uses HTTP registration + iptables only (no kernel module dependency)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| iptables + HTTP validator instead of NFQUEUE | WSL2 lacks reliable NFQUEUE/kernel module support; iptables + SQLite registration achieves the same validation goal without kernel dependencies | -- Pending |
| Buffered proxy (no streaming) for MVP | Simpler implementation; streaming SSE adds complexity; buffered mode works correctly if slower | -- Pending |
| English for all code and docs | International accessibility despite German spec origin | -- Pending |
| OAuth token as primary auth | Target user (solo dev with Claude subscription) most likely uses OAuth | -- Pending |
| Single-use time-limited call-IDs (10s) | Prevents replay attacks; short window limits exposure if call-ID is somehow intercepted | -- Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? -> Move to Out of Scope with reason
2. Requirements validated? -> Move to Validated with phase reference
3. New requirements emerged? -> Add to Active
4. Decisions to log? -> Add to Key Decisions
5. "What This Is" still accurate? -> Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-09 after Phase 03 completion — Secret redaction proxy validated*
