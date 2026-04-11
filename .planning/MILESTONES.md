# Milestones

## v1.0 MVP (Shipped: 2026-04-11)

**Phases completed:** 10 phases, 21 plans, 39 tasks

**Key accomplishments:**

- Dual-network Docker topology with 3 container stubs, DNS exfiltration blocking, capability dropping, and root-owned immutable security configuration
- 10-test bash integration suite verifying Docker network isolation, DNS blocking, capability dropping, file permissions, and whitelist configuration
- SQLite-backed call validator with iptables OUTPUT DROP policy enforced via shared Docker network namespace
- Full PreToolUse hook with domain extraction from curl/wget/WebFetch, whitelist enforcement, obfuscation detection, and call-ID registration via validator
- 13-test integration suite verifying hook interception, domain blocking, call-ID registration/single-use/expiry, and iptables enforcement in live Docker topology
- Buffered proxy with per-request whitelist reload, secret-to-placeholder redaction in outbound bodies, placeholder-to-secret restoration in inbound bodies, and OAuth/API-key auth forwarding
- 8-test integration suite proving secret redaction, placeholder restoration, config hot-reload, and auth forwarding via mock upstream in Docker
- Bash installer with dependency preflight, WSL2/Docker Desktop detection, OAuth/API key auth, and CLI wrapper with four subcommands
- 12 integration tests covering installer dependency checking, platform detection, auth setup, directory permissions, Docker builds, CLI wrapper validation, and container topology verification
- Integration test script verifying all 7 LOG requirements via Docker Compose with enabled/disabled logging and JSON structure validation
- Dynamic secret loading via Docker Compose env_file on proxy service, eliminating hardcoded secret var names from docker-compose.yml
- Integration tests proving env_file secret loading works for all 5 ENV requirements using Docker compose exec container inspection
- Expanded Claude container from minimal node:22-slim to full dev environment with git, gcc/make, Python3/pip/venv, ripgrep, and fd-find
- Removed hardcoded container_name directives and added LOG_PREFIX/WHITELIST_PATH parameterization across all services for COMPOSE_PROJECT_NAME-based multi-instance isolation
- Multi-instance CLI via --instance NAME flag with auto-create, migration, list/remove commands, and installer creating instances/default/ layout
- 9 integration tests covering instance flag parsing, DNS validation, migration, compose isolation, LOG_PREFIX, list command, and config scoping
- Migrated 52 docker exec calls to docker compose exec across 5 test scripts and created test-map.json with 15 path-to-test mappings plus test.env with dummy credentials
- Production-ready pre-push hook with jq-based test selection from test-map.json, dedicated claude-test compose instance, clean-state teardown between suites, and PASS/FAIL summary table with requirement IDs
- Closed v1.0 audit gaps: test-map.json coverage expanded to 3 cross-cutting source files, all 41 requirements marked Complete, /validate documented as debug-only

---
