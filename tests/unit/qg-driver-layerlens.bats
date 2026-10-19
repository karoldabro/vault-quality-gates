#!/usr/bin/env bats
# drivers/layerlens.sh — the `--!--` cycle edges in the DEPS.md files layerlens writes this run under
# paths=. The fake dart answers `pub global list` with $FAKE_GLOBAL and, for `pub global run
# layerlens`, copies the real recorded tests/fixtures/drivers/dart/layerlens-DEPS.md (2 edges) into
# each folder $FAKE_WRITE names.

load guard-helpers
load qg-dart-helpers

ROOT=/code
DRIVER="$ROOT/drivers/layerlens.sh"
FIX=/code/tests/fixtures/drivers/dart
DEPS="$FIX/layerlens-DEPS.md"

setup() {
    dart_setup
    mkdir -p "$TREE/lib/domain" "$TREE/lib/data" "$TREE/lib/ui"
    export FAKE_WRITE="lib/domain/DEPS.md=$DEPS lib/data/DEPS.md=$DEPS lib/ui/DEPS.md=$DEPS" FAKE_RC=0
}

teardown() { dart_teardown; }

measure() { rm -f "$QG_OUT/result.json"; QG_ARGS="${1:-package=givore}" "$DRIVER" run > /dev/null; }
layerlens_calls() { calls_of '^dart pub global run layerlens'; }

@test "describe is JSON naming layerlens with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = layerlens ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ]
    [[ "$output" == *'--!--'* ]]
}

@test "the recorded DEPS.md written in three folders measures 6 edges" {
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 6 ]
    [ "$(result .unit)" = edges ]
    [ "$(result .metric)" = "$((3 * $(grep -c -- '--!--' "$DEPS")))" ]
}

@test "findings name the DEPS.md file and the line of each edge" {
    measure
    [ "$(result '.findings | length')" = 6 ]
    [ "$(result '.findings[0].ruleId')" = layerlens.cycle ]
    [ "$(result '[.findings[].file] | unique | join(",")')" = lib/data/DEPS.md,lib/domain/DEPS.md,lib/ui/DEPS.md ]
    [ "$(result '.findings[0].line')" = "$(grep -n -- '--!--' "$DEPS" | head -1 | cut -d: -f1)" ]
    [ "$(result '.findings[0].message')" = 'models--!-->contracts;' ]
}

@test "argv is pub global run layerlens --path . --package <package> --only <only>, default lib/**" {
    measure
    [ "$(tr '\n' ' ' < "$ARGV")" = 'pub global run layerlens --path . --package givore --only lib/** ' ]
    measure 'package=givore only=lib/domain/**'
    [ "$(tr '\n' ' ' < "$ARGV")" = 'pub global run layerlens --path . --package givore --only lib/domain/** ' ]
}

@test "a missing package= is status error naming package=, and nothing runs" {
    measure only=lib/**
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'package='* ]]
    [ "$(calls_of .)" = 0 ]
}

@test "a stale DEPS.md under paths= is deleted before the run and never counted" {
    mkdir -p "$TREE/lib/old"
    printf 'a--!-->b;\nc--!-->d;\ne--!-->f;\n' > "$TREE/lib/old/DEPS.md"
    measure
    [ ! -e "$TREE/lib/old/DEPS.md" ]
    [ "$(result .metric)" = 6 ]
}

@test "a run that writes no DEPS.md is status error, even with a stale one planted" {
    mkdir -p "$TREE/lib/old"
    cp "$DEPS" "$TREE/lib/old/DEPS.md"
    unset FAKE_WRITE
    measure
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'wrote no DEPS.md'* ]]
}

@test "a DEPS.md written outside paths= is not counted, so a run with none inside is status error" {
    mkdir -p "$TREE/tool"
    export FAKE_WRITE="tool/DEPS.md=$DEPS"
    measure
    [ "$(result .status)" = error ]
    export FAKE_WRITE="tool/DEPS.md=$DEPS lib/domain/DEPS.md=$DEPS"
    measure
    [ "$(result .metric)" = 2 ]
}

@test "DEPS.md files with no cycle measure 0" {
    grep -v -- '--!--' "$DEPS" > "$WORK/clean.md"
    export FAKE_WRITE="lib/domain/DEPS.md=$WORK/clean.md"
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    [ "$(result '.findings | length')" = 0 ]
}

@test "an installed layerlens version other than version= is status error naming both, and layerlens never runs" {
    export FAKE_GLOBAL='layerlens 3.0.0'
    measure
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'layerlens 3.0.0 is installed, the row needs 3.1.0'* ]]
    [ "$(layerlens_calls)" = 0 ]
    measure 'package=givore version=3.0.0'
    [ "$(result .status)" = measured ]
}

@test "layerlens not installed is status error, and layerlens never runs" {
    export FAKE_GLOBAL='devtools 2.37.0'
    measure
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'is not installed'*'needs 3.1.0'* ]]
    [ "$(layerlens_calls)" = 0 ]
}

@test "a non-zero layerlens exit is status error even when it wrote DEPS.md files" {
    FAKE_RC=1 measure
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'exited 1'* ]]
}

@test "a paths= entry that is not a folder in the tree is status error" {
    measure 'package=givore paths=lib,missing'
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'path missing is not a folder'* ]]
    [ "$(layerlens_calls)" = 0 ]
}

@test "paths= limits the count to its folders" {
    measure 'package=givore paths=lib/domain'
    [ "$(result .metric)" = 2 ]
}

@test "a failed offline pub get is status error and layerlens never runs" {
    export FAKE_PUB_RC=1 FAKE_PUB_OUT='not in the cache'
    measure
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'run flutter pub get'* ]]
    [ "$(layerlens_calls)" = 0 ]
}
