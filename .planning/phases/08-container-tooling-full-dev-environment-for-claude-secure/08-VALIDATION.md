---
phase: 8
slug: container-tooling-full-dev-environment-for-claude-secure
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-10
---

# Phase 8 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash + curl + jq (shell-based integration tests) |
| **Config file** | None (scripts are self-contained) |
| **Quick run command** | `make test` |
| **Full suite command** | `bash tests/run-all.sh` |
| **Estimated runtime** | ~60 seconds |

---

## Sampling Rate

- **After every task commit:** Run `make test`
- **After every plan wave:** Run `bash tests/run-all.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 60 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 08-01-01 | 01 | 1 | Makefile targets | smoke | `make build` exits 0 | ❌ W0 | ⬜ pending |
| 08-01-02 | 01 | 1 | Dev watch mode | smoke | `docker compose -f docker-compose.yml -f docker-compose.dev.yml config --quiet` | ❌ W0 | ⬜ pending |
| 08-01-03 | 01 | 1 | ShellCheck linting | smoke | `make lint` exits 0 | ❌ W0 | ⬜ pending |
| 08-02-01 | 02 | 1 | Unified test runner | integration | `make test` exits 0 | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Makefile` — dev command surface (does not exist yet)
- [ ] `docker-compose.dev.yml` — dev overrides with watch config (does not exist yet)
- [ ] `tests/run-all.sh` — unified test runner (does not exist yet)

*All three are deliverables of this phase.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| `make dev` starts watch mode and syncs changes | Dev workflow | Watch mode requires interactive terminal and code edit | Start `make dev`, edit proxy.js, verify container restarts |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
