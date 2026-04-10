# Phase 7: Env-file Strategy and Secret Loading - Research

**Researched:** 2026-04-10
**Domain:** Docker Compose env_file mechanics, secret lifecycle, .env file organization
**Confidence:** HIGH

## Summary

This phase addresses a clear architectural gap in claude-secure: the relationship between two .env files, how secrets flow from host to containers, and how the proxy knows which secrets to redact. Currently, the system works but relies on a fragile, manual process where users must keep `docker-compose.yml` environment variables in sync with `whitelist.json` entries. Adding a new secret requires editing three places: (1) the `.env` file, (2) `docker-compose.yml` proxy environment block, and (3) `whitelist.json`.

The core problem is that `docker-compose.yml` hardcodes specific secret env var names (`GITHUB_TOKEN`, `STRIPE_KEY`, `OPENAI_API_KEY`) in the proxy service's `environment` block. This means every time a user adds or removes a secret in `whitelist.json`, they must also edit `docker-compose.yml` -- a file that lives in the app directory, not the user config directory. This violates the separation between app code and user configuration.

**Primary recommendation:** Use Docker Compose `env_file` directive on the proxy service to load all secrets from `~/.claude-secure/.env` automatically, eliminating the need to hardcode individual secret env var names in `docker-compose.yml`. The proxy already reads `whitelist.json` to discover which `env_var` names to look up via `process.env[entry.env_var]`, so it will find them regardless of how they got into the environment.

## Current State Analysis

### Two .env Files Explained

| File | Location | Current Contents | Purpose |
|------|----------|-----------------|---------|
| Repo `.env` | `/home/igor9000/claude-secure/.env` | `GITHUB_TOKEN=ghp_...` | Docker Compose auto-loads this (implicit `.env` in project dir). Currently contains one secret manually added. |
| Config `.env` | `~/.claude-secure/.env` | `CLAUDE_CODE_OAUTH_TOKEN=sk-ant-...`, `GITHUB_TOKEN=ghp_...` | Created by installer. Sourced by CLI wrapper via `set -a; source .env; set +a`. Contains auth + secrets. |

**The flow today:**
1. User runs `claude-secure` CLI wrapper
2. CLI wrapper sources `~/.claude-secure/.env` (exports all vars via `set -a`)
3. CLI wrapper runs `docker compose up` with `COMPOSE_FILE` pointing to app dir
4. Docker Compose also auto-loads `$APP_DIR/.env` (the repo `.env`) because it is in the same directory as `docker-compose.yml`
5. Docker Compose substitutes `${GITHUB_TOKEN:-}` etc. in `environment:` blocks
6. Proxy container receives the env vars and uses `process.env[entry.env_var]` to build redaction maps

**The problem:** Step 5 requires every secret env var to be explicitly listed in `docker-compose.yml`. The repo `.env` file (step 4) is redundant and confusing -- it duplicates secrets that are already exported by the CLI wrapper.

### How the Proxy Discovers Secrets

The proxy's `buildMaps()` function (proxy.js line 44-66) iterates over `config.secrets` from `whitelist.json`. For each entry, it reads `process.env[entry.env_var]`. This is already fully dynamic -- the proxy does NOT hardcode any secret names. The only reason secret names appear in `docker-compose.yml` is to pass them from the host shell environment into the container.

### Docker Compose `env_file` vs `environment`

| Mechanism | How It Works | Scope |
|-----------|-------------|-------|
| `environment:` block with `${VAR}` | Substitutes from host shell env or `.env` file at compose-up time | Only listed vars enter container |
| `env_file:` directive | Loads all key=value pairs from specified file into container env | ALL vars in file enter container |
| Implicit `.env` (project dir) | Auto-loaded for `${VAR}` substitution in compose file itself | Only for compose-file interpolation, NOT passed to containers |

**Key insight:** `env_file` passes ALL variables from a file directly into the container, without needing to list them individually in `docker-compose.yml`. This is exactly what we need for the proxy service.

## Architecture Patterns

### Recommended .env File Strategy

**Single .env file at `~/.claude-secure/.env`** containing everything:

```bash
# Auth (one of these, set by installer)
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
# ANTHROPIC_API_KEY=sk-ant-api-...

# Secrets to redact (must match env_var in whitelist.json)
GITHUB_TOKEN=ghp_...
STRIPE_KEY=sk_test_...
OPENAI_API_KEY=sk-...
```

**Eliminate the repo `.env` file entirely.** It is redundant -- the CLI wrapper already exports everything from `~/.claude-secure/.env` before running docker compose.

### Recommended docker-compose.yml Changes

```yaml
proxy:
  build: ./proxy
  container_name: claude-proxy
  env_file:
    - ${SECRETS_FILE:-/dev/null}    # All secrets loaded dynamically
  environment:
    - REAL_ANTHROPIC_BASE_URL=https://api.anthropic.com
    - WHITELIST_PATH=/etc/claude-secure/whitelist.json
    - LOG_ANTHROPIC=${LOG_ANTHROPIC:-0}
  # ... rest unchanged
```

The CLI wrapper sets `SECRETS_FILE=$CONFIG_DIR/.env` before running docker compose. The `env_file` directive loads ALL key-value pairs from that file into the proxy container's environment. The proxy's existing `buildMaps()` logic handles the rest.

**Why `env_file` on proxy service only:**
- The **claude** container must NOT have secret values in its environment (Claude Code could read them via `env` command). Currently it only gets auth tokens and proxy URLs.
- The **validator** container has no need for secrets.
- Only the **proxy** needs secret values to build redaction/restoration maps.

### Pattern: Adding a New Secret (After This Phase)

User workflow becomes:
1. Add secret entry to `~/.claude-secure/whitelist.json` (placeholder, env_var, allowed_domains)
2. Add the actual secret value to `~/.claude-secure/.env` (e.g., `MY_NEW_SECRET=value123`)
3. Restart: `claude-secure stop && claude-secure`

No `docker-compose.yml` editing required. The proxy picks up the new env var automatically via `env_file`, and the whitelist tells it what to redact.

### Anti-Patterns to Avoid

- **Passing all secrets to claude container:** Claude Code could exfiltrate them via the `env` command or `/proc/self/environ`. Only auth tokens should reach the claude container.
- **Using Docker secrets (swarm mode):** Requires Docker Swarm, massive overkill for a local dev tool.
- **Hardcoding secret names in docker-compose.yml:** The current approach. Breaks the dynamic discovery pattern that `whitelist.json` + `process.env` already provides.
- **Two .env files:** Confusing, error-prone, redundant. One canonical source of truth.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Passing dynamic env vars to containers | Custom entrypoint that reads a file and exports vars | Docker Compose `env_file:` directive | Built-in, well-tested, zero code needed |
| Secret file encryption at rest | Custom encrypt/decrypt wrapper | File permissions (`chmod 600`) | Good enough for single-user dev tool; encryption adds key-management complexity |
| .env file parsing | Custom bash parser | `set -a; source .env; set +a` (already used) | Handles quoting, empty lines, comments correctly |

## Common Pitfalls

### Pitfall 1: Docker Compose .env Auto-Loading Confusion
**What goes wrong:** Docker Compose automatically loads a `.env` file from the project directory for `${VAR}` interpolation in the compose file. This is NOT the same as `env_file:`. Users confuse the two.
**Why it happens:** Docker Compose has two different `.env` mechanisms with overlapping names.
**How to avoid:** Delete the repo `.env` file (it is gitignored anyway). Use only `~/.claude-secure/.env` loaded explicitly. Document clearly that auto-loaded `.env` is for compose interpolation only, while `env_file:` is for container env vars.
**Warning signs:** Secrets work sometimes but not others, depending on which directory `docker compose` is run from.

### Pitfall 2: env_file Exposes ALL Vars to Container
**What goes wrong:** `env_file` loads every line from the file into the container environment. If the file contains `CLAUDE_CODE_OAUTH_TOKEN`, the proxy container gets it (fine). But if accidentally pointed at the claude container, secrets leak.
**Why it happens:** `env_file` is a blunt instrument -- no filtering.
**How to avoid:** Only add `env_file` to the proxy service. The claude container keeps its explicit `environment:` block with only the vars it needs.
**Warning signs:** Running `docker compose exec claude env` shows secret values.

### Pitfall 3: env_file Path Must Be Absolute or Relative to Compose File
**What goes wrong:** `env_file: ~/.claude-secure/.env` does NOT work because Docker Compose does not expand `~`.
**Why it happens:** Docker Compose resolves `env_file` paths relative to the compose file location, and does not perform shell expansion.
**How to avoid:** Use a variable: `env_file: ${SECRETS_FILE}` where the CLI wrapper exports `SECRETS_FILE=$HOME/.claude-secure/.env` before invoking docker compose.
**Warning signs:** "file not found" errors on `docker compose up`.

### Pitfall 4: Comments and Blank Lines in .env
**What goes wrong:** Docker Compose `env_file` parsing differs slightly from bash `source`. Lines starting with `#` are comments in both. Blank lines are ignored in both. But inline comments (`VAR=value # comment`) are NOT stripped by Docker -- the `# comment` becomes part of the value.
**Why it happens:** Docker's .env parser is simpler than bash.
**How to avoid:** Never use inline comments in `.env` files. Only full-line comments.
**Warning signs:** Secret values contain `# ...` suffixes, causing redaction to fail.

### Pitfall 5: Repo .env Contains Real Secrets in Git Directory
**What goes wrong:** The repo `.env` at `/home/igor9000/claude-secure/.env` currently contains a real `GITHUB_TOKEN`. Even though `.env` is gitignored, it sits in the repo directory and could be accidentally committed if `.gitignore` is modified.
**Why it happens:** No clear guidance on where secrets should live.
**How to avoid:** Remove secrets from the repo `.env`. All secrets should live only in `~/.claude-secure/.env` (outside the repo).
**Warning signs:** `git status` shows `.env` as untracked (currently the case, but gitignored).

## Code Examples

### CLI Wrapper Changes (bin/claude-secure)

```bash
# Current: only sources .env for shell export
set -a
source "$CONFIG_DIR/.env"
set +a

# Add: export SECRETS_FILE for docker compose env_file directive
export SECRETS_FILE="$CONFIG_DIR/.env"
```

### docker-compose.yml Proxy Service Changes

```yaml
proxy:
  build: ./proxy
  container_name: claude-proxy
  env_file:
    - ${SECRETS_FILE:-/dev/null}
  environment:
    - REAL_ANTHROPIC_BASE_URL=https://api.anthropic.com
    - WHITELIST_PATH=/etc/claude-secure/whitelist.json
    - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
    - CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}
    - LOG_ANTHROPIC=${LOG_ANTHROPIC:-0}
```

Note: Auth tokens (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`) are kept in both `env_file` (they are in `.env`) and `environment` (for the claude service which does NOT get `env_file`). The proxy gets them via `env_file`. The claude service gets them via explicit `environment` with `${VAR}` substitution from the CLI wrapper's exported env.

### Installer Changes (install.sh)

```bash
setup_auth() {
  # ... existing auth prompt logic ...
  
  # After writing auth token to .env, add guidance comment
  echo "" >> "$CONFIG_DIR/.env"
  echo "# Add secrets below (must match env_var in whitelist.json)" >> "$CONFIG_DIR/.env"
  echo "# Example: GITHUB_TOKEN=ghp_your_token_here" >> "$CONFIG_DIR/.env"
}
```

### Proxy: No Changes Needed

The proxy's `buildMaps()` already does:
```javascript
const realValue = process.env[entry.env_var];  // Dynamic lookup
```
This works regardless of whether the env var came from `environment:` or `env_file:`. No proxy code changes needed.

## Scope of Changes

| File | Change | Why |
|------|--------|-----|
| `docker-compose.yml` | Add `env_file:` to proxy service, remove hardcoded `GITHUB_TOKEN`/`STRIPE_KEY`/`OPENAI_API_KEY` from proxy `environment:` | Dynamic secret loading |
| `bin/claude-secure` | Export `SECRETS_FILE=$CONFIG_DIR/.env` | Provides path for `env_file:` directive |
| `install.sh` | Add comment guidance in `.env` for secret vars | User documentation |
| `.env` (repo) | Delete or empty | Remove confusion, eliminate secret in repo dir |
| `tests/test-phase3.sh` | May need minor updates if test compose files change | Test compatibility |
| `proxy/proxy.js` | No changes | Already dynamic |
| `validator/validator.py` | No changes | Does not use secrets |

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash + curl + jq (integration tests in Docker) |
| Config file | `tests/test-phase3.sh` (existing secret redaction tests) |
| Quick run command | `bash tests/test-phase3.sh` |
| Full suite command | `bash tests/test-phase3.sh && bash tests/test-phase4.sh` |

### Phase Requirements -> Test Map

Since this phase has no formal requirement IDs (TBD), here are the behavioral requirements:

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ENV-01 | Secrets from env_file are available in proxy container | integration | `docker compose exec proxy printenv GITHUB_TOKEN` | No (Wave 0) |
| ENV-02 | Adding a new secret to .env + whitelist.json works without editing docker-compose.yml | integration | Add test secret, verify redaction | No (Wave 0) |
| ENV-03 | Claude container does NOT have secret env vars (only auth tokens) | integration | `docker compose exec claude env \| grep -v ANTHROPIC \| grep -v CLAUDE` | No (Wave 0) |
| ENV-04 | Proxy still redacts secrets correctly with env_file loading | integration | Existing test-phase3.sh tests | Yes |
| ENV-05 | System works when no optional secrets are configured (only auth) | integration | Start with minimal .env | No (Wave 0) |

### Wave 0 Gaps
- [ ] `tests/test-phase7.sh` -- covers ENV-01 through ENV-05
- [ ] Existing `tests/test-phase3.sh` may need updates if docker-compose structure changes

## Open Questions

1. **Should auth tokens stay in `environment:` block or move entirely to `env_file`?**
   - What we know: The claude container needs `CLAUDE_CODE_OAUTH_TOKEN` passed via `environment:` with `${VAR}` substitution. The proxy needs it too for forwarding to Anthropic.
   - What's unclear: Whether having auth tokens in both `env_file` (for proxy) and `environment:` (for claude) causes any Docker Compose precedence issues.
   - Recommendation: Keep auth tokens in both places. Docker Compose `environment:` takes precedence over `env_file:` when the same var appears in both, so explicit `environment:` entries for the proxy (like `LOG_ANTHROPIC`) are safe. The proxy gets auth from `env_file`, the claude container gets auth from `environment:`.

2. **Should the repo `.env` file be deleted or kept empty?**
   - What we know: It currently contains `GITHUB_TOKEN=ghp_...` (a real secret in the repo directory). It is gitignored.
   - Recommendation: Delete it. The CLI wrapper already exports everything needed. The repo `.env` only causes confusion. If someone runs `docker compose up` without the CLI wrapper, they should get an error (missing auth), not silently use a stale secret.

3. **Should `env_file` use a separate secrets-only file vs the existing `.env`?**
   - What we know: `~/.claude-secure/.env` contains both auth tokens and secrets.
   - Recommendation: Use the single `.env` file. Splitting into `.env` (auth) and `secrets.env` (secrets) adds complexity without security benefit -- they have the same permissions and the proxy needs both anyway.

## Sources

### Primary (HIGH confidence)
- Codebase analysis: `docker-compose.yml`, `proxy/proxy.js`, `bin/claude-secure`, `install.sh`, `whitelist.json`
- Docker Compose `env_file` documentation (training data, stable feature since Compose v1)

### Secondary (MEDIUM confidence)
- Docker Compose `.env` auto-loading behavior (training data, well-documented stable feature)
- Docker Compose variable precedence: `environment:` > `env_file:` > Dockerfile `ENV` (training data)

## Metadata

**Confidence breakdown:**
- Current state analysis: HIGH - based on direct codebase reading
- env_file mechanism: HIGH - Docker Compose stable feature, well-documented
- Pitfalls: HIGH - based on known Docker Compose behaviors
- Architecture recommendation: HIGH - straightforward application of existing Docker Compose features

**Research date:** 2026-04-10
**Valid until:** 2026-05-10 (stable Docker Compose features, unlikely to change)
