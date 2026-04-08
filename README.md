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
                  |  (Node.js, port 8080) |
                  |  - secret redaction   |
                  |  - buffered req/res   |
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

# Show container status
claude-secure status

# Pull latest source and rebuild images
claude-secure update
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

## Architecture Details

### claude Container

- Base image: Ubuntu 22.04
- Runs the Claude Code CLI
- All Linux capabilities dropped (`cap_drop: ALL`), `no-new-privileges` enforced
- Workspace directory bind-mounted as a Docker volume
- `ANTHROPIC_BASE_URL` points to the proxy (`http://proxy:8080`), so all API traffic routes through the redaction layer
- PreToolUse hook installed at `/etc/claude-secure/` (root-owned, read-only)
- Connected only to the `claude-internal` network (no external access)

### proxy Container

- Base image: Node.js 22 Alpine
- Zero npm dependencies -- uses only Node.js stdlib (`http`, `https`, `fs`)
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
