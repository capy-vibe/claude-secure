#!/bin/bash
# pre-tool-use.sh -- PreToolUse hook for claude-secure call validation
# Intercepts Bash/WebFetch/WebSearch tool calls, checks domain whitelist,
# registers call-IDs with validator for allowed payload calls.
set -euo pipefail

# Constants
WHITELIST="/etc/claude-secure/whitelist.json"
VALIDATOR_URL="http://127.0.0.1:8088"
LOG_FILE="/var/log/claude-secure/${LOG_PREFIX:-}hook.log"

# Capture stdin immediately (single-read stream -- must be first operational line)
INPUT=$(cat)

# --- Logging ---

log() {
  if [ "${LOG_HOOK:-0}" = "1" ]; then
    echo "[$(date -Iseconds)] $*" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

log_json() {
  local level="$1" action="$2" msg="$3"
  if [ "${LOG_HOOK:-0}" = "1" ]; then
    jq -nc \
      --arg ts "$(date -Iseconds)" \
      --arg svc "hook" \
      --arg level "$level" \
      --arg action "$action" \
      --arg msg "$msg" \
      --arg tool "${TOOL_NAME:-}" \
      --arg domain "${DOMAIN:-}" \
      '{ts: $ts, svc: $svc, level: $level, action: $action, msg: $msg, tool: $tool, domain: $domain}' \
      >> "/var/log/claude-secure/${LOG_PREFIX:-}hook.jsonl" 2>/dev/null || true
  fi
}

# --- Decision helpers ---

deny() {
  local reason="$1"
  log "DENY: $reason"
  log_json "warn" "deny" "$reason"
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

allow() {
  log "ALLOW: $1"
  log_json "info" "allow" "$1"
  exit 0
}

# --- Domain extraction ---

extract_domain() {
  case "$TOOL_NAME" in
    Bash)
      local cmd
      cmd=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

      # Only process commands that contain curl or wget
      if ! echo "$cmd" | grep -qE '\bcurl\b|\bwget\b'; then
        echo ""
        return
      fi

      # Check for shell obfuscation in the curl/wget portion
      local http_cmd
      http_cmd=$(echo "$cmd" | grep -oE '(curl|wget)\s+.*' || true)
      if echo "$http_cmd" | grep -qE '(\$[{(]|\$[A-Za-z]|`|eval\s|base64)'; then
        echo "__OBFUSCATED__"
        return
      fi

      # Extract URL
      local url
      url=$(echo "$cmd" | grep -oP 'https?://[^\s"'\''()<>|;&]+' | head -1)
      if [ -n "$url" ]; then
        echo "$url" | sed -E 's|https?://([^/:]+).*|\1|'
      else
        # curl/wget present but no URL extractable -- fail closed
        echo "__NO_URL__"
      fi
      ;;
    WebFetch)
      echo "$INPUT" | jq -r '.tool_input.url // empty' | sed -E 's|https?://([^/:]+).*|\1|'
      ;;
    WebSearch)
      echo ""
      ;;
  esac
}

# --- Payload detection ---

has_payload() {
  local cmd
  cmd=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
  # HTTP method flags indicating non-GET
  echo "$cmd" | grep -qE '\-X\s+(POST|PUT|PATCH|DELETE)' && return 0
  # Data flags (curl)
  echo "$cmd" | grep -qE '(\s|^)-(d|F)\s|--data\b|--data-raw\b|--data-binary\b|--data-urlencode\b|--form\b|--upload-file\b' && return 0
  # Pipe-to-curl pattern (data from stdin)
  echo "$cmd" | grep -qE '\|\s*curl\b' && return 0
  return 1
}

is_webfetch_payload() {
  local method
  method=$(echo "$INPUT" | jq -r '.tool_input.method // "GET"' | tr '[:lower:]' '[:upper:]')
  [[ "$method" != "GET" && "$method" != "HEAD" ]]
}

# --- Domain matching ---

domain_matches() {
  local domain="$1"
  local entry="$2"
  [ "$domain" = "$entry" ] && return 0
  [[ "$domain" == *".$entry" ]] && return 0
  return 1
}

domain_in_whitelist() {
  local domain="$1"
  local entries
  entries=$(jq -r '.secrets[].allowed_domains[]' "$WHITELIST" 2>/dev/null)
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    domain_matches "$domain" "$entry" && return 0
  done <<< "$entries"
  return 1
}

domain_in_readonly() {
  local domain="$1"
  local entries
  entries=$(jq -r '.readonly_domains[]' "$WHITELIST" 2>/dev/null)
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    domain_matches "$domain" "$entry" && return 0
  done <<< "$entries"
  return 1
}

# --- Call-ID registration ---

register_call_id() {
  local domain="$1"
  local call_id
  call_id=$(uuidgen)
  local response
  response=$(curl -s -w "\n%{http_code}" -X POST "${VALIDATOR_URL}/register" \
    -H "Content-Type: application/json" \
    -d "{\"call_id\": \"${call_id}\", \"domain\": \"${domain}\"}" 2>&1)
  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')
  if [ "$http_code" = "200" ]; then
    log "REGISTERED call-id=${call_id} domain=${domain}"
    log_json "info" "register" "call-id=${call_id} domain=${domain}"
    return 0
  else
    log "REGISTER FAILED: http_code=${http_code} body=${body}"
    return 1
  fi
}

# === Main Logic ===

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Non-network Bash commands (no curl/wget) -- allow
if [ "$TOOL_NAME" = "Bash" ]; then
  cmd=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
  if ! echo "$cmd" | grep -qE '\bcurl\b|\bwget\b'; then
    allow "non-network Bash command"
  fi
fi

# WebSearch -- always allow (read-only search, per CALL-04)
if [ "$TOOL_NAME" = "WebSearch" ]; then
  allow "WebSearch is read-only"
fi

# Extract domain
DOMAIN=$(extract_domain)

# Obfuscation detected
if [ "$DOMAIN" = "__OBFUSCATED__" ]; then
  deny "Blocked: potential URL obfuscation detected in command (fail-closed per security policy)"
fi

# No URL found in curl/wget command
if [ "$DOMAIN" = "__NO_URL__" ]; then
  deny "Blocked: curl/wget command but no URL could be extracted (fail-closed per security policy)"
fi

# Empty domain (safety check)
if [ -z "$DOMAIN" ]; then
  allow "no target domain detected"
fi

# Determine if this is a payload (outbound data) request
IS_PAYLOAD=false
if [ "$TOOL_NAME" = "Bash" ]; then
  has_payload && IS_PAYLOAD=true
elif [ "$TOOL_NAME" = "WebFetch" ]; then
  is_webfetch_payload && IS_PAYLOAD=true
fi

# PAYLOAD requests: must go to whitelisted domain + register call-ID
if [ "$IS_PAYLOAD" = "true" ]; then
  if domain_in_whitelist "$DOMAIN"; then
    if register_call_id "$DOMAIN"; then
      allow "payload to whitelisted domain ${DOMAIN} (call-ID registered)"
    else
      deny "Blocked: failed to register call-ID with validator for ${DOMAIN}"
    fi
  else
    deny "Blocked: outbound payload to non-whitelisted domain ${DOMAIN}"
  fi
else
  # READ-ONLY (GET) requests: allow to any domain without registration (per CALL-04/D-08)
  allow "read-only request to ${DOMAIN} (no registration needed)"
fi
