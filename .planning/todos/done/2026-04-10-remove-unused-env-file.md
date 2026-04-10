---
created: 2026-04-10T14:40:38.445Z
title: Remove unused .env file
area: general
files:
  - .env
---

## Problem

The `.env` file in the project root is currently not used. The project uses the `.env` file located in the `.claude-secret` directory on the host instead. The unused `.env` file should be removed along with any references or links to it (e.g., in docker-compose, scripts, or documentation) to avoid confusion.

## Solution

1. Verify that `.env` is indeed unused by checking all references (docker-compose.yml, scripts, Dockerfiles, documentation)
2. Confirm that `.claude-secret/.env` is the actual source of environment variables
3. Delete the root `.env` file
4. Remove any references/links to the root `.env` file
