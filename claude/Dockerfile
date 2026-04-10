FROM node:22-slim

# Install claude-code CLI and required tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl jq uuid-runtime dnsutils \
        git build-essential ca-certificates openssh-client wget \
        python3 python3-pip python3-venv \
        ripgrep fd-find && \
    rm -rf /var/lib/apt/lists/* && \
    npm install -g @anthropic-ai/claude-code

# Create non-root user for Claude Code (refuses to run as root with --dangerously-skip-permissions)
RUN useradd -m -s /bin/bash claude

# Create log directory
RUN mkdir -p /var/log/claude-secure && chown claude:claude /var/log/claude-secure

# Hook scripts -- root-owned, execute-only (per DOCK-05)
COPY hooks/ /etc/claude-secure/hooks/
RUN chown -R root:root /etc/claude-secure/hooks/ && \
    chmod 555 /etc/claude-secure/hooks/ && \
    chmod 555 /etc/claude-secure/hooks/*.sh

# Settings with hook configuration -- placed OUTSIDE user home to avoid
# being shadowed by any volume mount on ~/.claude.
# Symlink ensures Claude Code finds it at the expected path.
COPY settings.json /etc/claude-secure/settings.json
RUN chown root:root /etc/claude-secure/settings.json && \
    chmod 444 /etc/claude-secure/settings.json && \
    mkdir -p /home/claude/.claude && \
    ln -sf /etc/claude-secure/settings.json /home/claude/.claude/settings.json && \
    chown -R claude:claude /home/claude/.claude

# Pre-set onboarding flag so Claude Code doesn't try to reach api.anthropic.com
# directly on first startup (bypasses ANTHROPIC_BASE_URL -- see GitHub #26935)
RUN echo '{"hasCompletedOnboarding":true}' > /home/claude/.claude.json && \
    chown claude:claude /home/claude/.claude.json

# Disable telemetry and auto-updater to prevent direct connections to
# statsig.anthropic.com / sentry / update servers that bypass ANTHROPIC_BASE_URL
# and fail with EAI_AGAIN in the network-isolated container (GitHub #36998, #2481)
ENV DISABLE_TELEMETRY=1
ENV DISABLE_AUTOUPDATER=1
ENV DISABLE_ERROR_REPORTING=1
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

USER claude
WORKDIR /workspace
