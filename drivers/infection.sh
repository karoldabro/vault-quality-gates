#!/usr/bin/env bash
# Infection driver: the Mutation Score Indicator. Contract: vault/architecture/qg-driver-contract.md;
# keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  summary=<tree path> [log=<tree path>] [run=no] [runner=<repo path>] [bin=<infection path>]
#        [-- <infection argv>]
#   summary      Infection's summaryJson log, which the infection config must write
#   log          Infection's json log; its escaped mutants become findings
#   run=no       read the summary a previous run left; run nothing
#   bin          default vendor/bin/infection
#
# metric = .stats.msi, or .msi. A null msi is an error: a score that was never computed must not
# read as a pass.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"infection","summary":"Infection: the Mutation Score Indicator","requires":["jq"],"needs_tree":true}\n' ;;
    explain)
        if [ -n "${2:-}" ]; then
            printf 'Infection mutator %s changed this line and no test failed. Add a test that fails on the mutated code.\n' "$2"
        else
            printf 'Runs Infection unless run=no and reads the Mutation Score Indicator; higher is better. Kill escaped\n'
            printf 'mutants with tests that check behaviour. Keys: summary (required) log run runner bin, then -- <argv>.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        summary="$(qg_need infection percent summary)" || exit 0
        if [ "$(qg_kv run)" != no ]; then
            bin="$(qg_kv bin)" || bin='vendor/bin/infection'
            read -ra argv <<<"$(qg_argv)"
            # Infection exits 1 when the score is below its own --min-msi; the summary decides the value.
            qg_tool "$summary" '0 1' "$bin" "${argv[@]}" || { qg_fail infection percent "$QG_ERROR"; exit 0; }
        fi
        f="${QG_TREE}/${summary}"
        [ -r "$f" ] || { qg_fail infection percent "infection summary ${summary} does not exist"; exit 0; }
        msi="$(jq -r '.stats.msi // .msi // empty | select(type == "number")' "$f" 2>/dev/null)"
        [ -n "$msi" ] || { qg_fail infection percent "infection: ${summary} carries no msi, or msi is null"; exit 0; }
        findings=-
        if log="$(qg_kv log)" && [ -r "${QG_TREE}/${log}" ]; then
            jq -c '[(.escaped // [])[:50][] | .mutator as $m
                    | {ruleId: ($m.mutatorName // "infection"), file: $m.originalFilePath, line: $m.originalStartLine,
                       level: "warning", message: ("escaped mutant: " + ($m.mutatorName // "")), doc: null}]' \
                "${QG_TREE}/${log}" > "${QG_OUT}/findings.json" 2>/dev/null && findings="${QG_OUT}/findings.json"
        fi
        qg_result infection measured "$msi" percent "$findings" - ;;
    *)
        qg_usage infection ;;
esac
