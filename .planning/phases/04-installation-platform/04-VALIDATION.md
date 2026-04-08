---
phase: 04
slug: installation-platform
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-09
---

# Phase 04 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash + docker compose (shell-based integration tests) |
| **Config file** | none — tests are standalone bash scripts |
| **Quick run command** | `bash -n install.sh && bash -n bin/claude-secure` |
| **Full suite command** | `bash tests/test-phase4.sh` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash -n install.sh && bash -n bin/claude-secure` (syntax check)
- **After every plan wave:** Run `bash tests/test-phase4.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 04-01-01 | 01 | 1 | INST-01 | integration | `bash tests/test-phase4.sh` | ❌ W0 | ⬜ pending |
| 04-01-02 | 01 | 1 | INST-02 | integration | `bash tests/test-phase4.sh` | ❌ W0 | ⬜ pending |
| 04-01-03 | 01 | 1 | INST-03 | integration | `bash tests/test-phase4.sh` | ❌ W0 | ⬜ pending |
| 04-01-04 | 01 | 1 | INST-04 | integration | `bash tests/test-phase4.sh` | ❌ W0 | ⬜ pending |
| 04-01-05 | 01 | 1 | INST-05 | integration | `bash tests/test-phase4.sh` | ❌ W0 | ⬜ pending |
| 04-01-06 | 01 | 1 | INST-06 | integration | `bash tests/test-phase4.sh` | ❌ W0 | ⬜ pending |
| 04-02-01 | 02 | 2 | PLAT-01 | integration | `bash tests/test-phase4.sh` | ❌ W0 | ⬜ pending |
| 04-02-02 | 02 | 2 | PLAT-02 | integration | `bash tests/test-phase4.sh` | ❌ W0 | ⬜ pending |
| 04-02-03 | 02 | 2 | PLAT-03 | integration | `bash tests/test-phase4.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase4.sh` — integration test stubs for INST and PLAT requirements
- [ ] Existing test infrastructure (test-phase1.sh, test-phase2.sh, test-phase3.sh) as pattern reference

*Existing infrastructure covers test patterns; new test file needed for this phase's requirements.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| WSL2 runtime compatibility | PLAT-02 | Requires actual WSL2 environment | Run installer and claude-secure on WSL2 with Docker CE |
| Interactive auth prompt | INST-03 | Requires user input | Run installer without env vars set, verify prompt appears |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
