#!/usr/bin/env bash
# Failing tests (failures + errors) from a JUnit XML report. A zero-byte file is
# exit 2: an empty report means the suite never wrote one, not that it passed.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
f="$(guard_p_path "${1:-}")"; guard_p_readable "$f"
[ -s "$f" ] || guard_p_die "junit: ${f} is empty, the suite recorded nothing"

attr() { xmllint --xpath "string((//testsuite)[1]/@$1)" "$f" 2>/dev/null; }
tests="$(attr tests)"
[ -n "$tests" ] || guard_p_die "junit: ${f} has no <testsuite> element"
[ "$tests" -gt 0 ] 2>/dev/null || guard_p_die "junit: zero tests ran"

# Anyone can write the report, and $(( )) would run a command hidden in an attribute.
failures="$(attr failures)"; errors="$(attr errors)"
[[ "${failures:-0}" =~ ^[0-9]+$ ]] && [[ "${errors:-0}" =~ ^[0-9]+$ ]] \
    || guard_p_die "junit: ${f} carries a failures or errors value that is not a whole number"
guard_p_emit "$(( ${failures:-0} + ${errors:-0} ))"
