#!/usr/bin/env bash
# Vitest driver: failing tests from a JUnit report, or statement coverage from a Clover report.
# Contract: vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  metric=failed|coverage [junit=<tree path>] [clover=<tree path>] [config=<tree path>] [run=no]
#        [runner=<repo path>] [bin=<vitest path>] [-- <vitest argv>]
#   junit        default quality-reports/junit.xml; read for metric=failed
#   clover       default coverage/clover.xml; read for metric=coverage
#   config       default vitest.config.ts, passed as --config so no sibling config shadows it, with
#                --configLoader runner: the default loader writes <config>.timestamp-*.mjs beside the
#                config, which the sandbox refuses (needs vitest 3 or later)
#   run=no       read the report a previous run left; run nothing
#   bin          default node_modules/.bin/vitest
#
# metric failed = failures + errors of the <testsuites> root, plus 1 when vitest ran and exited
# non-zero with none (a coverage threshold failure); zero tests is an error.
# metric coverage = coveredstatements / statements of the project, two decimals.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

attr() { xmllint --xpath "string(/testsuites/@$1)" "$2" 2>/dev/null; }

case "${1:-}" in
    describe)
        printf '{"name":"vitest","summary":"Vitest: failing tests (JUnit) or statement coverage (Clover)","requires":["jq","xmllint"],"needs_tree":true,"sandbox":true,"writes":["coverage","quality-reports",".nuxt","node_modules/.vite","node_modules/.cache"]}\n' ;;
    explain)
        if [ "${2:-}" = vitest.failure ]; then
            printf 'A test failed or errored. Run it alone with vitest run <file> -t <name>, then fix the code or the test.\n'
        else
            printf 'Reads failing tests from the JUnit report or statement coverage from the Clover report, after running\n'
            printf 'vitest unless run=no. Keys: metric (failed, coverage) junit clover config run runner bin, then -- <argv>.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        metric="$(qg_need vitest tests metric)" || exit 0
        case "$metric" in
            failed)   unit=tests;   report="$(qg_kv junit)"  || report=quality-reports/junit.xml ;;
            coverage) unit=percent; report="$(qg_kv clover)" || report=coverage/clover.xml ;;
            *) qg_fail vitest tests "metric=${metric} is not failed or coverage"; exit 0 ;;
        esac
        ran=''
        if [ "$(qg_kv run)" != no ]; then
            bin="$(qg_kv bin)" || bin='node_modules/.bin/vitest'
            config="$(qg_kv config)" || config=vitest.config.ts
            read -ra argv <<<"$(qg_argv)"
            # Vitest exits 1 on a failing test and on a missed coverage threshold; the report decides.
            qg_tool "$report" '0 1' "$bin" --config "$config" --configLoader runner "${argv[@]}" || { qg_fail vitest "$unit" "$QG_ERROR"; exit 0; }
            ran="$QG_RC"
        fi
        f="${QG_TREE}/${report}"
        if [ "$metric" = coverage ]; then
            qg_clover_percent "$report" || { qg_fail vitest percent "$QG_ERROR"; exit 0; }
            qg_result vitest measured "$QG_PCT" percent - -
            exit 0
        fi
        [ -s "$f" ] || { qg_fail vitest tests "vitest report ${report} does not exist or is empty"; exit 0; }
        tests="$(attr tests "$f")" failures="$(attr failures "$f")" errors="$(attr errors "$f")"
        [ -n "$tests" ] || { qg_fail vitest tests "${report} has no <testsuites> root with a tests count"; exit 0; }
        # Anyone can write the report, and $(( )) would run a command hidden in an attribute.
        # At most nine digits: a longer number wraps in $(( )) and could read as 0.
        [[ "$tests" =~ ^[0-9]{1,9}$ ]] && [[ "$failures" =~ ^[0-9]{1,9}$ ]] && [[ "$errors" =~ ^[0-9]{1,9}$ ]] \
            || { qg_fail vitest tests "${report}: tests, failures or errors of the root is missing or not a whole number"; exit 0; }
        [ "$tests" -gt 0 ] || { qg_fail vitest tests "${report}: zero tests ran"; exit 0; }
        n=$(( failures + errors ))
        [ "$n" -gt 0 ] || [ "${ran:-0}" -eq 0 ] || n=1
        # One finding per failing testcase, the first 50; vitest names the file in classname.
        xmllint --xpath '//testcase[failure or error]' "$f" 2>/dev/null | grep -o '<testcase [^>]*>' | head -50 \
            | awk 'function attr(s, k) { return match(s, " " k "=\"[^\"]*\"") ? substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 4) : "" }
                   { printf "%s\t%s\n", attr($0, "name"), attr($0, "classname") }' \
            | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t")
                | {ruleId: "vitest.failure", file: (if (.[1] // "") == "" then null else .[1] end), line: null,
                   level: "error", message: ("failed: " + .[0]), doc: null}]' > "${QG_OUT}/findings.json"
        qg_result vitest measured "$n" tests "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage vitest ;;
esac
