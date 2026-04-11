#!/bin/bash
# test-phase4.sh -- Integration tests for Phase 4: Installation and Platform
# Tests INST-01 through INST-06, PLAT-01 through PLAT-03
#
# Strategy: Source install.sh (which has a BASH_SOURCE guard) to test individual
# functions in isolation. Use temp directories to avoid touching real ~/.claude-secure.
# For Docker integration tests, use the project's docker-compose.yml directly.
#
# Usage: bash tests/test-phase4.sh
# Exit 0 if all pass, exit 1 if any fail.
set -uo pipefail

PASS=0
FAIL=0
TOTAL=12

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

report() {
  local id="$1"
  local desc="$2"
  local result="$3"

  printf "  %-10s %-60s " "$id" "$desc"
  if [ "$result" -eq 0 ]; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL"
    ((FAIL++))
  fi
}

echo "========================================"
echo "  Phase 4 Integration Tests"
echo "  Installation & Platform"
echo "  (INST-01 -- INST-06, PLAT-01 -- PLAT-03)"
echo "========================================"
echo ""

echo "Running tests..."
echo ""

# =========================================================================
# INST-01: Installer script has valid syntax
# =========================================================================
bash -n "$PROJECT_DIR/install.sh" > /dev/null 2>&1
report "INST-01" "Installer script has valid bash syntax" $?

# =========================================================================
# INST-01b: Dependency checker function exists and checks all required tools
# =========================================================================
(
  INST01B_OK=0
  grep -q 'check_dependencies' "$PROJECT_DIR/install.sh" || INST01B_OK=1
  grep -q 'command -v docker' "$PROJECT_DIR/install.sh" || INST01B_OK=1
  grep -q 'command -v curl' "$PROJECT_DIR/install.sh" || INST01B_OK=1
  grep -q 'command -v jq' "$PROJECT_DIR/install.sh" || INST01B_OK=1
  grep -q 'command -v uuidgen' "$PROJECT_DIR/install.sh" || INST01B_OK=1
  grep -q 'docker compose version' "$PROJECT_DIR/install.sh" || INST01B_OK=1
  exit "$INST01B_OK"
)
report "INST-01b" "Dependency checker covers docker, curl, jq, uuidgen, compose v2" $?

# =========================================================================
# INST-01c: check_dependencies succeeds on current host (all deps present)
# =========================================================================
(
  source "$PROJECT_DIR/install.sh"
  check_dependencies > /dev/null 2>&1
)
report "INST-01c" "check_dependencies passes on host (all deps installed)" $?

# =========================================================================
# INST-02 / PLAT-01 / PLAT-02: Platform detection
# =========================================================================
(
  source "$PROJECT_DIR/install.sh"
  # Call detect_platform directly (not inside $()) so PLATFORM var propagates
  detect_platform > /dev/null 2>&1
  # Must set PLATFORM to either "linux" or "wsl2"
  if [ "$PLATFORM" = "linux" ] || [ "$PLATFORM" = "wsl2" ]; then
    exit 0
  fi
  exit 1
)
report "INST-02" "Platform detection sets PLATFORM to linux or wsl2" $?

# =========================================================================
# PLAT-03: iptables version logged during platform detection
# =========================================================================
(
  source "$PROJECT_DIR/install.sh"
  # On WSL2, detect_platform logs iptables version; on native linux it may not.
  # Verify the code path exists in the script.
  grep -q 'iptables -V' "$PROJECT_DIR/install.sh"
)
report "PLAT-03" "Platform detection includes iptables version check" $?

# =========================================================================
# INST-03: Auth setup writes .env with correct permissions
# =========================================================================
(
  TMPDIR_AUTH=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_AUTH"' EXIT

  # Source install.sh first (defines functions), then override CONFIG_DIR
  # (sourcing install.sh sets CONFIG_DIR=$HOME/.claude-secure, so we must override after)
  source "$PROJECT_DIR/install.sh"
  CONFIG_DIR="$TMPDIR_AUTH"

  # Provide auth via environment variable (non-interactive path)
  ANTHROPIC_API_KEY="test-key-12345"
  setup_auth > /dev/null 2>&1

  # setup_auth writes to $CONFIG_DIR/instances/default/.env
  ENV_FILE="$TMPDIR_AUTH/instances/default/.env"

  # Verify .env was created with correct content
  RESULT=0
  grep -q 'ANTHROPIC_API_KEY=test-key-12345' "$ENV_FILE" || RESULT=1
  # Verify chmod 600 permissions
  PERMS=$(stat -c '%a' "$ENV_FILE" 2>/dev/null)
  [ "$PERMS" = "600" ] || RESULT=1
  exit "$RESULT"
)
report "INST-03" "Auth setup writes .env with chmod 600 permissions" $?

# =========================================================================
# INST-04: Directory structure created with correct permissions
# =========================================================================
(
  TMPDIR_DIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_DIR"' EXIT

  # Source install.sh first (defines functions), then override CONFIG_DIR
  source "$PROJECT_DIR/install.sh"
  CONFIG_DIR="$TMPDIR_DIR/claude-secure-test"

  setup_directories > /dev/null 2>&1

  RESULT=0
  [ -d "$CONFIG_DIR" ] || RESULT=1
  PERMS=$(stat -c '%a' "$CONFIG_DIR" 2>/dev/null)
  [ "$PERMS" = "700" ] || RESULT=1
  exit "$RESULT"
)
report "INST-04" "setup_directories creates dir with chmod 700" $?

# =========================================================================
# INST-05: Docker Compose config is valid
# =========================================================================
(
  cd "$PROJECT_DIR"
  WORKSPACE_PATH="${WORKSPACE_PATH:-$HOME/claude-workspace}" \
    docker compose config --quiet > /dev/null 2>&1
)
report "INST-05" "docker-compose.yml validates (compose config --quiet)" $?

# =========================================================================
# INST-05b: Docker images build successfully
# =========================================================================
(
  cd "$PROJECT_DIR"
  WORKSPACE_PATH="${WORKSPACE_PATH:-$HOME/claude-workspace}" \
    docker compose build --quiet > /dev/null 2>&1
)
report "INST-05b" "Docker images build successfully" $?

# =========================================================================
# INST-06: CLI wrapper syntax and structure
# =========================================================================
(
  RESULT=0
  bash -n "$PROJECT_DIR/bin/claude-secure" > /dev/null 2>&1 || RESULT=1
  grep -q 'docker compose down' "$PROJECT_DIR/bin/claude-secure" || RESULT=1
  grep -q 'docker compose ps' "$PROJECT_DIR/bin/claude-secure" || RESULT=1
  grep -q 'COMPOSE_FILE' "$PROJECT_DIR/bin/claude-secure" || RESULT=1
  grep -q 'config\.sh' "$PROJECT_DIR/bin/claude-secure" || RESULT=1
  exit "$RESULT"
)
report "INST-06" "CLI wrapper has valid syntax and expected subcommands" $?

# =========================================================================
# PLAT-01/PLAT-02: Containers start and all 3 are running
# =========================================================================
(
  cd "$PROJECT_DIR"
  WORKSPACE_PATH="${WORKSPACE_PATH:-$HOME/claude-workspace}" \
    docker compose up -d --wait --timeout 30 > /dev/null 2>&1 || exit 1

  # Verify all 3 containers are running
  RUNNING=$(docker compose ps --format json 2>/dev/null | jq -s 'length')
  if [ "$RUNNING" -eq 3 ]; then
    exit 0
  fi
  exit 1
)
PLAT_RESULT=$?
report "PLAT-01" "All 3 containers start and run" $PLAT_RESULT

# =========================================================================
# PLAT-02: Proxy is reachable from claude container
# =========================================================================
if [ $PLAT_RESULT -eq 0 ]; then
  docker compose exec -T claude curl -s -o /dev/null -w '%{http_code}' \
    -X POST http://proxy:8080/v1/messages \
    -H 'content-type: application/json' \
    -d '{"model":"test","messages":[]}' 2>/dev/null | grep -qE '^[2345][0-9]{2}$'
  report "PLAT-02" "Proxy reachable from claude container" $?
else
  report "PLAT-02" "Proxy reachable from claude container (skipped - no containers)" 1
fi

# Cleanup containers
echo ""
echo "Cleaning up..."
cd "$PROJECT_DIR" && docker compose down > /dev/null 2>&1

echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed (of $TOTAL)"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
