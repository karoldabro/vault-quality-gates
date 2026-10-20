#!/usr/bin/env bash
# knip driver: unused files, exports, types and dependencies. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [runner=<repo path>] [bin=<knip path>] [config=<tree path>] [-- <extra knip argv>]
#   bin     default node_modules/.bin/knip, relative to the measured tree
#   config  default knip.json, passed as --config so no sibling config file shadows it
#
# metric = entries in every issue array of every file but `file` itself. knip exits 1 when it
# reports issues; 2 and above is a failure to run. Nuxt modules log to stdout before the report, so
# the report is the first stdout line starting with `{`.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"knip","summary":"knip: counts unused files, exports, types and dependencies","requires":["jq"],"needs_tree":true,"sandbox":true,"writes":["node_modules/.cache"]}\n' ;;
    explain)
        if [ -n "${2:-}" ]; then
            printf 'knip issue type %s. Delete the unused file, export, type or dependency, or use it; an entry\n' "${2#knip.}"
            printf 'knip cannot see belongs in knip.json, which the commit gate protects.\n'
        else
            printf 'Runs knip and counts every unused file, export, type and dependency it lists. Delete what is\n'
            printf 'unused. Keys: runner bin config, then -- <knip argv>.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        bin="$(qg_kv bin)" || bin='node_modules/.bin/knip'
        config="$(qg_kv config)" || config='knip.json'
        read -ra argv <<<"$(qg_argv)"
        qg_tool - '0 1' "$bin" --reporter json --config "$config" "${argv[@]}" || { qg_fail knip issues "$QG_ERROR"; exit 0; }
        grep -m1 '^{' "${QG_OUT}/stdout" > "${QG_OUT}/knip.json"
        if ! jq -e '.issues | type == "array"' "${QG_OUT}/knip.json" >/dev/null 2>&1; then
            tail -20 "${QG_OUT}/stdout"
            qg_fail knip issues "knip exited ${QG_RC} and printed no JSON report"; exit 0
        fi
        jq -c '[.issues[] | .file as $f | to_entries[] | select(.key != "file" and (.value | type) == "array")
                | .key as $t | .value[]
                | {ruleId: ("knip." + $t), file: $f, line: (if type == "object" then .line else null end), level: "warning",
                   message: ($t + ": " + (if type == "array" then (map(.name? // tostring) | join(", "))
                                          elif type == "object" then ((if .namespace then .namespace + "." else "" end) + (.name // ""))
                                          else tostring end)),
                   doc: null}]
               | sort_by(.file, .ruleId, (.line // 0), .message)' "${QG_OUT}/knip.json" > "${QG_OUT}/findings.json" \
            || { qg_fail knip issues 'knip printed an unreadable report'; exit 0; }
        qg_result knip measured "$(jq length "${QG_OUT}/findings.json")" issues "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage knip ;;
esac
