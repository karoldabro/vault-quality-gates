#!/usr/bin/env bash
# PHP Insights --format=json. The selector after # picks the category:
# code, complexity, architecture, style.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
f="$(guard_p_path "${1:-}")"; sel="$(guard_p_selector "${1:-}")"; [ -n "$sel" ] || sel=code
guard_p_readable "$f"
v="$(jq -r --arg k "$sel" '.summary[$k] // empty' "$f" 2>/dev/null)"
guard_p_emit "$v" "insights: ${f} has no summary.${sel}"
