#!/usr/bin/env bash
# mutation_test driver: the percent of mutations the suite detects. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-dart-drivers.md.
#
# args:  rules=<repo path> [builtin=yes] [paths=<path,path>]
#   rules     required: the mutation rules XML, passed as --rules
#   builtin   yes adds -b, the tool's built-in rules
#   paths     the mutation targets; default lib
#
# metric = 100 minus the undetected percent the tool prints, two decimals. mutation_test exits 0 when
# every mutation is caught and 255 when some survive; both measure. The mutated suite is code the
# commit wrote, so it runs through qg_isolated (lib/qg-dart.sh).
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"
# shellcheck source=../lib/qg-dart.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-dart.sh"

case "${1:-}" in
    describe)
        printf '{"name":"mutation-test","summary":"mutation_test: percent of mutations the suite detects","requires":["jq","git"],"needs_tree":true}\n' ;;
    explain)
        printf 'Mutates the code and counts the mutations no test notices. Open the report, find a surviving mutation\n'
        printf 'and add an assertion that fails on it. Keys: rules (required) builtin paths.\n' ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        rules="$(qg_need mutation-test percent rules)" || exit 0
        flags=(--rules "$rules")
        [ "$(qg_kv builtin)" = yes ] && flags+=(-b)
        qg_paths lib
        qg_dart_prepare mutation-test percent || exit 0
        private="$(mktemp -d)" && chmod 700 "$private" || { qg_fail mutation-test percent 'cannot create a private temp folder'; exit 0; }
        mutation_test() { qg_isolated "$private" "$QG_DART" run mutation_test "$@"; }
        qg_tool - '0 255' mutation_test "${flags[@]}" "${QG_PATH_LIST[@]}" \
            || { rm -rf "$private"; qg_fail mutation-test percent "$QG_ERROR"; exit 0; }
        rm -rf "$private"
        line="$(grep -oE 'Undetected Mutations: [0-9]+ \([0-9.]+%\)' "${QG_OUT}/stdout" | tail -1)"
        total="$(grep -oE 'Total tests: [0-9]+' "${QG_OUT}/stdout" | tail -1 | grep -oE '[0-9]+')"
        [ -n "$line" ] || { tail -20 "${QG_OUT}/stdout"; qg_fail mutation-test percent 'mutation_test printed no Undetected Mutations line'; exit 0; }
        [ "${total:-0}" -gt 0 ] 2>/dev/null || { qg_fail mutation-test percent 'mutation_test generated no mutation'; exit 0; }
        pct="$(printf '%s' "$line" | grep -oE '[0-9.]+%' | tr -d '%')"
        qg_result mutation-test measured "$(awk -v p="$pct" 'BEGIN { printf "%.2f", 100 - p }')" percent - - ;;
    *)
        qg_usage mutation-test ;;
esac
