#!/usr/bin/env bash
# Nuxt typecheck driver: TypeScript errors that `nuxt typecheck` or vue-tsc prints. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [bin=<tree path>] [files=changed] [include=<ERE>] [exclude=<ERE>] [lines=added]
#        [runner=<repo path>] [-- <argv>]
#   bin           default node_modules/.bin/nuxt, run from the measured tree with argv `typecheck`;
#                 any -- <argv> replaces `typecheck`, e.g. bin=node_modules/.bin/vue-tsc -- -b --noEmit
#   files=changed with include= and exclude=, only decides whether to run: no matching changed file
#                 measures 0 without running; the tool still checks the whole project
#   lines=added   count only errors on lines the commit adds
#
# metric = occurrences of `error TS<code>` over stdout and stderr. The tool exits 1 or 2 on type
# errors; any other exit code, or a non-zero exit with no `error TS`, is a failure to run.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"nuxt-typecheck","summary":"nuxt typecheck or vue-tsc: counts TypeScript errors","requires":["jq"],"needs_tree":true}\n' ;;
    explain)
        if [ -n "${2:-}" ]; then
            printf 'TypeScript error %s. Fix the type at the reported line.\n' "$2"
            printf 'A @ts-ignore or @ts-expect-error comment is counted by the suppressions gate.\n'
        else
            printf 'Runs nuxt typecheck (or the bin= tool) over the whole project and counts its TypeScript errors.\n'
            printf 'Keys: bin files=changed include exclude lines=added runner, then -- <argv replacing typecheck>.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        bin="$(qg_kv bin)" || bin='node_modules/.bin/nuxt'
        read -ra argv <<<"$(qg_argv)"
        [ "${#argv[@]}" -gt 0 ] || argv=(typecheck)
        if [ "$(qg_kv files)" = changed ]; then
            qg_files '.'
            if [ "${#QG_FILE_LIST[@]}" -eq 0 ]; then qg_result nuxt-typecheck measured 0 errors - -; exit 0; fi
        fi
        qg_tool - '0 1 2' "$bin" "${argv[@]}" || { qg_fail nuxt-typecheck errors "$QG_ERROR"; exit 0; }
        cat "${QG_OUT}/stdout" "${QG_OUT}/stderr" > "${QG_OUT}/typecheck.txt"
        n="$(grep -oE 'error TS[0-9]+' "${QG_OUT}/typecheck.txt" | wc -l | tr -d ' ')"
        if [ "$QG_RC" -ne 0 ] && [ "$n" -eq 0 ]; then
            tail -20 "${QG_OUT}/typecheck.txt"
            qg_fail nuxt-typecheck errors "$(basename "$bin") exited ${QG_RC} with no error TS line"; exit 0
        fi
        sed -nE 's/^(.+)\(([0-9]+),[0-9]+\): error (TS[0-9]+): (.*)$/\1\t\2\t\3\t\4/p' "${QG_OUT}/typecheck.txt" \
            | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t")
                | {ruleId: .[2], file: .[0], line: (.[1] | tonumber), level: "error", message: (.[3:] | join(" ")), doc: null}]' \
            > "${QG_OUT}/findings.json" || { qg_fail nuxt-typecheck errors 'cannot read the typecheck output'; exit 0; }
        if [ "$(qg_kv lines)" = added ]; then
            qg_added_only "${QG_OUT}/findings.json" || { qg_fail nuxt-typecheck errors "$QG_ERROR"; exit 0; }
            qg_result nuxt-typecheck measured "$QG_COUNT" errors "${QG_OUT}/findings.json" -
        else
            qg_result nuxt-typecheck measured "$n" errors "${QG_OUT}/findings.json" -
        fi ;;
    *)
        qg_usage nuxt-typecheck ;;
esac
