# Phase 02: Call Validation - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md -- this log preserves the alternatives considered.

**Date:** 2026-04-08
**Phase:** 02-call-validation
**Areas discussed:** Hook response format, Domain extraction strategy, Read-only request detection, iptables rule management
**Mode:** Auto (--auto flag, all defaults selected)

---

## Hook Response Format

| Option | Description | Selected |
|--------|-------------|----------|
| JSON stdout + exit code | Exit 0 = allow, exit 2 = block with JSON error on stdout | ✓ |
| Exit code only | Simple exit 0/1 with no structured output | |
| Structured file output | Write decision to a temp file | |

**User's choice:** JSON stdout + exit code (auto-selected recommended default)
**Notes:** Matches Claude Code PreToolUse hook protocol documented in training data.

---

## Domain Extraction Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Regex-based URL/domain extraction | Parse curl/wget URLs with regex, block if unparseable | ✓ |
| AST-based command parsing | Use shell parser to extract command structure | |
| Allowlist command patterns only | Only allow known-safe command patterns | |

**User's choice:** Regex-based extraction with fail-closed default (auto-selected recommended default)
**Notes:** Pragmatic approach -- covers common patterns (curl, wget, WebFetch URLs). Blocking unparseable commands is the secure default.

---

## Read-Only Request Detection

| Option | Description | Selected |
|--------|-------------|----------|
| HTTP method + data flag detection | Check for POST/PUT/PATCH/DELETE flags and data arguments | ✓ |
| Treat all Bash curl as write | Conservative -- require call-ID for any curl command | |
| Network-level inspection | Let iptables/validator decide based on packet content | |

**User's choice:** HTTP method + data flag detection (auto-selected recommended default)
**Notes:** Checks -X POST, -d, --data, -F, --form, --upload-file, and pipe-to-curl patterns. Allows read-only GET to non-whitelisted domains per CALL-04.

---

## iptables Rule Management

| Option | Description | Selected |
|--------|-------------|----------|
| Validator-managed per-call rules | Validator adds/removes ACCEPT rules per call-ID with auto-cleanup | ✓ |
| Persistent allowlist rules | Static rules based on whitelist, no per-call dynamics | |
| Proxy-only enforcement | Skip iptables, enforce only at proxy level | |

**User's choice:** Validator-managed per-call rules (auto-selected recommended default)
**Notes:** Default DROP on OUTPUT chain, ACCEPT only for proxy:8080 and validator:8088. Temporary rules added per registered call-ID. Matches CALL-07 requirement for network-level enforcement.

---

## Claude's Discretion

- Exact regex patterns for URL extraction
- Log format and verbosity
- SQLite schema details beyond core columns

## Deferred Ideas

None
