#!/usr/bin/env bash
# composer-dependency-analyser console output. The selector after # picks which
# issue class to count: shadow, unused, dev-in-prod, prod-only-in-dev.
# "No composer issues found" is a real zero, not an absent measurement.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
f="$(guard_p_path "${1:-}")"; sel="$(guard_p_selector "${1:-}")"; [ -n "$sel" ] || sel=shadow
guard_p_readable "$f"
plain="$(sed 's/\x1b\[[0-9;]*m//g' "$f")"
grep -q 'Found [0-9]\|No composer issues found' <<<"$plain" \
    || guard_p_die "cda: ${f} carries no result line, the command did not complete"
n="$(grep -oE "Found [0-9]+ ${sel}" <<<"$plain" | grep -oE '[0-9]+' | head -1)"
[ -n "$n" ] || n=0
guard_p_emit "$n"
