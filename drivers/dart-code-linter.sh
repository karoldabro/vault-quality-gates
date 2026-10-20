#!/usr/bin/env bash
# dart_code_linter driver: functions or classes over a metric limit, or issues of one rule, from one
# `dart_code_linter:metrics analyze` run shared by every row of a run. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-dart-drivers.md.
#
# args:  metric=<metricsId>><N> | metric=issue:<ruleId>   [paths=<dir,dir>] [ignore=<glob>]
#   metric   <metricsId>><N> counts functions (classes for number-of-methods) whose metric is over N, such as
#            cyclomatic-complexity>20 or number-of-methods>10; issue:<ruleId> counts that rule's issues
#   paths    default lib
#   ignore   passed as --exclude=<glob>
#
# Rows that differ only in metric= share one tool run (qg_shared_report). The tool writes a 31 MB
# report to stdout as well as to --json-path; stdout is dropped so it never fills the kept output.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"
# shellcheck source=../lib/qg-dart.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-dart.sh"

REPORT=quality-reports/dcl.json

produce() {
    local ignore extra=()
    qg_dart_env && qg_dart_packages || return 1
    qg_paths lib
    ignore="$(qg_kv ignore)" && extra=("--exclude=${ignore}")
    mkdir -p "${QG_TREE}/quality-reports"
    # dart_code_linter exits 1 when it reports issues; the report decides the value.
    # The tool's stdout copy of the report is dropped inside the sandbox, which may write /dev/null.
    qg_tool "$REPORT" '0 1' /bin/sh -c 'exec "$@" > /dev/null' dart-code-linter "$QG_DART" run dart_code_linter:metrics \
        analyze "${QG_PATH_LIST[@]}" --reporter=json "--json-path=${REPORT}" "${extra[@]}" --no-congratulate || return 1
    cp "${QG_TREE}/${REPORT}" "${QG_OUT}/dart-code-linter"
}

case "${1:-}" in
    describe)
        printf '{"name":"dart-code-linter","summary":"dart_code_linter: functions or classes over a metric limit, or issues of one rule","requires":["jq","git"],"needs_tree":true,"sandbox":true,"writes":[".dart_tool"]}\n' ;;
    explain)
        printf 'Counts functions or classes over a dart_code_linter metric limit, or the issues of one rule.\n'
        printf 'Split the function or class the finding names until its metric is under the limit.\n'
        printf 'Keys: metric (required: <metricsId>><N> or issue:<ruleId>) paths ignore.\n' ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        metric="$(qg_need dart-code-linter findings metric)" || exit 0
        case "$metric" in
            issue:?*) rule="${metric#issue:}" ;;
            *'>'*) id="${metric%%>*}" limit="${metric#*>}"
                   [[ -n "$id" && "$limit" =~ ^[0-9]{1,9}$ ]] \
                       || { qg_fail dart-code-linter findings "metric=${metric} is not <metricsId>><N> or issue:<ruleId>"; exit 0; } ;;
            *) qg_fail dart-code-linter findings "metric=${metric} is not <metricsId>><N> or issue:<ruleId>"; exit 0 ;;
        esac
        QG_ERROR=''
        qg_shared_report dart-code-linter produce || { qg_fail dart-code-linter findings "$QG_ERROR"; exit 0; }
        f="${QG_OUT}/dart-code-linter"
        jq -e '(.records | type) == "array"' "$f" >/dev/null 2>&1 \
            || { qg_fail dart-code-linter findings "${REPORT} has no records array"; exit 0; }
        if [ -n "${rule:-}" ]; then
            jq -c --arg r "$rule" '[.records[] | .path as $p | (.issues // [])[] | select(.ruleId == $r)
                | {ruleId: $r, file: $p, line: (.codeSpan.start.line // null), level: "error",
                   message: (.message // $r), doc: (.documentation // null)}]' "$f" > "${QG_OUT}/findings.json"
        else
            # number-of-methods is a class metric; every other one is read per function.
            jq -c --arg id "$id" --argjson n "$limit" '[.records[] | .path as $p
                | (if $id == "number-of-methods" then (.classes // {}) else (.functions // {}) end)
                | to_entries[] | .key as $k | .value as $e | ($e.metrics // [])[]
                | select(.metricsId == $id and .value > $n)
                | {ruleId: $id, file: $p, line: ($e.codeSpan.start.line // null), level: "error",
                   message: "\($k): \($id) \(.value) over \($n)", doc: null}]' "$f" > "${QG_OUT}/findings.json"
        fi
        n="$(jq length "${QG_OUT}/findings.json")"
        jq -c '.[0:200]' "${QG_OUT}/findings.json" > "${QG_OUT}/findings.top" && mv "${QG_OUT}/findings.top" "${QG_OUT}/findings.json"
        qg_result dart-code-linter measured "$n" findings "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage dart-code-linter ;;
esac
