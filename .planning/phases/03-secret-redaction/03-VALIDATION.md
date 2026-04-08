---
phase: 3
slug: secret-redaction
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-09
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash + curl + jq (shell-based integration tests) |
| **Config file** | none — tests are standalone shell scripts |
| **Quick run command** | `bash tests/test-phase3.sh` |
| **Full suite command** | `bash tests/test-phase1.sh && bash tests/test-phase2.sh && bash tests/test-phase3.sh` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase3.sh`
- **After every plan wave:** Run `bash tests/test-phase1.sh && bash tests/test-phase2.sh && bash tests/test-phase3.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 03-01-01 | 01 | 1 | SECR-01 | integration | `docker compose exec claude curl -s http://proxy:8080/` | Covered by Phase 1 | ⬜ pending |
| 03-01-02 | 01 | 1 | SECR-02 | integration | Send request with secret, verify placeholder in forwarded body | ❌ W0 | ⬜ pending |
| 03-01-03 | 01 | 1 | SECR-03 | integration | Mock upstream returns placeholder, verify real value in response | ❌ W0 | ⬜ pending |
| 03-01-04 | 01 | 1 | SECR-04 | integration | Modify whitelist.json, send request, verify new config | ❌ W0 | ⬜ pending |
| 03-01-05 | 01 | 1 | SECR-05 | integration | Send request, verify upstream receives correct auth header | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase3.sh` — integration tests covering SECR-01 through SECR-05
- [ ] Test approach: mock upstream or echo endpoint for verifying redacted/restored bodies

*Existing Phase 1/2 test infrastructure (`tests/test-phase1.sh`, `tests/test-phase2.sh`) covers container connectivity and proxy forwarding basics.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Log warning on missing env var | D-02 | Requires inspecting proxy container logs | 1. Remove a secret env var 2. Send request 3. Check `docker compose logs proxy` for warning |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
