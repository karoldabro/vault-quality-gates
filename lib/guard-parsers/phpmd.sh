#!/usr/bin/env bash
# phpmd --reportfile json. Counts files[].violations[]. A file PHPMD could not parse is
# listed under errors[] and is exit 2, naming the file: an unparsed file was never checked.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
f="$(guard_p_path "${1:-}")"; guard_p_readable "$f"
jq -e '(.files | type) == "array"' "$f" >/dev/null 2>&1 || guard_p_die "phpmd: ${f} has no files array"
bad="$(jq -r '(.errors // [])[] | "\(.fileName // "-"): \(.message // "-")"' "$f" 2>/dev/null | head -3)"
[ -z "$bad" ] || guard_p_die "phpmd could not parse: ${bad//$'\n'/; }"
v="$(jq -r '[.files[].violations[]?] | length' "$f" 2>/dev/null)"
guard_p_emit "$v" "phpmd: ${f} is not PHPMD JSON"
