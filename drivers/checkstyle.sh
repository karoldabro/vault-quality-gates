#!/usr/bin/env bash
# checkstyle driver: the <error> elements of a checkstyle report a committed runner writes, under
# lines=added only those on added lines. Contract: vault/architecture/qg-driver-contract.md; keys:
# vault/architecture/qg-dart-drivers.md.
#
# args:  runner=<repo path> report=<tree path> [lines=added]
#   runner   required: the tool itself, called as `<runner> <tree> <cache>`; it reads the changed paths
#            from $QG_FILES and writes report= inside the tree
#   report   required: the checkstyle file the runner writes, relative to the measured tree
#
# The runner owns its report: it may reuse one an earlier row of the same commit wrote, and deletes it
# when it fails. This driver never deletes it, and refuses a report the commit itself tracks.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"checkstyle","summary":"counts the errors of a checkstyle report a committed runner writes","requires":["jq","xmllint","git"],"needs_tree":true,"sandbox":false,"writes":[]}\n' ;;
    explain)
        if [ -n "${2:-}" ]; then
            printf 'Rule %s, reported by the repo'"'"'s own runner. Fix the line the finding names.\n' "$2"
        else
            printf 'Runs the repo'"'"'s committed runner, which writes a checkstyle report, and counts its errors.\n'
            printf 'Keys: runner (required) report (required) lines=added.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        qg_need checkstyle findings runner > /dev/null || exit 0
        report="$(qg_need checkstyle findings report)" || exit 0
        { qg_kv bin > /dev/null || [ -n "$(qg_argv)" ]; } \
            && { qg_fail checkstyle findings 'the checkstyle runner is the tool itself; bin= and -- argv are not allowed'; exit 0; }
        [ -n "${QG_RUNNER:-}" ] || { qg_fail checkstyle findings 'the engine set no QG_RUNNER for runner='; exit 0; }
        if [ "${QG_TARGET:-:index}" = ':index' ]; then tracked="$(git -C "${QG_REPO:-.}" ls-files -- "$report")"
        else tracked="$(git -C "${QG_REPO:-.}" ls-tree --name-only "$QG_TARGET" -- "$report" 2>/dev/null)"; fi
        [ -z "$tracked" ] || { qg_fail checkstyle findings "${report} is committed; a report must come from this run"; exit 0; }
        rc=0
        # Unconfined, but with the child environment, its own session and its process group killed after.
        QG_SANDBOX=0 qg_sandbox_run --runner "$QG_RUNNER" "$QG_TREE" "${QG_CACHE:-/tmp}" -- \
            > "${QG_OUT}/stdout" 2> "${QG_OUT}/stderr" || rc=$?
        cat "${QG_OUT}/stderr"
        [ -z "$QG_SANDBOX_ERROR" ] || { qg_fail checkstyle findings "$QG_SANDBOX_ERROR"; exit 0; }
        [ "$rc" = 0 ] || { tail -20 "${QG_OUT}/stdout"; qg_fail checkstyle findings "runner exited ${rc}"; exit 0; }
        f="${QG_TREE}/${report}"
        [ -s "$f" ] || { qg_fail checkstyle findings "the runner wrote no ${report}"; exit 0; }
        xmllint --noout "$f" 2>/dev/null || { qg_fail checkstyle findings "${report} is not well-formed XML"; exit 0; }
        # One line per <error>: file, line, source, message, with the XML entities undone.
        awk 'BEGIN { RS = "<"; FS = "\n" }
             function attr(s, k,   r) { r = ""; if (match(s, " " k "=\"[^\"]*\"")) r = substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 4); return r }
             function unesc(s) { gsub(/&quot;/, "\"", s); gsub(/&apos;|&#0?39;/, "\047", s); gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&amp;/, "\\&", s); return s }
             /^file / { file = unesc(attr($0, "name")) }
             /^error / { printf "%s\t%s\t%s\t%s\n", file, attr($0, "line"), unesc(attr($0, "source")), unesc(attr($0, "message")) }' "$f" \
            | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t")
                | {ruleId: (if .[2] == "" then "checkstyle.error" else .[2] end), file: .[0],
                   line: (.[1] | tonumber? // null), level: "error", message: .[3], doc: null}]' > "${QG_OUT}/findings.json"
        if [ "$(qg_kv lines)" = added ]; then
            qg_added_only "${QG_OUT}/findings.json" || { qg_fail checkstyle findings "$QG_ERROR"; exit 0; }
            qg_result checkstyle measured "$QG_COUNT" findings "${QG_OUT}/findings.json" -
        else
            qg_result checkstyle measured "$(jq length "${QG_OUT}/findings.json")" findings "${QG_OUT}/findings.json" -
        fi ;;
    *)
        qg_usage checkstyle ;;
esac
