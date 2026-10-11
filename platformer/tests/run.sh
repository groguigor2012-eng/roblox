#!/bin/sh
# Headless checks for the platformer framework, run with Lune (https://lune-org.github.io).
#   unit.luau      behaviour of the pure modules (movement/health math, data
#                  schema + migrations, session locking, retries, rate limiting,
#                  cleanup) against an in-memory DataStore
#   contracts.luau static checks: every config key is used and every config
#                  reference exists; remotes are used on both sides
set -e
cd "$(dirname "$0")/../.."
lune run platformer/tests/unit.luau
lune run platformer/tests/contracts.luau
