---
created: 2026-04-10T11:09:30.892Z
title: Log redacted secret mappings in anthropic.jsonl
area: tooling
files:
  - services/proxy/proxy.js
  - logs/anthropic.jsonl
---

## Problem

Currently the anthropic.jsonl log shows that redaction occurred but not *what* was redacted. For debugging and auditing, it would be valuable to see the actual mapping in cleartext — e.g., `"gh_4924769234792472" => "<redacted_user_token>"` — so the operator can verify which secrets were caught and what placeholders replaced them.

## Solution

Extend the proxy's logging to include a `redactions` field (or similar) in each anthropic.jsonl log entry that lists the original secret value (or a truncated/masked version) alongside its placeholder. Consider a configurable verbosity level — full cleartext in dev/debug mode, truncated in production.
