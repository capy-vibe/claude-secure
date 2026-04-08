#!/bin/bash
set -euo pipefail

# Phase 1 Integration Tests
# Verifies all Docker infrastructure requirements (DOCK-01 through DOCK-06, WHIT-01 through WHIT-03)
# plus settings.json accessibility check (DOCK-05b).
#
# Usage: bash tests/test-phase1.sh
# Exit 0 if all pass, exit 1 if any fail.

PASS=0
FAIL=0
TOTAL=10

run_test() {
  local id="$1"
  local desc="$2"
  local cmd="$3"

  printf "  %-8s %-60s " "$id" "$desc"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL"
    ((FAIL++))
  fi
}

echo "========================================"
echo "  Phase 1 Integration Tests"
echo "========================================"
echo ""

# Ensure containers are running (they may or may not be up from Plan 01)
echo "Ensuring containers are running..."
docker compose up -d --wait --timeout 30
echo ""

echo "Running tests..."
echo ""

# DOCK-01: Claude container has no direct internet
run_test "DOCK-01" "Claude container has no direct internet access" \
  "! docker exec claude-secure curl -sf --max-time 5 https://api.anthropic.com"

# DOCK-02: Proxy can reach external URLs
run_test "DOCK-02" "Proxy container can reach external URLs" \
  "docker exec claude-proxy curl -sf --max-time 10 https://api.anthropic.com/v1 -o /dev/null"

# DOCK-03: All 3 containers running
run_test "DOCK-03" "Docker Compose runs all 3 containers" \
  "test \$(docker compose ps --format json | jq -s 'length') -eq 3"

# DOCK-04: DNS queries blocked from claude
run_test "DOCK-04" "DNS queries from claude container are blocked" \
  "! docker exec claude-secure nslookup google.com"

# DOCK-05: Security files root-owned and read-only
run_test "DOCK-05" "Security files are root-owned and read-only" \
  "docker exec claude-secure stat -c '%U %a' /etc/claude-secure/whitelist.json | grep -q 'root 444' && \
   docker exec claude-secure stat -c '%U %a' /etc/claude-secure/hooks/pre-tool-use.sh | grep -q 'root 555' && \
   docker exec claude-secure stat -c '%U %a' /etc/claude-secure/settings.json | grep -q 'root 444'"

# DOCK-05b: Settings.json accessible via symlink (not shadowed by volume)
run_test "DOCK-05b" "settings.json accessible via symlink (not volume-shadowed)" \
  "docker exec claude-secure cat /root/.claude/settings.json | jq -e '.hooks.PreToolUse'"

# DOCK-06: Capabilities dropped and no-new-privileges
run_test "DOCK-06" "Claude container caps dropped, no-new-privileges set" \
  "docker inspect claude-secure --format '{{.HostConfig.CapDrop}}' | grep -q ALL && \
   docker inspect claude-secure --format '{{.HostConfig.SecurityOpt}}' | grep -q no-new-privileges"

# WHIT-01: Whitelist has secrets with correct schema
run_test "WHIT-01" "Whitelist maps placeholders to env vars and domains" \
  "jq -e '.secrets[0] | has(\"placeholder\",\"env_var\",\"allowed_domains\")' config/whitelist.json"

# WHIT-02: Whitelist has readonly_domains
run_test "WHIT-02" "Whitelist has readonly_domains section" \
  "jq -e 'has(\"readonly_domains\")' config/whitelist.json"

# WHIT-03: Whitelist is not writable inside container
run_test "WHIT-03" "Whitelist is read-only inside claude container" \
  "docker exec claude-secure test ! -w /etc/claude-secure/whitelist.json"

echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed (of $TOTAL)"
echo "========================================"

# Clean up
docker compose down > /dev/null 2>&1

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
