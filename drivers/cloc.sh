#!/usr/bin/env bash
# cloc driver: comment density, or a line count. Contract: vault/architecture/qg-driver-contract.md;
# keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [metric=comment-ratio|code|comment] [paths=<dir,dir>] [runner=<repo path>] [bin=<cloc path>]
#        [-- <extra cloc argv>]
#   metric       default comment-ratio = SUM.comment / SUM.code, rounded to three places
#   paths        default .
#   bin          default cloc, from PATH
#
# Zero lines of code is an error: an empty measurement must not read as a density of 0. Every file is
# counted, however long it takes (--timeout 0).
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"cloc","summary":"cloc: comment density (comment lines per code line) or a line count","requires":["jq","cloc"],"needs_tree":true}\n' ;;
    explain)
        printf 'Counts lines with cloc. comment-ratio is comment lines per code line; a lower ratio than allowed\n'
        printf 'means new code carries too many or too few comments for the row. Keys: metric paths runner bin.\n' ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        metric="$(qg_kv metric)" || metric=comment-ratio
        bin="$(qg_kv bin)" || bin=cloc
        read -ra argv <<<"$(qg_argv)"
        qg_paths .
        # --timeout 0: cloc otherwise skips a file whose count takes longer than a limit that scales
        # with machine load, so the same tree would read differently on a busy machine.
        qg_tool - 0 "$bin" --json --quiet --timeout 0 "${argv[@]}" "${QG_PATH_LIST[@]}" || { qg_fail cloc lines "$QG_ERROR"; exit 0; }
        sed -n '/^{/,$p' "${QG_OUT}/stdout" > "${QG_OUT}/cloc.json"
        code="$(jq -r '.SUM.code // 0' "${QG_OUT}/cloc.json" 2>/dev/null)"
        [ -n "$code" ] && [ "$code" != 0 ] || { qg_fail cloc lines "cloc reports zero lines of code in ${QG_PATH_LIST[*]}"; exit 0; }
        case "$metric" in
            comment-ratio) value="$(jq '.SUM.comment / .SUM.code * 1000 | round / 1000' "${QG_OUT}/cloc.json")"; unit=ratio ;;
            code|comment)  value="$(jq --arg k "$metric" '.SUM[$k]' "${QG_OUT}/cloc.json")"; unit=lines ;;
            *) qg_fail cloc lines "metric=${metric} is not comment-ratio, code or comment"; exit 0 ;;
        esac
        qg_result cloc measured "$value" "$unit" - - ;;
    *)
        qg_usage cloc ;;
esac
