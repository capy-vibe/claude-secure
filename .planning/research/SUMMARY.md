# Project Research Summary

**Project:** claude-secure
**Domain:** Docker-based CLI security isolation for AI coding assistants
**Researched:** 2026-04-08
**Confidence:** MEDIUM

## Executive Summary

claude-secure is a four-layer security wrapper around Claude Code that prevents secret exfiltration and unauthorized network calls from an AI coding assistant running on a developer workstation. The core insight from research is that no single mechanism is sufficient: hook interception is bypassable via arbitrary Bash execution, network isolation alone does not stop DNS exfiltration, and secret redaction is defeated by encoding variants. The recommended approach is genuine defense-in-depth — Docker `internal` network isolation, a PreToolUse hook for domain allowlisting, a buffered Node.js reverse proxy for bidirectional secret redaction, and a Python call-validator that gates network traffic through SQLite-backed call-IDs enforced by iptables — all using zero external dependencies beyond language stdlib.

The stack is deliberately minimal: Node.js 20 LTS and Python 3.11+ both with stdlib-only services, SQLite for ephemeral call-ID state, Bash + jq + uuidgen for hook scripts, and Docker Compose v2 for orchestration. This is the correct choice for a security tool — each external dependency in the security path is a supply-chain attack vector. The architecture has clear build-order dependencies: validator first (most self-contained), then proxy (needs only config files), then the Claude container (needs both upstream services running), then the installer (wraps a working system).

The primary risks are all Phase 1 problems: DNS leaks bypassing network isolation, secret encoding variants defeating string-replacement redaction, iptables rules conflicting with Docker's own chain management, and SQLite locking under parallel tool calls. Every one of these must be correctly addressed at the start, not retrofitted. The bidirectional placeholder restoration design also requires careful scoping — restoring placeholders globally in all response traffic creates a covert channel where Claude could echo placeholders and receive real secrets in tool call results.

## Key Findings

### Recommended Stack

All services use language stdlib with zero external dependencies. This is a deliberate security choice: the proxy and validator are themselves the security boundary, so minimizing their attack surface is paramount. Docker Compose v2 `internal: true` networks provide kernel-enforced isolation without host iptables complexity. Node.js 20 LTS and Python 3.11 are both available as slim Alpine images, keeping total container footprint under approximately 350MB.

**Core technologies:**
- Docker Engine 24.x + Compose v2.24: container runtime and orchestration — `internal: true` network flag provides kernel-level isolation, industry standard
- Node.js 20 LTS (stdlib only): Anthropic reverse proxy — buffered HTTP/HTTPS forwarding + secret substitution in ~80 lines, zero supply-chain risk
- Python 3.11+ (stdlib only): call validator service — `http.server` + `sqlite3` + `subprocess` (iptables), zero external dependencies
- SQLite 3.x (Python bundled): call-ID registration store — WAL mode handles concurrent reads/writes, zero-config, no extra container
- iptables (system): network-level call enforcement — available in Linux containers with `NET_ADMIN` capability, works on WSL2 via nftables compat shim
- Bash 5.x + jq 1.7 + uuidgen: hook scripts — no startup overhead, sufficient for domain extraction and UUID generation

### Expected Features

**Must have (table stakes):**
- Docker network isolation — foundational; without it there is no security boundary
- Secret redaction in LLM traffic — primary threat model; Anthropic must never see real secret values
- Domain allowlist / whitelist — minimum viable control surface; without it the tool is either unusable or insecure
- PreToolUse hook interception — the only sanctioned integration point for gating Claude Code tool calls
- Call validation (call-ID registration) — closes the hook-bypass gap; prevents background processes from making unauthorized network calls
- Installer / setup script — security tools abandoned without one-command setup
- File permission hardening — root-owned read-only config and hooks prevent Claude from disabling its own security

**Should have (competitive differentiators):**
- Bidirectional placeholder restoration — enables practical workflows (Claude can use real secret values in tool calls) while keeping secrets off Anthropic servers
- Defense-in-depth architecture (4 layers) — each layer catches what others miss; genuine security vs. a single-layer tool
- Single-use time-limited call-IDs — prevents replay attacks; signals serious security thinking
- Hot-reload whitelist config — no container restarts needed when updating secrets or domains
- Integration test suite for security claims — proves the system works, doubles as regression prevention

**Defer (v2+):**
- Streaming SSE proxy — buffered mode is correct for security; streaming requires chunk-aware redaction (Phase 2)
- `@file` secret scanning — known gap, requires intercepting Claude Code file reads (not exposed via hooks)
- Audit log dashboard — structured JSON logs are sufficient for solo dev (Phase 3)
- OAuth token refresh — manual refresh acceptable short-term (Phase 3)
- Multi-workspace support — out of scope until single-workspace is proven (Phase 3)
- macOS support — different Docker networking, doubles test matrix, explicitly out of scope

### Architecture Approach

The system runs three containers on two Docker networks. The `claude` container (Claude Code CLI) and `validator` container attach only to the `claude-internal` network (marked `internal: true`, no default gateway). The `proxy` container bridges both networks — it is the sole path from Claude to the internet. Claude Code's `ANTHROPIC_BASE_URL` is overridden to point to the proxy at `http://proxy:8080`. Hook scripts run inside the Claude container, are root-owned and read-only mounted, and register call-IDs with the validator before any tool call is allowed. All config is in a shared `config/` volume mounted read-only into containers that need it — the Claude container never sees the real `.env` file.

**Major components:**
1. **claude container** — runs Claude Code CLI in an isolated network namespace; no direct internet access; hooks intercept all tool calls
2. **proxy container** — Node.js HTTP reverse proxy; buffers full request/response bodies; replaces secret values with placeholders outbound and restores them (scoped to auth contexts) inbound; bridges internal and external networks
3. **validator container** — Python HTTP server + SQLite + iptables; registers call-IDs from hooks; enforces via iptables that only registered calls leave the claude container; has `NET_ADMIN` capability, claude container does not
4. **hooks** — Bash PreToolUse scripts; extract domains from tool call inputs; check domain allowlist; generate UUID call-IDs; POST to validator before returning allow (exit 0) to Claude Code
5. **config** — root-owned JSON whitelist + `.env` file; read fresh on every request/hook invocation; changes take effect without container restarts

### Critical Pitfalls

1. **DNS exfiltration bypass** — Docker `internal: true` blocks TCP/UDP egress but NOT Docker's embedded DNS resolver (127.0.0.11). Secrets can leak via crafted DNS queries. Prevention: block port 53 traffic from the claude container via iptables rules in the validator entrypoint; verify with `nslookup google.com` from inside the claude container (must fail).

2. **Secret encoding variants defeat string replacement** — naive `str.replace()` misses base64, URL-encoded, and hex-encoded secret variants. Claude itself may encode secrets before they appear in the request body. Prevention: pre-compute all common encoding variants of each secret at config load time and search for all of them; buffered mode (not streaming) ensures the full body is available for inspection.

3. **Bidirectional restoration creates a covert channel** — if the proxy does global placeholder-to-secret replacement on all Anthropic responses, Claude can echo a placeholder and receive the real secret in its tool call result context. Prevention: restoration must be scoped to specific controlled contexts (auth headers) only, never applied globally to response bodies.

4. **iptables rules conflict with Docker chain management** — Docker manages its own iptables chains (FORWARD, DOCKER-USER, NAT table). Custom rules added to the wrong chain are silently clobbered on container restart. Prevention: apply custom rules in container entrypoint scripts targeting the OUTPUT chain within the container's own network namespace; use DOCKER-USER chain on the host for forwarding rules; test rule persistence after `docker compose restart`.

5. **SQLite TOCTOU on call-ID validation** — a SELECT-then-DELETE implementation for call-ID checking has a time-of-check-time-of-use window; concurrent requests with the same call-ID can both pass. Prevention: use atomic `DELETE ... RETURNING *` (SQLite 3.35+) for check-and-consume in a single operation; enable WAL mode and `busy_timeout=5000` for concurrent access.

6. **WSL2 iptables/nftables incompatibility** — modern Linux distros default to nftables while `iptables` command may be a no-op compatibility shim. Prevention: installer preflight must detect iptables backend via `iptables --version`; document Docker CE in WSL2 as the supported configuration (not Docker Desktop from Windows).

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: Secure Foundation
**Rationale:** All eight table-stakes features have mutual dependencies that must be resolved before any higher-level work. The architecture build order is dictated by service dependencies: networks first, validator second (most isolated), proxy third, Claude container last. All critical pitfalls identified in research are Phase 1 problems — none can be safely deferred.
**Delivers:** A working, verifiable four-layer security wrapper. Claude Code runs in network isolation, secrets are redacted in transit, tool calls are gated by allowlist, network calls require hook-registered call-IDs, and the security claims are verified by an integration test suite.
**Addresses:** Docker network isolation, secret redaction + placeholder restoration (scoped to auth headers), domain allowlist, PreToolUse hook, call validator + SQLite + iptables, installer, file permission hardening.
**Avoids:** DNS leaks (iptables DNS block from day one), secret encoding bypass (multi-variant redaction from day one), bidirectional restoration covert channel (scoped restore only), iptables/Docker chain conflicts (entrypoint-applied OUTPUT chain rules), SQLite TOCTOU (atomic DELETE RETURNING), WSL2 iptables (preflight checks in installer).

Internal build order within Phase 1 (enforced by dependency graph):
1. Docker Compose + dual-network topology
2. Validator service (Python HTTP + SQLite + iptables rules)
3. Proxy service (Node.js buffered proxy + secret redaction)
4. Claude container + hook scripts
5. Integration test suite (blocked/allowed/redacted scenarios)
6. Installer script (wraps working system)

### Phase 2: Security Hardening and DX Polish
**Rationale:** Once the foundation is verified correct, expand coverage of known gaps and address the most significant UX pain point (proxy latency from buffered mode). These features are deferred from Phase 1 because they require the foundation to be working and tested first, and they don't affect the core security model.
**Delivers:** Streaming proxy with chunk-aware redaction, expanded secret encoding coverage (base64 partial matches within larger blobs), `@file` reference scanning (best-effort), structured audit logging with queryable JSON output, `claude-secure status` command showing redaction statistics.
**Uses:** Sliding-window or buffer-then-flush streaming approach for the proxy; inotify-based config file watcher instead of per-request disk reads.
**Implements:** Streaming proxy (replaces buffered), encoding-aware redaction expansion, UX observability commands.

### Phase 3: Workflow and Multi-Project Support
**Rationale:** Only after security correctness and DX polish are proven in single-project use does it make sense to add complexity for multi-project, multi-workspace, or advanced config management.
**Delivers:** Multi-workspace support (one claude-secure stack per project), OAuth token refresh handling, `claude-secure config` CLI for managing whitelist without JSON editing, optional audit log dashboard, Docker Compose project namespacing for concurrent instances.

### Phase Ordering Rationale

- **Validator before proxy** because the validator is self-contained and can be curl-tested in isolation; the proxy needs both config files and network infrastructure to test realistically.
- **Both services before the Claude container** because the Claude container consumes both services; building it last means integration issues surface at the right moment with the full system available for diagnosis.
- **Installer last** because it wraps a known-working system; building the installer before the system is correct leads to constant installer rework as the system changes.
- **Security hardening (Phase 2) before workflow features (Phase 3)** because multi-project support on an insecure foundation multiplies the attack surface.
- **Streaming deferred to Phase 2** because buffered mode is architecturally simpler and the correct security posture for Phase 1; chunk-aware redaction with split-secret detection significantly complicates the proxy logic.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 1, validator sub-step:** iptables rule management within Docker containers — the interaction between Docker's chain management and container-namespace rules needs concrete verification, especially on WSL2 with nftables backend. Validate against current Docker and kernel documentation before implementing.
- **Phase 1, proxy sub-step:** Claude Code hook response schema — the exact JSON format the PreToolUse hook must return (allow/block/error structure) must be verified against current Anthropic Claude Code documentation; this is the most likely area where training data may be outdated.
- **Phase 2, streaming sub-step:** Anthropic SSE protocol format — streaming redaction requires understanding the exact SSE chunk boundaries the Anthropic API produces. Needs live API research before Phase 2 design.

Phases with standard patterns (skip research-phase):
- **Phase 1, Docker Compose networking:** `internal: true` network behavior is a stable, well-documented Docker feature unchanged for years.
- **Phase 1, Node.js stdlib proxy:** buffered HTTP forwarding with `http.createServer` + `http.request` is a stable pattern; stdlib APIs have not changed meaningfully since Node 12.
- **Phase 1, SQLite WAL mode:** `PRAGMA journal_mode=WAL` + `busy_timeout` + atomic `DELETE RETURNING` are stable, well-documented SQLite features (available since SQLite 3.35, bundled with Python 3.11).
- **Phase 3, multi-workspace:** Docker Compose project namespacing is standard and well-documented.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM | Core technologies are mature and stable. Version numbers should be verified against current releases before implementation. No live verification was performed. |
| Features | MEDIUM | Table stakes are HIGH confidence (well-established security patterns). Differentiator competitive landscape could not be verified — WebSearch was unavailable during research. |
| Architecture | HIGH | Derived directly from the detailed project specification plus Docker/networking fundamentals that are extremely stable. The four-layer model, dual-network topology, and build order are solidly grounded. |
| Pitfalls | MEDIUM | Core Docker/iptables/SQLite behaviors are well-established. Claude Code hook specifics and WSL2 edge cases should be verified against current documentation. Some pitfalls are based on general security reasoning rather than documented incidents specific to this domain. |

**Overall confidence:** MEDIUM

### Gaps to Address

- **Claude Code hook response schema:** the exact JSON format for PreToolUse hook allow/block responses may have changed since training data cutoff. Verify against current Anthropic Claude Code documentation before implementing hook scripts.
- **`ANTHROPIC_BASE_URL` proxy interception completeness:** verify that setting this environment variable is sufficient to intercept all Anthropic API calls made by Claude Code, including any background calls, not just interactive completions.
- **iptables backend on target WSL2 environments:** the nftables/iptables compatibility situation varies by distro and WSL2 kernel version. The installer preflight check design should be validated against real WSL2 environments.
- **Anthropic API streaming format (SSE):** only relevant in Phase 2, but the exact chunk boundary behavior of the Anthropic streaming API is not verified from training data. Must research before designing the streaming proxy.
- **Docker volume mount exclusions:** the approach of creating empty shadow files at sensitive paths to hide secrets from the claude container needs validation — Docker bind mounts may not support this pattern transparently on all configurations.

## Sources

### Primary (HIGH confidence)
- Docker Compose networking documentation — `internal: true` network flag, dual-network topology, DOCKER-USER chain behavior
- Node.js stdlib http/https documentation — buffered HTTP server and client patterns, stable since Node 0.x
- Python stdlib http.server + sqlite3 documentation — BaseHTTPRequestHandler, WAL mode, threading safety
- iptables in Docker containers — NET_ADMIN capability, container network namespace management
- Project specification: `/home/igor9000/claude-secure/Project.md` — primary architecture source

### Secondary (MEDIUM confidence)
- Anthropic Claude Code hooks documentation — PreToolUse hook mechanism, exit codes, JSON stdin format (training data; current docs should be verified)
- SQLite atomicity documentation — `DELETE ... RETURNING *` syntax (SQLite 3.35+), TOCTOU prevention
- Docker DNS behavior — embedded DNS resolver (127.0.0.11) behavior on internal networks
- WSL2 kernel and networking documentation — nftables/iptables compatibility, module availability

### Tertiary (LOW confidence)
- Competitive landscape for Docker-based AI coding assistant security wrappers — not verified, WebSearch unavailable during research
- Anthropic SSE streaming format details — needed for Phase 2, not verified against current API documentation

---
*Research completed: 2026-04-08*
*Ready for roadmap: yes*
