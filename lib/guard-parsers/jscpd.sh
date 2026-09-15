#!/usr/bin/env bash
# jscpd-report.json. The selector after # picks the number; default is the
# duplicated-line percentage. Legal selectors: percentage, clones, newClones,
# duplicatedLines, percentageTokens.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
f="$(guard_p_path "${1:-}")"; sel="$(guard_p_selector "${1:-}")"; [ -n "$sel" ] || sel=percentage
guard_p_readable "$f"
v="$(jq -r --arg k "$sel" '.statistics.total[$k] // empty' "$f" 2>/dev/null)"
case "$sel" in percentage|percentageTokens) v="$(awk -v v="$v" 'BEGIN { if (v != "") printf "%.2f", v }')" ;; esac
guard_p_emit "$v" "jscpd: ${f} has no statistics.total.${sel}"
