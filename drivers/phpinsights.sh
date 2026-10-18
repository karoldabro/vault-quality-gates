#!/usr/bin/env bash
# PHP Insights driver: one category score. Contract: vault/architecture/qg-driver-contract.md;
# keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [metric=code|complexity|architecture|style] [runner=<repo path>] [bin=<phpinsights path>]
#        [paths=<dir,dir>] [config=<repo path>] [-- <extra phpinsights argv>]
#   metric       default code
#   paths        default app
#
# metric = summary.<metric>, a score where higher is better. Rows of one run that differ only in
# metric= share one PHP Insights run (qg_shared_report).
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

produce() {
    local opts=(--format=json --no-interaction) config
    config="$(qg_kv config)" && opts+=("--config-path=${config}")
    qg_tool - '0 1' "$bin" analyse "${QG_PATH_LIST[@]}" "${opts[@]}" "${argv[@]}" || return 1
    # The JSON report is the last thing PHP Insights prints; a runner may print lines before it.
    sed -n '/^{/,$p' "${QG_OUT}/stdout" > "${QG_OUT}/insights.json"
    if ! jq -e '.summary | type == "object"' "${QG_OUT}/insights.json" >/dev/null 2>&1; then
        tail -20 "${QG_OUT}/stdout"
        QG_ERROR="phpinsights exited ${QG_RC} and wrote no JSON report"; return 1
    fi
}

case "${1:-}" in
    describe)
        printf '{"name":"phpinsights","summary":"PHP Insights: one category score (code, complexity, architecture or style)","requires":["jq"],"needs_tree":true}\n' ;;
    explain)
        if [ -n "${2:-}" ]; then
            printf 'PHP Insights check %s. Fix the code it names; the score rises as these issues go.\n' "$2"
        else
            printf 'Runs PHP Insights and reads one category score; higher is better. Fix the listed issues to raise it.\n'
            printf 'Keys: metric (code, complexity, architecture, style) runner bin paths config, then -- <argv>.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        metric="$(qg_kv metric)" || metric=code
        case "$metric" in code|complexity|architecture|style) ;; *) qg_fail phpinsights score "metric=${metric} is not code, complexity, architecture or style"; exit 0 ;; esac
        bin="$(qg_kv bin)" || bin='vendor/bin/phpinsights'
        read -ra argv <<<"$(qg_argv)"
        qg_paths app
        qg_shared_report insights.json produce || { qg_fail phpinsights score "$QG_ERROR"; exit 0; }
        value="$(jq --arg k "$metric" '.summary[$k] | select(type == "number")' "${QG_OUT}/insights.json")"
        [ -n "$value" ] || { qg_fail phpinsights score "phpinsights reports no summary.${metric}"; exit 0; }
        # PHP Insights names files relative to the analysed directory; the first 100 issues of the
        # category are kept.
        category="$(tr '[:lower:]' '[:upper:]' <<<"${metric:0:1}")${metric:1}"
        jq -c --arg c "$category" --arg p "${QG_PATH_LIST[0]}" '[(.[$c] // [])[:100][]
                | {ruleId: (.insightClass // .title), file: (if .file then (if ($p == "." or (.file | startswith($p + "/"))) then .file else ($p + "/" + .file) end) else null end),
                   line: (.line // null), level: "warning", message: ((.title // "") + ((if .message then ": " + .message else "" end))), doc: null}]' \
            "${QG_OUT}/insights.json" > "${QG_OUT}/findings.json"
        qg_result phpinsights measured "$value" score "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage phpinsights ;;
esac
