#!/usr/bin/env bats
# drivers/dart-code-linter.sh — functions (classes for number-of-methods) over a metric limit, or the
# issues of one rule, from quality-reports/dcl.json written this run. Rows that differ only in
# metric= share one tool run through QG_RUN_DIR.
#
# The fake dart copies $FAKE_WRITE's report into the tree (the tool's --json-path), prints it on
# stdout as the real tool does, and exits $FAKE_RC. tests/fixtures/drivers/dart/dcl.json is six
# records cut from the 31 MB report recorded on 884aad23.

load guard-helpers
load qg-dart-helpers

ROOT=/code
DRIVER="$ROOT/drivers/dart-code-linter.sh"
FIX=/code/tests/fixtures/drivers/dart
REPORT=quality-reports/dcl.json
IGNORE='ignore={/**.g.dart,/**.freezed.dart,/**.mocks.dart,/**.config.dart,/**/generated/**}'

setup() {
    dart_setup
    mkdir -p "$TREE/lib"
    use_report "$FIX/dcl.json"
    export FAKE_RC=1
}

teardown() { dart_teardown; }

use_report() { export FAKE_WRITE="$REPORT=$1" FAKE_OUT="$1"; }
measure() { rm -f "$QG_OUT/result.json"; QG_ARGS="$1" "$DRIVER" run > /dev/null; }
dcl_calls() { calls_of '^dart run dart_code_linter:metrics analyze'; }

# expected <metric=> -> the v1 select on the recorded report, written apart from the driver's filter.
expected() {
    case "$1" in
        issue:*) jq --arg r "${1#issue:}" '[.records[].issues[]? | select(.ruleId == $r)] | length' "$FIX/dcl.json" ;;
        number-of-methods\>*) jq --argjson n "${1#*>}" '[.records[] | .classes // {} | .[] | .metrics[]
            | select(.metricsId == "number-of-methods" and .value > $n)] | length' "$FIX/dcl.json" ;;
        *) jq --arg id "${1%%>*}" --argjson n "${1#*>}" '[.records[] | .functions // {} | .[] | .metrics[]
            | select(.metricsId == $id and .value > $n)] | length' "$FIX/dcl.json" ;;
    esac
}

# report_fn <file> <metricsId> <value>... -> a report with one function per value, all in lib/a.dart.
report_fn() {
    local out="$1" id="$2"; shift 2
    printf '%s\n' "$@" | jq -s --arg id "$id" '{formatVersion: 2, records: [{path: "lib/a.dart",
        functions: (to_entries | map({key: "f\(.key)", value: {codeSpan: {start: {line: (.key + 10)}},
            metrics: [{metricsId: $id, value: .value}]}}) | from_entries)}]}' > "$out"
}

@test "describe is JSON naming dart-code-linter with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = dart-code-linter ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ]
    [[ "$output" == *'metric'* ]]
}

@test "the six recycling_mobile_app rows on the recorded report equal the v1 selects: 1, 3, 0, 1, 1 and 2" {
    local m want got
    for m in 'cyclomatic-complexity>20:1' 'issue:avoid-banned-imports:3' 'maximum-nesting-level>5:0' \
        'number-of-parameters>4:1' 'source-lines-of-code>50:1' 'number-of-methods>10:2'; do
        want="${m##*:}"; m="${m%:*}"
        measure "metric=$m paths=lib $IGNORE"
        got="$(result .metric)"
        [ "$(result .status)" = measured ] || { echo "$m not measured: $(result .error)"; return 1; }
        [ "$got" = "$want" ] && [ "$got" = "$(expected "$m")" ] || { echo "$m: driver $got v1 $(expected "$m") want $want"; return 1; }
    done
}

@test "a function at the limit N is not over it: >N-1 counts 1, >N and >N+1 count 0" {
    report_fn "$WORK/r.json" cyclomatic-complexity 20
    use_report "$WORK/r.json"
    measure 'metric=cyclomatic-complexity>19'
    [ "$(result .metric)" = 1 ]
    measure 'metric=cyclomatic-complexity>20'
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    measure 'metric=cyclomatic-complexity>21'
    [ "$(result .metric)" = 0 ]
}

@test "number-of-methods reads .classes, never a function's metric of that name" {
    jq -n '{records: [{path: "lib/a.dart",
        functions: {f: {codeSpan: {start: {line: 3}}, metrics: [{metricsId: "number-of-methods", value: 99}, {metricsId: "cyclomatic-complexity", value: 2}]}},
        classes: {Big: {codeSpan: {start: {line: 20}}, metrics: [{metricsId: "number-of-methods", value: 11}, {metricsId: "cyclomatic-complexity", value: 99}]}}}]}' > "$WORK/r.json"
    use_report "$WORK/r.json"
    measure 'metric=number-of-methods>10'
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings[0].line')" = 20 ]
    [ "$(result '.findings[0].message')" = 'Big: number-of-methods 11 over 10' ]
    measure 'metric=cyclomatic-complexity>10'
    [ "$(result .metric)" = 0 ]
}

@test "findings of a metric row name the function, its file and its line" {
    measure 'metric=cyclomatic-complexity>20'
    [ "$(result '.findings[0].ruleId')" = cyclomatic-complexity ]
    [ "$(result '.findings[0].file')" = "$(jq -r '[.records[] | select(any(.functions // {} | .[] | .metrics[]; .metricsId == "cyclomatic-complexity" and .value > 20))][0].path' "$FIX/dcl.json")" ]
    [[ "$(result '.findings[0].message')" == *': cyclomatic-complexity 28 over 20' ]]
    [ "$(result '.findings[0].line')" != null ]
}

@test "issue:<rule> counts that rule's issues with their file, line and documentation" {
    measure metric=issue:avoid-banned-imports
    [ "$(result .metric)" = 3 ]
    [ "$(result '.findings[0].ruleId')" = avoid-banned-imports ]
    [ "$(result '.findings[0].file')" = "$(jq -r '[.records[] | select((.issues // []) | length > 0)][0].path' "$FIX/dcl.json")" ]
    [ "$(result '.findings[0].line')" = "$(jq -r '[.records[].issues[]?][0].codeSpan.start.line' "$FIX/dcl.json")" ]
    [ "$(result '.findings[0].doc')" = "$(jq -r '[.records[].issues[]?][0].documentation' "$FIX/dcl.json")" ]
    [ "$(result '.findings[0].message')" = "$(jq -r '[.records[].issues[]?][0].message' "$FIX/dcl.json")" ]
    measure metric=issue:no-such-rule
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
}

@test "a missing metric= is status error naming metric=, and nothing runs" {
    measure paths=lib
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'metric='* ]]
    [ "$(calls_of .)" = 0 ]
}

@test "a malformed metric= is status error, and nothing runs" {
    local m
    for m in cyclomatic-complexity '>20' 'cyclomatic-complexity>' 'cyclomatic-complexity>2x' \
        'cyclomatic-complexity>-1' 'cyclomatic-complexity>1234567890' issue:; do
        measure "metric=$m"
        [ "$(result .status)" = error ] && [ "$(result .metric)" = null ] || { echo "metric=$m: $(result .status)"; return 1; }
    done
    [ "$(calls_of .)" = 0 ]
}

@test "a planted report the tool did not write this run is status error, and the planted file is deleted" {
    mkdir -p "$TREE/quality-reports"
    cp "$FIX/dcl.json" "$TREE/$REPORT"
    unset FAKE_WRITE
    FAKE_RC=0 measure 'metric=cyclomatic-complexity>20'
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'wrote no report'* ]]
    [ ! -e "$TREE/$REPORT" ]
}

@test "exits 0 and 1 with a report are measured; exit 2 and 255 are status error" {
    local rc
    for rc in 0 1; do
        FAKE_RC="$rc" measure 'metric=cyclomatic-complexity>20'
        [ "$(result .status)" = measured ] || { echo "exit $rc"; return 1; }
    done
    for rc in 2 255; do
        FAKE_RC="$rc" measure 'metric=cyclomatic-complexity>20'
        [ "$(result .status)" = error ] && [ "$(result .metric)" = null ] || { echo "exit $rc"; return 1; }
        [[ "$(result .error)" == *"exited $rc"* ]]
    done
}

@test "a report without a records array is status error" {
    printf '{"formatVersion":2}\n' > "$WORK/r.json"
    use_report "$WORK/r.json"
    measure 'metric=cyclomatic-complexity>20'
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'no records array'* ]]
    printf 'not json\n' > "$WORK/r.json"
    measure 'metric=cyclomatic-complexity>20'
    [ "$(result .status)" = error ]
}

@test "argv is run dart_code_linter:metrics analyze <paths> --reporter=json --json-path=<report> --exclude=<ignore> --no-congratulate" {
    measure "metric=cyclomatic-complexity>20 paths=lib,test $IGNORE"
    [ "$(tr '\n' ' ' < "$ARGV")" = "run dart_code_linter:metrics analyze lib test --reporter=json --json-path=$REPORT --exclude=${IGNORE#ignore=} --no-congratulate " ]
    measure 'metric=cyclomatic-complexity>20'
    [ "$(tr '\n' ' ' < "$ARGV")" = "run dart_code_linter:metrics analyze lib --reporter=json --json-path=$REPORT --no-congratulate " ]
}

@test "the tool's stdout copy of the report is dropped, never kept in QG_OUT" {
    measure 'metric=cyclomatic-complexity>20'
    [ "$(result .status)" = measured ]
    [ ! -s "$QG_OUT/stdout" ]
}

@test "six rows differing only in metric= share one tool run and one pub get under QG_RUN_DIR" {
    export QG_RUN_DIR="$WORK/run"; mkdir -p "$QG_RUN_DIR"
    local m
    for m in 'cyclomatic-complexity>20' issue:avoid-banned-imports 'maximum-nesting-level>5' \
        'number-of-parameters>4' 'source-lines-of-code>50' 'number-of-methods>10'; do
        measure "metric=$m paths=lib $IGNORE"
        [ "$(result .metric)" = "$(expected "$m")" ] || { echo "$m: $(result .metric)"; return 1; }
    done
    [ "$(dcl_calls)" = 1 ]
    [ "$(calls_of '^dart pub get')" = 1 ]
}

@test "a row with other paths=, or another QG_TARGET, runs the tool again under the same QG_RUN_DIR" {
    export QG_RUN_DIR="$WORK/run"; mkdir -p "$QG_RUN_DIR" "$TREE/test"
    measure 'metric=cyclomatic-complexity>20 paths=lib'
    measure 'metric=number-of-methods>10 paths=lib'
    [ "$(dcl_calls)" = 1 ]
    measure 'metric=number-of-methods>10 paths=lib,test'
    [ "$(dcl_calls)" = 2 ]
    QG_TARGET=0123456789abcdef0123456789abcdef01234567 measure 'metric=cyclomatic-complexity>20 paths=lib'
    [ "$(dcl_calls)" = 3 ]
}

@test "without QG_RUN_DIR every row runs the tool" {
    measure 'metric=cyclomatic-complexity>20'
    measure 'metric=number-of-methods>10'
    [ "$(dcl_calls)" = 2 ]
}

@test "250 functions over the limit measure 250 and keep the first 200 findings" {
    # shellcheck disable=SC2046
    report_fn "$WORK/r.json" cyclomatic-complexity $(seq 21 270)
    use_report "$WORK/r.json"
    measure 'metric=cyclomatic-complexity>20'
    [ "$(result .metric)" = 250 ]
    [ "$(result '.findings | length')" = 200 ]
}

@test "a failed offline pub get is status error and the linter never runs" {
    export FAKE_PUB_RC=1 FAKE_PUB_OUT='dart_code_linter 1.1.6 is not in the cache'
    measure 'metric=cyclomatic-complexity>20'
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'run flutter pub get'* ]]
    [ "$(dcl_calls)" = 0 ]
}

@test "dart-code-linter measures through the real kit path under the sandbox" {
    unset QG_SANDBOX
    export QG_SANDBOX_WRITES="$("$DRIVER" describe | jq -r '.writes | join(" ")')"
    # The sandbox hides the test's variables, so this fake has its report and its escape target baked in.
    { printf '#!/usr/bin/env bash\nFIX=%q\nESC=%q\n' "$FIX/dcl.json" "$WORK/escaped"; cat <<'EOF2'
if [ "${1:-} ${2:-}" = 'pub get' ]; then exit 0; fi
for a in "$@"; do case "$a" in --json-path=*) cp "$FIX" "${a#--json-path=}" ;; esac; done
echo x > "$ESC" 2>/dev/null
cat "$FIX"
exit 1
EOF2
    } > "$SDK/bin/cache/dart-sdk/bin/dart"
    measure 'metric=cyclomatic-complexity>20'
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = "$(expected 'cyclomatic-complexity>20')" ]
    [ ! -e "$WORK/escaped" ]
}
