#!/usr/bin/env bash
# The command's own exit status as the metric: 0 clean, 1 dirty. Any other status
# is exit 2 — 127 is "command not found", which must never read as a passing check.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
case "${2:-}" in
    0) printf '0\n' ;;
    1) printf '1\n' ;;
    '') guard_p_die "exitcode: no command status passed" ;;
    *) guard_p_die "exitcode: command exited ${2}, which is neither clean nor a finding" ;;
esac
