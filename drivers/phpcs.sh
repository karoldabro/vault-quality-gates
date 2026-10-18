#!/usr/bin/env bash
# PHP_CodeSniffer driver: every error and warning phpcs reports. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [runner=<repo path>] [bin=<phpcs path>] [standard=<repo path>] [files=changed]
#        [include=<ERE>] [exclude=<ERE>] [paths=<dir,dir>] [lines=added] [-- <extra phpcs argv>]
#   bin          default vendor/bin/phpcs, relative to the measured tree
#   lines=added  count only messages on lines the commit adds
#
# metric = errors + warnings. phpcs exits 1 on errors and 2 on fixable ones; 3 and above is a
# failure to run.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"phpcs","summary":"PHP_CodeSniffer: counts every error and warning","requires":["jq"],"needs_tree":true}\n' ;;
    explain)
        if [ -n "${2:-}" ]; then
            printf 'PHP_CodeSniffer sniff %s. Fix the code at the reported line; vendor/bin/phpcbf fixes the\n' "$2"
            printf 'fixable ones. A phpcs:ignore comment is counted by the suppressions gate.\n'
        else
            printf 'Runs PHP_CodeSniffer and counts errors and warnings. Fix each listed line; phpcbf fixes many.\n'
            printf 'Keys: runner bin standard files=changed include exclude paths lines=added, then -- <phpcs argv>.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        bin="$(qg_kv bin)" || bin='vendor/bin/phpcs'
        read -ra argv <<<"$(qg_argv)"
        opts=(--report=json --basepath=.)
        standard="$(qg_kv standard)" && opts+=("--standard=${standard}")
        targets=()
        if [ "$(qg_kv files)" = changed ]; then
            qg_files '\.php$'
            if [ "${#QG_FILE_LIST[@]}" -eq 0 ]; then qg_result phpcs measured 0 findings - -; exit 0; fi
            targets=("${QG_FILE_LIST[@]}")
        elif qg_kv paths >/dev/null; then
            qg_paths .; targets=("${QG_PATH_LIST[@]}")
        fi
        qg_tool - '0 1 2' "$bin" "${opts[@]}" "${argv[@]}" "${targets[@]}" || { qg_fail phpcs findings "$QG_ERROR"; exit 0; }
        grep '^{' "${QG_OUT}/stdout" | tail -1 > "${QG_OUT}/phpcs.json"
        if ! jq -e '.totals' "${QG_OUT}/phpcs.json" >/dev/null 2>&1; then
            tail -20 "${QG_OUT}/stdout"
            qg_fail phpcs findings "phpcs exited ${QG_RC} and wrote no JSON report"; exit 0
        fi
        jq -c '[(.files // {}) | to_entries[] | .key as $f | .value.messages[]
                | {ruleId: .source, file: $f, line: .line, level: (if .type == "ERROR" then "error" else "warning" end),
                   message: .message, doc: null}]' "${QG_OUT}/phpcs.json" > "${QG_OUT}/findings.json"
        if [ "$(qg_kv lines)" = added ]; then
            qg_added_only "${QG_OUT}/findings.json" || { qg_fail phpcs findings "$QG_ERROR"; exit 0; }
            qg_result phpcs measured "$QG_COUNT" findings "${QG_OUT}/findings.json" -
        else
            qg_result phpcs measured "$(jq '(.totals.errors // 0) + (.totals.warnings // 0)' "${QG_OUT}/phpcs.json")" \
                findings "${QG_OUT}/findings.json" -
        fi ;;
    *)
        qg_usage phpcs ;;
esac
