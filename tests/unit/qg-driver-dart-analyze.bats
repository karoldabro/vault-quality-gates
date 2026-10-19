#!/usr/bin/env bats
# drivers/dart-analyze.sh — dart analyze --format=machine diagnostics at or above severity=, kept by
# code=. The fake dart prints the real recorded tests/fixtures/drivers/dart/analyze-machine.txt (487
# lines, 32 UNAWAITED_FUTURES, 46 WARNING, 441 INFO, no ERROR on 884aad23) with /TREE/ set to the
# test's tree, or an inline machine report.

load guard-helpers
load qg-dart-helpers

ROOT=/code
DRIVER="$ROOT/drivers/dart-analyze.sh"
FIX=/code/tests/fixtures/drivers/dart

setup() {
    dart_setup
    sed "s#/TREE/#$TREE/#" "$FIX/analyze-machine.txt" > "$WORK/analyze.out"
    export FAKE_OUT="$WORK/analyze.out" FAKE_RC=2
}

teardown() { dart_teardown; }

measure() { rm -f "$QG_OUT/result.json"; QG_ARGS="${1:-}" "$DRIVER" run > /dev/null; }

machine() {  # machine <line>... -> the fake prints these machine lines instead of the recording
    printf '%s\n' "$@" > "$WORK/inline.out"
    FAKE_OUT="$WORK/inline.out"
}

@test "describe is JSON naming dart-analyze with needs_tree true; explain prints text and the code's doc" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = dart-analyze ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    run "$DRIVER" explain unawaited_futures
    [[ "$output" == *'https://dart.dev/tools/diagnostics/unawaited_futures'* ]]
}

@test "the recorded output measures 487 findings, after pub get, from one dart analyze --format=machine -- . call" {
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 487 ]
    [ "$(result .unit)" = findings ]
    [ "$(cat "$CALLS")" = $'dart pub get --offline --enforce-lockfile\ndart analyze --format=machine -- .' ]
}

@test "code=unawaited_futures measures 32 on the recorded output, in either case, with lower-cased ruleIds" {
    measure code=unawaited_futures
    [ "$(result .metric)" = 32 ]
    [ "$(result '[.findings[].ruleId] | unique | join(",")')" = unawaited_futures ]
    measure code=UNAWAITED_FUTURES
    [ "$(result .metric)" = 32 ]
    measure code=unawaited_futures,unused_import
    [ "$(result .metric)" = 61 ]
}

@test "severity=warning measures the 46 warnings and severity=error the 0 errors of the recorded output" {
    measure severity=warning
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 46 ]
    measure severity=error
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    measure severity=info
    [ "$(result .metric)" = 487 ]
}

@test "severity= is a floor: info counts all three levels, warning two, error one" {
    machine 'ERROR|COMPILE_TIME_ERROR|UNDEFINED_IDENTIFIER|/x/lib/a.dart|1|1|1|e' \
        'WARNING|STATIC_WARNING|UNUSED_IMPORT|/x/lib/a.dart|2|1|1|w' \
        'INFO|LINT|PREFER_CONST|/x/lib/a.dart|3|1|1|i'
    measure
    [ "$(result .metric)" = 3 ]
    measure severity=warning
    [ "$(result .metric)" = 2 ]
    measure severity=error
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings[0].level')" = error ]
}

@test "an unknown severity= is status error naming it, and dart never runs" {
    measure severity=hint
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'severity=hint'* ]]
    [ "$(calls_of .)" = 0 ]
}

@test "dart analyze exits 0, 1, 2 and 3 are measured" {
    local rc
    for rc in 0 1 2 3; do
        FAKE_RC="$rc" measure
        [ "$(result .status)" = measured ] || { echo "exit $rc not measured"; return 1; }
        [ "$(result .metric)" = 487 ]
    done
}

@test "dart analyze exit 4 or 64 is status error with metric null" {
    local rc
    for rc in 4 64; do
        FAKE_RC="$rc" measure
        [ "$(result .status)" = error ] && [ "$(result .metric)" = null ] || { echo "exit $rc"; return 1; }
        [[ "$(result .error)" == *"exited $rc"* ]]
    done
}

@test "a \\| inside the message or the path is one field: the line counts once with the pipe restored" {
    machine 'INFO|LINT|SOME_LINT|/x/lib/a\|b.dart|7|1|2|Use a \| b instead of c \| d.' \
        'INFO|LINT|SOME_LINT|/x/lib/c.dart|9|1|2|plain'
    measure
    echo "message: $(result '.findings[0].message')  file: $(result '.findings[0].file')"
    [ "$(result .metric)" = 2 ]
    [ "$(result '.findings[0].message')" = 'Use a | b instead of c | d.' ]
    [ "$(result '.findings[0].file')" = '/x/lib/a|b.dart' ]
    [ "$(result '.findings[0].line')" = 7 ]
}

@test "findings carry the tree-relative file, the line, the level and the diagnostics doc url" {
    measure code=unused_field
    [ "$(result '.findings[0].file')" = lib/data/api/clients/wrapper.dart ]
    [ "$(result '.findings[0].line')" = 33 ]
    [ "$(result '.findings[0].level')" = warning ]
    [ "$(result '.findings[0].ruleId')" = unused_field ]
    [ "$(result '.findings[0].doc')" = https://dart.dev/tools/diagnostics/unused_field ]
    measure code=non_constant_identifier_names
    [ "$(result '.findings[0].level')" = note ]
}

@test "a nested analysis_options.yaml outside options-allow= is status error naming it, and nothing runs" {
    mkdir -p "$TREE/tool/givore_lints" "$TREE/packages/x"
    : > "$TREE/analysis_options.yaml"
    : > "$TREE/tool/givore_lints/analysis_options.yaml"
    : > "$TREE/packages/x/analysis_options.yaml"
    measure options-allow=tool/givore_lints/analysis_options.yaml
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'packages/x/analysis_options.yaml'* ]]
    [[ "$(result .error)" != *'tool/givore_lints'* ]]
    [ "$(calls_of .)" = 0 ]
}

@test "nested analysis_options.yaml files all named in options-allow= are measured" {
    mkdir -p "$TREE/tool/givore_lints" "$TREE/packages/x"
    : > "$TREE/tool/givore_lints/analysis_options.yaml"
    : > "$TREE/packages/x/analysis_options.yaml"
    measure options-allow=tool/givore_lints/analysis_options.yaml,packages/x/analysis_options.yaml
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 487 ]
}

@test "the root analysis_options.yaml and those under .dart_tool, build and .git are never nested options" {
    mkdir -p "$TREE/.dart_tool/pkg" "$TREE/build/x" "$TREE/.git/y" "$TREE/app/build"
    : > "$TREE/analysis_options.yaml"
    : > "$TREE/.dart_tool/pkg/analysis_options.yaml"
    : > "$TREE/build/x/analysis_options.yaml"
    : > "$TREE/.git/y/analysis_options.yaml"
    : > "$TREE/app/build/analysis_options.yaml"
    measure
    [ "$(result .status)" = measured ]
}

@test "paths= spelled lib, lib/ and ./lib reach dart analyze as lib; paths=lib,test passes both" {
    local p
    for p in lib lib/ ./lib; do
        measure "paths=$p"
        [ "$(tr '\n' ' ' < "$ARGV")" = 'analyze --format=machine -- lib ' ] || { echo "paths=$p: $(cat "$ARGV")"; return 1; }
    done
    measure paths=lib,test
    [ "$(tr '\n' ' ' < "$ARGV")" = 'analyze --format=machine -- lib test ' ]
}

@test "files=changed with no Dart file changed measures 0 and runs nothing" {
    mkdir -p "$TREE/lib"; : > "$TREE/README.md"
    files_list README.md lib/gone.dart
    measure files=changed
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    [ "$(calls_of .)" = 0 ]
}

@test "files=changed passes the existing changed Dart files kept by include= and exclude=" {
    mkdir -p "$TREE/lib" "$TREE/test"
    : > "$TREE/lib/a.dart"; : > "$TREE/lib/a.g.dart"; : > "$TREE/test/t.dart"
    files_list lib/a.dart lib/a.g.dart test/t.dart lib/gone.dart
    measure 'files=changed include=^lib/ exclude=\.g\.dart$'
    [ "$(tr '\n' ' ' < "$ARGV")" = 'analyze --format=machine -- lib/a.dart ' ]
}

@test "lines=added counts only the findings on lines the commit adds" {
    mkdir -p "$REPO/lib"
    printf 'one\ntwo\n' > "$REPO/lib/a.dart"
    ( cd "$REPO" && commit_all base )
    export QG_BASES="$(git -C "$REPO" rev-parse HEAD)" QG_TREE="$REPO"
    printf 'one\ntwo\nthree\n' > "$REPO/lib/a.dart"
    git -C "$REPO" add -A
    files_list lib/a.dart
    machine "INFO|LINT|OLD_LINT|$REPO/lib/a.dart|2|1|1|old line" \
        "WARNING|STATIC_WARNING|NEW_WARNING|$REPO/lib/a.dart|3|1|1|added line"
    measure lines=added
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings | length')" = 1 ]
    [ "$(result '.findings[0].ruleId')" = new_warning ]
}

@test "a failed offline pub get is status error and dart analyze never runs" {
    export FAKE_PUB_RC=1 FAKE_PUB_OUT='lakos 2.0.7 is not in the cache'
    measure
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'run flutter pub get'* ]]
    [ "$(calls_of '^dart analyze')" = 0 ]
}
