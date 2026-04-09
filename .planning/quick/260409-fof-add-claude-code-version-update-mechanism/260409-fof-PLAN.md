---
phase: quick
plan: 260409-fof
type: execute
wave: 1
depends_on: []
files_modified:
  - bin/claude-secure
autonomous: true
must_haves:
  truths:
    - "Running `claude-secure upgrade` rebuilds the claude image with --no-cache to pull latest @anthropic-ai/claude-code"
    - "Running `claude-secure status` shows the installed Claude Code version alongside container status"
  artifacts:
    - path: "bin/claude-secure"
      provides: "upgrade subcommand and version-enhanced status"
      contains: "upgrade)"
  key_links:
    - from: "bin/claude-secure upgrade"
      to: "docker compose build --no-cache claude"
      via: "case statement branch"
      pattern: "build --no-cache claude"
---

<objective>
Add an `upgrade` subcommand to `claude-secure` that rebuilds the claude container with `--no-cache` to pull the latest `@anthropic-ai/claude-code`, and enhance the `status` subcommand to display the currently installed Claude Code version.

Purpose: Let users easily update Claude Code to the latest version without manually running docker commands, and see what version they're running.
Output: Updated `bin/claude-secure` script with `upgrade` and enhanced `status`.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@bin/claude-secure
@claude/Dockerfile
</context>

<tasks>

<task type="auto">
  <name>Task 1: Add upgrade subcommand and enhance status with version display</name>
  <files>bin/claude-secure</files>
  <action>
Modify the case statement in `bin/claude-secure` to add two changes:

1. **Add `upgrade` subcommand** (new case branch before `update`):
   ```
   upgrade)
     echo "Upgrading Claude Code to latest version..."
     docker compose build --no-cache claude
     echo "Upgrade complete. Restart with: claude-secure"
     ;;
   ```
   The `--no-cache` flag forces Docker to re-run the `npm install -g @anthropic-ai/claude-code` step, pulling the latest version from npm. Only rebuilds the `claude` service (not proxy or validator).

2. **Enhance `status` subcommand** to show Claude Code version:
   ```
   status)
     docker compose ps
     # Show Claude Code version if claude container is running
     if docker compose ps --status running --format '{{.Service}}' | grep -q '^claude$'; then
       echo ""
       echo "Claude Code version: $(docker compose exec -T claude claude --version 2>/dev/null || echo 'unknown')"
     fi
     ;;
   ```
   Use `-T` flag (no TTY) on exec since this is non-interactive output. If the container is not running, only show `docker compose ps` output (no version). The `2>/dev/null` handles cases where claude binary might produce stderr output.

3. **Add a `help` case** with usage info (add before the `*` default case):
   ```
   help|--help|-h)
     echo "Usage: claude-secure [command]"
     echo ""
     echo "Commands:"
     echo "  (none)     Start containers and open Claude Code session"
     echo "  status     Show container status and Claude Code version"
     echo "  stop       Stop all containers"
     echo "  update     Pull latest claude-secure and rebuild"
     echo "  upgrade    Rebuild claude image with latest Claude Code (--no-cache)"
     echo "  help       Show this help message"
     ;;
   ```
  </action>
  <verify>
    <automated>bash -n /home/igor9000/claude-secure/bin/claude-secure && echo "Syntax OK" && grep -q 'upgrade)' /home/igor9000/claude-secure/bin/claude-secure && grep -q 'no-cache' /home/igor9000/claude-secure/bin/claude-secure && grep -q 'claude --version' /home/igor9000/claude-secure/bin/claude-secure && echo "All patterns found"</automated>
  </verify>
  <done>
    - `claude-secure upgrade` case branch exists and runs `docker compose build --no-cache claude`
    - `claude-secure status` shows container status AND Claude Code version when running
    - `claude-secure help` prints usage information
    - Script passes bash syntax check
  </done>
</task>

</tasks>

<verification>
- `bash -n bin/claude-secure` passes (no syntax errors)
- `grep -c 'upgrade\|status\|help' bin/claude-secure` shows all three subcommands present
- The upgrade command specifically targets only the `claude` service with `--no-cache`
- The status command gracefully handles the case where containers are not running
</verification>

<success_criteria>
- `claude-secure upgrade` rebuilds only the claude container with --no-cache to get latest npm package
- `claude-secure status` displays container status plus Claude Code version when running
- `claude-secure help` shows available commands
- Script remains valid bash with no syntax errors
</success_criteria>

<output>
After completion, create `.planning/quick/260409-fof-add-claude-code-version-update-mechanism/260409-fof-SUMMARY.md`
</output>
