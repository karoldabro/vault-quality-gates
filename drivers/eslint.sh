#!/usr/bin/env bash
# ESLint driver: messages of one class in ESLint's JSON report. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [metric=errors|problems|rules] [rules=<ruleId,ruleId>] [config=<tree path>] [paths=<dir,dir>]
#        [files=changed] [include=<ERE>] [exclude=<ERE>] [lines=added] [bin=<tree path>]
#        [runner=<repo path>] [-- <extra eslint argv>]
#   metric       errors (default) counts severity 2, problems every message, rules the messages
#                whose ruleId is listed in rules=
#   config       default eslint.config.mjs, passed as -c so no sibling eslint.config.js is read
#   paths        default .; files=changed lints the changed files instead, with --no-warn-ignored
#   bin          default node_modules/.bin/eslint, run from the measured tree
#   lines=added  count only messages of the class on lines the commit adds
#
# metric = messages of the class. ESLint exits 1 on errors; 2 and above is a failure to run. A run
# over paths= that lints no file is an error: a config that ignores everything would read 0.
# Rows of one run that differ only in metric= and rules= share one ESLint run.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

# The producer of the shared report: runs ESLint over the targets and leaves its JSON in
# $QG_OUT/eslint.json. The report is written inside the tree, so a runner needs no other path.
eslint_report() {
    local report=".qg-eslint-${QG_ROW:-row}.json" rc=0
    qg_tool "$report" '0 1' "$bin" -c "$config" -f json -o "$report" "${opts[@]}" "${argv[@]}" -- "${targets[@]}" || rc=1
    [ "$rc" -ne 0 ] || cp "${QG_TREE}/${report}" "${QG_OUT}/eslint.json"
    rm -f "${QG_TREE:?}/${report}"
    return "$rc"
}

case "${1:-}" in
    describe)
        printf '{"name":"eslint","summary":"ESLint: counts errors, all problems or the messages of listed rules","requires":["jq"],"needs_tree":true}\n' ;;
    explain)
        if [ -n "${2:-}" ]; then
            printf 'ESLint rule %s. Fix the code at the reported line; eslint --fix fixes the fixable ones.\n' "$2"
            printf 'An eslint-disable comment is counted by the suppressions gate.\n'
        else
            printf 'Runs ESLint and counts errors, all problems, or the messages of the rules the row lists.\n'
            printf 'Keys: metric rules config paths files=changed include exclude lines=added bin runner, then -- <eslint argv>.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        metric="$(qg_kv metric)" || metric=errors
        case "$metric" in
            errors) class='.severity == 2' ;;
            problems) class='true' ;;
            rules)
                rules="$(qg_need eslint findings rules)" || exit 0
                class='(.ruleId // "") as $r | $rules | split(",") | any(. == $r)' ;;
            *) qg_fail eslint findings "metric=${metric} is not one of errors, problems, rules"; exit 0 ;;
        esac
        bin="$(qg_kv bin)" || bin='node_modules/.bin/eslint'
        config="$(qg_kv config)" || config='eslint.config.mjs'
        read -ra argv <<<"$(qg_argv)"
        opts=()
        changed=''
        if [ "$(qg_kv files)" = changed ]; then
            changed=1
            qg_files '.'
            if [ "${#QG_FILE_LIST[@]}" -eq 0 ]; then qg_result eslint measured 0 findings - -; exit 0; fi
            targets=("${QG_FILE_LIST[@]}")
            # A changed file the config ignores is not linted and not reported, as in v1.
            opts=(--no-warn-ignored)
            eslint_report || { qg_fail eslint findings "$QG_ERROR"; exit 0; }
        else
            qg_paths .; targets=("${QG_PATH_LIST[@]}")
            qg_shared_report eslint.json eslint_report metric rules || { qg_fail eslint findings "$QG_ERROR"; exit 0; }
        fi
        if ! jq -e 'type == "array"' "${QG_OUT}/eslint.json" >/dev/null 2>&1; then
            qg_fail eslint findings "eslint exited ${QG_RC:-0} and wrote an unreadable report"; exit 0
        fi
        if [ -z "$changed" ] && [ "$(jq length "${QG_OUT}/eslint.json")" -eq 0 ]; then
            qg_fail eslint findings "eslint linted no file under ${targets[*]}; the config ignores them all"; exit 0
        fi
        jq -c --arg rules "${rules:-}" '[.[] | .filePath as $f | .messages[] | select('"$class"')
                | {ruleId: (.ruleId // (if .fatal then "parse" else "directive" end)), file: $f, line: .line,
                   level: (if .severity == 2 then "error" else "warning" end), message: .message, doc: null}]' \
            "${QG_OUT}/eslint.json" > "${QG_OUT}/findings.json" \
            || { qg_fail eslint findings 'eslint wrote an unreadable report'; exit 0; }
        if [ "$(qg_kv lines)" = added ]; then
            qg_added_only "${QG_OUT}/findings.json" || { qg_fail eslint findings "$QG_ERROR"; exit 0; }
            qg_result eslint measured "$QG_COUNT" findings "${QG_OUT}/findings.json" -
        else
            qg_result eslint measured "$(jq length "${QG_OUT}/findings.json")" findings "${QG_OUT}/findings.json" -
        fi ;;
    *)
        qg_usage eslint ;;
esac
