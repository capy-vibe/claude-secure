# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v1.0 — MVP

**Shipped:** 2026-04-11
**Phases:** 11 | **Plans:** 21 | **Timeline:** 4 days (2026-04-08 to 2026-04-11)

### What Was Built
- Four-layer security wrapper: Docker isolation, PreToolUse hook validation, secret-redacting proxy, iptables call validator
- One-command installer with WSL2 support and CLI wrapper (`claude-secure`)
- Per-service structured JSON logging with host-side unified log directory
- Dynamic secret loading via env_file (no docker-compose.yml edits for new secrets)
- Multi-instance support with `--instance NAME`, auto-creation, migration, list/remove
- Smart pre-push hook with test-map.json-based test selection and dedicated test instance
- 52 integration tests across 9 test scripts covering 48 requirements

### What Worked
- Per-phase test scripts (vs standalone E2E suite) gave better test locality and faster iteration
- Shared network namespace (`network_mode: service:claude`) simplified iptables enforcement
- Zero external dependencies in proxy (Node.js stdlib) and validator (Python stdlib) — no supply chain risk
- Phase-by-phase execution with per-plan atomic commits made progress trackable and reversible
- env_file pattern eliminated entire class of "forgot to add secret to docker-compose.yml" errors

### What Was Inefficient
- Phase 5 (Integration Testing) was planned as standalone but never built — tests were already covered per-phase. The planning overhead for an unneeded phase could have been avoided with earlier audit
- ROADMAP.md had stale progress table entries (phases 1-2 showing "Planning complete" after execution) — automation didn't catch all status fields
- REQUIREMENTS.md summary count said "41 total" while actual count was 48 after Phase 9 additions — summary line wasn't auto-updated

### Patterns Established
- Docker Compose `internal: true` network + second external network for proxy — standard isolation pattern
- `COMPOSE_PROJECT_NAME` for multi-instance isolation (no container_name directives)
- test-map.json for path-to-test mapping consumed by pre-push hook
- Per-request config reload in proxy (no restart needed for whitelist changes)
- SQLite WAL mode for concurrent call-ID registration and validation

### Key Lessons
- Build tests alongside features (per-phase), not as a separate "testing phase"
- Run milestone audit before the final phase — Phase 11 gap closure was efficient because audit identified exact gaps
- Shared network namespace is simpler than iptables across namespaces — prefer it for container-level enforcement
- Zero-dependency services (stdlib only) in security-critical paths reduce attack surface and simplify maintenance

## Cross-Milestone Trends

| Metric | v1.0 |
|--------|------|
| Phases | 11 |
| Plans | 21 |
| Requirements | 48 |
| LOC | ~3,000 |
| Timeline | 4 days |
| Test count | 52 |
