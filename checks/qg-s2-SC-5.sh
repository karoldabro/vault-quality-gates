#!/usr/bin/env bash
# S2 SC-5 — migrations/recycling-api/checks.tsv loads with its config, names every v1 id of the
# committed recycling-api file, gives each row a distinct real why, and every config file a row
# reads is protected.
#
#   checks/qg-s2-SC-5.sh [<recycling-api checkout>]     default ~/workspace/recycling-api
#
# Exit 0 pass, 1 fail, 2 could not run. The load, why and protection cases run in tests/unit/; this
# script adds the comparison with the checkout's committed v1 ids.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE="${1:-$HOME/workspace/recycling-api}"
v1="$(git -C "$LIVE" show HEAD:quality/checks.tsv 2>/dev/null)" || { echo "cannot read quality/checks.tsv at HEAD of ${LIVE}"; exit 2; }
if [ "$(head -1 <<<"$v1")" = "$(printf 'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate')" ]; then
    missing="$(comm -23 <(awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $1 }' <<<"$v1" | sort) \
                        <(awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $1 }' "$ROOT/migrations/recycling-api/checks.tsv" | sort))"
    [ -z "$missing" ] || { printf 'v1 ids the v2 file does not name:\n%s\n' "$missing"; exit 1; }
fi
. "$ROOT/checks/_qg-cases.sh"
qg_cases \
    qg-migration-recycling.bats \
    "the v2 file loads, names every v1 id, and every why is distinct and real" \
    "every config file a v2 row reads, every runner and every compose file is protected"
