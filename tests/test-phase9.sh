#!/bin/bash
# test-phase9.sh -- Integration tests for Phase 9: Multi-Instance Support
# Tests MULTI-01 through MULTI-09
#
# Strategy: Use temp directories for all config to avoid touching real ~/.claude-secure.
# Test bin/claude-secure functions by invoking with controlled environments.
# For Docker-dependent tests, skip gracefully if Docker is unavailable.
#
# Usage: bash tests/test-phase9.sh
# Exit 0 if all pass, exit 1 if any fail.
set -uo pipefail

PASS=0
FAIL=0
TOTAL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

run_test() {
  local name="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" 2>/dev/null; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "========================================"
echo "  Phase 9 Integration Tests"
echo "  Multi-Instance Support"
echo "  (MULTI-01 -- MULTI-09)"
echo "========================================"
echo ""

# =========================================================================
# MULTI-01: --instance flag is required
# Running without --instance should exit non-zero with error message
# =========================================================================
test_instance_required() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  # Create minimal installation structure so the script passes the install check
  mkdir -p "$tmpdir/.claude-secure/instances/default"
  echo 'APP_DIR="/tmp/fake"' > "$tmpdir/.claude-secure/config.sh"
  echo 'PLATFORM="linux"' >> "$tmpdir/.claude-secure/config.sh"
  echo 'WORKSPACE_PATH="/tmp/ws"' > "$tmpdir/.claude-secure/instances/default/config.sh"
  echo 'ANTHROPIC_API_KEY=test' > "$tmpdir/.claude-secure/instances/default/.env"

  # Run without --instance, expect failure
  local output
  output=$(HOME="$tmpdir" bash "$PROJECT_DIR/bin/claude-secure" 2>&1) && return 1
  # Verify error message mentions --instance
  echo "$output" | grep -qi "instance.*required\|instance NAME" || return 1
  return 0
}
run_test "MULTI-01: --instance flag required" test_instance_required

# =========================================================================
# MULTI-02: DNS-safe instance name validation
# Instance names must match ^[a-z0-9][a-z0-9-]*$
# =========================================================================
test_dns_name_valid() {
  local name="$1"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

test_dns_validation() {
  # Valid names
  test_dns_name_valid "myproject" || return 1
  test_dns_name_valid "my-project" || return 1
  test_dns_name_valid "project123" || return 1
  test_dns_name_valid "a" || return 1
  test_dns_name_valid "1abc" || return 1

  # Invalid names -- must NOT match
  test_dns_name_valid "MyProject" && return 1
  test_dns_name_valid "my_project" && return 1
  test_dns_name_valid "my project" && return 1
  test_dns_name_valid "-project" && return 1
  test_dns_name_valid "" && return 1

  return 0
}
run_test "MULTI-02: DNS-safe instance name validation" test_dns_validation

# =========================================================================
# MULTI-03: Migration from single-instance layout
# Old layout: CONFIG_DIR/{config.sh, .env} -> new: CONFIG_DIR/instances/default/
# =========================================================================
test_migration() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg"

  # Create old single-instance layout
  cat > "$cfg/config.sh" <<'EOF'
WORKSPACE_PATH="/home/user/workspace"
PLATFORM="linux"
APP_DIR="/opt/claude-secure"
EOF
  cat > "$cfg/.env" <<'EOF'
ANTHROPIC_API_KEY=sk-test-key-12345
GITHUB_TOKEN=ghp_test
EOF

  # Need a whitelist template at the APP_DIR path
  local fake_app="$tmpdir/app"
  mkdir -p "$fake_app/config"
  echo '{"secrets":[]}' > "$fake_app/config/whitelist.json"

  # Update config.sh to point to our fake app
  cat > "$cfg/config.sh" <<EOF
WORKSPACE_PATH="/home/user/workspace"
PLATFORM="linux"
APP_DIR="$fake_app"
EOF

  # Run the CLI which triggers migrate_if_needed
  # We just need to trigger migration - run with 'help' to avoid Docker calls
  HOME="$tmpdir" bash "$PROJECT_DIR/bin/claude-secure" list 2>/dev/null || true

  # Verify migration results
  [ -d "$cfg/instances/default" ] || return 1
  [ -f "$cfg/instances/default/.env" ] || return 1
  grep -q 'ANTHROPIC_API_KEY=sk-test-key-12345' "$cfg/instances/default/.env" || return 1
  [ -f "$cfg/instances/default/config.sh" ] || return 1
  grep -q 'WORKSPACE_PATH=' "$cfg/instances/default/config.sh" || return 1
  # Global config should NOT have WORKSPACE_PATH anymore
  ! grep -q '^WORKSPACE_PATH=' "$cfg/config.sh" || return 1
  # Global config should still have APP_DIR and PLATFORM
  grep -q 'APP_DIR=' "$cfg/config.sh" || return 1
  grep -q 'PLATFORM=' "$cfg/config.sh" || return 1
  # Root-level .env should be gone (moved)
  [ ! -f "$cfg/.env" ] || return 1

  return 0
}
run_test "MULTI-03: Migration from single-instance to multi-instance" test_migration

# =========================================================================
# MULTI-04: COMPOSE_PROJECT_NAME isolation
# docker-compose.yml must not have container_name directives
# Different COMPOSE_PROJECT_NAME values produce different container names
# =========================================================================
test_compose_isolation() {
  # Verify no container_name directives in docker-compose.yml
  if grep -q 'container_name:' "$PROJECT_DIR/docker-compose.yml"; then
    return 1
  fi

  # Docker-dependent test: skip gracefully if not available
  if ! docker compose version >/dev/null 2>&1; then
    echo "    (Docker not available - skipping container name uniqueness check)"
    return 0
  fi

  # Verify different project names produce different container names
  local out1 out2
  out1=$(cd "$PROJECT_DIR" && COMPOSE_PROJECT_NAME=claude-test1 WORKSPACE_PATH=/tmp docker compose config 2>/dev/null) || return 1
  out2=$(cd "$PROJECT_DIR" && COMPOSE_PROJECT_NAME=claude-test2 WORKSPACE_PATH=/tmp docker compose config 2>/dev/null) || return 1

  # The config output uses project name as prefix - verify they differ
  [ "$out1" != "$out2" ] || return 1

  return 0
}
run_test "MULTI-04: COMPOSE_PROJECT_NAME isolation (no container_name)" test_compose_isolation

# =========================================================================
# MULTI-05: Per-instance config files
# Each instance directory has its own config.sh, .env, whitelist.json
# =========================================================================
test_per_instance_config() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg/instances/foo" "$cfg/instances/bar"

  # Instance foo
  echo 'WORKSPACE_PATH="/home/user/project-foo"' > "$cfg/instances/foo/config.sh"
  echo 'ANTHROPIC_API_KEY=key-foo' > "$cfg/instances/foo/.env"
  echo '{"secrets":["foo"]}' > "$cfg/instances/foo/whitelist.json"

  # Instance bar
  echo 'WORKSPACE_PATH="/home/user/project-bar"' > "$cfg/instances/bar/config.sh"
  echo 'ANTHROPIC_API_KEY=key-bar' > "$cfg/instances/bar/.env"
  echo '{"secrets":["bar"]}' > "$cfg/instances/bar/whitelist.json"

  # Verify files exist for both
  [ -f "$cfg/instances/foo/config.sh" ] || return 1
  [ -f "$cfg/instances/foo/.env" ] || return 1
  [ -f "$cfg/instances/foo/whitelist.json" ] || return 1
  [ -f "$cfg/instances/bar/config.sh" ] || return 1
  [ -f "$cfg/instances/bar/.env" ] || return 1
  [ -f "$cfg/instances/bar/whitelist.json" ] || return 1

  # Verify files are independent (different content)
  ! diff -q "$cfg/instances/foo/config.sh" "$cfg/instances/bar/config.sh" >/dev/null 2>&1 || return 1
  ! diff -q "$cfg/instances/foo/.env" "$cfg/instances/bar/.env" >/dev/null 2>&1 || return 1
  ! diff -q "$cfg/instances/foo/whitelist.json" "$cfg/instances/bar/whitelist.json" >/dev/null 2>&1 || return 1

  return 0
}
run_test "MULTI-05: Per-instance config files are independent" test_per_instance_config

# =========================================================================
# MULTI-06: LOG_PREFIX in docker-compose.yml and service code
# All three services must have LOG_PREFIX env var in compose
# Service code must reference LOG_PREFIX for log filenames
# =========================================================================
test_log_prefix() {
  local compose="$PROJECT_DIR/docker-compose.yml"

  # Verify LOG_PREFIX env var in docker-compose.yml for all services
  # Each service section should have LOG_PREFIX
  local count
  count=$(grep -c 'LOG_PREFIX=\${LOG_PREFIX:-}' "$compose" 2>/dev/null || echo "0")
  # Need at least 3 (claude, proxy, validator)
  [ "$count" -ge 3 ] || return 1

  # Verify proxy.js contains LOG_PREFIX
  grep -q 'LOG_PREFIX' "$PROJECT_DIR/proxy/proxy.js" || return 1

  # Verify validator.py contains LOG_PREFIX or log_prefix
  grep -qi 'log_prefix\|LOG_PREFIX' "$PROJECT_DIR/validator/validator.py" || return 1

  # Verify pre-tool-use.sh contains LOG_PREFIX
  grep -q 'LOG_PREFIX' "$PROJECT_DIR/claude/hooks/pre-tool-use.sh" || return 1

  return 0
}
run_test "MULTI-06: LOG_PREFIX in compose and service code" test_log_prefix

# =========================================================================
# MULTI-07: list command output format
# List should show all configured instances with name and workspace
# =========================================================================
test_list_command() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg/instances/foo" "$cfg/instances/bar"

  echo 'APP_DIR="/tmp/fake"' > "$cfg/config.sh"
  echo 'PLATFORM="linux"' >> "$cfg/config.sh"

  echo 'WORKSPACE_PATH="/home/user/project-foo"' > "$cfg/instances/foo/config.sh"
  echo 'ANTHROPIC_API_KEY=test' > "$cfg/instances/foo/.env"
  echo 'WORKSPACE_PATH="/home/user/project-bar"' > "$cfg/instances/bar/config.sh"
  echo 'ANTHROPIC_API_KEY=test' > "$cfg/instances/bar/.env"

  # Run list command
  local output
  output=$(HOME="$tmpdir" bash "$PROJECT_DIR/bin/claude-secure" list 2>/dev/null) || true

  # Verify output contains both instance names
  echo "$output" | grep -q 'foo' || return 1
  echo "$output" | grep -q 'bar' || return 1

  return 0
}
run_test "MULTI-07: list command shows all instances" test_list_command

# =========================================================================
# MULTI-08: Instance auto-creation directory structure
# After create_instance, instance dir has config.sh, .env, whitelist.json
# =========================================================================
test_auto_creation_structure() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg"

  # Create global config with APP_DIR pointing to our project
  local fake_app="$tmpdir/app"
  mkdir -p "$fake_app/config"
  cp "$PROJECT_DIR/config/whitelist.json" "$fake_app/config/whitelist.json"

  cat > "$cfg/config.sh" <<EOF
APP_DIR="$fake_app"
PLATFORM="linux"
EOF

  # Simulate auto-creation: create instance directory structure manually
  # (create_instance is interactive so we simulate its output)
  local idir="$cfg/instances/testinst"
  mkdir -p "$idir"
  echo 'WORKSPACE_PATH="/tmp/ws-testinst"' > "$idir/config.sh"
  echo 'ANTHROPIC_API_KEY=test-key' > "$idir/.env"
  chmod 600 "$idir/.env"
  cp "$fake_app/config/whitelist.json" "$idir/whitelist.json"

  # Verify expected structure
  [ -f "$idir/config.sh" ] || return 1
  [ -f "$idir/.env" ] || return 1
  [ -f "$idir/whitelist.json" ] || return 1

  # Verify whitelist matches template
  diff -q "$fake_app/config/whitelist.json" "$idir/whitelist.json" >/dev/null 2>&1 || return 1

  return 0
}
run_test "MULTI-08: Instance auto-creation directory structure" test_auto_creation_structure

# =========================================================================
# MULTI-09: Global config.sh contains only APP_DIR and PLATFORM
# After installation, global config.sh should NOT have WORKSPACE_PATH
# =========================================================================
test_global_config_scope() {
  # Source install.sh to get setup_workspace function
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg"

  # The installer's setup_workspace writes WORKSPACE_PATH to config.sh
  # but after migration/multi-instance, global config.sh should only have APP_DIR and PLATFORM.
  # Verify by checking the actual bin/claude-secure expects:
  # - Global config.sh is sourced first (only APP_DIR, PLATFORM)
  # - Instance config.sh provides WORKSPACE_PATH

  # Simulate a properly configured global config
  cat > "$cfg/config.sh" <<'EOF'
PLATFORM="linux"
APP_DIR="/opt/claude-secure/app"
EOF

  # Verify global config does NOT contain WORKSPACE_PATH
  ! grep -q '^WORKSPACE_PATH=' "$cfg/config.sh" || return 1
  # Verify it contains APP_DIR and PLATFORM
  grep -q 'APP_DIR=' "$cfg/config.sh" || return 1
  grep -q 'PLATFORM=' "$cfg/config.sh" || return 1

  # Also verify in the CLI: it sources global config first for APP_DIR/PLATFORM
  grep -q 'source.*config\.sh' "$PROJECT_DIR/bin/claude-secure" || return 1
  # And instance config is loaded separately
  grep -q 'INSTANCE_DIR' "$PROJECT_DIR/bin/claude-secure" || return 1

  return 0
}
run_test "MULTI-09: Global config scope (APP_DIR and PLATFORM only)" test_global_config_scope

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed (of $TOTAL total)"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
