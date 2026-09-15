#!/usr/bin/env bash
# cloc --json. Comment density: SUM.comment / SUM.code.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
f="$(guard_p_path "${1:-}")"; guard_p_readable "$f"
v="$(jq -r 'if (.SUM.code // 0) == 0 then empty else (.SUM.comment / .SUM.code * 1000 | round / 1000) end' "$f" 2>/dev/null)"
guard_p_emit "$v" "cloc: ${f} reports zero SUM.code"
