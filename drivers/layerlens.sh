#!/usr/bin/env bash
# layerlens driver: dependency cycles between folders, as the `--!--` edges in the DEPS.md files
# layerlens writes. Contract: vault/architecture/qg-driver-contract.md; keys:
# vault/architecture/qg-dart-drivers.md.
#
# args:  package=<name> [only=<glob>] [paths=<dir,dir>] [version=<x.y.z>]
#   package   required: the package name in pubspec.yaml
#   only      default lib/**
#   paths     where DEPS.md files are deleted before the run and counted after it; default lib
#   version   default 3.1.0; layerlens is a global install, and another version is an error
#
# metric = `--!--` lines in the DEPS.md files this run wrote. A run that wrote none is an error.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"
# shellcheck source=../lib/qg-dart.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-dart.sh"

case "${1:-}" in
    describe)
        printf '{"name":"layerlens","summary":"layerlens: dependency cycles between folders","requires":["jq","git"],"needs_tree":true,"sandbox":true,"writes":[".dart_tool"]}\n' ;;
    explain)
        printf 'Counts the cycle edges (--!--) layerlens draws in each folder'"'"'s DEPS.md. Open the DEPS.md the finding\n'
        printf 'names and remove one import of the cycle. Keys: package (required) only paths version.\n' ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        package="$(qg_need layerlens edges package)" || exit 0
        only="$(qg_kv only)" || only='lib/**'
        version="$(qg_kv version)" || version=3.1.0
        qg_paths lib
        qg_dart_prepare layerlens edges || exit 0
        have="$("$QG_DART" pub global list 2>/dev/null | awk '$1 == "layerlens" { print $2 }')"
        [ "$have" = "$version" ] \
            || { qg_fail layerlens edges "layerlens ${have:-is not installed}${have:+ is installed}, the row needs ${version}: dart pub global activate layerlens ${version}"; exit 0; }
        for p in "${QG_PATH_LIST[@]}"; do
            [ -d "${QG_TREE}/${p}" ] || { qg_fail layerlens edges "path ${p} is not a folder in the measured tree"; exit 0; }
            find "${QG_TREE}/${p}" -name DEPS.md -type f -delete
        done
        # layerlens writes a DEPS.md into every folder under paths=: those folders join the writes.
        QG_SANDBOX_WRITES="${QG_SANDBOX_WRITES:-} ${QG_PATH_LIST[*]}" \
        qg_tool - 0 "$QG_DART" pub global run layerlens --path . --package "$package" --only "$only" \
            || { qg_fail layerlens edges "$QG_ERROR"; exit 0; }
        (cd "$QG_TREE" && find "${QG_PATH_LIST[@]}" -name DEPS.md -type f -print0) > "${QG_OUT}/deps"
        [ -s "${QG_OUT}/deps" ] || { qg_fail layerlens edges "layerlens wrote no DEPS.md under ${QG_PATH_LIST[*]}"; exit 0; }
        mapfile -d '' deps < "${QG_OUT}/deps"
        rc=0
        (cd "$QG_TREE" && grep -Hn -- '--!--' "${deps[@]}") > "${QG_OUT}/hits" || rc=$?
        # grep exits 1 when no file holds a cycle, 2 when one could not be read.
        [ "$rc" -le 1 ] || { qg_fail layerlens edges "reading the DEPS.md files failed (grep exit ${rc})"; exit 0; }
        n="$(grep -c . "${QG_OUT}/hits")"
        head -200 "${QG_OUT}/hits" | jq -R -s -c '[split("\n")[] | select(length > 0)
            | capture("^(?<f>[^:]+):(?<l>[0-9]+):(?<m>.*)$")
            | {ruleId: "layerlens.cycle", file: .f, line: (.l | tonumber), level: "error", message: .m, doc: null}]' \
            > "${QG_OUT}/findings.json"
        qg_result layerlens measured "$n" edges "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage layerlens ;;
esac
