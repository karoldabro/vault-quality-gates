#!/usr/bin/env bash
# composer-dependency-analyser driver: one class of composer.json dependency issue. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [metric=shadow|unused|dev-in-prod|prod-only-in-dev] [runner=<repo path>]
#        [bin=<analyser path>] [config=<repo path>] [-- <extra argv>]
#   metric       default shadow
#
# metric = the packages listed under `Found <n> <metric>`; `No composer issues found` is 0. The
# tool exits 1 both on issues and on a bad config, so only its result line tells them apart. Rows
# of one run that differ only in metric= share one run (qg_shared_report).
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

produce() {
    local opts=() config
    config="$(qg_kv config)" && opts+=("--config=${config}")
    qg_tool - '0 1' "$bin" "${opts[@]}" "${argv[@]}" || return 1
    sed 's/\x1b\[[0-9;]*m//g' "${QG_OUT}/stdout" > "${QG_OUT}/cda.txt"
    if ! grep -q 'Found [0-9]\|No composer issues found' "${QG_OUT}/cda.txt"; then
        tail -20 "${QG_OUT}/cda.txt"
        QG_ERROR="composer-dependency-analyser exited ${QG_RC} and printed no result line"; return 1
    fi
}

case "${1:-}" in
    describe)
        printf '{"name":"composer-dependency-analyser","summary":"composer-dependency-analyser: counts one class of dependency issue","requires":["jq"],"needs_tree":true}\n' ;;
    explain)
        case "${2:-}" in
            cda.shadow) printf 'Code uses a package that composer.json does not require. Add it to require, or stop using it.\n' ;;
            cda.unused) printf 'composer.json requires a package no code uses. Remove it from composer.json.\n' ;;
            cda.*)      printf 'A dependency sits in the wrong composer.json section. Move it to the section its use needs.\n' ;;
            *)  printf 'Runs composer-dependency-analyser and counts one issue class: shadow (used, not required),\n'
                printf 'unused (required, not used), dev-in-prod, prod-only-in-dev. Keys: metric runner bin config.\n' ;;
        esac ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        metric="$(qg_kv metric)" || metric=shadow
        bin="$(qg_kv bin)" || bin='vendor/bin/composer-dependency-analyser'
        read -ra argv <<<"$(qg_argv)"
        qg_shared_report cda.txt produce || { qg_fail composer-dependency-analyser packages "$QG_ERROR"; exit 0; }
        n="$(grep -oE "Found [0-9]+ ${metric}" "${QG_OUT}/cda.txt" | grep -oE '[0-9]+' | head -1)"
        # One finding per package of this class, with the first use the tool names.
        awk -v sel="$metric" '
            /^Found [0-9]+ / { on = ($3 == sel || index($0, "Found " $2 " " sel) == 1) ; next }
            on && /^  • / { if (pkg != "") print pkg "\t"; pkg = $0; sub(/^  • /, "", pkg); next }
            on && pkg != "" && /e\.g\. / { use = $0; sub(/^ *e\.g\. /, "", use); print pkg "\t" use; pkg = "" }
            on && pkg != "" && /^$/ { print pkg "\t"; pkg = "" }' "${QG_OUT}/cda.txt" \
            | jq -R -s -c --arg m "$metric" '[split("\n")[] | select(length > 0) | split("\t")
                | (.[1] // "") as $u | ($u | capture(" in (?<f>[^ :]+):(?<l>[0-9]+)") // {}) as $loc
                | {ruleId: ("cda." + $m), file: ($loc.f // null), line: (($loc.l // null) | if . then tonumber else null end),
                   level: "error", message: (.[0] + " (" + $m + ")" + (if $u != "" then ": " + $u else "" end)), doc: null}]' \
            > "${QG_OUT}/findings.json"
        qg_result composer-dependency-analyser measured "${n:-0}" packages "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage composer-dependency-analyser ;;
esac
