#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.claude-secure"
PLATFORM=""
app_dir=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_dependencies() {
  local missing=()

  command -v docker >/dev/null 2>&1 || missing+=("docker (https://docs.docker.com/engine/install/)")
  command -v curl >/dev/null 2>&1 || missing+=("curl (apt install curl)")
  command -v jq >/dev/null 2>&1 || missing+=("jq (apt install jq)")
  command -v uuidgen >/dev/null 2>&1 || missing+=("uuidgen (apt install uuid-runtime)")

  # Docker Compose v2 check (plugin, not standalone)
  if command -v docker >/dev/null 2>&1; then
    if ! docker compose version >/dev/null 2>&1; then
      if command -v docker-compose >/dev/null 2>&1; then
        missing+=("docker compose v2 (you have v1 which is deprecated -- upgrade Docker)")
      else
        missing+=("docker compose (install Docker Compose plugin)")
      fi
    fi
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    log_error "Missing required dependencies:"
    for dep in "${missing[@]}"; do
      echo "  - $dep"
    done
    exit 1
  fi

  log_info "All dependencies satisfied"
}

detect_platform() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    PLATFORM="wsl2"
    log_info "Detected WSL2 environment"

    # Check for Docker Desktop vs Docker CE
    local os_info
    os_info=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || echo "unknown")
    if echo "$os_info" | grep -qi "docker desktop"; then
      log_warn "Docker Desktop detected. iptables may not work correctly."
      log_warn "Recommended: use Docker CE installed directly in WSL2."
    fi

    # Log iptables backend
    local ipt_version
    ipt_version=$(iptables -V 2>/dev/null || echo "not found")
    log_info "iptables version: $ipt_version"
  else
    PLATFORM="linux"
    log_info "Detected native Linux environment"
  fi

  log_info "Detected platform: $PLATFORM"
}

check_existing() {
  if [ -d "$CONFIG_DIR" ]; then
    log_warn "Existing installation found at $CONFIG_DIR"
    read -rp "Overwrite existing installation? [y/N]: " overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
      log_info "Installation cancelled."
      exit 0
    fi
    # Backup existing .env
    if [ -f "$CONFIG_DIR/.env" ]; then
      cp "$CONFIG_DIR/.env" "$CONFIG_DIR/.env.backup.$(date +%s)"
      log_info "Backed up existing .env"
    fi
  fi
}

setup_directories() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  log_info "Created config directory: $CONFIG_DIR"

  # Create logs directory for service logging (LOG_DIR in docker-compose)
  # chmod 755: owner has full access, others can read/traverse.
  # Container processes write via the bind mount where Docker maps UIDs.
  # If container UID mismatch causes write failures, the CLI wrapper's
  # mkdir -p at launch time can adjust permissions as needed.
  mkdir -p "$CONFIG_DIR/logs"
  # 777 required: three containers write as different UIDs (claude:1001, node:1000, root:0)
  chmod 777 "$CONFIG_DIR/logs"
  log_info "Created logs directory: $CONFIG_DIR/logs"
}

setup_auth() {
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" > "$CONFIG_DIR/.env"
    echo "" >> "$CONFIG_DIR/.env"
    echo "# Add secrets below (must match env_var in whitelist.json)" >> "$CONFIG_DIR/.env"
    echo "# Example: GITHUB_TOKEN=ghp_your_token_here" >> "$CONFIG_DIR/.env"
    chmod 600 "$CONFIG_DIR/.env"
    log_info "Using ANTHROPIC_API_KEY from environment"
    return
  fi

  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    echo "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}" > "$CONFIG_DIR/.env"
    echo "" >> "$CONFIG_DIR/.env"
    echo "# Add secrets below (must match env_var in whitelist.json)" >> "$CONFIG_DIR/.env"
    echo "# Example: GITHUB_TOKEN=ghp_your_token_here" >> "$CONFIG_DIR/.env"
    chmod 600 "$CONFIG_DIR/.env"
    log_info "Using CLAUDE_CODE_OAUTH_TOKEN from environment"
    return
  fi

  # Interactive prompt
  echo ""
  echo "Choose authentication method:"
  echo "  1) OAuth token [recommended]"
  echo "  2) API key"
  read -rp "Choice [1]: " auth_choice
  auth_choice="${auth_choice:-1}"

  case "$auth_choice" in
    2)
      read -rsp "API key: " key
      echo ""
      echo "ANTHROPIC_API_KEY=${key}" > "$CONFIG_DIR/.env"
      echo "" >> "$CONFIG_DIR/.env"
      echo "# Add secrets below (must match env_var in whitelist.json)" >> "$CONFIG_DIR/.env"
      echo "# Example: GITHUB_TOKEN=ghp_your_token_here" >> "$CONFIG_DIR/.env"
      log_info "API key saved"
      ;;
    *)
      echo "Run 'claude setup-token' first to get your OAuth token."
      read -rsp "OAuth token: " token
      echo ""
      echo "CLAUDE_CODE_OAUTH_TOKEN=${token}" > "$CONFIG_DIR/.env"
      echo "" >> "$CONFIG_DIR/.env"
      echo "# Add secrets below (must match env_var in whitelist.json)" >> "$CONFIG_DIR/.env"
      echo "# Example: GITHUB_TOKEN=ghp_your_token_here" >> "$CONFIG_DIR/.env"
      log_info "OAuth token saved"
      ;;
  esac

  chmod 600 "$CONFIG_DIR/.env"
}

setup_workspace() {
  read -rp "Workspace path [$HOME/claude-workspace]: " ws_path
  ws_path="${ws_path:-$HOME/claude-workspace}"

  # Resolve to absolute path
  ws_path="$(realpath -m "$ws_path")"

  mkdir -p "$ws_path"

  # Write config (app_dir written later by copy_app_files)
  cat > "$CONFIG_DIR/config.sh" <<CONF
WORKSPACE_PATH="$ws_path"
PLATFORM="$PLATFORM"
CONF

  log_info "Workspace: $ws_path"
}

copy_app_files() {
  app_dir="$CONFIG_DIR/app"

  if [ "$SCRIPT_DIR" = "$app_dir" ]; then
    log_info "Running from installed location, skipping copy"
  elif [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    rm -rf "$app_dir" 2>/dev/null || true
    cp -r "$SCRIPT_DIR" "$app_dir"
    log_info "Copied project files to $app_dir"
  else
    log_error "Cannot find docker-compose.yml in $SCRIPT_DIR. Run from the claude-secure project directory."
    exit 1
  fi

  # Append APP_DIR to config.sh
  echo "APP_DIR=\"$app_dir\"" >> "$CONFIG_DIR/config.sh"

  # Whitelist lives at config/whitelist.json in the repo (single source of truth).
  # Docker Compose mounts it directly — no copy needed.
}

build_images() {
  log_info "Building Docker images..."
  cd "$app_dir" && docker compose build
  docker compose config --quiet
  log_info "Docker images built successfully"
}

install_cli() {
  local cli_src="$CONFIG_DIR/app/bin/claude-secure"
  local target

  if [ -w /usr/local/bin ]; then
    target="/usr/local/bin/claude-secure"
    cp "$cli_src" "$target"
    chmod 755 "$target"
    log_info "Installed CLI to $target"
  elif command -v sudo >/dev/null 2>&1; then
    target="/usr/local/bin/claude-secure"
    sudo cp "$cli_src" "$target"
    sudo chmod 755 "$target"
    log_info "Installed CLI to $target (via sudo)"
  else
    target="$HOME/.local/bin/claude-secure"
    mkdir -p "$HOME/.local/bin"
    cp "$cli_src" "$target"
    chmod 755 "$target"
    log_info "Installed CLI to $target"
    if ! echo "$PATH" | tr ':' '\n' | grep -q "$HOME/.local/bin"; then
      log_warn "$HOME/.local/bin is not in PATH. Add it to your shell profile."
    fi
  fi
}

main() {
  echo "=== claude-secure installer ==="
  echo ""

  check_dependencies
  detect_platform
  check_existing
  setup_directories
  setup_auth
  setup_workspace
  copy_app_files
  build_images
  install_cli

  echo ""
  log_info "Installation complete!"
  log_info "Run 'claude-secure' to start."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
