# claude-secure

A security wrapper for Claude Code that prevents API key and secret exfiltration by running it in a fully network-isolated Docker environment.

## Problem

Claude Code has unrestricted network access. It reads `.env` files and other configuration, pulling secrets into the LLM context. Those secrets are then sent to Anthropic's API as part of every conversation turn. Additionally, tool calls like `Bash(curl ...)` or `WebFetch` can exfiltrate data to arbitrary external URLs. There is no built-in mechanism to prevent this.

claude-secure solves this with a four-layer defense-in-depth architecture that ensures no secret ever leaves the isolated environment uncontrolled.

## How It Works

Four independent security layers work together so that any single layer failing does not compromise the system:

**Layer 1: Docker Network Isolation** -- The Claude container runs on a Docker network marked `internal: true`, which blocks all direct external access at the network level.

**Layer 2: PreToolUse Hook** -- A shell hook intercepts every `Bash`, `WebFetch`, and `WebSearch` tool call before execution. It extracts the target domain, checks it against a configurable whitelist, blocks payloads to non-whitelisted domains, and detects shell obfuscation attempts (variable expansion, `eval`, base64 encoding in curl commands).

**Layer 3: Anthropic Proxy** -- All traffic from Claude Code to the Anthropic API passes through a buffered proxy. The proxy scans each request body for secret values and replaces them with placeholders before forwarding. On the response, it restores placeholders to real values so Claude Code functions normally -- but Anthropic never sees the actual secrets.

**Layer 4: Call Validator** -- The hook registers a single-use, time-limited (10-second TTL) call-ID with the validator before allowing any outbound payload request. The validator manages iptables rules to enforce that only registered calls can reach external services. Call-IDs are stored in SQLite and expire automatically.

### Architecture Diagram

```
                        +---------------------------+
                        |     claude-external       |
                        |       (network)           |
                        +---------------------------+
                              |              |
                              |         api.anthropic.com
                              |
                  +-----------+-----------+
                  |       proxy           |
                  |  (Node.js)            |
                  |  - HTTP :8080         |
                  |  - HTTPS :443         |
                  |  - secret redaction   |
                  |  - buffered req/res   |
                  |  - DNS alias:         |
                  |    api.anthropic.com  |
                  +-----------+-----------+
                              |
                  +-----------+-----------+
                  |   claude-internal     |
                  |   (network,           |
                  |    internal: true)    |
                  +-----------+-----------+
                              |
          +-------------------+-------------------+
          |                                       |
+---------+---------+               +-------------+---------+
|      claude       |               |       validator       |
| (Ubuntu, Claude   |               | (Python, SQLite,      |
|  Code CLI)        | <- shared ->  |  iptables)            |
| - PreToolUse hook |   network     | - call-ID registry    |
| - workspace mount |   namespace   | - iptables rules      |
+-------------------+               +-------------+---------+
```

The proxy container bridges both networks. The validator shares the claude container's network namespace (`network_mode: service:claude`) so it can manage iptables rules for Claude's outbound traffic directly.

## Prerequisites

- Docker Engine 24+
- Docker Compose v2 (the `docker compose` plugin, not standalone `docker-compose` v1)
- curl
- jq
- uuidgen (`uuid-runtime` package on Debian/Ubuntu)
- Linux (native) or WSL2 -- no macOS support

## Installation

```bash
git clone <repo-url>
cd claude-secure
./install.sh
```

The installer:

1. Checks that all host dependencies are present
2. Detects platform (native Linux or WSL2) and warns about Docker Desktop iptables issues
3. Prompts for authentication -- OAuth token (recommended, via `claude setup-token`) or API key as fallback
4. Prompts for a workspace path (default: `~/claude-workspace`)
5. Copies project files to `~/.claude-secure/app/`
6. Copies the default `whitelist.json` to `~/.claude-secure/whitelist.json` and symlinks it back so config edits persist across updates
7. Builds Docker images
8. Installs the `claude-secure` CLI to `/usr/local/bin` (or `~/.local/bin` as fallback)

## Usage

```bash
# Start containers and launch Claude Code interactively
claude-secure

# Stop all containers
claude-secure stop

# Show container status and Claude Code version
claude-secure status

# Pull latest source, rebuild images, and update CLI wrapper
claude-secure update

# Rebuild claude image with latest Claude Code from npm (--no-cache)
claude-secure upgrade

# Show all available commands
claude-secure help
```

## Configuration

The whitelist controls which domains can receive outbound data and which secrets are redacted by the proxy. The configuration file lives at `~/.claude-secure/whitelist.json` (symlinked into the Docker build context by the installer).

The whitelist is re-read on every request -- no container restart is needed after editing.

### Default Structure

```json
{
  "secrets": [
    {
      "placeholder": "PLACEHOLDER_GITHUB",
      "env_var": "GITHUB_TOKEN",
      "allowed_domains": ["github.com", "api.github.com", "raw.githubusercontent.com"]
    },
    {
      "placeholder": "PLACEHOLDER_STRIPE",
      "env_var": "STRIPE_KEY",
      "allowed_domains": ["stripe.com", "api.stripe.com"]
    },
    {
      "placeholder": "PLACEHOLDER_OPENAI",
      "env_var": "OPENAI_API_KEY",
      "allowed_domains": ["api.openai.com"]
    }
  ],
  "readonly_domains": [
    "google.com",
    "stackoverflow.com",
    "docs.anthropic.com"
  ]
}
```

**`secrets`** -- Each entry defines:
- `placeholder`: The string that replaces the secret value in LLM context sent to Anthropic
- `env_var`: The environment variable holding the real secret value
- `allowed_domains`: Domains to which this secret may be sent in outbound payload requests

**`readonly_domains`** -- Domains allowed for read-only (GET) requests without call-ID registration. These are typically documentation and reference sites.

To add a new secret, add an entry to the `secrets` array with a unique placeholder, the environment variable name, and the domains that need it. Set the environment variable in `~/.claude-secure/.env`.

## Logging

All three services (hook, proxy, validator) support structured JSONL logging. Logging is disabled by default and enabled via environment variable toggles, so there is zero overhead unless you opt in.

### Enabling Logs

Append log flags to any `claude-secure` command:

```bash
# Enable specific service logging
claude-secure log:hook         # Enable hook script logging
claude-secure log:anthropic    # Enable proxy logging
claude-secure log:iptables     # Enable validator/iptables logging

# Enable all logging at once
claude-secure log:all

# Flags combine with commands
claude-secure log:all          # Start with all logging enabled
claude-secure log:hook log:anthropic  # Enable hook + proxy only
```

### Log Format

Each service writes structured JSONL (one JSON object per line) with four standard fields:

```json
{"ts":"2026-04-10T12:00:00.000Z","svc":"hook","level":"info","msg":"allow domain=github.com tool=Bash"}
```

| Field   | Description                                  |
|---------|----------------------------------------------|
| `ts`    | ISO 8601 timestamp (UTC)                     |
| `svc`   | Service name: `hook`, `anthropic`, `iptables`|
| `level` | Log level: `info`, `warning`, `error`        |
| `msg`   | Human-readable event description             |

### Viewing Logs

Use the `logs` subcommand to tail log files in real time:

```bash
claude-secure logs              # Tail all log files
claude-secure logs hook         # Tail hook logs only
claude-secure logs anthropic    # Tail proxy logs only
claude-secure logs iptables     # Tail validator logs only
claude-secure logs clear        # Delete all log files
```

### Log Location

Log files are stored at `~/.claude-secure/logs/`:

- `hook.jsonl` -- PreToolUse hook decisions (allow, deny, register)
- `anthropic.jsonl` -- Proxy request metadata (method, path, status, duration, redaction count)
- `iptables.jsonl` -- Validator call-ID registration and iptables rule events

### Security Note

Proxy logs never include request or response bodies. Since bodies may contain secrets before redaction, only metadata (HTTP method, path, status code, duration, and redaction count) is logged. This ensures that enabling logging does not create a secondary channel for secret exposure.

## Architecture Details

### claude Container

- Base image: Node.js 22 Slim
- Runs the Claude Code CLI
- All Linux capabilities dropped (`cap_drop: ALL`), `no-new-privileges` enforced
- Workspace directory bind-mounted as a Docker volume
- `ANTHROPIC_BASE_URL` points to the proxy (`http://proxy:8080`), so all API traffic routes through the redaction layer
- `HTTP_PROXY` and `HTTPS_PROXY` set to `http://proxy:8080`, routing all outbound HTTP/HTTPS tool calls (curl, wget, WebFetch) through the proxy for domain validation and CONNECT tunneling
- `NODE_TLS_REJECT_UNAUTHORIZED=0` set to accept the proxy's self-signed certificate for intercepted HTTPS calls
- Telemetry, auto-updater, and error reporting disabled to prevent non-essential external connections
- Onboarding flag pre-set (`hasCompletedOnboarding`) to skip startup checks that bypass `ANTHROPIC_BASE_URL`
- PreToolUse hook installed at `/etc/claude-secure/` (root-owned, read-only)
- Connected only to the `claude-internal` network (no external access)

### proxy Container

- Base image: Node.js 22 Slim
- Zero npm dependencies -- uses only Node.js stdlib (`http`, `https`, `net`, `dns`, `fs`)
- Listens on HTTP port 8080 (for `ANTHROPIC_BASE_URL` traffic) and HTTPS port 443 with a self-signed certificate (for intercepted hardcoded calls)
- Registered as a Docker network alias for `api.anthropic.com`, `statsig.anthropic.com`, and `sentry.anthropic.com` on the internal network -- Claude Code's hardcoded external calls resolve to the proxy instead of failing
- Acts as a forward proxy for the claude container (`HTTP_PROXY`/`HTTPS_PROXY`), enabling outbound HTTPS connections to whitelisted domains via CONNECT tunneling
- Validates CONNECT targets against the whitelist -- non-whitelisted domains are rejected with 403
- Uses external DNS (8.8.8.8, 1.1.1.1) for upstream resolution to bypass Docker network aliases that would otherwise cause a DNS loop
- Buffers entire request body, performs longest-first secret replacement, forwards to `api.anthropic.com`
- Buffers entire response, restores placeholders to real values, returns to Claude
- Strips `Accept-Encoding` to prevent compressed responses that cannot be scanned
- Connected to both `claude-internal` and `claude-external` networks

### validator Container

- Base image: Python 3.11 Alpine
- Zero pip dependencies -- uses only Python stdlib (`http.server`, `sqlite3`, `subprocess`, `json`, `threading`)
- SQLite database in WAL mode for concurrent read/write access
- `POST /register` -- accepts call-ID + domain, stores with 10-second TTL
- `GET /validate?call_id=X` -- checks if call-ID is valid and not expired
- Background thread sweeps expired entries periodically
- Shares network namespace with claude container (`network_mode: service:claude`) for direct iptables rule management
- Allows DNS queries to Docker embedded DNS (127.0.0.11) for domain resolution during call-ID registration
- Requires `NET_ADMIN` capability for iptables access

## Security Model

**Secrets are redacted before reaching Anthropic.** The proxy replaces every secret value in the request body with a placeholder. Anthropic's API only ever sees `PLACEHOLDER_GITHUB`, never the actual token.

**Outbound payload requests require whitelisted domain + registered call-ID.** The PreToolUse hook checks that the target domain appears in `whitelist.json` and registers a single-use call-ID with the validator before allowing the call to proceed.

**Read-only (GET) requests are allowed without registration.** Fetching documentation, searching the web, and reading public APIs do not require call-ID registration.

**Shell obfuscation is detected and blocked.** The hook scans curl/wget commands for variable expansion (`$VAR`, `${VAR}`), backtick substitution, `eval`, and `base64` encoding. Any detected obfuscation results in an immediate deny.

**Hook scripts and config are root-owned and read-only.** Inside the container, the Claude process cannot modify the security layer.

**Zero external dependencies in security-critical paths.** The proxy uses only Node.js stdlib. The validator uses only Python stdlib. No npm packages, no pip packages -- eliminating supply-chain attack surface.

## Limitations

- **Buffered proxy (no streaming)** -- All API responses are buffered for redaction before returning. This adds latency compared to streaming.
- **No `@file` content scanning** -- When Claude Code references files via `@file`, the file contents enter LLM context but are not scanned by the proxy (they are part of the user-side message, not a secret environment variable).
- **No macOS support** -- Docker Desktop on macOS does not support the network isolation and iptables patterns this project requires.
- **No automatic OAuth token refresh** -- If the OAuth token expires, you must re-run the auth setup manually.

## Platform Support

- **Linux (native)** -- Fully supported. Any modern distribution with Docker Engine 24+ and kernel 4.x+.
- **WSL2** -- Supported. The installer detects WSL2 automatically and validates the iptables backend.

Docker Desktop on WSL2 may have iptables compatibility issues. Docker CE installed directly in the WSL2 distribution is recommended.

## License

[TBD]
