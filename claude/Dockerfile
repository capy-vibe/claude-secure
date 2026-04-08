FROM node:22-slim

# Install claude-code CLI and required tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl jq uuid-runtime dnsutils && \
    rm -rf /var/lib/apt/lists/* && \
    npm install -g @anthropic-ai/claude-code

# Create log directory
RUN mkdir -p /var/log/claude-secure

# Hook scripts -- root-owned, execute-only (per DOCK-05)
COPY hooks/ /etc/claude-secure/hooks/
RUN chown -R root:root /etc/claude-secure/hooks/ && \
    chmod 555 /etc/claude-secure/hooks/ && \
    chmod 555 /etc/claude-secure/hooks/*.sh

# Settings with hook configuration -- placed OUTSIDE /root/.claude to avoid
# being shadowed by the claude-auth named volume mount (per Blocker 4).
# Symlink ensures Claude Code finds it at the expected path.
COPY settings.json /etc/claude-secure/settings.json
RUN chown root:root /etc/claude-secure/settings.json && \
    chmod 444 /etc/claude-secure/settings.json && \
    mkdir -p /root/.claude && \
    ln -sf /etc/claude-secure/settings.json /root/.claude/settings.json

WORKDIR /workspace
