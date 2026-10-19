#!/usr/bin/env bats
# drivers/lakos.sh — one lakos graph metric (.metrics.nccd, .ccd or .acd). lakos exits 5 on a cycle
# and still prints its JSON, so exits 0 and 5 measure. The fake dart prints the real recorded
# tests/fixtures/drivers/dart/lakos.json (nccd 4.51, ccd 37603, acd 40.09, a cycle) or an inline one.

load guard-helpers
load qg-dart-helpers

ROOT=/code
DRIVER="$ROOT/drivers/lakos.sh"
FIX=/code/tests/fixtures/drivers/dart

setup() {
    dart_setup
    mkdir -p "$TREE/lib"
    export FAKE_OUT="$FIX/lakos.json" FAKE_RC=5
}

teardown() { dart_teardown; }

measure() { rm -f "$QG_OUT/result.json"; QG_ARGS="${1:-}" "$DRIVER" run > /dev/null; }
lakos_calls() { calls_of '^dart run lakos'; }

@test "describe is JSON naming lakos with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = lakos ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ]
    [[ "$output" == *'nccd'* ]]
}

@test "the recorded output at exit 5 measures the default metric nccd, 4.51" {
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 4.51 ]
    [ "$(result .unit)" = ratio ]
}

@test "exit 0 is measured" {
    FAKE_RC=0 measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 4.51 ]
}

@test "metric=ccd and metric=acd read their own field" {
    measure metric=ccd
    [ "$(result .metric)" = 37603 ]
    measure metric=acd
    [ "$(result .metric)" = 40.09 ]
}

@test "an unknown metric= is status error naming it, and nothing runs" {
    measure metric=numNodes
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'metric=numNodes'* ]]
    [ "$(calls_of .)" = 0 ]
}

@test "exits 1, 2 and 4 are status error with metric null, even with JSON" {
    local rc
    for rc in 1 2 4; do
        FAKE_RC="$rc" measure
        [ "$(result .status)" = error ] && [ "$(result .metric)" = null ] || { echo "exit $rc"; return 1; }
        [[ "$(result .error)" == *"exited $rc"* ]]
    done
}

@test "no JSON on stdout is status error" {
    printf 'Unhandled exception: FileSystemException\n' > "$WORK/out.txt"
    FAKE_OUT="$WORK/out.txt" measure
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'no numeric .metrics.nccd'* ]]
}

@test "JSON without the metric, or with a non-numeric one, is status error" {
    printf '{"metrics":{"ccd":1}}\n' > "$WORK/out.json"
    FAKE_OUT="$WORK/out.json" measure
    [ "$(result .status)" = error ]
    printf '{"metrics":{"nccd":"4.51"}}\n' > "$WORK/out.json"
    FAKE_OUT="$WORK/out.json" measure
    [ "$(result .status)" = error ]
}

@test "text printed before the JSON is skipped" {
    { printf 'Resolving dependencies...\nBuilding package executable...\n'; cat "$FIX/lakos.json"; } > "$WORK/out.txt"
    FAKE_OUT="$WORK/out.txt" measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 4.51 ]
}

@test "a cyclic graph adds one note finding naming the first cycle; an acyclic one adds none" {
    measure
    [ "$(result '.findings | length')" = 1 ]
    [ "$(result '.findings[0].ruleId')" = lakos.cycle ]
    [ "$(result '.findings[0].level')" = note ]
    [[ "$(result '.findings[0].message')" == 'first cycle: /data/api/model/reaction/reaction_count_api_model.dart -> '* ]]
    jq '.metrics.isAcyclic = true' "$FIX/lakos.json" > "$WORK/out.json"
    FAKE_OUT="$WORK/out.json" FAKE_RC=0 measure
    [ "$(result '.findings | length')" = 0 ]
    jq '.metrics.isAcyclic = true | .metrics.firstCycle = null' "$FIX/lakos.json" > "$WORK/out.json"
    FAKE_OUT="$WORK/out.json" FAKE_RC=0 measure
    [ "$(result '.findings | length')" = 0 ]
}

@test "argv is run lakos --format json --metrics [--ignore <glob>] <folder>, default lib" {
    measure
    [ "$(tr '\n' ' ' < "$ARGV")" = 'run lakos --format json --metrics lib ' ]
    measure 'paths=src ignore={**.g.dart,**.freezed.dart,generated/**}'
    [ "$(tr '\n' ' ' < "$ARGV")" = 'run lakos --format json --metrics --ignore {**.g.dart,**.freezed.dart,generated/**} src ' ]
}

@test "paths= naming two folders is status error, and nothing runs" {
    measure paths=lib,test
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'one folder'* ]]
    [ "$(calls_of .)" = 0 ]
}

@test "a failed offline pub get is status error and lakos never runs" {
    export FAKE_PUB_RC=1 FAKE_PUB_OUT='lakos 2.0.7 is not in the cache'
    measure
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'run flutter pub get'* ]]
    [ "$(lakos_calls)" = 0 ]
}
