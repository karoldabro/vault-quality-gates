#!/usr/bin/env bash
# dart format driver: changed Dart files `dart format` would rewrite. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-dart-drivers.md.
#
# args:  files=changed [include=<ERE>] [exclude=<ERE>] [-- <extra dart format argv>]
#
# metric = files dart format would change. It exits 1 when one would change; an exit 1 that names
# no file is an error, never a pass.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"
# shellcheck source=../lib/qg-dart.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-dart.sh"

case "${1:-}" in
    describe)
        printf '{"name":"dart-format","summary":"dart format: changed Dart files that are not formatted","requires":["jq","git"],"needs_tree":true}\n' ;;
    explain)
        printf 'Lists changed Dart files dart format would rewrite. Run dart format <file> on each and commit the result.\n'
        printf 'Keys: files=changed (required) include exclude, then -- <argv>.\n' ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        [ "$(qg_kv files)" = changed ] || { qg_fail dart-format files 'driver dart-format needs files=changed'; exit 0; }
        qg_files '\.dart$'
        if [ "${#QG_FILE_LIST[@]}" -eq 0 ]; then qg_result dart-format measured 0 files - -; exit 0; fi
        qg_dart_prepare dart-format files || exit 0
        read -ra argv <<<"$(qg_argv)"
        qg_tool - '0 1' "$QG_DART" format --output=none --set-exit-if-changed "${argv[@]}" -- "${QG_FILE_LIST[@]}" \
            || { qg_fail dart-format files "$QG_ERROR"; exit 0; }
        grep '^Changed ' "${QG_OUT}/stdout" | sed 's/^Changed //' \
            | jq -R -s -c '[split("\n")[] | select(length > 0)
                | {ruleId: "dart-format.unformatted", file: ., line: null, level: "error",
                   message: "not formatted; run dart format on it", doc: null}]' > "${QG_OUT}/findings.json"
        n="$(jq length "${QG_OUT}/findings.json")"
        if [ "$QG_RC" = 1 ] && [ "$n" = 0 ]; then
            tail -20 "${QG_OUT}/stdout"
            qg_fail dart-format files 'dart format exited 1 and named no changed file'; exit 0
        fi
        qg_result dart-format measured "$n" files "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage dart-format ;;
esac
