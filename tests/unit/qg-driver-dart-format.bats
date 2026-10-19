#!/usr/bin/env bats
# drivers/dart-format.sh — changed Dart files dart format would rewrite: the `Changed <path>` lines of
# `dart format --output=none --set-exit-if-changed`, never its `Formatted ...` summary. The fake dart
# records its argv one per line, prints $FAKE_OUT and exits $FAKE_RC.

load guard-helpers
load qg-dart-helpers

ROOT=/code
DRIVER="$ROOT/drivers/dart-format.sh"
# The recycling_mobile_app format-files row's exclude=.
MIGRATION_EXCLUDE='exclude=\.(g|freezed|mocks|config)\.dart$|^lib/generated/|^tool/givore_lints/test/fixtures/'

setup() {
    dart_setup
    mkdir -p "$TREE/lib"
    : > "$TREE/lib/a.dart"; : > "$TREE/lib/b.dart"; : > "$TREE/lib/c.dart"
    files_list lib/a.dart lib/b.dart lib/c.dart
    export FAKE_OUT="$WORK/format.out" FAKE_RC=1
    printf 'Changed lib/a.dart\nChanged lib/c.dart\nFormatted 3 files (2 changed) in 0.04 seconds.\n' > "$FAKE_OUT"
}

teardown() { dart_teardown; }

measure() { rm -f "$QG_OUT/result.json"; QG_ARGS="${1:-files=changed}" "$DRIVER" run > /dev/null; }

# files_after_dashdash -> the argv the fake saw after the `--` separator, one per line.
files_after_dashdash() { sed -n '/^--$/,$p' "$ARGV" | tail -n +2; }

@test "describe is JSON naming dart-format with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = dart-format ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ]
    [[ "$output" == *'files=changed'* ]]
}

@test "without files=changed it is status error naming files=changed, and nothing runs" {
    measure paths=lib
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'files=changed'* ]]
    [ "$(calls_of .)" = 0 ]
}

@test "exit 1 with two Changed lines measures 2, and the Formatted summary is never counted" {
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 2 ]
    [ "$(result .unit)" = files ]
    [ "$(result '[.findings[].file] | join(",")')" = lib/a.dart,lib/c.dart ]
    [ "$(result '.findings[0].ruleId')" = dart-format.unformatted ]
}

@test "exit 0 with only the summary line measures 0" {
    printf 'Formatted 3 files (0 changed) in 0.03 seconds.\n' > "$FAKE_OUT"
    FAKE_RC=0 measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
}

@test "exit 1 that names no Changed file is status error, never a pass" {
    printf 'Formatted 3 files (1 changed) in 0.03 seconds.\n' > "$FAKE_OUT"
    measure
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'exited 1 and named no changed file'* ]]
}

@test "exit 2 or 65 is status error with metric null, even with Changed lines" {
    local rc
    for rc in 2 65; do
        FAKE_RC="$rc" measure
        [ "$(result .status)" = error ] && [ "$(result .metric)" = null ] || { echo "exit $rc"; return 1; }
        [[ "$(result .error)" == *"exited $rc"* ]]
    done
}

@test "argv is format --output=none --set-exit-if-changed, the extra argv, -- and the changed Dart files" {
    measure 'files=changed -- --line-length=120'
    [ "$(tr '\n' ' ' < "$ARGV")" = 'format --output=none --set-exit-if-changed --line-length=120 -- lib/a.dart lib/b.dart lib/c.dart ' ]
    [ "$(calls_of '^dart pub get --offline --enforce-lockfile$')" = 1 ]
}

@test "no changed Dart file measures 0 and runs nothing, not even pub get" {
    : > "$TREE/README.md"
    files_list README.md lib/deleted.dart
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    [ "$(calls_of .)" = 0 ]
}

@test "a changed file deleted from the tree is not passed to dart format" {
    files_list lib/a.dart lib/deleted.dart
    measure
    [ "$(files_after_dashdash)" = lib/a.dart ]
}

@test "the migration's exclude= drops .g.dart, generated and lint-fixture files, so they alone read 0" {
    mkdir -p "$TREE/lib/generated/l10n" "$TREE/tool/givore_lints/test/fixtures"
    : > "$TREE/lib/m.g.dart"; : > "$TREE/lib/m.freezed.dart"; : > "$TREE/lib/m.mocks.dart"; : > "$TREE/lib/m.config.dart"
    : > "$TREE/lib/generated/l10n/intl.dart"; : > "$TREE/tool/givore_lints/test/fixtures/bad.dart"
    files_list lib/m.g.dart lib/m.freezed.dart lib/m.mocks.dart lib/m.config.dart lib/generated/l10n/intl.dart \
        tool/givore_lints/test/fixtures/bad.dart
    measure "files=changed $MIGRATION_EXCLUDE"
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    [ "$(calls_of .)" = 0 ]
    files_list lib/m.g.dart lib/a.dart tool/givore_lints/test/fixtures/bad.dart
    measure "files=changed $MIGRATION_EXCLUDE"
    [ "$(files_after_dashdash)" = lib/a.dart ]
}

@test "a \\|-escaped exclude= matches a literal pipe, so it excludes nothing" {
    : > "$TREE/lib/m.g.dart"
    files_list lib/a.dart lib/m.g.dart
    measure 'files=changed exclude=\.(g\|freezed)\.dart$'
    [ "$(files_after_dashdash | tr '\n' ' ')" = 'lib/a.dart lib/m.g.dart ' ]
    measure 'files=changed exclude=\.(g|freezed)\.dart$'
    [ "$(files_after_dashdash)" = lib/a.dart ]
}

@test "names with a space, a leading - and non-ASCII reach the argv whole, after --" {
    mkdir -p "$TREE/lib/my dir"
    : > "$TREE/lib/my dir/a b.dart"; : > "$TREE/-x.dart"; : > "$TREE/lib/zażółć.dart"
    files_list 'lib/my dir/a b.dart' -x.dart lib/zażółć.dart
    printf 'Changed lib/my dir/a b.dart\n' > "$FAKE_OUT"
    measure
    [ "$(files_after_dashdash)" = $'lib/my dir/a b.dart\n-x.dart\nlib/zażółć.dart' ]
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings[0].file')" = 'lib/my dir/a b.dart' ]
}

@test "one changed file reaches the argv as one name" {
    files_list lib/b.dart
    printf 'Formatted 1 file (0 changed) in 0.01 seconds.\n' > "$FAKE_OUT"
    FAKE_RC=0 measure
    [ "$(files_after_dashdash)" = lib/b.dart ]
    [ "$(result .metric)" = 0 ]
}

@test "500 changed files all reach one dart format call, and 500 Changed lines measure 500" {
    local i names=()
    mkdir -p "$TREE/lib/many"
    for i in $(seq 1 500); do : > "$TREE/lib/many/f$i.dart"; names+=("lib/many/f$i.dart"); done
    files_list "${names[@]}"
    printf 'Changed %s\n' "${names[@]}" > "$FAKE_OUT"
    measure
    [ "$(files_after_dashdash | wc -l)" = 500 ]
    [ "$(calls_of '^dart format')" = 1 ]
    [ "$(result .metric)" = 500 ]
    [ "$(result '.findings | length')" = 500 ]
}
