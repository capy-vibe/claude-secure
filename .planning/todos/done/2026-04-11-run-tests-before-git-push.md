---
created: 2026-04-11T12:40:45.830Z
title: Run tests before git push
area: tooling
files: []
---

## Problem

There is no automated gate to ensure tests pass before code is pushed to the remote repository. This risks pushing broken code that could fail CI or break the main branch.

## Solution

Add a git pre-push hook that runs the project's test suite and blocks the push if any tests fail. This could be implemented as a shell script in `.git/hooks/pre-push` or managed via the project's hook infrastructure. Consider which test suites to run (unit tests, integration tests, or a fast subset) to keep push latency reasonable.
