#!/usr/bin/env bash
# Laravel Pint driver: files whose code style Pint would change. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [runner=<repo path>] [bin=<pint path>] [files=changed] [include=<ERE>] [exclude=<ERE>]
#        [paths=<dir,dir>] [-- <extra pint argv>]
#   bin          default vendor/bin/pint, relative to the measured tree
#   files=changed  test only the changed .php files; none changed measures 0
#
# metric = files Pint would change. Pint exits 1 both on a style finding and on a crash, so only
# its JSON report tells them apart.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"pint","summary":"Laravel Pint: counts the files whose code style Pint would change","requires":["jq"],"needs_tree":true,"sandbox":false,"writes":[]}\n' ;;
    explain)
        if [ -n "${2:-}" ]; then
            printf 'Pint would reformat this file. Run vendor/bin/pint <file> to apply its fixes, then stage the result.\n'
        else
            printf 'Runs Pint in test mode and counts the files it would reformat. Run vendor/bin/pint on each listed\n'
            printf 'file and stage the change. Keys: runner bin files=changed include exclude paths, then -- <pint argv>.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        bin="$(qg_kv bin)" || bin='vendor/bin/pint'
        read -ra argv <<<"$(qg_argv)"
        targets=()
        if [ "$(qg_kv files)" = changed ]; then
            qg_files '\.php$'
            if [ "${#QG_FILE_LIST[@]}" -eq 0 ]; then qg_result pint measured 0 files - -; exit 0; fi
            targets=("${QG_FILE_LIST[@]}")
        elif qg_kv paths >/dev/null; then
            qg_paths .; targets=("${QG_PATH_LIST[@]}")
        fi
        qg_tool - '0 1' "$bin" --test -v --format=json "${argv[@]}" "${targets[@]}" \
            || { qg_fail pint files "$QG_ERROR"; exit 0; }
        grep '^{' "${QG_OUT}/stdout" | tail -1 > "${QG_OUT}/pint.json"
        if ! jq -e '.files | type == "array"' "${QG_OUT}/pint.json" >/dev/null 2>&1; then
            tail -20 "${QG_OUT}/stdout"
            qg_fail pint files "pint exited ${QG_RC} and wrote no JSON report"; exit 0
        fi
        # One finding per file, naming the fixers; the diff stays out of result.json.
        jq -c '[.files[] | {ruleId: "pint", file: .name, line: null, level: "error",
                 message: ("style: " + ((.appliedFixers // []) | join(", "))), doc: null}]' \
            "${QG_OUT}/pint.json" > "${QG_OUT}/findings.json"
        qg_result pint measured "$(jq '.files | length' "${QG_OUT}/pint.json")" files "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage pint ;;
esac
