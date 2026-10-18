#!/usr/bin/env bash
# PHPStan driver: every PHPStan error, file-less ones included. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [runner=<repo path>] [bin=<phpstan path>] [files=changed] [include=<ERE>] [exclude=<ERE>]
#        [lines=added] [-- <extra phpstan argv>]
#   bin          default vendor/bin/phpstan, relative to the measured tree
#   files=changed  analyse only the changed .php files; none changed measures 0
#   lines=added  count only errors on lines the commit adds
#
# metric = totals.errors + totals.file_errors. A boot failure or an unmatched ignore pattern
# carries no file, and counting file_errors alone would read it as a clean run.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

findings() {  # findings <phpstan json> -> qg.result/1 findings on stdout
    jq -c '
        [ ((.files // {}) | to_entries[] | .key as $f | .value.messages[]
            | {ruleId: (.identifier // "phpstan"), file: $f, line: .line, level: "error", message: .message,
               doc: (if .tip then .tip else null end)}),
          ((.errors // [])[] | {ruleId: "phpstan.fileless", file: null, line: null, level: "error", message: ., doc: null}) ]' "$1"
}

case "${1:-}" in
    describe)
        printf '{"name":"phpstan","summary":"PHPStan static analysis: counts every error, file-less ones included","requires":["jq"],"needs_tree":true}\n' ;;
    explain)
        if [ "${2:-}" = phpstan.fileless ]; then
            printf 'An error PHPStan reports without a file: a boot failure, a bad config, or an ignore pattern in\n'
            printf 'phpstan.neon or the baseline that no longer matches anything. Fix the config, or remove the stale\n'
            printf 'ignore entry; regenerating the baseline to hide a real error is never the fix.\n'
        elif [ -n "${2:-}" ]; then
            printf 'PHPStan rule %s. Read the message and fix the code it points at; https://phpstan.org/error-identifiers/%s\n' "$2" "$2"
            printf 'explains the rule. Adding an ignore or growing the baseline is refused by the gate.\n'
        else
            printf 'Runs PHPStan on the measured tree and counts every error, including errors that carry no file.\n'
            printf 'A higher count than allowed refuses the commit. Fix each listed finding in the code.\n'
            printf 'Keys: runner bin files=changed include exclude lines=added, then -- <phpstan argv>.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        bin="$(qg_kv bin)" || bin='vendor/bin/phpstan'
        read -ra argv <<<"$(qg_argv)"
        QG_FILE_LIST=()
        if [ "$(qg_kv files)" = changed ]; then
            qg_files '\.php$'
            if [ "${#QG_FILE_LIST[@]}" -eq 0 ]; then qg_result phpstan measured 0 findings - -; exit 0; fi
        fi
        if ! qg_tool - '0 1' "$bin" analyse --no-progress --error-format=json "${argv[@]}" "${QG_FILE_LIST[@]}"; then
            # PHPStan exits 1 on errors; any exit above 1 with a readable report is still a crash.
            qg_fail phpstan findings "phpstan exited ${QG_RC} and wrote no JSON report"; exit 0
        fi
        # PHPStan prints its JSON as one line; a runner may print other lines around it.
        grep '^{' "${QG_OUT}/stdout" | tail -1 > "${QG_OUT}/phpstan.json"
        if ! jq -e '.totals' "${QG_OUT}/phpstan.json" >/dev/null 2>&1; then
            tail -20 "${QG_OUT}/stdout"
            qg_fail phpstan findings "phpstan exited ${QG_RC} and wrote no JSON report"; exit 0
        fi
        findings "${QG_OUT}/phpstan.json" > "${QG_OUT}/findings.json"
        if [ "$(qg_kv lines)" = added ]; then
            # A file-less error (a boot failure, a bad config) matches no added line, so counting only
            # added lines would read it as a clean run.
            fileless="$(jq '.totals.errors // 0' "${QG_OUT}/phpstan.json")"
            if [ "$fileless" != 0 ]; then
                jq -r '(.errors // [])[]' "${QG_OUT}/phpstan.json" | head -5
                qg_fail phpstan findings "phpstan reports ${fileless} error(s) that carry no file; fix the configuration first"; exit 0
            fi
            qg_added_only "${QG_OUT}/findings.json" || { qg_fail phpstan findings "$QG_ERROR"; exit 0; }
            qg_result phpstan measured "$QG_COUNT" findings "${QG_OUT}/findings.json" -
        else
            qg_result phpstan measured "$(jq '(.totals.errors // 0) + (.totals.file_errors // 0)' "${QG_OUT}/phpstan.json")" \
                findings "${QG_OUT}/findings.json" -
        fi ;;
    *)
        qg_usage phpstan ;;
esac
