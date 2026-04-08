<!-- GSD:project-start source:PROJECT.md -->
## Project

**claude-secure**

An installable security wrapper for Claude Code that runs it in a fully network-isolated Docker environment. It prevents API keys and secrets from leaking to Anthropic or arbitrary external URLs through a four-layer architecture: Docker isolation, PreToolUse hook validation, an Anthropic proxy with secret redaction, and an iptables-based call validator with SQLite registration. Built for solo developers who want to use Claude Code on projects with real API keys without risking secret exfiltration.

**Core Value:** No secret ever leaves the isolated environment uncontrolled — every outbound call is validated, every secret in LLM context is redacted, and Claude Code cannot bypass the security layers.

### Constraints

- **Platform**: Must work on Linux (native) and WSL2 — no macOS Docker Desktop support needed
- **Dependencies**: Docker, Docker Compose, curl, jq, uuidgen must be available on host
- **Security**: Hook scripts, settings, and whitelist must be root-owned and immutable by the Claude process
- **Architecture**: Proxy uses buffered request/response (no streaming) for Phase 1
- **Auth**: OAuth token (via `claude setup-token`) is primary; API key supported as fallback
- **No NFQUEUE**: Validator uses HTTP registration + iptables only (no kernel module dependency)
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Recommended Stack
### Core Technologies
| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Docker Engine | 24.x+ | Container runtime for isolation | Industry standard. `internal` network flag provides true network isolation without iptables on the host. Required by project constraints. | HIGH |
| Docker Compose | v2.24+ | Multi-container orchestration | Declarative networking, service dependencies, health checks. V2 is the current standard (v1 is deprecated). `internal: true` on networks prevents external access. | HIGH |
| Node.js | 22 LTS | Anthropic proxy service | LTS until April 2027. Native `http` module is sufficient for a buffered forward proxy -- no framework needed. Excellent JSON manipulation for secret redaction. | HIGH |
| Python | 3.11+ | Call validator service | stdlib `http.server` + `sqlite3` means zero external dependencies. Perfect for a lightweight validation microservice. | HIGH |
| SQLite | 3.x (bundled with Python) | Call-ID registration store | Zero-config, single-file, bundled with Python. WAL mode handles concurrent reads/writes from HTTP server + iptables helper. | HIGH |
| iptables | system (nftables backend) | Network-level call enforcement | Available in all Linux containers with `NET_ADMIN` capability. Modern kernels use nftables backend transparently via iptables CLI. | HIGH |
| Bash | 5.x | Hook scripts, installer, CLI wrapper | Available everywhere. Claude Code hooks are shell scripts by design. No dependency beyond coreutils + jq + curl + uuidgen. | HIGH |
| jq | 1.7+ | JSON processing in hooks | Standard tool for JSON manipulation in shell. Required for parsing tool call payloads in PreToolUse hooks. | HIGH |
### Supporting Libraries (Node.js Proxy)
| Library | Version | Purpose | Why This Over Alternatives |
|---------|---------|---------|---------------------------|
| Node.js `http` (stdlib) | -- | HTTP server and client | No dependency needed. Buffered proxy is ~80 lines with `http.createServer` + `http.request`. Adding express/fastify would be overengineering for a single-route forward proxy. |
| Node.js `https` (stdlib) | -- | TLS client for upstream Anthropic API | Needed to forward requests to `api.anthropic.com` over HTTPS. |
| Node.js `fs` (stdlib) | -- | Read whitelist config on each request | Fresh reads ensure config changes take effect without restart. |
### Supporting Libraries (Python Validator)
| Library | Purpose | Why This Over Alternatives |
|---------|---------|---------------------------|
| `http.server` (stdlib) | HTTP endpoint for call-ID registration and validation | Zero dependencies. `BaseHTTPRequestHandler` is sufficient for 2 endpoints (register + validate). |
| `sqlite3` (stdlib) | Call-ID storage with time-limited expiry | Bundled with Python. WAL mode for concurrent access. `DELETE FROM calls WHERE expires < datetime('now')` handles TTL. |
| `subprocess` (stdlib) | Execute iptables commands | Direct iptables rule manipulation from Python. |
| `json` (stdlib) | Request/response parsing | Stdlib JSON handling, no external parser needed. |
| `threading` (stdlib) | Periodic cleanup of expired call-IDs | Background thread to sweep expired entries every 5 seconds. |
### Development & Testing Tools
| Tool | Purpose | Notes |
|------|---------|-------|
| Docker Compose `profiles` | Separate test containers from production | `profiles: ["test"]` on test service containers so they don't start by default |
| `docker compose exec` | Run integration test commands inside containers | Tests execute within the network topology, verifying real isolation |
| Bash + curl + jq | Integration test harness | Shell-based tests that curl endpoints, attempt blocked calls, verify responses. No test framework dependency needed for Docker-level integration tests. |
| ShellCheck | Bash script linting | Catches common shell scripting errors in hooks and installer |
| `pytest` | Python validator unit tests | Only needed if unit-testing the validator logic outside Docker. For integration tests, shell scripts suffice. |
## Installation
# Host dependencies (must be pre-installed)
# docker, docker-compose (v2), curl, jq, uuidgen, bash
# No npm install needed -- Node.js proxy uses only stdlib
# No pip install needed -- Python validator uses only stdlib
# The installer script handles:
# 1. Docker image builds (Dockerfiles in project)
# 2. Config file generation (whitelist.json)
# 3. Claude Code hook installation
# 4. CLI shortcut creation
## Alternatives Considered
| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Node.js stdlib `http` | `http-proxy` npm package | If you need WebSocket proxying, streaming, or load balancing. For this project's buffered single-upstream proxy, stdlib is simpler and has zero supply-chain risk. |
| Node.js stdlib `http` | `express` + `http-proxy-middleware` | If the proxy needs multiple routes, middleware chains, or complex request routing. Overkill for a single-purpose forward proxy. |
| Python `http.server` | Flask / FastAPI | If the validator needed complex routing, async handling, or OpenAPI docs. Two endpoints (register/validate) don't justify the dependency. |
| SQLite | Redis | If call-ID volume exceeded thousands per second or you needed pub/sub. SQLite handles this project's volume (tens of calls per minute) trivially, with no additional container needed. |
| Shell-based integration tests | Testcontainers (Python/Java) | If you needed programmatic container lifecycle management or complex test orchestration. For this project, `docker compose up` + shell scripts are more transparent and debuggable. |
| iptables CLI | nftables CLI directly | If targeting only modern kernels and wanting cleaner syntax. iptables CLI works on both legacy and nftables backends, maximizing compatibility across Linux and WSL2. |
| Bash hooks | Python hooks | If hook logic became complex enough to need proper error handling, classes, or libraries. For domain-checking and call-ID generation, bash + jq + curl + uuidgen is sufficient and has faster startup. |
## What NOT to Use
| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `node-http-proxy` / `http-proxy` npm | Adds supply-chain attack surface to a security tool. The proxy IS the security layer -- minimizing dependencies is critical. Also, its streaming default conflicts with our buffered redaction approach. | Node.js stdlib `http`/`https` |
| Express/Fastify for proxy | Framework overhead for a single-route proxy. Adds dependencies, increases attack surface, and the middleware model doesn't match our "buffer entire body, transform, forward" pattern. | Node.js stdlib `http` |
| NFQUEUE / `libnetfilter_queue` | Requires kernel module support that WSL2 often lacks. Complex C/Python bindings. Project explicitly scoped this out. | iptables + HTTP validator pattern |
| `scapy` (Python) | Packet-level inspection is overkill and has WSL2 kernel compatibility issues. | iptables rules + HTTP-level validation |
| Docker `--network=host` | Defeats the entire purpose of network isolation. | Docker Compose internal networks |
| `mitmproxy` | Full MITM proxy is massive overkill. Designed for interactive debugging, not programmatic secret redaction. Hard to embed in a container as a library. | Custom Node.js buffered proxy |
| Nginx as proxy | Config-file-driven, not programmatic. Cannot do per-request secret redaction with dynamic config reloads. Lua scripting is possible but harder to maintain than Node.js. | Custom Node.js buffered proxy |
| Docker Swarm / Kubernetes | Massive operational overhead for a local dev tool running 3 containers. | Docker Compose |
| `got` / `axios` / `node-fetch` for proxy client | Extra dependencies in a security-critical path. Node.js `http.request` does everything needed for buffered forwarding. | Node.js stdlib `https.request` |
## Stack Patterns by Architecture Layer
- Use `internal: true` on the Compose network to block all external access by default
- Proxy container gets a second network (external) for reaching `api.anthropic.com`
- Claude container and validator are on internal network only
- Use `cap_add: [NET_ADMIN]` on validator container for iptables access
- Hook script installed to Claude Code's hook directory
- Reads tool name + arguments from stdin (JSON)
- For Bash/WebFetch/WebSearch: extracts target domain, checks whitelist
- On allow: generates UUID call-ID, registers with validator via HTTP, returns allow
- On block: returns block with reason
- Dependencies: bash, jq, curl, uuidgen (all standard Linux tools)
- Listens on internal network port (e.g., 8080)
- Claude container's `ANTHROPIC_BASE_URL` points here
- Buffers entire request body, scans for secret values, replaces with placeholders
- Forwards to real `api.anthropic.com` via external network
- Buffers response, restores placeholders to real values
- Config re-read on every request (no restart needed)
- HTTP server on internal network
- `POST /register` -- hook registers call-ID with destination info, stores in SQLite with 10s TTL
- `GET /validate?call_id=X` -- iptables helper checks if call-ID is valid
- Background thread cleans expired entries
- iptables rules: OUTPUT chain on claude container, REJECT by default, specific rules added/removed per validated call
## Version Compatibility
| Component | Compatible With | Notes |
|-----------|-----------------|-------|
| Docker Compose v2 | Docker Engine 24+ | V2 is built into Docker CLI. Do not use standalone `docker-compose` (v1, deprecated). |
| Node.js 20 LTS | Alpine 3.18+ base image | Use `node:20-alpine` for small image size (~50MB). |
| Python 3.11+ | Alpine 3.18+ base image | Use `python:3.11-alpine` for small image size. SQLite bundled. |
| iptables | Linux kernel 4.x+ / WSL2 | WSL2 uses Linux 5.15+ kernel, iptables works via nftables backend. |
| jq 1.7 | Alpine package manager | `apk add jq` in Dockerfile. |
| SQLite WAL mode | Python 3.11+ sqlite3 module | WAL mode enabled via `PRAGMA journal_mode=WAL;` on connection. |
## Container Image Strategy
| Container | Base Image | Size Target | Key Packages |
|-----------|------------|-------------|--------------|
| claude | ubuntu:22.04 or debian:bookworm | ~200MB | Claude Code CLI, bash, jq, curl, uuidgen |
| proxy | node:20-alpine | ~60MB | Node.js only (stdlib) |
| validator | python:3.11-alpine | ~50MB | Python only (stdlib), iptables, ip6tables |
## Sources
- Training data (Docker Compose networking, internal networks) -- HIGH confidence, mature stable feature
- Training data (Node.js http stdlib) -- HIGH confidence, stable API since Node 0.x
- Training data (Python http.server + sqlite3) -- HIGH confidence, stdlib modules stable for years
- Training data (iptables in containers) -- HIGH confidence, well-documented Docker pattern
- Training data (npm package assessment: http-proxy, express) -- MEDIUM confidence, versions may have changed
- No live verification performed (WebSearch, WebFetch, Context7 unavailable) -- version numbers should be validated before implementation
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
