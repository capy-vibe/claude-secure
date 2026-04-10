---
phase: 6
slug: service-logging
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-10
---

# Phase 6 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash + docker compose (integration tests) |
| **Config file** | tests/test-logging.sh (Wave 0 installs) |
| **Quick run command** | `docker compose exec claude bash /app/tests/test-logging.sh --quick` |
| **Full suite command** | `docker compose exec claude bash /app/tests/test-logging.sh` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `docker compose exec claude bash /app/tests/test-logging.sh --quick`
- **After every plan wave:** Run `docker compose exec claude bash /app/tests/test-logging.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 06-01-01 | 01 | 1 | LOG-01 | integration | `grep LOG_HOOK docker-compose.yml` | ❌ W0 | ⬜ pending |
| 06-01-02 | 01 | 1 | LOG-02 | integration | `grep LOG_ANTHROPIC docker-compose.yml` | ❌ W0 | ⬜ pending |
| 06-01-03 | 01 | 1 | LOG-03 | integration | `grep LOG_IPTABLES docker-compose.yml` | ❌ W0 | ⬜ pending |
| 06-02-01 | 02 | 2 | LOG-04 | integration | `test -f ~/.claude-secure/logs/hook.jsonl` | ❌ W0 | ⬜ pending |
| 06-02-02 | 02 | 2 | LOG-05 | integration | `jq . ~/.claude-secure/logs/proxy.jsonl` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-logging.sh` — integration test script for logging features
- [ ] Log directory creation in CLI wrapper

*Existing Docker test infrastructure covers container-level testing.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Secret values never appear in log files | LOG-SEC | Security-critical visual inspection | Run with LOG_ANTHROPIC=1, send request with secret, grep log file for secret value |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
