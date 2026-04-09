---
created: 2026-04-09T13:02:00.373Z
title: Smoke test security layers
area: testing
files: []
---

## Problem

Need to verify the three core security layers work end-to-end in a running claude-secure environment:

1. **PreToolUse hook intercepts** - Confirm the hook fires on tool calls (Bash, WebFetch, etc.) and correctly allows/blocks based on domain whitelist
2. **Secret redaction by proxy** - Confirm that a GitHub secret (or other configured secret) present in the LLM context is replaced with its placeholder before the request reaches api.anthropic.com
3. **iptables call-ID enforcement** - Confirm that outbound calls from the claude container are only allowed when a valid call-ID was registered via the PreToolUse hook (i.e., direct curl from inside the container without hook registration gets rejected)

## Solution

Create a manual smoke test checklist or script that:
- Triggers a tool call and checks proxy logs for placeholder substitution
- Attempts an outbound request without hook registration and verifies iptables blocks it
- Inspects validator logs/SQLite for call-ID lifecycle (register -> validate -> expire)
