# Feature Landscape

**Domain:** Docker-based CLI security isolation for AI coding assistants
**Researched:** 2026-04-08
**Confidence:** MEDIUM (based on domain knowledge; WebSearch unavailable for verification)

## Table Stakes

Features users expect. Missing = product feels incomplete or untrustworthy.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Docker network isolation | Without it, there is no security boundary -- the entire premise fails. Users choosing a security wrapper expect hard isolation, not software-only guardrails. | Medium | Docker Compose with `internal: true` networks. Well-understood pattern. Main complexity is bridging the proxy correctly. |
| Secret redaction in LLM traffic | The primary threat model: secrets in `.env` files enter Claude's context and get sent to Anthropic. If the proxy does not strip them, users have zero protection against the most common leak vector. | High | Bidirectional: redact outbound, restore inbound. Must handle partial matches, encoding variants (base64, URL-encoded), and multi-line values. Phase 1 can do exact-match only. |
| Domain allowlist / whitelist | Users need to control which external services Claude can reach. Without allowlists, the tool either blocks everything (unusable) or allows everything (insecure). A configurable allowlist is the minimum viable control surface. | Low | JSON config file mapping allowed domains. Simple to implement, critical for usability. |
| PreToolUse hook interception | Claude Code's hook system is the only sanctioned integration point. Without hooking `Bash`, `WebFetch`, and `WebSearch` tool calls, there is no way to inspect and gate outbound requests before they execute. | Medium | Must parse tool call payloads, extract URLs/domains from bash commands (curl, wget, etc.), and make allow/deny decisions. Regex-based extraction is fragile but sufficient for MVP. |
| Installer / setup script | Security tools that require manual multi-step setup get abandoned. Users expect `curl ... \| bash` or a single script that handles Docker check, container build, config generation, and Claude Code hook registration. | Medium | Must detect platform (Linux vs WSL2), check dependencies, set file permissions, and configure auth. The "last mile" that determines adoption. |
| Call validation (call-ID registration) | Without validating that each outbound network call was authorized by the hook, a compromised or clever prompt could bypass the hook layer entirely (e.g., spawning a background process). The validator closes this gap. | High | HTTP registration endpoint + iptables rules. SQLite for call-ID storage. Single-use + time-limited tokens. This is the novel security layer. |
| File permission hardening | If Claude (running as user) can modify the hook scripts, whitelist, or proxy config, it can disable its own security. Root-owned, read-only config is the baseline expectation for any security boundary. | Low | `chown root:root` + `chmod 444` on config/hooks. Simple but critical. Easy to forget during development. |
| Platform support: Linux native + WSL2 | The target user (solo dev) commonly uses either native Linux or WSL2. Not supporting WSL2 eliminates a large portion of the target audience. | Medium | WSL2 has Docker Desktop or dockerd-in-WSL. iptables works in WSL2 but NFQUEUE does not -- the project already accounts for this. Test on both. |

## Differentiators

Features that set the product apart from generic Docker isolation or manual security practices. Not expected, but valued.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Bidirectional secret placeholder system | Most redaction tools strip secrets one-way. Restoring placeholders in Anthropic responses so Claude can use real values in tool calls (e.g., `curl -H "Authorization: Bearer $API_KEY"`) is unique and enables practical workflows that pure redaction breaks. | High | Must maintain a per-request mapping of placeholder-to-secret. Handle edge cases: partial matches in code blocks, secrets that appear in non-sensitive contexts. |
| Defense-in-depth architecture (4 layers) | Competitors use 1-2 layers. Having Docker isolation + hook validation + proxy redaction + network-level call validation provides genuine defense-in-depth. Each layer catches what others miss. Marketing gold and actual security. | High | Complexity is in the integration, not individual layers. Each layer must fail-closed: if the validator is down, all calls are blocked. |
| Single-use time-limited call-IDs | Prevents replay attacks. Even if an attacker observes a valid call-ID, it expires in 10 seconds and cannot be reused. This is uncommon in developer tools and signals serious security thinking. | Medium | SQLite with TTL-based cleanup. Must handle clock skew in containers (use monotonic time or container-synced clocks). |
| OAuth token as primary auth | Most Docker wrappers assume API key auth. Supporting OAuth (via `claude setup-token`) matches how subscription Claude Code users actually authenticate, reducing friction. | Medium | Must intercept and forward OAuth tokens correctly through the proxy. Token refresh is Phase 3 but basic flow must work. |
| Hot-reload whitelist config | Proxy reads secrets fresh from config on each request. No container restart needed when adding/removing secrets or domains. This is a significant DX advantage for iterative development. | Low | Already designed into the architecture. Just avoid caching config in memory beyond a single request cycle. |
| Structured audit logging | Recording every tool call, allow/deny decision, redaction event, and call-ID lifecycle creates a verifiable audit trail. Useful for security review, debugging, and understanding what Claude actually did. | Medium | JSON-structured logs to stdout/file. Phase 1: basic logging. Phase 3: dashboard/query tool. |
| Integration test suite for security claims | A test suite that actually demonstrates blocked vs allowed calls in Docker gives users confidence the security works. Most security tools lack this -- users must trust the docs. | Medium | Docker-based tests that attempt exfiltration, verify redaction, test expired call-IDs. These double as regression tests. |

## Anti-Features

Features to explicitly NOT build. These would add complexity, expand attack surface, or mislead users about security guarantees.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Streaming SSE proxy support (Phase 1) | Streaming requires fundamentally different redaction logic -- you cannot redact a secret that arrives across multiple SSE chunks. Buffered mode is correct for security; streaming is a performance optimization that weakens the security model. | Use buffered request/response in Phase 1. Document the latency tradeoff. Streaming in Phase 2 only after chunk-aware redaction is designed. |
| Automatic secret detection / scanning | Heuristic secret detection (regex for API key patterns, entropy analysis) produces false positives and false negatives. Users will either over-trust it or be annoyed by it. Explicit secret registration is more honest and reliable. | Require users to explicitly register secrets in the whitelist config. Clear ownership of what is protected. |
| macOS support | Docker Desktop on macOS has different networking (no iptables, different bridge model). Supporting it doubles the test matrix and requires alternative network enforcement. The target user is Linux/WSL2. | Document as out of scope. If demand exists, add as a separate milestone with its own architecture. |
| GUI / web dashboard (Phase 1) | A dashboard adds a web server to the security boundary, expanding attack surface. It also implies ongoing monitoring, which is not the use case (solo dev, ephemeral sessions). | CLI-first. Structured logs that can be queried with `jq`. Dashboard in Phase 3 if validated. |
| Multi-tenant / multi-user support | This is a solo developer tool. Multi-user adds auth, RBAC, session isolation, and turns a simple wrapper into a platform. | Single-user. One workspace, one set of secrets, one Claude instance. |
| NFQUEUE / kernel module packet inspection | WSL2 does not reliably support NFQUEUE. Requiring kernel modules makes installation fragile and platform-dependent. | iptables + HTTP validator achieves the same goal without kernel dependencies. Already decided in PROJECT.md. |
| Secret detection in `@file` references | Claude can reference files via `@file` syntax. Scanning those for secrets before they reach Anthropic requires intercepting Claude Code's file reading, which is not exposed via hooks. | Document as known gap and accepted risk. Advise users not to `@file` sensitive configs. |
| Automatic updates / self-updating | Auto-update mechanisms in security tools are themselves attack vectors. A compromised update channel could disable all protections. | Manual updates via git pull + rebuild. Version pinning. Users control when they update. |
| Browser-based secret entry UI | Adding a web interface for entering secrets expands the attack surface and adds a dependency. | Secrets go in a JSON config file edited with any text editor. Simple, auditable, no extra attack surface. |

## Feature Dependencies

```
Docker Network Isolation
  --> Anthropic Proxy (requires isolated network to force traffic through proxy)
    --> Secret Redaction (runs inside proxy)
    --> Placeholder Restoration (runs inside proxy)
  --> Call Validator (requires isolated network to enforce iptables rules)
    --> SQLite Call-ID Store (validator dependency)
    --> iptables Rules (validator dependency)

PreToolUse Hook
  --> Call-ID Registration (hook registers call-IDs with validator before allowing calls)
  --> Domain Allowlist Check (hook checks whitelist before allowing calls)
  --> Call Validator (hook must register before validator will allow network traffic)

Installer Script
  --> Docker Network Isolation (installer sets up Docker Compose)
  --> PreToolUse Hook (installer registers hooks with Claude Code)
  --> File Permission Hardening (installer sets permissions)
  --> Auth Configuration (installer configures OAuth/API key)

Whitelist Config (JSON)
  --> Secret Redaction (proxy reads secret values from config)
  --> Domain Allowlist Check (hook reads allowed domains from config)
  --> Placeholder Restoration (proxy reads placeholder mappings from config)
```

## MVP Recommendation

Prioritize (in order):

1. **Docker Compose with isolated network** -- foundational; everything else depends on this
2. **Whitelist config format (JSON)** -- defines the data model that proxy and hook consume
3. **Anthropic proxy with secret redaction + placeholder restoration** -- addresses the primary threat (secrets to Anthropic)
4. **PreToolUse hook with domain checking + call-ID registration** -- addresses the secondary threat (exfiltration via tool calls)
5. **Call validator with SQLite + iptables** -- closes the bypass gap (unauthorized network calls)
6. **Installer script** -- adoption depends on setup UX
7. **Integration tests for security claims** -- proves the system works, prevents regressions

Defer:

- **Streaming proxy:** Phase 2. Buffered mode is correct and simpler. Latency is acceptable for security.
- **`@file` secret scanning:** Phase 2 enhancement. Known gap, low probability of accidental use.
- **Audit log dashboard:** Phase 3. Structured JSON logs are sufficient for solo dev.
- **OAuth token refresh:** Phase 3. Manual token refresh is acceptable short-term.
- **`claude-secure config` CLI:** Phase 3. Editing JSON directly is fine for technical users.
- **Multi-workspace support:** Phase 3. One project at a time is the MVP workflow.

## Complexity Assessment

| Feature Group | Estimated Complexity | Risk Level | Notes |
|---------------|---------------------|------------|-------|
| Docker Compose + networking | Medium | Low | Well-documented patterns. Main risk: WSL2 Docker networking edge cases. |
| Anthropic proxy (redact/restore) | High | Medium | Bidirectional secret handling has subtle edge cases. Must handle request bodies, headers, and response bodies. Encoding variants add complexity. |
| PreToolUse hook | Medium | Medium | Parsing bash commands for URLs is inherently fragile. Must handle pipes, subshells, variable expansion. Good-enough extraction is acceptable. |
| Call validator + iptables | High | High | iptables rule management from a container is non-trivial. Must handle rule cleanup on shutdown. SQLite concurrency with short-lived call-IDs needs careful locking. |
| Installer | Medium | Medium | Must handle many platform variations. WSL2 detection, Docker version checks, permission escalation. Error messages must be excellent. |
| Integration tests | Medium | Low | Docker-in-Docker or sibling containers. Test design is straightforward; infrastructure setup takes time. |

## Sources

- Project context: `/home/igor9000/claude-secure/.planning/PROJECT.md`
- Domain knowledge: Docker networking, iptables, Claude Code hooks system, container security patterns
- Confidence note: WebSearch was unavailable. Findings are based on training data knowledge of Docker isolation patterns, AI coding assistant security concerns, and the specific project architecture described in PROJECT.md. The feature categorization is HIGH confidence for table stakes (well-established security patterns) and MEDIUM confidence for differentiators (competitive landscape could not be verified against current tools).
