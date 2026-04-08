# Phase 02: Call Validation - Context

**Gathered:** 2026-04-08
**Status:** Ready for planning

<domain>
## Phase Boundary

Implement the call validation layer: the PreToolUse hook intercepts Bash/WebFetch/WebSearch tool calls, extracts target domains, checks against the whitelist, generates call-IDs for allowed calls, registers them with the validator, and iptables rules enforce that only registered calls reach the network. Read-only GET requests to any domain are allowed without registration; outbound payloads (POST/PUT/PATCH) to non-whitelisted domains are blocked.

This phase transforms the stub hook (exit 0) and stub validator (accept all) from Phase 1 into functioning security gates.

</domain>

<decisions>
## Implementation Decisions

### Hook Response Format
- **D-01:** Hook communicates with Claude Code via JSON on stdout. Exit 0 = allow (with optional JSON), exit 2 = block (JSON with `{"error": "reason"}`). This matches the Claude Code PreToolUse hook protocol.
- **D-02:** Hook reads tool call payload from stdin as JSON, extracts tool name and arguments.

### Domain Extraction Strategy
- **D-03:** Extract URLs/domains from tool call payloads using regex-based parsing. For Bash tool calls, parse curl/wget commands for target URLs. For WebFetch/WebSearch, extract the URL directly from the tool arguments.
- **D-04:** If a domain cannot be extracted from a Bash command (ambiguous or obfuscated), block the call. Fail-closed is the security default.
- **D-05:** Domain matching includes subdomains — `api.github.com` matches a whitelist entry for `github.com`.

### Read-Only Request Detection
- **D-06:** For Bash tool calls, detect outbound payloads by checking for HTTP method flags (`-X POST`, `-X PUT`, `-X PATCH`, `-X DELETE`), data flags (`-d`, `--data`, `-F`, `--form`, `--upload-file`), and pipe-to-curl patterns.
- **D-07:** WebFetch tool calls: check the method field if present; default to GET if absent.
- **D-08:** Read-only GET requests to non-whitelisted domains are allowed without call-ID registration (per CALL-04). They still go through the hook but skip the validator registration step.

### Call-ID Management
- **D-09:** Hook generates UUIDs via `uuidgen` and registers with validator at `http://validator:8088/register` including call-ID, target domain, and timestamp.
- **D-10:** Validator stores call-IDs in SQLite with columns: call_id, domain, created_at, expires_at, used (boolean). WAL mode for concurrent access.
- **D-11:** Call-IDs expire after 10 seconds (per project constraint). Background cleanup thread sweeps expired entries.
- **D-12:** Call-IDs are single-use — once validated, marked as used and cannot be reused.

### iptables Enforcement
- **D-13:** Validator manages iptables rules on the claude container's OUTPUT chain. Default policy: DROP all outbound except traffic to proxy (port 8080) and validator (port 8088) on the internal network.
- **D-14:** When a call-ID is registered, validator adds a temporary iptables ACCEPT rule for the target domain/IP. Rule is removed when the call-ID expires or is used.
- **D-15:** iptables rules use domain-to-IP resolution at rule creation time. DNS resolution happens in the validator container (which has network access on the internal network).

### Claude's Discretion
- Exact regex patterns for URL extraction from Bash commands — researcher should investigate common patterns
- Log format and verbosity for hook decisions — implementer can decide
- SQLite schema details beyond the core columns listed above

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project Architecture
- `.planning/PROJECT.md` -- Core value, constraints, four-layer architecture description
- `.planning/REQUIREMENTS.md` -- CALL-01 through CALL-07 acceptance criteria
- `CLAUDE.md` -- Technology stack, container image strategy, stack patterns

### Phase 1 Artifacts (foundation)
- `docker-compose.yml` -- Network topology, service definitions, volume mounts
- `claude/Dockerfile` -- Claude container build, non-root user, permission hardening
- `claude/hooks/pre-tool-use.sh` -- Stub hook to be replaced
- `claude/settings.json` -- PreToolUse hook configuration (matcher pattern)
- `validator/validator.py` -- Stub validator to be replaced
- `validator/Dockerfile` -- Validator container with iptables installed
- `config/whitelist.json` -- Secret-to-domain mapping schema

### Phase 1 Research
- `.planning/phases/01-docker-infrastructure/01-RESEARCH.md` -- Docker networking findings, blockers discovered

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `claude/hooks/pre-tool-use.sh` — Stub hook, already wired into settings.json via `/etc/claude-secure/hooks/pre-tool-use.sh`. Replace contents, keep path.
- `validator/validator.py` — Stub validator with /register, /health, /validate endpoints already defined. Expand with real logic.
- `config/whitelist.json` — Schema already has `secrets[].allowed_domains` and `readonly_domains`. Hook reads this for domain checking.

### Established Patterns
- Container networking: claude on internal-only, validator on internal with NET_ADMIN cap
- File permissions: root-owned chmod 555 for hooks, chmod 444 for config
- Settings.json at `/etc/claude-secure/settings.json` with symlink to `/root/.claude/settings.json`
- Non-root user `claudeuser` in claude container (Claude Code refuses root execution)

### Integration Points
- Hook reads stdin JSON from Claude Code, writes JSON to stdout
- Hook calls validator at `http://validator:8088/register` via curl (curl is installed in claude container)
- Validator manages iptables on the claude container's network namespace (has NET_ADMIN)
- Whitelist mounted read-only at `/etc/claude-secure/whitelist.json` in both claude and validator containers

</code_context>

<specifics>
## Specific Ideas

No specific requirements -- open to standard approaches. The requirements (CALL-01 through CALL-07) and project architecture (CLAUDE.md) define the implementation clearly.

</specifics>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope

</deferred>

---

*Phase: 02-call-validation*
*Context gathered: 2026-04-08*
