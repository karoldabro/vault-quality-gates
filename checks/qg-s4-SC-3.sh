#!/usr/bin/env bash
# S4 SC-3 — migrations/recycling_mobile_app/checks.tsv loads with its config, names every v1 id of the
# checkout's committed file, gives each row a distinct real why, protects every file a row reads, holds
# no `\|` in a driver row, and runs the flutter-test and mutation-test rows last.
#
#   checks/qg-s4-SC-3.sh [<recycling_mobile_app checkout>]     default ~/workspace/recycling_mobile_app
#
# Exit 0 pass, 1 fail, 2 could not run. The load, why, protection and order cases run in
# tests/unit/qg-migration-mobile.bats; this script adds the comparison with the checkout's v1 ids.
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE="${1:-$HOME/workspace/recycling_mobile_app}"
v1="$(git -C "$LIVE" show release/1.17.0:quality/checks.tsv 2>/dev/null)" \
    || { echo "cannot read quality/checks.tsv at release/1.17.0 of ${LIVE}"; exit 2; }
if [ "$(head -1 <<<"$v1")" = "$(printf 'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate')" ]; then
    missing="$(comm -23 <(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && NF > 1 { print $1 }' <<<"$v1" | sort) \
                        <(awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $1 }' "$ROOT/migrations/recycling_mobile_app/checks.tsv" | sort))"
    [ -z "$missing" ] || { printf 'v1 ids the v2 file does not name:\n%s\n' "$missing"; exit 1; }
fi
. "$ROOT/checks/_qg-cases.sh"
qg_cases \
    qg-migration-mobile.bats \
    "the v2 file loads, names every v1 id, and every why is distinct and real" \
    "every file a v2 row reads, every Dart default config and every package override is protected" \
    "no driver row holds a table-escaped \\| and the suite rows run after every other push or baseline row"
