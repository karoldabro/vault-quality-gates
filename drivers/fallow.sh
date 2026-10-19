#!/usr/bin/env bash
# fallow driver: duplicated lines, layer-boundary imports, or complexity above a limit. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  metric=dupes|boundaries|complexity-excess [max-cyclomatic=<n> max-cognitive=<n>]
#        [runner=<repo path>] [bin=<fallow path>] [config=<tree path>] [-- <extra fallow argv>]
#   metric=dupes              `fallow dupes`; metric = stats.duplicated_lines
#   metric=boundaries         `fallow dead-code --boundary-violations`; metric = boundary_violations entries
#   metric=complexity-excess  `fallow health --max-cyclomatic <n> --max-cognitive <n>`, both keys required;
#                             metric = sum over findings of how far cyclomatic and cognitive exceed them
#   bin     default node_modules/.bin/fallow, relative to the measured tree
#   config  default .fallowrc.json, passed as --config so no sibling config file shadows it
#
# Each runs with --no-cache --format json. fallow exits 1 whenever it reports anything, so exits 0
# and 1 with a JSON report on stdout are measured; a report without the key the metric reads is an
# error.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"fallow","summary":"fallow: duplicated lines, boundary violations or complexity excess","requires":["jq"],"needs_tree":true}\n' ;;
    explain)
        case "${2:-}" in
            fallow.dupes)
                printf 'fallow found this block repeated elsewhere. Extract the shared code into one function or\n'
                printf 'component; `fallow dupes --trace <file>:<line>` lists every copy.\n' ;;
            fallow.boundaries)
                printf 'This import crosses a layer boundary that .fallowrc.json forbids. Import from an allowed layer\n'
                printf 'or move the code to the layer that may use it.\n' ;;
            fallow.complexity)
                printf 'This function or template is over the cyclomatic or cognitive limit of the row. Split it into\n'
                printf 'smaller functions or components; every point above a limit counts.\n' ;;
            *)
                printf 'Runs fallow and reads one number: metric=dupes duplicated lines, metric=boundaries boundary\n'
                printf 'violations, metric=complexity-excess points above max-cyclomatic= and max-cognitive=.\n'
                printf 'Keys: metric max-cyclomatic max-cognitive runner bin config, then -- <fallow argv>.\n' ;;
        esac ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        metric="$(qg_need fallow count metric)" || exit 0
        cyc=0 cog=0
        case "$metric" in
            dupes) unit=lines; sub=(dupes) ;;
            boundaries) unit=violations; sub=(dead-code --boundary-violations) ;;
            complexity-excess)
                unit=points
                cyc="$(qg_need fallow "$unit" max-cyclomatic)" || exit 0
                cog="$(qg_need fallow "$unit" max-cognitive)" || exit 0
                if ! [[ "$cyc" =~ ^[0-9]{1,6}$ && "$cog" =~ ^[0-9]{1,6}$ ]]; then
                    qg_fail fallow "$unit" 'max-cyclomatic= and max-cognitive= must be whole numbers'; exit 0
                fi
                sub=(health --max-cyclomatic "$cyc" --max-cognitive "$cog") ;;
            *) qg_fail fallow count "fallow metric=${metric} is not one of dupes, boundaries, complexity-excess"; exit 0 ;;
        esac
        bin="$(qg_kv bin)" || bin='node_modules/.bin/fallow'
        config="$(qg_kv config)" || config='.fallowrc.json'
        read -ra argv <<<"$(qg_argv)"
        qg_tool - '0 1' "$bin" "${sub[@]}" --config "$config" --no-cache --format json "${argv[@]}" \
            || { qg_fail fallow "$unit" "$QG_ERROR"; exit 0; }
        # The whole of stdout is one JSON document, as v1 parsed it.
        if ! jq -s -e 'length == 1 and (.[0] | type) == "object"' "${QG_OUT}/stdout" >/dev/null 2>&1; then
            tail -20 "${QG_OUT}/stdout"
            qg_fail fallow "$unit" "fallow ${sub[0]} exited ${QG_RC} and printed no JSON report"; exit 0
        fi
        case "$metric" in
            dupes)
                key='stats.duplicated_lines'
                check='(.stats.duplicated_lines | type) == "number"'
                value='.stats.duplicated_lines'
                findings='[(.clone_groups // [])[] | .instances as $i | $i[]
                    | {ruleId: "fallow.dupes", file: .file, line: .start_line, level: "warning",
                       message: "Lines \(.start_line)-\(.end_line) repeat in \($i | length - 1) other place(s)", doc: null}]' ;;
            boundaries)
                key='boundary_violations'
                check='(.boundary_violations | type) == "array"'
                value='.boundary_violations | length'
                findings='[.boundary_violations[]
                    | {ruleId: "fallow.boundaries", file: .from_path, line: .line, level: "error",
                       message: "\(.from_zone) imports \(.to_zone): \(.import_specifier) (\(.to_path))", doc: null}]' ;;
            complexity-excess)
                key='findings'
                check='(.findings | type) == "array"'
                value='def x: ([0, (.cyclomatic // 0) - $c] | max) + ([0, (.cognitive // 0) - $g] | max);
                    [.findings[] | x] | add // 0'
                findings='def x: ([0, (.cyclomatic // 0) - $c] | max) + ([0, (.cognitive // 0) - $g] | max);
                    [.findings[] | select(x > 0)
                    | {ruleId: "fallow.complexity", file: .path, line: .line, level: "warning",
                       message: "\(.name): cyclomatic \(.cyclomatic // 0) (limit \($c)), cognitive \(.cognitive // 0) (limit \($g))",
                       doc: null}]' ;;
        esac
        if ! jq -e "$check" "${QG_OUT}/stdout" >/dev/null 2>&1; then
            qg_fail fallow "$unit" "fallow ${sub[0]} report has no ${key}"; exit 0
        fi
        n="$(jq --argjson c "$cyc" --argjson g "$cog" "$value" "${QG_OUT}/stdout" 2>/dev/null)"
        jq -c --argjson c "$cyc" --argjson g "$cog" "${findings}"' | sort_by(.file, (.line // 0), .ruleId, .message)' \
            "${QG_OUT}/stdout" > "${QG_OUT}/findings.json" 2>/dev/null || n=''
        if ! [[ "$n" =~ ^[0-9]+$ ]]; then
            qg_fail fallow "$unit" "fallow ${sub[0]} report holds a ${key} that is not a count"; exit 0
        fi
        qg_result fallow measured "$n" "$unit" "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage fallow ;;
esac
