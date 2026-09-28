#!/usr/bin/env bash
# phpstan --error-format=json. Counts every reported error: totals.file_errors plus
# totals.errors, the file-less ones. A boot failure or an internal error carries no file,
# and a count of file errors alone would read it as a clean run.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
f="$(guard_p_path "${1:-}")"; guard_p_readable "$f"
v="$(jq -r '.totals as $t
    | if ($t.errors | type) == "number" and ($t.file_errors | type) == "number"
      then $t.errors + $t.file_errors else empty end' "$f" 2>/dev/null)"
guard_p_emit "$v" "phpstan-all: ${f} has no numeric totals.errors and totals.file_errors"
