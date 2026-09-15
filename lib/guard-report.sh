#!/usr/bin/env bash
# Renders one guard run into quality-reports/status.json and REPORT.md.
#
# Reads the pipe-separated results of bin/guard.sh on stdin:
#   id|value|baseline|status|detail
#
# status.json keeps the six category keys ~/vault/givore/quality/build-dashboard.mjs
# fixes. An id outside them lands under codeQuality.checks, which that aggregator
# already renders as an open map. REPORT.md carries exactly four headings, in the
# order below; the operator reads it and nothing parses it.
#
# bash and jq only. A PHP repo should not need a Python runtime to read its own gate.

set -uo pipefail
export LC_ALL=C

reports="$1"; commit="$2"; accepted="$3"; surface="$4"
mkdir -p "$reports"

rows="$(while IFS='|' read -r id value base status detail; do
    [ -n "${id:-}" ] || continue
    jq -nc --arg id "$id" --arg value "${value:-}" --arg baseline "${base:-}" \
           --arg status "${status:-}" --arg detail "${detail:-}" \
       '{id:$id, value:$value, baseline:$baseline, status:$status, detail:$detail}'
done | jq -sc '.')"
[ -n "$rows" ] || rows='[]'

jq -n --argjson rows "$rows" --arg commit "$commit" --arg surface "$surface" \
      --arg accepted "${accepted:-0}" --arg now "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
      -f "$(dirname "$0")/guard-status.jq" > "${reports}/status.json"

# --- REPORT.md ---------------------------------------------------------------

table() {   # table <jq select expression>
    local body
    body="$(jq -r --argjson rows "$rows" -n \
        "\$rows | map(select($1)) | .[] | \"| \\(.id) | \\(.value) | \\(.baseline) | \\(.detail) |\"")"
    if [ -z "$body" ]; then printf '_none_\n'; return; fi
    printf '| metric | measured | baseline | detail |\n|---|---|---|---|\n%s\n' "$body"
}

{
    printf '# Quality report — %s\n\n' "${commit:-working tree}"
    printf '## Open regressions\n\n';  table '.status == "worse"';        printf '\n'
    printf '## Unmeasurable\n\n';      table '.status == "unmeasurable"'; printf '\n'
    printf '## All metrics\n\n';       table '.status != "absent"';       printf '\n'
    printf '## Absent\n\n';            table '.status == "absent"'
} > "${reports}/REPORT.md"
