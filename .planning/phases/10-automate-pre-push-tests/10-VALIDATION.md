---
phase: 10
slug: automate-pre-push-tests
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-11
---

# Phase 10 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash + Docker Compose integration tests |
| **Config file** | `tests/test-map.json` (new, created this phase) |
| **Quick run command** | `RUN_ALL_TESTS=1 bash git-hooks/pre-push < /dev/null` |
| **Full suite command** | `RUN_ALL_TESTS=1 bash git-hooks/pre-push < /dev/null` |
| **Estimated runtime** | ~180 seconds (7 suites × ~25s each with full teardown/rebuild) |

---

## Sampling Rate

- **After every task commit:** Run `bash -n git-hooks/pre-push` (syntax check)
- **After every plan wave:** Run `RUN_ALL_TESTS=1 bash git-hooks/pre-push < /dev/null`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 180 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 10-01-01 | 01 | 1 | D-01 (smart selection) | manual | Change proxy file, run hook, verify subset | N/A | ⬜ pending |
| 10-01-02 | 01 | 1 | D-02 (RUN_ALL_TESTS) | manual | `RUN_ALL_TESTS=1 bash git-hooks/pre-push < /dev/null` | N/A | ⬜ pending |
| 10-01-03 | 01 | 1 | D-03 (docs-only skip) | manual | Change only .planning/ files, verify skip | N/A | ⬜ pending |
| 10-02-01 | 02 | 1 | D-04 (test instance) | manual | Run hook while another instance active | N/A | ⬜ pending |
| 10-02-02 | 02 | 1 | D-05 (teardown on success) | manual | After success, verify containers down | N/A | ⬜ pending |
| 10-02-03 | 02 | 1 | D-08 (clean state) | manual | Observe `docker compose down --volumes` between suites | N/A | ⬜ pending |
| 10-03-01 | 03 | 2 | D-07 (summary table) | manual | Introduce failure, verify table output | N/A | ⬜ pending |
| 10-03-02 | 03 | 2 | D-09 (test .env) | manual | Verify test instance uses own credentials | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

*Existing infrastructure covers all phase requirements. No test framework to install — this phase creates the test orchestration itself.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Smart test selection | D-01 | Requires actual git state with changed files | Change a proxy file, run hook, verify only proxy suites execute |
| RUN_ALL_TESTS override | D-02 | Requires env var override during hook run | `RUN_ALL_TESTS=1 bash git-hooks/pre-push < /dev/null` |
| Docs-only skip | D-03 | Requires specific git diff state | Stage only .planning/ changes, run hook, verify exit 0 with skip |
| Test instance isolation | D-04 | Requires running instance to test collision | Start default instance, run hook, verify separate project |
| Teardown on success only | D-05 | Requires observing container state after run | Check `docker compose -p claude-test ps` after success vs failure |
| Full teardown between suites | D-08 | Requires observing hook output during run | Watch for `docker compose down --volumes` between each suite |
| Summary table on failure | D-07 | Requires deliberate test failure | Break a test, run hook, verify table format |
| Test .env credentials | D-09 | Requires inspecting env inside test containers | Run hook, exec into test container, check env vars |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 180s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
