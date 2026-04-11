# Phase 10: Automate Pre-Push Tests - Research

**Researched:** 2026-04-11
**Domain:** Git hooks, Bash scripting, Docker Compose multi-instance, test orchestration
**Confidence:** HIGH

## Summary

Phase 10 hardens the existing naive `git-hooks/pre-push` into a production-ready test gate with smart test selection, dedicated test instance isolation, clean-state guarantees, and structured failure output. The domain is entirely Bash scripting + Docker Compose orchestration -- no new libraries or tools are needed. The existing codebase already has all the building blocks: 7 test scripts following a consistent `report()` pattern, a multi-instance CLI with `COMPOSE_PROJECT_NAME` isolation, and an installer that copies hooks from `git-hooks/`.

The primary challenge is the file-to-test mapping (deciding which test suites to run based on `git diff`), the test instance lifecycle (dedicated compose project with its own `.env`), and the clean-state teardown/rebuild between suites. All of these are straightforward Bash engineering with no external dependencies.

**Primary recommendation:** Replace `git-hooks/pre-push` with a smart hook that uses a static mapping file (`tests/test-map.json`) to select test suites based on changed paths, manages a dedicated `claude-test` compose instance, runs full `docker compose down && up` between suites, and produces a summary table with requirement IDs on failure.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Smart subset based on `git diff` -- map changed files to relevant test suites (e.g., `proxy/` changes -> `test-phase3.sh`, `claude/` changes -> `test-phase1.sh`)
- **D-02:** Override with `RUN_ALL_TESTS=1` env var to force all tests regardless of changes
- **D-03:** When no files match any known test mapping (docs-only, `.planning/` only), skip tests and allow push
- **D-04:** Dedicated `test` instance with its own compose project, isolated from user's running instances. Hook auto-starts the test instance if not already running.
- **D-05:** Teardown on success only -- leave containers up on failure for debugging, `docker compose down` on success
- **D-06:** Pre-push hook is local-only. CI pipeline is a separate concern for a future phase. No shared test runner needed.
- **D-07:** On failure, show a summary table of requirement IDs with PASS/FAIL status per suite, then block the push.
- **D-08:** Each test suite starts with identical preconditions -- full `docker compose down && up` between suites guarantees clean state
- **D-09:** Test instance uses its own `.env` with test-appropriate credentials (dummy keys, test secrets)

### Claude's Discretion
- File-to-test mapping design (static config file vs. convention-based detection)
- Summary table format and styling

### Deferred Ideas (OUT OF SCOPE)
- CI pipeline integration (GitHub Actions) -- separate future phase
- Parallel test execution with isolated compose projects
- Lightweight reset script between suites
</user_constraints>

## Standard Stack

### Core
| Technology | Version | Purpose | Why Standard |
|------------|---------|---------|--------------|
| Bash | 5.x | Hook script, test runner orchestration | Already used for all hooks and test scripts. No new dependency. |
| jq | 1.7+ | Parse test-map.json, aggregate results | Already a project dependency. Best tool for JSON in shell. |
| Docker Compose | v2.24+ | Test instance lifecycle, `down`/`up` between suites | Already used. `COMPOSE_PROJECT_NAME` provides instance isolation. |
| git | 2.x | `git diff` for changed file detection | Already available. Standard for pre-push hooks. |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| `uuidgen` | Not needed this phase | -- |
| `curl` | Not needed this phase (tests use it internally) | -- |

**No installation needed.** All tools are already present in the project and on the host.

## Architecture Patterns

### Recommended Project Structure
```
git-hooks/
  pre-push              # Smart hook (REPLACES current naive version)
tests/
  test-map.json         # Static file-to-test mapping config
  test-phase1.sh        # (existing, unchanged)
  test-phase2.sh        # (existing, unchanged)
  test-phase3.sh        # (existing, unchanged)
  test-phase4.sh        # (existing, unchanged)
  test-phase6.sh        # (existing, unchanged)
  test-phase7.sh        # (existing, unchanged)
  test-phase9.sh        # (existing, unchanged)
  test-env.sh           # Test .env template for test instance
```

### Pattern 1: Static File-to-Test Mapping (Recommended for Claude's Discretion)

**What:** A JSON file that maps directory/file glob patterns to test suites.
**Why over convention-based:** Explicit is better than implicit. Some tests cover cross-cutting concerns (e.g., test-phase7.sh tests env-file strategy which spans proxy + claude + compose). A static mapping makes these relationships visible and editable.

**Example `tests/test-map.json`:**
```json
{
  "mappings": [
    { "paths": ["claude/", "claude/**"], "tests": ["test-phase1.sh", "test-phase2.sh"] },
    { "paths": ["proxy/", "proxy/**"], "tests": ["test-phase1.sh", "test-phase3.sh"] },
    { "paths": ["validator/", "validator/**"], "tests": ["test-phase1.sh", "test-phase2.sh"] },
    { "paths": ["docker-compose.yml"], "tests": ["test-phase1.sh"] },
    { "paths": ["config/whitelist.json"], "tests": ["test-phase1.sh", "test-phase3.sh"] },
    { "paths": ["install.sh"], "tests": ["test-phase4.sh"] },
    { "paths": ["bin/claude-secure"], "tests": ["test-phase9.sh"] },
    { "paths": ["git-hooks/**"], "tests": ["test-phase2.sh"] }
  ],
  "always_skip": [".planning/", "*.md", ".claude/", ".git/"]
}
```

**How to use in Bash:**
```bash
# Get changed files relative to remote
CHANGED_FILES=$(git diff --name-only "$(git merge-base HEAD @{u})" HEAD 2>/dev/null)
# If no upstream tracking, diff against main
if [ -z "$CHANGED_FILES" ]; then
  CHANGED_FILES=$(git diff --name-only "$(git merge-base HEAD main)" HEAD 2>/dev/null)
fi

# Match changed files against mappings using jq
SELECTED_TESTS=$(echo "$CHANGED_FILES" | while read -r file; do
  jq -r --arg f "$file" '
    .mappings[] | select(.paths[] as $p | $f | startswith($p | rtrimstr("**") | rtrimstr("/"))) | .tests[]
  ' tests/test-map.json
done | sort -u)
```

### Pattern 2: Dedicated Test Instance via COMPOSE_PROJECT_NAME

**What:** Use `COMPOSE_PROJECT_NAME=claude-test` to create an isolated Docker environment.
**Why:** The existing CLI uses `COMPOSE_PROJECT_NAME="claude-${INSTANCE}"` (line 161 of `bin/claude-secure`). Using `claude-test` follows this convention and ensures test containers never collide with running dev instances.

**Key environment variables for test instance:**
```bash
export COMPOSE_PROJECT_NAME="claude-test"
export COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"
export SECRETS_FILE="$REPO_ROOT/tests/test-env.sh"  # or test.env
export WHITELIST_PATH="$REPO_ROOT/config/whitelist.json"
export WORKSPACE_PATH="$TMPDIR/claude-test-workspace"
export LOG_DIR="$TMPDIR/claude-test-logs"
```

### Pattern 3: Clean State Between Suites (D-08)

**What:** Full `docker compose down && docker compose up -d --wait` between each test suite.
**Why:** User explicitly required identical preconditions. Reliability over speed.

```bash
for test_script in "${SELECTED_TESTS[@]}"; do
  # Clean slate
  docker compose down --volumes --remove-orphans 2>/dev/null
  docker compose up -d --wait --timeout 30 || { echo "FATAL: containers failed to start"; FATAL=1; break; }
  
  # Run test
  bash "$test_script"
  # ... collect results
done
```

Note: `--volumes` is needed to clear `validator-db` volume between suites. Without it, SQLite state leaks between tests.

### Pattern 4: Summary Table with Requirement IDs (D-07)

**What:** Parse test output to extract requirement ID results and display a summary table.
**Why:** The existing `report()` function in each test script outputs lines like:
```
  DOCK-01  Claude container has no direct internet access              PASS
```

This is parseable. The hook can capture stdout, grep for PASS/FAIL lines, and build a summary.

```bash
# Capture test output
OUTPUT=$(bash "$test_script" 2>&1)
EXIT_CODE=$?
echo "$OUTPUT"

# Extract results (fields: ID, description, PASS/FAIL)
echo "$OUTPUT" | grep -E '(PASS|FAIL)$' >> "$RESULTS_FILE"
```

### Anti-Patterns to Avoid
- **Running tests against user's live instance:** Never use the user's running `claude-{instance}` containers. Always use `claude-test` project.
- **Skipping `--volumes` on teardown:** Leaves SQLite state in `validator-db` volume, causing false passes/failures in subsequent suites.
- **Using `docker compose restart` instead of full down/up:** Does not reset volumes or environment changes made during tests (e.g., test-phase3.sh modifies whitelist.json on host).
- **Hardcoding container names:** Container names depend on `COMPOSE_PROJECT_NAME`. Use `docker compose exec` not `docker exec claude-secure`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON config parsing in Bash | Custom awk/sed parser | `jq` | Already a dependency. Handles edge cases (spaces in paths, special chars). |
| Git changed-file detection | Custom diff parser | `git diff --name-only` with merge-base | Standard git plumbing. Handles rebases, merge commits correctly. |
| Container isolation | iptables rules, network namespaces | `COMPOSE_PROJECT_NAME` | Docker Compose handles all isolation. One env var. |
| Test output parsing | Custom regex engine | `grep -E '(PASS\|FAIL)$'` on report() output | The existing `report()` function produces parseable output by design. |

## Common Pitfalls

### Pitfall 1: Pre-push Hook Receives Refs on Stdin
**What goes wrong:** The pre-push hook receives pushed ref information on stdin (local ref, local SHA, remote ref, remote SHA). If the hook reads stdin for other purposes (e.g., user prompts), it consumes the ref data.
**Why it happens:** Git pipes ref info to the hook's stdin per the githooks(5) spec.
**How to avoid:** Read stdin into a variable at the top of the hook, then use it for determining what changed. Never use interactive `read` in a pre-push hook.
**Warning signs:** Hook works with `git push` but not `git push origin main` (different ref formats).

```bash
# Correct: read refs from stdin immediately
while read -r local_ref local_sha remote_ref remote_sha; do
  # Use these to determine changed files
  CHANGED_FILES=$(git diff --name-only "$remote_sha" "$local_sha" 2>/dev/null)
done
```

### Pitfall 2: Merge-Base Detection for New Branches
**What goes wrong:** `git diff --name-only @{u}..HEAD` fails when pushing a new branch (no upstream tracking ref).
**Why it happens:** New branches have no `@{u}` (upstream) configured yet.
**How to avoid:** Fall back to `git merge-base HEAD main` or use the remote SHA from stdin (which is `0000000...` for new remote refs).
**Warning signs:** Hook crashes on first push of a new branch.

### Pitfall 3: Test Scripts Assume Default Container Names
**What goes wrong:** Test scripts use `docker exec claude-secure` (hardcoded), but the test instance containers are named `claude-test-claude-1`.
**Why it happens:** Container names include `COMPOSE_PROJECT_NAME` prefix.
**How to avoid:** Existing test scripts already use `docker compose` commands for some operations but also use `docker exec claude-secure` directly. The test scripts need to either: (a) be updated to use `docker compose exec claude` instead, or (b) the hook must set container name aliases.
**Warning signs:** "No such container: claude-secure" errors during test runs.

**CRITICAL:** This is the biggest implementation risk. All 7 test scripts use `docker exec claude-secure`, `docker exec claude-proxy`, `docker exec claude-validator` directly. Under `COMPOSE_PROJECT_NAME=claude-test`, containers are named `claude-test-claude-1`, `claude-test-proxy-1`, `claude-test-validator-1`. **Every test script will need to be updated to use `docker compose exec <service>` or the `container_name:` directive must be set dynamically.**

**Recommended approach:** Use `docker compose exec` consistently. It respects `COMPOSE_PROJECT_NAME` automatically. This requires updating `docker exec claude-secure` -> `docker compose exec claude` across all test scripts. However, note that `docker compose exec` does not support `-d` (detach) the same way -- for background processes (mock upstream in test-phase3.sh), use `docker compose exec -d`.

Actually, `docker compose exec` DOES support `-d` for detached mode. The migration is:
- `docker exec claude-secure CMD` -> `docker compose exec claude CMD`
- `docker exec -d claude-proxy CMD` -> `docker compose exec -d proxy CMD`
- `docker exec claude-proxy CMD` -> `docker compose exec proxy CMD`
- `docker inspect claude-secure` -> `docker inspect $(docker compose ps -q claude)`

### Pitfall 4: Whitelist.json Modification During Tests
**What goes wrong:** test-phase3.sh modifies `config/whitelist.json` on the host (for SECR-04 hot-reload test) and restores it afterward. If the test is interrupted, the whitelist is left in a modified state.
**Why it happens:** The test uses a `trap cleanup EXIT` but only restores if it reaches that code.
**How to avoid:** The test instance should use its own copy of `whitelist.json`, not the main project copy. Set `WHITELIST_PATH` to a test-specific copy.

### Pitfall 5: Docker Compose Down Timeout
**What goes wrong:** `docker compose down` hangs waiting for containers to stop gracefully.
**Why it happens:** Some containers (especially with `sleep infinity`) ignore SIGTERM.
**How to avoid:** Use `docker compose down --timeout 5` to limit wait time.

### Pitfall 6: Volume Cleanup Between Suites
**What goes wrong:** `validator-db` volume persists SQLite data between test suites, causing stale call-ID entries.
**Why it happens:** `docker compose down` without `--volumes` preserves named volumes.
**How to avoid:** Use `docker compose down --volumes --remove-orphans` between suites.

## Code Examples

### Pre-push Hook Skeleton
```bash
#!/bin/bash
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TEST_MAP="$REPO_ROOT/tests/test-map.json"
TEST_DIR="$REPO_ROOT/tests"

# Read refs from stdin (git pre-push protocol)
CHANGED_FILES=""
while read -r local_ref local_sha remote_ref remote_sha; do
  if [ "$remote_sha" = "0000000000000000000000000000000000000000" ]; then
    # New remote branch -- diff against main
    FILES=$(git diff --name-only "$(git merge-base HEAD main)" HEAD 2>/dev/null)
  else
    FILES=$(git diff --name-only "$remote_sha" "$local_sha" 2>/dev/null)
  fi
  CHANGED_FILES="$CHANGED_FILES"$'\n'"$FILES"
done

# Deduplicate
CHANGED_FILES=$(echo "$CHANGED_FILES" | sort -u | sed '/^$/d')

# Check for RUN_ALL_TESTS override
if [ "${RUN_ALL_TESTS:-0}" = "1" ]; then
  SELECTED_TESTS=("$TEST_DIR"/test-phase*.sh)
else
  # Match against test map
  # ... jq logic to resolve CHANGED_FILES -> test scripts
  # If no matches, exit 0 (allow push)
fi
```

### Test Instance Environment Template (`tests/test.env`)
```bash
# Test instance credentials -- dummy values only
ANTHROPIC_API_KEY=test-api-key-for-integration-tests
CLAUDE_CODE_OAUTH_TOKEN=
GITHUB_TOKEN=ghp_test_secret_value_12345
STRIPE_KEY=sk_test_stripe_secret_67890
OPENAI_API_KEY=sk-test-openai-secret-abcde
```

### Summary Table Output Format
```
========================================
  Pre-Push Test Results
========================================

Suite            Req IDs              Status
-----------      --------             ------
test-phase1      DOCK-01..06,WHIT-*   PASS
test-phase2      CALL-01..07          PASS
test-phase3      SECR-01..05          FAIL

  Failed requirements:
  SECR-04   Config hot-reload: removed secret no longer redacted    FAIL
  SECR-04b  Config hot-reload: restored secret is redacted again    FAIL

========================================
Push blocked: 1 suite(s) failed.
========================================
```

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash + Docker Compose integration tests |
| Config file | `tests/test-map.json` (new, created this phase) |
| Quick run command | `RUN_ALL_TESTS=1 bash git-hooks/pre-push < /dev/null` |
| Full suite command | `RUN_ALL_TESTS=1 bash git-hooks/pre-push < /dev/null` |

### Phase Requirements -> Test Map

Phase 10 has no formal requirement IDs assigned (listed as `null`). Testing is behavioral:

| Behavior | Test Type | How to Verify |
|----------|-----------|---------------|
| Smart test selection based on changed files | manual | Change a proxy file, run hook, verify only proxy-related suites execute |
| `RUN_ALL_TESTS=1` runs all suites | manual | `RUN_ALL_TESTS=1 git push` or `RUN_ALL_TESTS=1 bash git-hooks/pre-push < /dev/null` |
| Docs-only changes skip tests | manual | Change only `.planning/` files, verify hook exits 0 with skip message |
| Dedicated test instance isolation | manual | Run hook while another instance is active, verify no collision |
| Full teardown between suites | manual | Observe `docker compose down --volumes` between each suite in output |
| Summary table on failure | manual | Introduce a deliberate test failure, verify table output |
| Containers left up on failure | manual | After failed push, verify `docker compose -p claude-test ps` shows running containers |
| Containers torn down on success | manual | After successful push, verify `docker compose -p claude-test ps` shows nothing |

### Wave 0 Gaps
- None -- no test framework to install. This phase creates the test orchestration itself.

## Open Questions

1. **Container name hardcoding in existing test scripts**
   - What we know: All 7 test scripts use `docker exec claude-secure`, `docker exec claude-proxy`, etc. with hardcoded names. Under `COMPOSE_PROJECT_NAME=claude-test`, these names won't exist.
   - What's unclear: Should we update all test scripts to use `docker compose exec` (breaking change for manual test runs), or should we add `container_name:` to docker-compose.yml (but that prevents multi-instance)?
   - Recommendation: Update test scripts to use `docker compose exec <service>`. This is the correct approach since `docker compose exec` automatically respects `COMPOSE_PROJECT_NAME`. The hook should export `COMPOSE_PROJECT_NAME` and `COMPOSE_FILE` before calling test scripts. Manual test runs already set these via `docker compose up`. This is the cleanest solution.

2. **test-phase3.sh modifies host whitelist.json**
   - What we know: SECR-04 test modifies `config/whitelist.json` on the host to test hot-reload. It restores in a trap.
   - What's unclear: Should the test instance use a separate copy of whitelist.json?
   - Recommendation: Yes. Copy `config/whitelist.json` to a temp location, set `WHITELIST_PATH` to the copy. Test-phase3.sh can safely modify it without affecting the repo. This aligns with D-09 (test instance has own config).

3. **Pre-push hook stdin handling with no-op pushes**
   - What we know: If nothing is being pushed (e.g., already up to date), git may not pipe anything to stdin.
   - Recommendation: Handle empty stdin gracefully -- if no refs received, exit 0.

## Sources

### Primary (HIGH confidence)
- Existing codebase: `git-hooks/pre-push`, all 7 `tests/test-phase*.sh`, `bin/claude-secure`, `docker-compose.yml`, `install.sh`
- Git documentation: githooks(5) pre-push hook spec -- receives `<local ref> <local SHA> <remote ref> <remote SHA>` on stdin
- Docker Compose documentation: `COMPOSE_PROJECT_NAME` isolation, `docker compose exec` service resolution

### Secondary (MEDIUM confidence)
- Training data on Bash pre-push hook patterns, `git diff --name-only` with merge-base
- Training data on Docker Compose named volume cleanup behavior

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - all tools already in use, no new dependencies
- Architecture: HIGH - follows existing patterns (multi-instance, test scripts, report function)
- Pitfalls: HIGH - identified from direct code inspection of existing test scripts (container name hardcoding is verified)

**Research date:** 2026-04-11
**Valid until:** 2026-05-11 (stable domain, no rapidly changing dependencies)
