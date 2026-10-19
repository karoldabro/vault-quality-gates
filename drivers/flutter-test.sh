#!/usr/bin/env bash
# flutter test driver: failing tests, or line coverage, from one `flutter test --coverage --machine`
# run shared by every row of a run. Contract: vault/architecture/qg-driver-contract.md; keys:
# vault/architecture/qg-dart-drivers.md.
#
# args:  metric=failed|coverage [concurrency=<n>] [include=<ERE>] [exclude=<ERE>]
#   metric        required. failed: tests whose result is failure or error, a file that fails to
#                 load included. coverage: LH over LF of the lcov blocks kept, two decimals
#   include       coverage keeps blocks whose tree-relative path matches; exclude drops them
#
# The suite is code the commit wrote, so it runs through qg_isolated (lib/qg-dart.sh): its own session,
# a minimal environment, every leftover process killed. Its stream and lcov file go to a 0700 folder
# outside the measured tree. Coverage counts only the libraries some test loads, as v1 does. A run with no `done` event, no visible
# test, an exit code other than 0 or 1, or exit 1 with no failure is an error, never a pass.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"
# shellcheck source=../lib/qg-dart.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-dart.sh"

# produce -> $QG_OUT/flutter-test holds {failed, tests, done, rc, lh, lf, findings}.
produce() {
    local d tmp rc=0 conc inc exc argv=()
    qg_dart_env && qg_dart_packages || return 1
    conc="$(qg_kv concurrency)" && argv+=("--concurrency=${conc}")
    inc="$(qg_kv include)" || inc=''
    exc="$(qg_kv exclude)" || exc=''
    d="$(mktemp -d)" && chmod 700 "$d" || { QG_ERROR='cannot create a private folder for the test stream'; return 1; }
    tmp="$(mktemp -d)" || { QG_ERROR='cannot create a private temp folder for the suite'; rm -rf "$d"; return 1; }
    ( cd "$QG_TREE" && qg_isolated "$tmp" "$QG_FLUTTER" test --no-pub --coverage --coverage-path "${d}/lcov.info" \
        --machine "${argv[@]}" ) > "${d}/stream" 2> "${d}/stderr" || rc=$?
    rm -rf "$tmp"
    tail -20 "${d}/stderr"
    if [ "$rc" != 0 ] && [ "$rc" != 1 ]; then
        QG_ERROR="flutter test exited ${rc}"; rm -rf "$d"; return 1
    fi
    # The machine stream mixes event objects with blank lines and [{"event":...}] arrays.
    grep '^{' "${d}/stream" | jq -s -c --argjson rc "$rc" '
        (map(select(.type == "testStart")) | map({key: (.test.id | tostring), value: .test}) | from_entries) as $t
        | map(select(.type == "testDone")) as $done
        | {done: any(.[]; .type == "done"), rc: $rc,
           tests: ($done | map(select(.hidden != true and .skipped != true)) | length),
           failed: (([$done[] | select(.result == "failure" or .result == "error") | .testID]
                     + [.[] | select(.type == "error") | .testID]) | unique | length),
           findings: ($done | map(select(.result == "failure" or .result == "error"))[0:50]
               | map($t[.testID | tostring] as $s
                 | {ruleId: "flutter-test.failure", file: (($s.root_url // $s.url // null) | if . == null then null else sub("^file://"; "") end),
                    line: ($s.root_line // $s.line // null), level: "error",
                    message: ("failed: " + ($s.name // "a test")), doc: null}))}' \
        > "${d}/summary" 2> /dev/null || { QG_ERROR='the flutter test stream holds no readable event'; rm -rf "$d"; return 1; }
    if [ -s "${d}/lcov.info" ]; then
        # The EREs travel in the environment: awk -v would turn \. into . under gawk.
        QG_INC="$inc" QG_EXC="$exc" awk -v t="${QG_TREE%/}/" '
            BEGIN { inc = ENVIRON["QG_INC"]; exc = ENVIRON["QG_EXC"] }
            /^SF:/ { f = substr($0, 4); if (index(f, t) == 1) f = substr(f, length(t) + 1); sub(/^\.\//, "", f)
                     keep = (inc == "" || f ~ inc) && (exc == "" || f !~ exc) }
            /^LH:/ && keep { h += substr($0, 4) }
            /^LF:/ && keep { n += substr($0, 4) }
            END { printf "{\"lh\":%d,\"lf\":%d}\n", h, n }' "${d}/lcov.info" > "${d}/cov"
    else
        printf '{"lh":null,"lf":null}\n' > "${d}/cov"
    fi
    jq -s -c '.[0] + .[1]' "${d}/summary" "${d}/cov" > "${QG_OUT}/flutter-test"
    rm -rf "$d"
}

case "${1:-}" in
    describe)
        printf '{"name":"flutter-test","summary":"flutter test: failing tests or line coverage of one suite run","requires":["jq","git","awk"],"needs_tree":true}\n' ;;
    explain)
        if [ "${2:-}" = flutter-test.failure ]; then
            printf 'A test failed, errored or did not load. Run it alone with flutter test <file>, then fix the code or the test.\n'
        else
            printf 'Runs the Flutter suite once with coverage and reads failing tests or line coverage.\n'
            printf 'Keys: metric (required: failed, coverage) concurrency include exclude.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        metric="$(qg_need flutter-test tests metric)" || exit 0
        case "$metric" in failed) unit=tests ;; coverage) unit=percent ;;
            *) qg_fail flutter-test tests "metric=${metric} is not failed or coverage"; exit 0 ;; esac
        QG_ERROR=''
        qg_shared_report flutter-test produce || { qg_fail flutter-test "$unit" "$QG_ERROR"; exit 0; }
        s="${QG_OUT}/flutter-test"
        [ "$(jq -r '.done' "$s")" = true ] || { qg_fail flutter-test "$unit" 'the test run ended without a done event'; exit 0; }
        [ "$(jq -r '.tests' "$s")" -gt 0 ] || { qg_fail flutter-test "$unit" 'no test ran'; exit 0; }
        failed="$(jq -r '.failed' "$s")"
        if [ "$(jq -r '.rc' "$s")" = 1 ] && [ "$failed" = 0 ]; then
            qg_fail flutter-test "$unit" 'flutter test exited 1 and reported no failing test'; exit 0
        fi
        if [ "$metric" = failed ]; then
            jq -c '.findings' "$s" > "${QG_OUT}/findings.json"
            qg_result flutter-test measured "$failed" tests "${QG_OUT}/findings.json" -
        else
            lf="$(jq -r '.lf' "$s")" lh="$(jq -r '.lh' "$s")"
            [ "$lf" != null ] || { qg_fail flutter-test percent 'flutter test wrote no lcov.info'; exit 0; }
            [ "$lf" -gt 0 ] || { qg_fail flutter-test percent 'no coverage line is left after include= and exclude='; exit 0; }
            qg_result flutter-test measured "$(awk -v h="$lh" -v f="$lf" 'BEGIN { printf "%.2f", h / f * 100 }')" percent - -
        fi ;;
    *)
        qg_usage flutter-test ;;
esac
