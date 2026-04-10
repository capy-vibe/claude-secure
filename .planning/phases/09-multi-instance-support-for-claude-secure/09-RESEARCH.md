# Phase 9: Multi-Instance Support for claude-secure - Research

**Researched:** 2026-04-10
**Domain:** Docker Compose multi-instance orchestration, Bash CLI design, config management
**Confidence:** HIGH

## Summary

Phase 9 transforms claude-secure from a single-instance tool into one that supports multiple simultaneous isolated environments. The core technical mechanism is Docker Compose's `COMPOSE_PROJECT_NAME`, which automatically prefixes all resource names (containers, networks, volumes) with the project name, providing complete isolation between instances without any changes to the compose file's service definitions.

The main work areas are: (1) removing hardcoded `container_name` directives from `docker-compose.yml`, (2) refactoring `bin/claude-secure` to accept `--instance NAME` and route all operations through instance-scoped config and COMPOSE_PROJECT_NAME, (3) restructuring `~/.claude-secure/` to support per-instance config directories, and (4) adding a migration path for existing single-instance users.

**Primary recommendation:** Use `COMPOSE_PROJECT_NAME=claude-{instance}` as the isolation primitive. Remove all `container_name` directives. Restructure config to `~/.claude-secure/instances/{name}/`. All CLI commands require `--instance NAME` with no default.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Users specify instances with `--instance NAME` flag on all commands (e.g., `claude-secure --instance myproject`, `claude-secure stop --instance myproject`)
- **D-02:** Instance names are user-chosen, must be DNS-safe (lowercase, alphanumeric, hyphens)
- **D-03:** `--instance` is always required -- no default instance, no last-used tracking. Prevents accidental operations on wrong instance.
- **D-04:** Existing single-instance setups auto-migrate to an instance named `default` on first run after upgrade
- **D-05:** Each instance gets its own Docker networks (e.g., `claude-internal-{name}`, `claude-external-{name}`) -- full network isolation between instances
- **D-06:** Each instance has its own whitelist.json and .env -- fully independent secrets and domain configuration
- **D-07:** Log files use shared directory `~/.claude-secure/logs/` with instance-name prefix (e.g., `myapp-hook.jsonl`, `myapp-anthropic.jsonl`)
- **D-08:** Minimal new commands: existing commands gain `--instance` flag, plus new `claude-secure list` subcommand
- **D-09:** Instance auto-created on first use -- `claude-secure --instance foo` prompts for workspace path if instance doesn't exist, copies initial whitelist.json template and .env template
- **D-10:** `claude-secure list` shows table with instance name, running/stopped status, and workspace path
- **D-11:** `~/.claude-secure/instances/{name}/` subdirectory per instance containing config.sh, .env, whitelist.json
- **D-12:** Global config stays at `~/.claude-secure/config.sh` (APP_DIR, PLATFORM)
- **D-13:** Shared logs directory at `~/.claude-secure/logs/` with instance-prefixed filenames

### Claude's Discretion
- Docker Compose multi-instance strategy (COMPOSE_PROJECT_NAME vs templated compose files vs other approach)
- Container naming convention for multi-instance (remove hardcoded container_name or parameterize)
- Migration script implementation details for existing single-instance users
- Whether `claude-secure remove --instance X` is needed or just `stop` + manual cleanup

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

## Standard Stack

No new libraries or dependencies are required. This phase is purely refactoring existing Bash scripts and Docker Compose configuration.

### Core Technologies (unchanged)
| Technology | Version | Purpose | Notes for This Phase |
|------------|---------|---------|---------------------|
| Docker Compose | v2.24+ | Multi-container orchestration | `COMPOSE_PROJECT_NAME` env var provides instance isolation |
| Bash | 5.x | CLI wrapper and installer | `--instance` flag parsing, instance config management |
| Docker Engine | 24.x+ | Container runtime | No changes needed at engine level |

### Key Docker Compose Mechanism: COMPOSE_PROJECT_NAME

Setting `COMPOSE_PROJECT_NAME=claude-{instance}` causes Docker Compose to prefix all auto-generated resource names:
- Containers: `claude-{instance}-{service}-1` (e.g., `claude-myproject-claude-1`)
- Networks: `claude-{instance}_claude-internal`, `claude-{instance}_claude-external`
- Volumes: `claude-{instance}_workspace`, `claude-{instance}_validator-db`

This provides complete isolation between instances with zero changes to service definitions in docker-compose.yml (beyond removing `container_name`).

**Confidence:** HIGH -- Docker Compose project name prefixing is a well-documented, stable feature used in CI/CD and multi-tenant deployments. Verified via Docker official docs.

## Architecture Patterns

### Current Config Directory Layout
```
~/.claude-secure/
  config.sh          # APP_DIR, PLATFORM, WORKSPACE_PATH
  .env               # Auth credentials + secrets
  whitelist.json     # Symlink to app/config/whitelist.json
  logs/              # All log files (flat)
  app -> /path/to/claude-secure/  # Symlink to project
```

### Target Config Directory Layout (D-11, D-12, D-13)
```
~/.claude-secure/
  config.sh                      # GLOBAL: APP_DIR, PLATFORM only
  app -> /path/to/claude-secure/ # Unchanged
  logs/                          # SHARED: instance-prefixed files
    myproject-hook.jsonl
    myproject-anthropic.jsonl
    myproject-iptables.jsonl
    work-hook.jsonl
    work-anthropic.jsonl
  instances/
    myproject/
      config.sh                  # WORKSPACE_PATH for this instance
      .env                       # Auth + secrets for this instance
      whitelist.json             # Whitelist for this instance
    work/
      config.sh
      .env
      whitelist.json
```

### Pattern 1: COMPOSE_PROJECT_NAME for Instance Isolation (Recommended)

**What:** Set `COMPOSE_PROJECT_NAME=claude-{instance}` before any `docker compose` command. Remove all `container_name` directives from docker-compose.yml. Docker Compose automatically namespaces all resources.

**When to use:** Always -- this is the standard Docker Compose approach for running multiple copies of the same application.

**Why this over alternatives:**
- Templated compose files: Unnecessary complexity. COMPOSE_PROJECT_NAME achieves the same isolation with zero file duplication.
- Per-instance compose files: Maintenance nightmare. One compose file is the single source of truth.

**Key behaviors:**
- `network_mode: "service:claude"` on validator service -- works correctly because it references the service name, not container name. Docker Compose resolves within the project scope.
- Network names in D-05 (e.g., `claude-internal-{name}`) will actually be `claude-{name}_claude-internal` due to Compose's naming convention. This is functionally equivalent and meets the isolation requirement.
- Volumes are also project-scoped: each instance gets its own `workspace` and `validator-db` volumes.

**Example:**
```bash
# Instance "myproject" starts its own isolated set of containers
COMPOSE_PROJECT_NAME="claude-myproject" docker compose up -d
# Instance "work" runs simultaneously with full isolation
COMPOSE_PROJECT_NAME="claude-work" docker compose up -d
# List containers shows both sets
docker compose ls  # Shows both projects
```

### Pattern 2: Instance-Aware CLI Flag Parsing

**What:** Parse `--instance NAME` as the first flag before subcommand routing. Validate the name is DNS-safe. Load instance-specific config, set COMPOSE_PROJECT_NAME, then proceed with existing command logic.

**Structure:**
```bash
# Parse --instance early
INSTANCE=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

# Validate required
if [ -z "$INSTANCE" ] && [ "${args[0]:-}" != "list" ] && [ "${args[0]:-}" != "help" ]; then
  echo "ERROR: --instance NAME is required" >&2
  exit 1
fi

# Validate DNS-safe
if [[ ! "$INSTANCE" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "ERROR: Instance name must be DNS-safe (lowercase, alphanumeric, hyphens)" >&2
  exit 1
fi

# Set instance paths
INSTANCE_DIR="$CONFIG_DIR/instances/$INSTANCE"
export COMPOSE_PROJECT_NAME="claude-${INSTANCE}"
```

### Pattern 3: Auto-Create Instance on First Use (D-09)

**What:** When `--instance foo` is used and `~/.claude-secure/instances/foo/` doesn't exist, prompt for workspace path, copy template whitelist.json, create empty .env with auth from global or prompt.

**Flow:**
1. Check if `$INSTANCE_DIR` exists
2. If not, prompt: "Instance 'foo' not found. Create it?"
3. Prompt for workspace path
4. Copy `$APP_DIR/config/whitelist.json` to `$INSTANCE_DIR/whitelist.json`
5. Copy or prompt for auth credentials into `$INSTANCE_DIR/.env`
6. Write instance `config.sh` with WORKSPACE_PATH

### Pattern 4: Migration from Single-Instance (D-04)

**What:** On first run after upgrade, detect old layout (`~/.claude-secure/.env` exists but `~/.claude-secure/instances/` doesn't). Move config into `instances/default/`.

**Detection logic:**
```bash
if [ -f "$CONFIG_DIR/.env" ] && [ ! -d "$CONFIG_DIR/instances" ]; then
  # Old single-instance layout detected -- migrate to instances/default/
  migrate_to_multi_instance
fi
```

**Migration steps:**
1. Create `$CONFIG_DIR/instances/default/`
2. Move `$CONFIG_DIR/.env` to `instances/default/.env`
3. Copy (not move) whitelist.json to `instances/default/whitelist.json`
4. Extract WORKSPACE_PATH from old config.sh into `instances/default/config.sh`
5. Rewrite global config.sh to keep only APP_DIR and PLATFORM
6. Print migration notice to user

### Pattern 5: Log File Instance Prefixing (D-07, D-13)

**What:** Pass instance name as environment variable to Docker Compose so containers prefix their log filenames.

**Implementation options:**

Option A (recommended): Set `LOG_PREFIX` env var, containers use it in their log paths.
- Proxy: `const logFile = path.join('/var/log/claude-secure', (process.env.LOG_PREFIX || '') + 'anthropic.jsonl')`
- Validator: Similar pattern in Python
- Hook: `LOG_FILE="/var/log/claude-secure/${LOG_PREFIX:-}hook.jsonl"`

Option B: Mount instance-specific log subdirectory instead of shared directory. Simpler container code but doesn't meet D-13 requirement of shared directory with prefixed filenames.

**Recommendation:** Option A. Add `LOG_PREFIX=${INSTANCE}-` as an exported env var in the CLI wrapper. Pass it through docker-compose.yml as `LOG_PREFIX=${LOG_PREFIX:-}`.

### Anti-Patterns to Avoid

- **Templated compose files per instance:** Creates maintenance burden. One compose file + COMPOSE_PROJECT_NAME is the Docker standard.
- **Hardcoded container_name:** Prevents COMPOSE_PROJECT_NAME from working. Must be removed entirely.
- **Default instance fallback:** D-03 explicitly forbids this. Every command must require `--instance`.
- **Storing instance state in compose file:** All instance-specific state belongs in `~/.claude-secure/instances/{name}/`, not in modified compose files.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Container/network/volume namespacing | Custom naming logic in scripts | `COMPOSE_PROJECT_NAME` | Docker Compose handles all resource prefixing automatically |
| Instance status detection | Manual `docker inspect` parsing | `docker compose --project-name X ps --format json` | Compose knows its own project resources |
| DNS-safe name validation | Complex regex | `[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]` | Docker Compose project name constraints are well-defined |

## Common Pitfalls

### Pitfall 1: container_name Blocks Multi-Instance
**What goes wrong:** With `container_name: claude-secure` in compose file, second instance fails with "container name already in use."
**Why it happens:** `container_name` is an absolute name that ignores COMPOSE_PROJECT_NAME.
**How to avoid:** Remove all three `container_name` directives from docker-compose.yml.
**Warning signs:** "Conflict. The container name X is already in use" error.

### Pitfall 2: cleanup_containers() Hardcodes Names
**What goes wrong:** The current `cleanup_containers()` function hardcodes `claude-proxy`, `claude-secure`, `claude-validator`. After removing container_name, these names no longer exist.
**Why it happens:** The function was written for single-instance with fixed names.
**How to avoid:** Replace with `docker compose --project-name X down --remove-orphans` or use `docker compose` project-scoped cleanup. Alternatively, compute container names from COMPOSE_PROJECT_NAME.
**Warning signs:** cleanup_containers silently fails (containers not found), stale containers accumulate.

### Pitfall 3: Volume Data Isolation After Migration
**What goes wrong:** Existing single-instance has Docker volumes named `claude-secure_workspace` and `claude-secure_validator-db` (using old directory-based project name). After migration, the `default` instance would create new volumes `claude-default_workspace`.
**Why it happens:** COMPOSE_PROJECT_NAME changes the volume prefix.
**How to avoid:** During migration, either (a) rename existing Docker volumes, or (b) set the default instance's COMPOSE_PROJECT_NAME to match the old project name. Option (b) is simpler: use `COMPOSE_PROJECT_NAME=claude-secure` for the `default` instance specifically, since the old naming was directory-based and happened to be `claude-secure` (from running in the `claude-secure` directory). **However**, the actual old project name depends on what directory docker compose was run from. The CLI uses `COMPOSE_FILE` which means Compose uses the directory of the compose file, which is `$APP_DIR` (symlinked to project root). Need to verify: if APP_DIR is a symlink, Compose follows the symlink for the project name. This needs testing during implementation.
**Warning signs:** User's workspace data appears empty after migration.

### Pitfall 4: Whitelist Path in Compose File
**What goes wrong:** docker-compose.yml mounts `./config/whitelist.json` using a relative path. For multi-instance, each instance needs its own whitelist.
**Why it happens:** Relative paths in compose are resolved relative to the compose file location.
**How to avoid:** Change the whitelist mount to use an environment variable: `${WHITELIST_PATH:-./config/whitelist.json}:/etc/claude-secure/whitelist.json:ro`. Set WHITELIST_PATH to the instance's whitelist path in the CLI wrapper.

### Pitfall 5: Log Prefix Must Propagate to All Three Log-Producing Services
**What goes wrong:** Adding LOG_PREFIX to one service but forgetting others. Hook, proxy, and validator all write logs.
**Why it happens:** Logs are written by three separate codebases (bash hook, Node.js proxy, Python validator).
**How to avoid:** Add LOG_PREFIX to the docker-compose.yml environment section for all three services. Update all three log-writing code paths.
**Warning signs:** Some log files are prefixed, others aren't. Shared log directory becomes confusing.

### Pitfall 6: `docker compose ls` vs Per-Instance Status
**What goes wrong:** `claude-secure list` needs to show all instances and their status. Using `docker compose ps` only shows one project at a time.
**Why it happens:** Docker Compose commands are project-scoped.
**How to avoid:** Use `docker compose ls --format json` to list all running projects, then cross-reference with `~/.claude-secure/instances/*/config.sh` to show stopped instances too.

### Pitfall 7: SECRETS_FILE Path Must Be Instance-Specific
**What goes wrong:** `SECRETS_FILE` is used as `env_file` in docker-compose.yml. If it still points to `~/.claude-secure/.env` (old path), all instances share the same secrets.
**Why it happens:** The CLI sets `SECRETS_FILE="$CONFIG_DIR/.env"` which is the global path.
**How to avoid:** Change to `SECRETS_FILE="$INSTANCE_DIR/.env"`.

## Code Examples

### docker-compose.yml Changes Required

```yaml
# BEFORE (single-instance, hardcoded names):
services:
  claude:
    container_name: claude-secure   # REMOVE THIS
    # ...
  proxy:
    container_name: claude-proxy    # REMOVE THIS
    # ...
  validator:
    container_name: claude-validator  # REMOVE THIS
    # ...

# AFTER (multi-instance ready):
services:
  claude:
    # No container_name -- Docker Compose generates from project name
    environment:
      - LOG_PREFIX=${LOG_PREFIX:-}
    volumes:
      - workspace:/workspace
      - ${WHITELIST_PATH:-./config/whitelist.json}:/etc/claude-secure/whitelist.json:ro
      - ${LOG_DIR:-./logs}:/var/log/claude-secure
    # ... rest unchanged

  proxy:
    environment:
      - LOG_PREFIX=${LOG_PREFIX:-}
    volumes:
      - ${WHITELIST_PATH:-./config/whitelist.json}:/etc/claude-secure/whitelist.json:ro
      - ${LOG_DIR:-./logs}:/var/log/claude-secure
    # ... rest unchanged

  validator:
    environment:
      - LOG_PREFIX=${LOG_PREFIX:-}
    volumes:
      - ${WHITELIST_PATH:-./config/whitelist.json}:/etc/claude-secure/whitelist.json:ro
      - ${LOG_DIR:-./logs}:/var/log/claude-secure
    # ... rest unchanged
```

### CLI Instance Loading Pattern

```bash
# After parsing --instance NAME and validating:
INSTANCE_DIR="$CONFIG_DIR/instances/$INSTANCE"

# Load global config (APP_DIR, PLATFORM)
source "$CONFIG_DIR/config.sh"

# Load instance config (WORKSPACE_PATH)
source "$INSTANCE_DIR/config.sh"

# Load instance secrets
set -a
source "$INSTANCE_DIR/.env"
set +a

# Set compose variables
export COMPOSE_PROJECT_NAME="claude-${INSTANCE}"
export COMPOSE_FILE="$APP_DIR/docker-compose.yml"
export SECRETS_FILE="$INSTANCE_DIR/.env"
export WHITELIST_PATH="$INSTANCE_DIR/whitelist.json"
export LOG_DIR="$CONFIG_DIR/logs"
export LOG_PREFIX="${INSTANCE}-"
export WORKSPACE_PATH
```

### List Command Pattern

```bash
# claude-secure list
printf "%-20s %-10s %s\n" "INSTANCE" "STATUS" "WORKSPACE"
printf "%-20s %-10s %s\n" "--------" "------" "---------"

# Get running projects from Docker
declare -A running_projects
while IFS= read -r line; do
  name=$(echo "$line" | jq -r '.Name')
  running_projects["$name"]=1
done < <(docker compose ls --format json 2>/dev/null | jq -c '.[]')

# Iterate all configured instances
for instance_dir in "$CONFIG_DIR/instances"/*/; do
  [ -d "$instance_dir" ] || continue
  name=$(basename "$instance_dir")
  ws=$(grep '^WORKSPACE_PATH=' "$instance_dir/config.sh" | cut -d'"' -f2)
  project="claude-${name}"
  if [ -n "${running_projects[$project]:-}" ]; then
    status="running"
  else
    status="stopped"
  fi
  printf "%-20s %-10s %s\n" "$name" "$status" "$ws"
done
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| docker-compose v1 (standalone binary) | docker compose v2 (plugin) | 2023 | V2 is required; V1 deprecated. `docker compose ls` command only exists in V2. |
| `container_name` for fixed naming | Project-scoped auto-naming | Always available | Removing container_name is the correct modern pattern for multi-instance |

## Open Questions

1. **Volume migration for existing `default` instance**
   - What we know: Old volumes are named based on the old COMPOSE_PROJECT_NAME (derived from directory name where compose ran). The CLI wrapper uses `COMPOSE_FILE` pointing to `$APP_DIR/docker-compose.yml`, and `$APP_DIR` is a symlink to the project root.
   - What's unclear: What project name did Docker Compose use? If `APP_DIR=/home/user/.claude-secure/app` (a symlink), Compose may have used `app` as the project name, giving volumes like `app_workspace`. Or it may have followed the symlink to `claude-secure`.
   - Recommendation: During migration implementation, inspect `docker volume ls` output to detect existing volume names. Consider setting `COMPOSE_PROJECT_NAME=app` for the `default` instance if that's what was used historically, OR document that migration creates a fresh workspace volume (the workspace is bind-mounted from a host path, so no data loss -- only `validator-db` is a Docker-managed volume, and it's just a transient call-ID database).

2. **Whether `remove` subcommand is needed**
   - What we know: D-08 says minimal new commands. Only `list` is explicitly called out.
   - Recommendation: Include `claude-secure remove --instance X` as a convenience. Without it, users must manually: stop instance, delete `~/.claude-secure/instances/X/`, and run `docker volume rm` for orphaned volumes. A `remove` command is ~10 lines and prevents confusion. Mark as discretionary.

3. **Auth credential sharing vs per-instance**
   - What we know: D-06 says each instance has its own .env. But most users will use the same Anthropic auth for all instances.
   - Recommendation: On instance creation (D-09), offer to copy auth credentials from an existing instance's .env (or from the global .env during migration). The user can then customize per-instance if needed.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash + curl + jq (integration tests) |
| Config file | `tests/test-phase*.sh` pattern |
| Quick run command | `bash tests/test-phase9.sh` |
| Full suite command | `for f in tests/test-phase*.sh; do bash "$f"; done` |

### Phase Requirements -> Test Map

No formal requirement IDs assigned yet (TBD in REQUIREMENTS.md). Suggested test coverage:

| Behavior | Test Type | Automated Command | File Exists? |
|----------|-----------|-------------------|-------------|
| `--instance` flag parsing and DNS validation | unit (bash) | `bash tests/test-phase9.sh` | No -- Wave 0 |
| Instance auto-creation creates config files | integration | `bash tests/test-phase9.sh` | No -- Wave 0 |
| Two instances run simultaneously (different COMPOSE_PROJECT_NAME) | integration | `bash tests/test-phase9.sh` | No -- Wave 0 |
| Migration from single-instance creates `instances/default/` | integration | `bash tests/test-phase9.sh` | No -- Wave 0 |
| `claude-secure list` shows correct instance status | integration | `bash tests/test-phase9.sh` | No -- Wave 0 |
| Stopping one instance doesn't affect another | integration | `bash tests/test-phase9.sh` | No -- Wave 0 |
| Log files are instance-prefixed in shared logs directory | integration | `bash tests/test-phase9.sh` | No -- Wave 0 |

### Wave 0 Gaps
- [ ] `tests/test-phase9.sh` -- multi-instance integration tests
- [ ] Test infrastructure for temp config dirs (pattern from test-phase4.sh is reusable)

## Sources

### Primary (HIGH confidence)
- Docker official docs: [Specify a project name](https://docs.docker.com/compose/how-tos/project-name/) -- COMPOSE_PROJECT_NAME behavior
- Docker official docs: [Networking in Compose](https://docs.docker.com/compose/how-tos/networking/) -- network naming with project prefix
- Docker official docs: [How Compose works](https://docs.docker.com/compose/intro/compose-application-model/) -- resource grouping by project name
- Existing codebase: `docker-compose.yml`, `bin/claude-secure`, `install.sh` -- current architecture

### Secondary (MEDIUM confidence)
- Docker community forums and GitHub issues: [container_name prevents scaling](https://github.com/docker/compose/issues/3722) -- confirmed container_name must be removed
- [Running Multiple Instances of Docker Compose Application](https://www.essamamdani.com/running-multiple-instances-of-a-single-docker-compose-application) -- community pattern validation

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- no new dependencies, well-understood Docker Compose features
- Architecture: HIGH -- straightforward refactoring with clear patterns from existing codebase
- Pitfalls: HIGH -- based on direct code analysis of current hardcoded values
- Migration: MEDIUM -- volume naming edge case needs runtime verification

**Research date:** 2026-04-10
**Valid until:** 2026-05-10 (stable technologies, 30-day validity)
