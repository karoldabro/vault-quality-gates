#!/usr/bin/env bash
# phpstan --error-format=json. Counts file errors above whatever the project's
# baseline neon already suppresses.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
f="$(guard_p_path "${1:-}")"; guard_p_readable "$f"
v="$(jq -r '.totals.file_errors // empty' "$f" 2>/dev/null)"
guard_p_emit "$v" "phpstan: ${f} has no totals.file_errors"
