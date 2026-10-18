#!/usr/bin/env bash
# dependency-cruiser driver: imports that break a rule of the dependency-cruiser config. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [runner=<repo path>] [bin=<depcruise path>] [config=<tree path>] [paths=<dir,dir>]
#        [-- <extra depcruise argv>]
#   bin     default node_modules/.bin/depcruise, relative to the measured tree
#   config  default .dependency-cruiser.cjs, passed as --config
#   paths   default .; what depcruise cruises
#
# metric = summary.violations of every severity. depcruise exits with the count of error-severity
# violations, so any exit code that comes with a JSON summary is measured; a run that cruised no
# module is an error.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"depcruise","summary":"dependency-cruiser: counts imports that break a dependency rule","requires":["jq"],"needs_tree":true}\n' ;;
    explain)
        if [ -n "${2:-}" ]; then
            printf 'dependency-cruiser rule %s. Its comment in the dependency-cruiser config says which layer may\n' "${2#depcruise.}"
            printf 'import which. Move the import behind the allowed layer or break the cycle.\n'
        else
            printf 'Runs dependency-cruiser and counts every import that breaks a rule of its config, warnings included.\n'
            printf 'Keys: runner bin config paths, then -- <depcruise argv>.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        bin="$(qg_kv bin)" || bin='node_modules/.bin/depcruise'
        config="$(qg_kv config)" || config='.dependency-cruiser.cjs'
        read -ra argv <<<"$(qg_argv)"
        qg_paths .
        qg_tool - "$(printf '%s ' {0..255})" "$bin" --config "$config" --output-type json "${argv[@]}" "${QG_PATH_LIST[@]}" \
            || { qg_fail depcruise violations "$QG_ERROR"; exit 0; }
        # The whole of stdout is one JSON document, as v1 parsed it.
        if ! jq -s -e 'length == 1 and (.[0].summary | type) == "object"' "${QG_OUT}/stdout" >/dev/null 2>&1; then
            tail -20 "${QG_OUT}/stdout"
            qg_fail depcruise violations "depcruise exited ${QG_RC} and printed no JSON summary"; exit 0
        fi
        if jq -e '.summary.totalCruised == 0' "${QG_OUT}/stdout" >/dev/null; then
            qg_fail depcruise violations 'depcruise cruised no module'; exit 0
        fi
        jq -c 'if (.summary.violations | type) != "array" then error("no list") else . end
               | [.summary.violations[]
                | {ruleId: ("depcruise." + (.rule.name // "unnamed")), file: .from, line: null,
                   level: ({"error": "error", "warn": "warning", "info": "info"}[.rule.severity // ""] // "warning"),
                   message: ("\(.type // "dependency") \(.from) -> \(.to)"
                             + (if (.cycle | type) == "array" then " (cycle " + ([.cycle[].name] | join(" -> ")) + ")" else "" end)),
                   doc: null}]
               | sort_by(.file, .ruleId, .message)' "${QG_OUT}/stdout" > "${QG_OUT}/findings.json" 2>/dev/null \
            || { qg_fail depcruise violations 'depcruise printed no summary.violations list'; exit 0; }
        qg_result depcruise measured "$(jq length "${QG_OUT}/findings.json")" violations "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage depcruise ;;
esac
