#!/usr/bin/env bash
# Mutation Score Indicator from Infection's summaryJson or json log.
# A null msi is exit 2 — the live defect this parser exists for: a score that was
# never computed reported as a pass for three months.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
f="$(guard_p_path "${1:-}")"; guard_p_readable "$f"
msi="$(jq -r '.stats.msi // .msi // empty' "$f" 2>/dev/null)"
[ "$msi" = 'null' ] && msi=''
guard_p_emit "$msi" "infection: ${f} carries no msi, or msi is null"
