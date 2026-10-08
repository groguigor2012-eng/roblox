#!/bin/sh
# Full offline verification for Protect the Pumpkin Farm.
#   1. compile every .luau file (syntax)            - needs Lune
#   2. selene lint (undefined/unused variables)     - optional, needs selene
#   3. static cross-reference checks                - needs python3
#   4. headless unit + transaction specs            - needs Lune
#   5. end-to-end server simulation (6 scenarios)   - needs Lune, about a minute
# Run from anywhere: PumpkinFarm/tests/run.sh
set -e
cd "$(dirname "$0")/.."
lune run tests/compile_check.luau
if command -v selene >/dev/null 2>&1; then
	selene src
else
	echo "selene not installed, skipping lint"
fi
python3 tests/static_check.py
lune run tests/run.luau
lune run tests/simulate.luau
