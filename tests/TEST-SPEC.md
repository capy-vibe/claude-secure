# Test Specification

64 integration tests across 7 suites covering all security layers of claude-secure.

## Infrastructure

### Test Runner (`run-tests.sh`)

```bash
./run-tests.sh                              # Run all suites
./run-tests.sh test-phase2.sh test-phase3.sh  # Run specific suites
```

- Isolated Docker Compose instance: `COMPOSE_PROJECT_NAME=claude-test`
- Dummy credentials via `tests/test.env` (never real secrets)
- Temp whitelist copy with `chmod 666` (container-writable for hot-reload tests)
- `docker compose down --volumes` between suites for clean state
- Each suite manages its own container lifecycle (build, up, health check)

### Smart Pre-Push Hook (`git-hooks/pre-push`)

Runs automatically on `git push`. Selects relevant suites based on changed files via `tests/test-map.json`:

| Changed Path | Triggers |
|-------------|----------|
| `proxy/` | test-phase1, test-phase3 |
| `claude/` | test-phase1, test-phase2 |
| `validator/` | test-phase1, test-phase2 |
| `config/whitelist.json` | test-phase1, test-phase3 |
| `install.sh` | test-phase4 |
| `bin/claude-secure` | test-phase9 |
| `git-hooks/` | test-phase2 |
| `tests/test-phase*.sh` | self (matching suite) |

Skip patterns: `*.md`, `.planning/`, `.claude/`, `.git/`
Safety fallback: unmapped files trigger all suites.
Override: `RUN_ALL_TESTS=1 git push` or skip with `git push --no-verify`.

### Test Mechanism Patterns

| Pattern | Used By | Purpose |
|---------|---------|---------|
| `docker compose exec -T claude <cmd>` | Phase 1, 2, 3, 7 | Run commands inside containers |
| `echo '{json}' \| docker compose exec -T claude /etc/claude-secure/hooks/pre-tool-use.sh` | Phase 2 | Simulate Claude Code tool calls |
| Mock HTTP upstream via `node -e` inside proxy container | Phase 3 | Capture requests the proxy forwards upstream |
| `docker-compose.test-phase3.yml` override | Phase 3 | Inject test secrets and mock upstream URL |
| `source install.sh` + call functions in subshell | Phase 4 | Test installer functions in isolation |
| Temp directories with controlled `HOME` | Phase 9 | Test CLI without touching real config |
| `jq` assertions on JSON output | All | Validate structured data |

---

## Phase 1: Docker Infrastructure (10 tests)

**File:** `tests/test-phase1.sh`
**Covers:** Container isolation, networking, permissions, whitelist config.

| ID | Test | How |
|----|------|-----|
| DOCK-01 | Claude container has no direct internet access | `curl` to external URL from claude fails |
| DOCK-02 | Proxy container can reach external URLs | Node.js `https.get` to httpbin.org from proxy succeeds |
| DOCK-03 | Docker Compose runs all 3 containers | `docker compose ps` returns exactly 3 services |
| DOCK-04 | Outbound connections from claude are blocked | `curl` to non-whitelisted domain from claude fails |
| DOCK-05 | Security files are root-owned and read-only | `stat` on hook (root 555), settings (root 444), whitelist mount (RW=false) |
| DOCK-05b | settings.json accessible via symlink | `cat` + `jq` reads hooks config through symlink path |
| DOCK-06 | Capabilities dropped, no-new-privileges set | `docker inspect` checks CapDrop=ALL, SecurityOpt=no-new-privileges |
| WHIT-01 | Whitelist maps placeholders to env vars and domains | `jq` validates secrets array has placeholder, env_var, allowed_domains |
| WHIT-02 | Whitelist has readonly_domains section | `jq` checks key exists |
| WHIT-03 | Whitelist is read-only inside claude container | `test ! -w` on mounted whitelist path |

## Phase 2: Call Validation (13 tests)

**File:** `tests/test-phase2.sh`
**Covers:** PreToolUse hook behavior, validator call-ID lifecycle, iptables enforcement.

| ID | Test | How |
|----|------|-----|
| CALL-01 | Hook allows non-network Bash commands | Pipe `{"tool_name":"Bash","command":"echo hello"}` to hook, expect allow |
| CALL-02 | Hook extracts domain from curl GET | Pipe curl GET to example.com, expect allow (read-only) |
| CALL-02b | Hook extracts domain from WebFetch | Pipe WebFetch tool JSON, expect allow |
| CALL-03 | Hook blocks POST to non-whitelisted domain | Pipe curl POST to evil.com, expect deny with "non-whitelisted" |
| CALL-03b | Hook blocks POST with --data flag | Pipe curl with `--data @file`, expect deny |
| CALL-03c | Hook blocks obfuscated URLs | Pipe curl with `${EVIL_DOMAIN}`, expect deny with "obfuscation" |
| CALL-04 | Hook allows GET to any domain | Pipe curl GET to random-site.org, expect allow |
| CALL-04b | WebSearch allowed without registration | Pipe WebSearch tool JSON, expect allow |
| CALL-05 | Hook registers call-ID for whitelisted payload | Pipe curl POST to api.github.com (whitelisted), expect allow (proves registration succeeded) |
| CALL-06 | Validator single-use call-ID enforcement | Register UUID, validate once (true), validate again (false) |
| CALL-07 | iptables blocks outbound without call-ID | `curl` to 8.8.8.8 from claude fails (DROP rule) |
| CALL-07b | iptables allows traffic to proxy | Extract proxy IP from iptables, curl succeeds |
| CALL-06b | Validator rejects expired call-IDs (10s TTL) | Register UUID, sleep 12s, validate returns false |

## Phase 3: Secret Redaction (8 tests)

**File:** `tests/test-phase3.sh`
**Covers:** Proxy redaction, placeholder restoration, config hot-reload, auth forwarding.
**Setup:** Docker Compose override injects test secrets + mock upstream on port 9999 inside proxy.

| ID | Test | How |
|----|------|-----|
| SECR-01 | Proxy intercepts Claude-to-Anthropic traffic | POST to proxy:8080/v1/messages returns HTTP 200 |
| SECR-02 | Secret values replaced with placeholders | Send request with github+stripe tokens, mock upstream log shows PLACEHOLDER_* not real values |
| SECR-02b | All three secrets redacted in single request | Send all three secrets, verify all three placeholders in upstream log |
| SECR-03 | Placeholders restored to real values in responses | Mock upstream returns placeholders, claude receives real secret values |
| SECR-04 | Config hot-reload: removed secret passes through | Remove GITHUB entry from whitelist inside container, send token, upstream sees real value |
| SECR-04b | Config hot-reload: restored secret redacted again | Restore whitelist, send token, upstream sees PLACEHOLDER_GITHUB |
| SECR-05 | Proxy's API key forwarded, claude's stripped | Claude sends x-api-key header, upstream receives proxy's key instead |
| SECR-05b | Auth mode correctly reported | Proxy logs report "API key" mode when no OAuth token set |

## Phase 4: Installation & Platform (12 tests)

**File:** `tests/test-phase4.sh`
**Covers:** Installer script syntax, dependency checking, platform detection, auth setup, Docker validation.

| ID | Test | How |
|----|------|-----|
| INST-01 | Installer has valid bash syntax | `bash -n install.sh` |
| INST-01b | Dependency checker covers all tools | Grep for docker, curl, jq, uuidgen, compose v2 checks |
| INST-01c | check_dependencies passes on host | Source install.sh, call function, assert exit 0 |
| INST-02 | Platform detection sets PLATFORM | Call `detect_platform`, check PLATFORM is "linux" or "wsl2" |
| PLAT-03 | Platform detection checks iptables version | Grep install.sh for `iptables -V` |
| INST-03 | Auth setup writes .env with 600 permissions | Call `setup_auth` in temp dir, verify file + `chmod 600` |
| INST-04 | setup_directories creates dir with 700 | Call function in temp dir, verify permissions |
| INST-05 | docker-compose.yml validates | `docker compose config --quiet` |
| INST-05b | Docker images build successfully | `docker compose build --quiet` |
| INST-06 | CLI wrapper has valid syntax and subcommands | `bash -n` + grep for expected patterns |
| PLAT-01 | All 3 containers start and run | `docker compose up -d --wait`, count = 3 |
| PLAT-02 | Proxy reachable from claude container | curl from claude to proxy:8080 returns HTTP response |

## Phase 6: Service Logging (7 tests)

**File:** `tests/test-phase6.sh`
**Covers:** JSONL log output per service, log format, log disable, CLI logs subcommand.

| ID | Test | How |
|----|------|-----|
| LOG-01 | Hook writes JSONL when LOG_HOOK=1 | Trigger hook, check hook.jsonl exists and non-empty |
| LOG-02 | Proxy writes JSONL when LOG_ANTHROPIC=1 | Make request through proxy, check anthropic.jsonl |
| LOG-03 | Validator writes JSONL when LOG_IPTABLES=1 | Start containers, check iptables.jsonl |
| LOG-04 | All three JSONL files in unified host directory | Check all three files exist in LOG_DIR |
| LOG-05 | Log entries have ts, svc, level, msg fields | `jq -e '.ts and .svc and .level and .msg'` on each log |
| LOG-06 | No logs created when logging disabled | Restart with LOG_*=0, verify no log files |
| LOG-07 | logs subcommand exists in CLI | Grep bin/claude-secure for `logs)` and `tail -f` |

## Phase 7: Env-File Strategy (5 tests)

**File:** `tests/test-phase7.sh`
**Covers:** Dynamic secret loading via env_file, secret propagation, minimal config operation.

| ID | Test | How |
|----|------|-----|
| ENV-01 | Secrets from env_file available in proxy | `printenv TEST_SECRET_ALPHA` inside proxy matches expected value |
| ENV-02 | New secret works without docker-compose.yml edit | TEST_SECRET_ALPHA not in compose file but available in container |
| ENV-03 | Claude container has secret env vars for tooling | `env` inside claude shows TEST_SECRET_ALPHA and GITHUB_TOKEN |
| ENV-04 | Proxy has secrets and whitelist for redaction | `printenv` + `jq` verify proxy has both token and config |
| ENV-05 | System starts with auth-only .env | Restart with minimal .env, proxy runs, secret vars absent |

## Phase 9: Multi-Instance Support (9 tests)

**File:** `tests/test-phase9.sh`
**Covers:** CLI instance management, name validation, config isolation, migration.
**Note:** No Docker containers started. Tests run against CLI wrapper with temp directories.

| ID | Test | How |
|----|------|-----|
| MULTI-01 | --instance flag required | Run CLI without flag, expect error exit + message |
| MULTI-02 | DNS-safe instance name validation | Bash regex `^[a-z0-9][a-z0-9-]*$` against valid/invalid names |
| MULTI-03 | Migration from single-instance layout | Create old layout, trigger migration, verify new structure |
| MULTI-04 | COMPOSE_PROJECT_NAME isolation | No hardcoded container_name, different project names produce different configs |
| MULTI-05 | Per-instance config files are independent | Create two instances, verify separate config.sh, .env, whitelist.json |
| MULTI-06 | LOG_PREFIX in compose and all services | Grep compose + proxy + validator + hook for LOG_PREFIX usage |
| MULTI-07 | list command shows all instances | Create foo/bar instances, `claude-secure list` shows both |
| MULTI-08 | Instance auto-creation directory structure | Verify created instance has config.sh, .env (600), whitelist.json |
| MULTI-09 | Global config scope (APP_DIR and PLATFORM only) | Verify global config excludes WORKSPACE_PATH, CLI loads both configs |
