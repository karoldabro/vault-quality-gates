#!/usr/bin/env bash
# Push pass record SC-3 — the whole unit suite passes, the 43d7082 hook bodies included.
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
command -v docker >/dev/null 2>&1 || { printf 'docker not found\n'; exit 2; }
./tests/run.sh tests/unit
