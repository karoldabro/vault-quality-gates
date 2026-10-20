#!/usr/bin/env bash
# PHPUnit driver: failing tests from a JUnit report, or line coverage from a Clover report.
# Contract: vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  metric=failed|coverage [junit=<tree path>] [clover=<tree path>] [run=no]
#        [reset=<tree path,...>] [runner=<repo path>] [bin=<phpunit path>] [-- <phpunit argv>]
#   junit        default storage/coverage/junit.xml; read for metric=failed
#   clover       default storage/coverage/clover.xml; read for metric=coverage
#   run=no       read the report a previous run left; run nothing
#   reset        files emptied before the run, such as a log the suite appends to
#   bin          default vendor/bin/phpunit. To set an environment variable inside a runner, write
#                `bin=env -- XDEBUG_MODE=coverage vendor/bin/phpunit <phpunit argv>`
#
# metric failed = failures + errors of the first <testsuite>; zero tests is an error.
# metric coverage = coveredstatements / statements of the project, two decimals.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

attr() { xmllint --xpath "string($2/@$1)" "$3" 2>/dev/null; }

case "${1:-}" in
    describe)
        printf '{"name":"phpunit","summary":"PHPUnit: failing tests (JUnit) or line coverage (Clover)","requires":["jq","xmllint"],"needs_tree":true,"sandbox":false,"writes":[]}\n' ;;
    explain)
        if [ "${2:-}" = phpunit.failure ]; then
            printf 'A test failed or errored. Run it alone with vendor/bin/phpunit --filter <name>, then fix the code or the test.\n'
        else
            printf 'Reads failing tests from the JUnit report or line coverage from the Clover report, after running the\n'
            printf 'suite unless run=no. Keys: metric (failed, coverage) junit clover run reset runner bin, then -- <argv>.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        metric="$(qg_need phpunit tests metric)" || exit 0
        case "$metric" in
            failed)   unit=tests;   report="$(qg_kv junit)"  || report=storage/coverage/junit.xml ;;
            coverage) unit=percent; report="$(qg_kv clover)" || report=storage/coverage/clover.xml ;;
            *) qg_fail phpunit tests "metric=${metric} is not failed or coverage"; exit 0 ;;
        esac
        if [ "$(qg_kv run)" != no ]; then
            bin="$(qg_kv bin)" || bin='vendor/bin/phpunit'
            read -ra argv <<<"$(qg_argv)"
            if reset="$(qg_kv reset)"; then
                IFS=',' read -r -a resets <<<"$reset"
                for f in "${resets[@]}"; do mkdir -p "$(dirname "${QG_TREE}/${f}")" && : > "${QG_TREE}/${f}"; done
            fi
            # PHPUnit exits 1 on failing tests and 2 on errored ones; the report decides the value.
            qg_tool "$report" '0 1 2' "$bin" "${argv[@]}" || { qg_fail phpunit "$unit" "$QG_ERROR"; exit 0; }
        fi
        f="${QG_TREE}/${report}"
        [ -r "$f" ] || { qg_fail phpunit "$unit" "phpunit report ${report} does not exist"; exit 0; }
        [ -s "$f" ] || { qg_fail phpunit "$unit" "phpunit report ${report} is empty, the suite recorded nothing"; exit 0; }
        if [ "$metric" = failed ]; then
            tests="$(attr tests '(//testsuite)[1]' "$f")"
            [ -n "$tests" ] || { qg_fail phpunit tests "${report} has no <testsuite> element"; exit 0; }
            [ "$tests" -gt 0 ] 2>/dev/null || { qg_fail phpunit tests "${report}: zero tests ran"; exit 0; }
            failures="$(attr failures '(//testsuite)[1]' "$f")" errors="$(attr errors '(//testsuite)[1]' "$f")"
            # Anyone can write the report, and $(( )) would run a command hidden in an attribute.
            # At most nine digits: a longer number wraps in $(( )) and could read as 0.
            [[ "${failures:-0}" =~ ^[0-9]{1,9}$ ]] && [[ "${errors:-0}" =~ ^[0-9]{1,9}$ ]] \
                || { qg_fail phpunit tests "${report}: failures or errors is not a whole number"; exit 0; }
            # One finding per failing testcase, the first 50.
            xmllint --xpath '//testcase[failure or error]' "$f" 2>/dev/null | grep -o '<testcase [^>]*>' | head -50 \
                | awk 'function attr(s, k) { return match(s, " " k "=\"[^\"]*\"") ? substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 4) : "" }
                       { printf "%s\t%s\t%s\n", attr($0, "name"), attr($0, "file"), attr($0, "line") }' \
                | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t")
                    | {ruleId: "phpunit.failure", file: (if (.[1] // "") == "" then null else .[1] end),
                       line: ((.[2] // "") | if test("^[0-9]+$") then tonumber else null end), level: "error",
                       message: ("failed: " + .[0]), doc: null}]' > "${QG_OUT}/findings.json"
            qg_result phpunit measured "$(( ${failures:-0} + ${errors:-0} ))" tests "${QG_OUT}/findings.json" -
        else
            qg_clover_percent "$report" || { qg_fail phpunit percent "$QG_ERROR"; exit 0; }
            qg_result phpunit measured "$QG_PCT" percent - -
        fi ;;
    *)
        qg_usage phpunit ;;
esac
