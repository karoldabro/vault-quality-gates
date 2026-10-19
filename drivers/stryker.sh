#!/usr/bin/env bash
# Stryker driver: the mutation score of a StrykerJS JSON report. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [report=<tree path>] [config=<tree path>] [run=no] [runner=<repo path>] [bin=<stryker path>]
#        [-- <extra stryker argv>]
#   report       default reports/mutation/mutation.json, which the config's jsonReporter must write
#   config       default stryker.config.json, run as `stryker run <config>`
#   run=no       read the report a previous run left; run nothing
#   bin          default node_modules/.bin/stryker
#
# metric = (Killed + Timeout) / (all mutants - Ignored - CompileError) x 100, two decimals, as
# app.givore.com scripts/quality-metric.mjs `mutation` computes it. Zero counted mutants is an error.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"stryker","summary":"StrykerJS: the mutation score","requires":["jq"],"needs_tree":true}\n' ;;
    explain)
        if [ -n "${2:-}" ]; then
            printf 'Stryker mutator %s changed this line and no test failed. Add a test that fails on the mutated code.\n' "$2"
        else
            printf 'Runs Stryker unless run=no and reads the mutation score from its JSON report; higher is better. Kill\n'
            printf 'surviving mutants with tests that check behaviour. Keys: report config run runner bin, then -- <argv>.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        report="$(qg_kv report)" || report=reports/mutation/mutation.json
        if [ "$(qg_kv run)" != no ]; then
            bin="$(qg_kv bin)" || bin='node_modules/.bin/stryker'
            config="$(qg_kv config)" || config=stryker.config.json
            read -ra argv <<<"$(qg_argv)"
            # Stryker exits non-zero below its break threshold; a fresh report decides the value.
            qg_tool "$report" "$(seq -s ' ' 0 255)" "$bin" run "$config" "${argv[@]}" \
                || { qg_fail stryker percent "$QG_ERROR"; exit 0; }
        fi
        f="${QG_TREE}/${report}"
        [ -s "$f" ] || { qg_fail stryker percent "stryker report ${report} does not exist or is empty"; exit 0; }
        counts="$(jq -r '[.files | to_entries[] | .value.mutants[] | .status]
            | [(map(select(. == "Killed" or . == "Timeout")) | length),
               (map(select(. != "Ignored" and . != "CompileError")) | length)] | @tsv' "$f" 2>/dev/null)" \
            || { qg_fail stryker percent "stryker: ${report} has no files object with a mutants list each"; exit 0; }
        read -r killed counted <<<"$counts"
        [ "${counted:-0}" -gt 0 ] || { qg_fail stryker percent "stryker: ${report} holds no counted mutants"; exit 0; }
        # Number(x.toFixed(2)): round half up on the exact double, then drop trailing zeros.
        pct="$(awk -v k="$killed" -v c="$counted" 'BEGIN {
            x = k / c * 100; s = sprintf("%.40f", x); sub(/^[0-9]*\.[0-9][0-9]/, "", s)
            r = sprintf("%.2f", (s ~ /^50*$/) ? x + 0.001 : x)
            sub(/0+$/, "", r); sub(/\.$/, "", r); print r }')"
        # One finding per surviving or uncovered mutant, the first 50.
        jq -c '[.files | to_entries[] | .key as $file | .value.mutants[]
                | select(.status == "Survived" or .status == "NoCoverage")
                | {ruleId: (.mutatorName // "stryker"), file: $file, line: (.location.start.line // null), level: "warning",
                   message: ((if .status == "Survived" then "surviving" else "uncovered" end) + " mutant: " + (.mutatorName // "")),
                   doc: null}][:50]' \
            "$f" > "${QG_OUT}/findings.json" 2>/dev/null || printf '[]' > "${QG_OUT}/findings.json"
        qg_result stryker measured "$pct" percent "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage stryker ;;
esac
