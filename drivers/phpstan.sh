#!/usr/bin/env bash
# PHPStan driver: every PHPStan error, file-less ones included. Contract:
# vault/architecture/qg-driver-contract.md. This file is the worked example the contract names.
#
# args:  [runner=<repo path>] [bin=<phpstan path>] [paths=changed] [-- <extra phpstan argv>]
#   runner       the engine copies it from the config revision into $QG_RUNNER; it is called as
#                $QG_RUNNER "$QG_TREE" "$QG_CACHE" <bin> <argv>
#   bin          default vendor/bin/phpstan, relative to the measured tree
#   paths=changed  analyse only the changed .php files ($QG_FILES); none changed measures 0
#
# metric = totals.errors + totals.file_errors. A boot failure or an unmatched ignore pattern
# carries no file, and counting file_errors alone would read it as a clean run.
set -uo pipefail
export LC_ALL=C

kv() {  # kv <key> -> the value of key=value before ` -- ` in QG_ARGS
    local head="${QG_ARGS:-}" w
    case "$head" in '-- '*) return 1 ;; *' -- '*) head="${head%% -- *}" ;; esac
    for w in $head; do case "$w" in "$1="*) printf '%s' "${w#*=}"; return 0 ;; esac; done
    return 1
}
extra() { case "${QG_ARGS:-}" in '-- '*) printf '%s' "${QG_ARGS#-- }" ;; *' -- '*) printf '%s' "${QG_ARGS#* -- }" ;; esac; }

result() {  # result <status> <metric json> <error json> <raw file or ->
    local findings='[]'
    [ "$4" = - ] || findings="$(jq -c '
        [ ((.files // {}) | to_entries[] | .key as $f | .value.messages[]
            | {ruleId: (.identifier // "phpstan"), file: $f, line: .line, level: "error", message: .message,
               doc: (if .tip then .tip else null end)}),
          ((.errors // [])[] | {ruleId: "phpstan.fileless", file: null, line: null, level: "error", message: ., doc: null}) ]' "$4")"
    jq -n --arg s "$1" --argjson m "$2" --argjson e "$3" --argjson f "$findings" --arg r "qg run commit --only ${QG_ROW:-<id>}" \
        '{schema: "qg.result/1", driver: "phpstan", status: $s, metric: $m, unit: "findings", findings: $f, error: $e, reproduce: $r}' \
        > "${QG_OUT}/result.json"
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
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        bin="$(kv bin)" || bin='vendor/bin/phpstan'
        read -ra argv <<<"$(extra)"
        files=()
        if [ "$(kv paths)" = changed ]; then
            while IFS= read -r -d '' f; do
                case "$f" in *.php) [ -e "${QG_TREE}/${f}" ] && files+=("$f") ;; esac
            done < "${QG_FILES:-/dev/null}"
            if [ "${#files[@]}" -eq 0 ]; then result measured 0 null -; exit 0; fi
        fi
        cmd=("$bin" analyse --no-progress --error-format=json "${argv[@]}" "${files[@]}")
        rc=0
        if [ -n "${QG_RUNNER:-}" ]; then "$QG_RUNNER" "$QG_TREE" "${QG_CACHE:-/tmp}" "${cmd[@]}" > "${QG_OUT}/stdout" 2> "${QG_OUT}/stderr" || rc=$?
        else ( cd "$QG_TREE" && "${cmd[@]}" ) > "${QG_OUT}/stdout" 2> "${QG_OUT}/stderr" || rc=$?; fi
        cat "${QG_OUT}/stderr"
        # PHPStan prints its JSON as one line; a runner may print other lines around it.
        grep '^{' "${QG_OUT}/stdout" | tail -1 > "${QG_OUT}/phpstan.json"
        if [ "$rc" -gt 1 ] || ! jq -e '.totals' "${QG_OUT}/phpstan.json" >/dev/null 2>&1; then
            tail -20 "${QG_OUT}/stdout"
            result error null "$(jq -n --arg e "phpstan exited ${rc} and wrote no JSON report" '$e')" -
            exit 0
        fi
        result measured "$(jq '(.totals.errors // 0) + (.totals.file_errors // 0)' "${QG_OUT}/phpstan.json")" null "${QG_OUT}/phpstan.json" ;;
    *)
        printf 'usage: phpstan.sh describe | explain [<ruleId>] | run\n' >&2; exit 2 ;;
esac
