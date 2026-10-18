#!/usr/bin/env bash
# PHPMD driver: every rule violation PHPMD reports. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  ruleset=<repo path> [runner=<repo path>] [bin=<phpmd path>] [baseline=<repo path>]
#        [phpini=<directive=value>] [files=changed] [include=<ERE>] [exclude=<ERE>]
#        [paths=<dir,dir>] [lines=added] [-- <extra phpmd argv>]
#   bin          default vendor/bin/phpmd, relative to the measured tree
#   phpini       run as `php -d <phpini> <bin>`, e.g. phpini=error_reporting=24575
#
# metric = violations. PHPMD exits 2 on violations and 1 on a failure to run; a file it could
# not parse is listed under errors[] and was never checked, so it is an error, not a pass.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"phpmd","summary":"PHPMD: counts every rule violation","requires":["jq"],"needs_tree":true}\n' ;;
    explain)
        if [ -n "${2:-}" ]; then
            printf 'PHPMD rule %s. Change the code so the rule holds; https://phpmd.org/rules/ explains each rule.\n' "$2"
            printf 'Growing the PHPMD baseline or adding @SuppressWarnings is refused by the gate.\n'
        else
            printf 'Runs PHPMD with the ruleset and counts violations. Fix each listed method or class.\n'
            printf 'Keys: ruleset (required) runner bin baseline phpini files=changed include exclude paths lines=added.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        ruleset="$(qg_need phpmd findings ruleset)" || exit 0
        bin="$(qg_kv bin)" || bin='vendor/bin/phpmd'
        read -ra argv <<<"$(qg_argv)"
        cmd=("$bin")
        phpini="$(qg_kv phpini)" && cmd=(php -d "$phpini" "$bin")
        if [ "$(qg_kv files)" = changed ]; then
            qg_files '\.php$'
            if [ "${#QG_FILE_LIST[@]}" -eq 0 ]; then qg_result phpmd measured 0 findings - -; exit 0; fi
            targets="$(IFS=,; printf '%s' "${QG_FILE_LIST[*]}")"
        elif targets="$(qg_kv paths)"; then :
        else
            qg_fail phpmd findings 'driver phpmd needs files=changed or paths=<dir,dir>'; exit 0
        fi
        extra=()
        baseline="$(qg_kv baseline)" && extra=(--baseline-file "$baseline")
        # Exit 3 is files PHPMD could not parse; its errors[] names them below.
        qg_tool - '0 2 3' "${cmd[@]}" "$targets" json "$ruleset" "${extra[@]}" "${argv[@]}" \
            || { qg_fail phpmd findings "$QG_ERROR"; exit 0; }
        # PHPMD pretty-prints its JSON; anything a runner prints before it is skipped.
        sed -n '/^{/,$p' "${QG_OUT}/stdout" > "${QG_OUT}/phpmd.json"
        if ! jq -e '(.files | type) == "array"' "${QG_OUT}/phpmd.json" >/dev/null 2>&1; then
            tail -20 "${QG_OUT}/stdout"
            qg_fail phpmd findings "phpmd exited ${QG_RC} and wrote no JSON report"; exit 0
        fi
        bad="$(jq -r '(.errors // [])[] | "\(.fileName // "-"): \(.message // "-")"' "${QG_OUT}/phpmd.json" | head -3)"
        if [ -n "$bad" ]; then qg_fail phpmd findings "phpmd could not parse: ${bad//$'\n'/; }"; exit 0; fi
        [ "$QG_RC" != 3 ] || { qg_fail phpmd findings 'phpmd exited 3 (files it could not parse) and named none'; exit 0; }
        jq -c '[.files[] | .file as $f | (.violations // [])[]
                | {ruleId: .rule, file: $f, line: .beginLine, level: "error", message: .description, doc: .externalInfoUrl}]' \
            "${QG_OUT}/phpmd.json" > "${QG_OUT}/findings.json"
        if [ "$(qg_kv lines)" = added ]; then
            qg_added_only "${QG_OUT}/findings.json" || { qg_fail phpmd findings "$QG_ERROR"; exit 0; }
            qg_result phpmd measured "$QG_COUNT" findings "${QG_OUT}/findings.json" -
        else
            qg_result phpmd measured "$(jq length "${QG_OUT}/findings.json")" findings "${QG_OUT}/findings.json" -
        fi ;;
    *)
        qg_usage phpmd ;;
esac
