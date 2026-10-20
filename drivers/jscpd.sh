#!/usr/bin/env bash
# jscpd driver for the whole repo: the duplicated-line percentage or the clone count. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [metric=percentage|clones] [paths=<dir,dir>] [version=<jscpd version>] [bin=<tree path>]
#        [config=<tree path>] [min-lines=<n>] [min-tokens=<n>] [format=<f>] [ignore=<glob>]
#        [runner=<repo path>] [-- <extra jscpd argv>]
#   metric       default percentage
#   paths        default .; jscpd scans these directories of the measured tree
#   version      default 5.3.2, run as `pnpm dlx jscpd@<version>` when bin= is absent
#   bin          an installed jscpd, run from the measured tree; config  passed as -c
#
# Rows of one run with the same args, metric= aside, share one jscpd run.
# metric percentage = .statistics.total.percentage with two decimals; clones = .statistics.total.clones.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"jscpd","summary":"jscpd: duplicated-line percentage or clone count of the repo","requires":["jq","pnpm"],"needs_tree":true,"sandbox":false,"writes":[]}\n' ;;
    explain)
        printf 'Finds copied blocks with jscpd across the scanned paths. Extract the shared code into one function,\n'
        printf 'composable or module. Keys: metric (percentage, clones) paths version bin config min-lines min-tokens\n'
        printf 'format ignore runner, then -- <argv>.\n' ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        metric="$(qg_kv metric)" || metric=percentage
        case "$metric" in
            percentage) unit=percent ;;
            clones)     unit=clones ;;
            *) qg_fail jscpd clones "metric=${metric} is not percentage or clones"; exit 0 ;;
        esac
        qg_paths .
        qg_shared_report jscpd.json qg_jscpd_report || { qg_fail jscpd "$unit" "$QG_ERROR"; exit 0; }
        v="$(jq -r --arg k "$metric" '.statistics.total[$k] | select(type == "number")' "${QG_OUT}/jscpd.json" 2>/dev/null)"
        [ -n "$v" ] || { qg_fail jscpd "$unit" "jscpd: the report has no numeric statistics.total.${metric}"; exit 0; }
        [ "$metric" = clones ] || v="$(awk -v v="$v" 'BEGIN { printf "%.2f", v }')"
        # One finding per clone, the first 50, on its first side.
        jq -c '[(.duplicates // [])[:50][]
                | {ruleId: "jscpd.duplicateBlock", file: .firstFile.name, line: .firstFile.start, level: "warning",
                   message: "Lines \(.firstFile.start)-\(.firstFile.end) duplicate \(.secondFile.name):\(.secondFile.start)-\(.secondFile.end)",
                   doc: null}]' "${QG_OUT}/jscpd.json" > "${QG_OUT}/findings.json" 2>/dev/null \
            || printf '[]' > "${QG_OUT}/findings.json"
        qg_result jscpd measured "$v" "$unit" "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage jscpd ;;
esac
