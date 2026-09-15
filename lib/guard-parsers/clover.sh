#!/usr/bin/env bash
# Line coverage percentage from a Clover XML report.
# The project-level <metrics> is the authoritative total.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
f="$(guard_p_path "${1:-}")"; guard_p_readable "$f"

attr() { xmllint --xpath "string(/coverage/project/metrics/@$1)" "$f" 2>/dev/null; }
total="$(attr statements)"; covered="$(attr coveredstatements)"

[ -n "$total" ] || guard_p_die "clover: ${f} has no /coverage/project/metrics"
[ "$total" -gt 0 ] 2>/dev/null || guard_p_die "clover: zero statements, nothing was measured"

guard_p_emit "$(awk -v c="${covered:-0}" -v t="$total" 'BEGIN { printf "%.2f", c / t * 100 }')"
