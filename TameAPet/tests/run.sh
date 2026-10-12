#!/bin/sh
# Headless checks for Tame a Pet (needs Lune: https://lune-org.github.io).
set -e
cd "$(dirname "$0")/.."
lune run tests/run.luau
