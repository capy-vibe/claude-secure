---
phase: 1
slug: docker-infrastructure
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-08
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash + docker compose exec + curl |
| **Config file** | None needed -- shell scripts |
| **Quick run command** | `bash tests/test-phase1.sh` |
| **Full suite command** | `bash tests/test-phase1.sh` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase1.sh`
- **After every plan wave:** Run `bash tests/test-phase1.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 01-01-01 | 01 | 1 | DOCK-01 | integration | `docker exec claude-secure curl -sf --max-time 5 https://api.anthropic.com && exit 1 \|\| exit 0` | Wave 0 | pending |
| 01-01-02 | 01 | 1 | DOCK-02 | integration | `docker exec claude-proxy curl -sf --max-time 10 https://api.anthropic.com/v1 -o /dev/null` | Wave 0 | pending |
| 01-01-03 | 01 | 1 | DOCK-03 | smoke | `docker compose ps --format json \| jq -e 'length == 3'` | Wave 0 | pending |
| 01-01-04 | 01 | 1 | DOCK-04 | integration | `docker exec claude-secure nslookup google.com 2>&1 \| grep -q "SERVFAIL\|connection timed out\|can't resolve"` | Wave 0 | pending |
| 01-01-05 | 01 | 1 | DOCK-05 | integration | `docker exec claude-secure stat -c '%U %a' /etc/claude-secure/whitelist.json \| grep -q 'root 444'` | Wave 0 | pending |
| 01-01-06 | 01 | 1 | DOCK-06 | integration | `docker inspect claude-secure --format '{{.HostConfig.CapDrop}}' \| grep -q ALL` | Wave 0 | pending |
| 01-02-01 | 02 | 1 | WHIT-01 | unit | `jq -e '.secrets[0] \| has("placeholder","env_var","allowed_domains")' config/whitelist.json` | Wave 0 | pending |
| 01-02-02 | 02 | 1 | WHIT-02 | unit | `jq -e 'has("readonly_domains")' config/whitelist.json` | Wave 0 | pending |
| 01-02-03 | 02 | 1 | WHIT-03 | integration | `docker exec claude-secure test ! -w /etc/claude-secure/whitelist.json` | Wave 0 | pending |

---

## Wave 0 Requirements

- [ ] `tests/test-phase1.sh` — integration test script covering all 9 requirements
- [ ] All containers buildable and startable via `docker compose up`

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| None | — | — | All phase behaviors have automated verification |

---

## Validation Sign-Off

- [ ] All tasks have automated verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
