---
phase: 02
slug: call-validation
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-08
---

# Phase 02 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash integration tests (shell + curl + docker exec) |
| **Config file** | tests/test-phase1.sh (existing), tests/test-phase2.sh (new) |
| **Quick run command** | `bash tests/test-phase2.sh` |
| **Full suite command** | `bash tests/test-phase1.sh && bash tests/test-phase2.sh` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase2.sh`
- **After every plan wave:** Run `bash tests/test-phase1.sh && bash tests/test-phase2.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 02-01-01 | 01 | 1 | CALL-01, CALL-02 | integration | `docker exec claude-secure bash -c "echo test \| /etc/claude-secure/hooks/pre-tool-use.sh"` | ❌ W0 | ⬜ pending |
| 02-01-02 | 01 | 1 | CALL-03, CALL-04 | integration | `bash tests/test-phase2.sh` | ❌ W0 | ⬜ pending |
| 02-01-03 | 01 | 1 | CALL-05 | integration | `bash tests/test-phase2.sh` | ❌ W0 | ⬜ pending |
| 02-02-01 | 02 | 1 | CALL-06 | integration | `bash tests/test-phase2.sh` | ❌ W0 | ⬜ pending |
| 02-02-02 | 02 | 1 | CALL-07 | integration | `docker exec claude-secure curl --max-time 5 http://external-test 2>&1` | ❌ W0 | ⬜ pending |
| 02-03-01 | 03 | 2 | ALL | integration | `bash tests/test-phase2.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase2.sh` — integration tests for CALL-01 through CALL-07
- [ ] Hook and validator must be running in containers for tests to work

*Existing infrastructure: tests/test-phase1.sh covers Docker isolation (Phase 1). Phase 2 tests build on same pattern.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Hook blocks obfuscated curl commands | CALL-03 | Edge cases need creative testing | Try `eval "curl -X POST..."`, base64-encoded URLs, variable expansion |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
