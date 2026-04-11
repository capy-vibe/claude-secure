# claude-secure

## What This Is

An installable security wrapper for Claude Code that runs it in a fully network-isolated Docker environment. It prevents API keys and secrets from leaking to Anthropic or arbitrary external URLs through a four-layer architecture: Docker isolation, PreToolUse hook validation, an Anthropic proxy with secret redaction, and an iptables-based call validator with SQLite registration. Supports multiple independent instances, structured logging, and smart pre-push test selection. Built for solo developers who want to use Claude Code on projects with real API keys without risking secret exfiltration.

## Core Value

No secret ever leaves the isolated environment uncontrolled — every outbound call is validated, every secret in LLM context is redacted, and Claude Code cannot bypass the security layers.

## Requirements

### Validated

- Docker Compose setup with three containers (claude, proxy, validator) on isolated internal network — v1.0
- Whitelist configuration (JSON) mapping secrets to placeholder names, environment variables, and allowed domains — v1.0
- File permissions model: hooks and config are root-owned and read-only, workspace is user-writable — v1.0
- PreToolUse hook that intercepts Bash/WebFetch/WebSearch tool calls, checks domains against whitelist, blocks payloads to non-whitelisted domains — v1.0
- Hook generates unique call-ID and registers it with the validator before allowing whitelisted calls — v1.0
- SQLite-based call validator with HTTP registration endpoint and iptables integration for network-level enforcement — v1.0
- Call-IDs are single-use and time-limited (10-second expiry) — v1.0
- Anthropic proxy that intercepts all Claude-to-Anthropic traffic, redacts known secret values, and replaces them with placeholders — v1.0
- Proxy restores placeholders to real values in Anthropic responses so Claude can use them in tool calls — v1.0
- Installer script with dependency checking, auth setup (API key or OAuth token), workspace configuration, and CLI shortcut — v1.0
- OAuth token authentication as primary auth method — v1.0
- Support for Linux (native) and WSL2 — v1.0
- Integration tests that verify blocked/allowed call scenarios end-to-end in Docker — v1.0
- Per-service structured JSON logging (hook, proxy, iptables) with host-side log directory — v1.0
- Dynamic secret loading via Docker Compose env_file (adding secrets requires only .env + whitelist.json edits) — v1.0
- Full dev environment in Claude container (git, build-essential, Python, ripgrep, fd-find) — v1.0
- Multi-instance support: `--instance NAME` flag, auto-creation, DNS-safe validation, list/remove commands, instance-scoped config and logs — v1.0
- Pre-push hook with smart test selection, dedicated test instance, clean-state guarantees, and failure summary table — v1.0

### Active

(None — next milestone requirements TBD)

### Out of Scope

- Streaming SSE support in Anthropic proxy — buffered mode sufficient for MVP
- `@file` content scanning for secrets in hook — enhancement
- WSL2 NFQUEUE kernel-level packet inspection — using iptables + HTTP validator instead
- `claude-secure config` CLI tool — comfort feature
- Automatic OAuth token refresh — enhancement
- Audit log dashboard — enhancement
- macOS support — not in scope
- Secret detection in indirect file references Claude sends via `@file` to Anthropic — documented known gap, accepted risk

## Context

Shipped v1.0 with ~3,000 LOC across Bash (2,348), Python (399), and JavaScript (284).
Tech stack: Docker Compose, Node.js 22 stdlib proxy, Python 3.11 stdlib validator, iptables, Bash hooks.
11 phases, 21 plans, 48 requirements all verified complete.
52 integration tests across 9 test scripts with smart pre-push selection.

## Constraints

- **Platform**: Must work on Linux (native) and WSL2 — no macOS Docker Desktop support needed
- **Dependencies**: Docker, Docker Compose, curl, jq, uuidgen must be available on host
- **Security**: Hook scripts, settings, and whitelist must be root-owned and immutable by the Claude process
- **Architecture**: Proxy uses buffered request/response (no streaming)
- **Auth**: OAuth token (via `claude setup-token`) is primary; API key supported as fallback
- **No NFQUEUE**: Validator uses HTTP registration + iptables only (no kernel module dependency)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| iptables + HTTP validator instead of NFQUEUE | WSL2 lacks reliable NFQUEUE/kernel module support; iptables + SQLite registration achieves the same validation goal without kernel dependencies | Good — works on both native Linux and WSL2 |
| Buffered proxy (no streaming) for MVP | Simpler implementation; streaming SSE adds complexity; buffered mode works correctly if slower | Good — sufficient for all v1.0 use cases |
| English for all code and docs | International accessibility despite German spec origin | Good |
| OAuth token as primary auth | Target user (solo dev with Claude subscription) most likely uses OAuth | Good — API key fallback covers other cases |
| Single-use time-limited call-IDs (10s) | Prevents replay attacks; short window limits exposure if call-ID is somehow intercepted | Good — no issues reported |
| Shared network namespace (network_mode: service:claude) | Enables iptables enforcement on claude container from validator | Good — simpler than separate namespace bridging |
| Node.js 22 LTS over 20 | Node 20 reaches EOL April 2026 | Good — longer support window |
| Per-phase test scripts over standalone E2E suite | Phase 5 (Integration Testing) absorbed into per-phase test scripts | Good — 52 tests across 9 scripts, better locality |
| env_file for secret loading | Eliminates hardcoded secret names in docker-compose.yml | Good — adding secrets now requires only .env + whitelist.json |
| COMPOSE_PROJECT_NAME for multi-instance | Avoids container_name collisions, standard Docker Compose pattern | Good — clean isolation with standard tooling |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition:**
1. Requirements invalidated? -> Move to Out of Scope with reason
2. Requirements validated? -> Move to Validated with phase reference
3. New requirements emerged? -> Add to Active
4. Decisions to log? -> Add to Key Decisions
5. "What This Is" still accurate? -> Update if drifted

**After each milestone:**
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-11 after v1.0 milestone completion*
