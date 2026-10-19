#!/usr/bin/env bash
# lakos driver: one dependency-graph metric of a Dart package. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-dart-drivers.md.
#
# args:  [metric=nccd|ccd|acd] [paths=<dir>] [ignore=<glob>]
#   metric   default nccd (normalized cumulative component dependency)
#   paths    default lib; one folder
#   ignore   passed as --ignore <glob>
#
# lakos exits 5 when the graph has a cycle and still prints its JSON, so exits 0 and 5 measure.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"
# shellcheck source=../lib/qg-dart.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-dart.sh"

case "${1:-}" in
    describe)
        printf '{"name":"lakos","summary":"lakos: a dependency-graph metric (nccd, ccd or acd)","requires":["jq","git"],"needs_tree":true}\n' ;;
    explain)
        printf 'Reads one lakos graph metric. A higher nccd means files depend on more of the package; remove\n'
        printf 'imports the importing file does not need. Keys: metric (nccd ccd acd) paths ignore.\n' ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        metric="$(qg_kv metric)" || metric=nccd
        case "$metric" in nccd|ccd|acd) ;; *) qg_fail lakos ratio "metric=${metric} is not nccd, ccd or acd"; exit 0 ;; esac
        qg_paths lib
        [ "${#QG_PATH_LIST[@]}" -eq 1 ] || { qg_fail lakos ratio 'driver lakos measures one folder in paths='; exit 0; }
        extra=()
        ignore="$(qg_kv ignore)" && extra=(--ignore "$ignore")
        qg_dart_prepare lakos ratio || exit 0
        qg_tool - '0 5' "$QG_DART" run lakos --format json --metrics "${extra[@]}" "${QG_PATH_LIST[0]}" \
            || { qg_fail lakos ratio "$QG_ERROR"; exit 0; }
        sed -n '/^{/,$p' "${QG_OUT}/stdout" > "${QG_OUT}/lakos.json"
        value="$(jq -e --arg m "$metric" '.metrics[$m] | numbers' "${QG_OUT}/lakos.json" 2>/dev/null)" \
            || { qg_fail lakos ratio "lakos exited ${QG_RC} with no numeric .metrics.${metric}"; exit 0; }
        jq -c 'if .metrics.isAcyclic == false and (.metrics.firstCycle | type) == "array"
               then [{ruleId: "lakos.cycle", file: null, line: null, level: "note",
                      message: ("first cycle: " + (.metrics.firstCycle | join(" -> "))), doc: null}]
               else [] end' "${QG_OUT}/lakos.json" > "${QG_OUT}/findings.json"
        qg_result lakos measured "$value" ratio "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage lakos ;;
esac
