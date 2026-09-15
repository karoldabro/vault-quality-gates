#!/usr/bin/env bash
# diff-cover --json-report. Coverage of the changed lines only.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
f="$(guard_p_path "${1:-}")"; guard_p_readable "$f"
total="$(jq -r '.total_num_lines // 0' "$f" 2>/dev/null)"
[ "${total:-0}" -gt 0 ] 2>/dev/null || guard_p_die "diffcover: no lines changed, nothing to measure"
v="$(jq -r '.total_percent_covered // empty' "$f" 2>/dev/null)"
guard_p_emit "$v" "diffcover: ${f} has no total_percent_covered"
