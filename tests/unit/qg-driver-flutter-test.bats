#!/usr/bin/env bats
# drivers/flutter-test.sh — metric=failed counts failing tests of a `flutter test --machine` stream;
# metric=coverage is kept LH over kept LF of the lcov file the run writes. Both rows of a run share
# one suite run.
#
# The test image has no Flutter: a fake SDK under $WORK/sdk is named by guard_flutter_root in the
# committed quality/config and its bin/ is first on PATH. The suite runs through qg_isolated with an
# emptied environment, so the fake flutter reads its setup from files under $WORK baked into it:
# stream (a real recorded stream from tests/fixtures/drivers/dart/, /TREE replaced by its cwd), lcov
# (copied to the --coverage-path it receives), rc (its exit code) and extra.sh (sourced last). It
# appends its argv to flutter.argv and dumps its env to flutter.env. The fake dart records its argv.

load guard-helpers

DRIVER=/code/drivers/flutter-test.sh
FIX=/code/tests/fixtures/drivers/dart
FILTER_INC='^lib/'
FILTER_EXC='\.(g|freezed|mocks|config|gr)\.dart$|^lib/generated/'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR QG_BASES CLAUDECODE AI_AGENT PUB_CACHE XDG_CACHE_HOME FLUTTER_ROOT
    fake_sdk "$WORK/sdk"
    export PATH="$WORK/sdk/bin:$PATH"
    new_repo "$WORK/repo"
    mkdir -p quality lib test
    printf 'guard_flutter_root: %s\n' "$WORK/sdk" > quality/config
    printf 'name: app\n' > pubspec.yaml
    printf 'void main() {}\n' > test/a_test.dart
    commit_all init
    mkdir -p "$WORK/out"
    export QG_REPO="$WORK/repo" QG_TREE="$WORK/repo" QG_TARGET=:index QG_CONFIG_REV="$(git rev-parse HEAD)"
    export QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=flutter-row QG_FILES=/dev/null
    use_stream flutter-test-pass.jsonl
    cp "$FIX/lcov.info" "$WORK/lcov"
    printf '0\n' > "$WORK/rc"
    # Cases run unsandboxed so the fakes can record; the sandbox case below runs it.
    export QG_SANDBOX=0
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# The driver runs flutter through the shim of qg_dart_env, which calls
# `dart --disable-dart-dev --packages=<cfg> <snapshot> <argv>`; the fake dart hands those calls to the
# fake flutter tool. Records written under the sandbox fail quietly; the stream and lcov still flow.
fake_sdk() {
    mkdir -p "$1/bin/cache/dart-sdk/bin"
    { printf '#!/usr/bin/env bash\nW=%q\n' "$WORK"; cat <<'EOF'
printf '%s\n' "$*" >> "$W/flutter.argv" 2>/dev/null
env > "$W/flutter.env" 2>/dev/null
pwd > "$W/flutter.pwd" 2>/dev/null
cov=''
while [ $# -gt 0 ]; do [ "$1" = --coverage-path ] && cov="$2"; shift; done
printf '%s\n' "$cov" > "$W/flutter.cov" 2>/dev/null
[ -n "$cov" ] && [ -r "$W/lcov" ] && cp "$W/lcov" "$cov"
[ -r "$W/stream" ] && sed "s#/TREE#${PWD}#g" "$W/stream"
[ -r "$W/extra.sh" ] && . "$W/extra.sh"
exit "$(cat "$W/rc" 2>/dev/null || printf 0)"
EOF
    } > "$1/flutter-tool"
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$1/flutter-tool" > "$1/bin/flutter"
    { printf '#!/usr/bin/env bash\nW=%q\nT=%q\n' "$WORK" "$1/flutter-tool"; cat <<'EOF'
if [ "${1:-}" = --disable-dart-dev ]; then shift 3; exec "$T" "$@"; fi
printf '%s|%s\n' "$PWD" "$*" >> "$W/dart.argv"
exit "$(cat "$W/dart.rc" 2>/dev/null || printf 0)"
EOF
    } > "$1/bin/cache/dart-sdk/bin/dart"
    chmod +x "$1/flutter-tool" "$1/bin/flutter" "$1/bin/cache/dart-sdk/bin/dart"
}

use_stream() { cp "$FIX/$1" "$WORK/stream"; }
result() { jq -r "$1" "${2:-$QG_OUT}/result.json"; }
measure() { QG_ARGS="$1" "$DRIVER" run > /dev/null 2>&1; }
calls() { [ -e "$WORK/flutter.argv" ] && wc -l < "$WORK/flutter.argv" | tr -d ' ' || printf 0; }

lcov_block() {  # lcov_block <SF path> <LH> <LF>
    printf 'SF:%s\nDA:1,1\nLF:%s\nLH:%s\nend_of_record\n' "$1" "$3" "$2"
}

@test "describe is JSON naming flutter-test with needs_tree true; explain names the keys and the rule" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = flutter-test ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [[ "$output" == *'metric (required: failed, coverage)'* ]]
    run "$DRIVER" explain flutter-test.failure
    [[ "$output" == *'flutter test <file>'* ]]
}

@test "a missing or unknown metric is status error and flutter is never called" {
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'metric='* ]]
    measure metric=passed
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'metric=passed'* ]]
    [ "$(calls)" = 0 ]
}

@test "the recorded passing stream at exit 0 measures 0 failed tests with no finding" {
    measure metric=failed
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    [ "$(result .unit)" = tests ]
    [ "$(result '.findings | length')" = 0 ]
}

@test "flutter gets test --no-pub --coverage --machine --coverage-path <private dir>/lcov.info, in the tree, after an offline pub get" {
    measure metric=failed
    local cov
    cov="$(cat "$WORK/flutter.cov")"
    [ "$(cat "$WORK/flutter.argv")" = "test --no-pub --coverage --machine --coverage-path $cov" ]
    [ "$cov" = "$(sed -n 's/^QG_PRIVATE=//p' "$WORK/flutter.env")/lcov.info" ]
    [[ "$cov" != "$QG_TREE"* ]]
    [ ! -e "$(dirname "$cov")" ]
    [ "$(cat "$WORK/flutter.pwd")" = "$QG_TREE" ]
    [ "$(cat "$WORK/dart.argv")" = "$QG_TREE|pub get --offline --enforce-lockfile" ]
}

@test "concurrency=4 adds --concurrency=4 after --machine" {
    measure 'metric=failed concurrency=4'
    [[ "$(cat "$WORK/flutter.argv")" == *' --machine --concurrency=4 '* ]]
}

@test "the suite runs sandboxed: it measures, and writes only .dart_tool, build and its private folder" {
    unset QG_SANDBOX
    export QG_SANDBOX_WRITES="$("$DRIVER" describe | jq -r '.writes | join(" ")')"
    printf '%s\n' 'echo x > build/ok; echo x > "$W/escaped" 2>/dev/null; echo x > lib/mutated.dart 2>/dev/null' > "$WORK/extra.sh"
    use_stream flutter-test-fail.jsonl; printf '1\n' > "$WORK/rc"
    measure metric=failed
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 1 ]
    measure metric=coverage
    [ "$(result .status)" = measured ]
    [ -e "$QG_TREE/build/ok" ]
    [ ! -e "$WORK/escaped" ] && [ ! -e "$QG_TREE/lib/mutated.dart" ] && [ ! -e "$WORK/flutter.argv" ]
}

@test "the recorded failing stream at exit 1 measures 1, with the failing test's file, line and name" {
    use_stream flutter-test-fail.jsonl; printf '1\n' > "$WORK/rc"
    measure metric=failed
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings | length')" = 1 ]
    [ "$(result '.findings[0].ruleId')" = flutter-test.failure ]
    [ "$(result '.findings[0].file')" = test/qg_seed_fail_test.dart ]
    [ "$(result '.findings[0].line')" = 2 ]
    [ "$(result '.findings[0].message')" = 'failed: qg seeded failure' ]
}

@test "the recorded load-error stream at exit 1 measures 1 failed test, never 0" {
    use_stream flutter-test-load-error.jsonl; printf '1\n' > "$WORK/rc"
    measure metric=failed
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 1 ]
    [[ "$(result '.findings[0].message')" == 'failed: loading '* ]]
}

@test "an error event on a test whose testDone never arrives still counts as a failure" {
    grep -v '"testID":3,"result"' "$FIX/flutter-test-fail.jsonl" > "$WORK/stream"
    printf '1\n' > "$WORK/rc"
    measure metric=failed
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 1 ]
}

@test "a stream cut before the done event is status error with metric null" {
    grep -v '"type":"done"' "$FIX/flutter-test-pass.jsonl" > "$WORK/stream"
    measure metric=failed
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'without a done event'* ]]
}

@test "a stream whose only tests are hidden or skipped is status error: no test ran" {
    grep -v '"hidden":false' "$FIX/flutter-test-pass.jsonl" > "$WORK/stream"
    grep -q '"type":"done"' "$WORK/stream"
    measure metric=failed
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'no test ran'* ]]
    sed 's/"skipped":false,"hidden":false/"skipped":true,"hidden":false/' "$FIX/flutter-test-pass.jsonl" > "$WORK/stream"
    measure metric=failed
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
}

@test "exit 1 with no failing test in the stream is status error" {
    printf '1\n' > "$WORK/rc"
    measure metric=failed
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'exited 1 and reported no failing test'* ]]
}

@test "exits 2 and 255 are status error even with a failing stream" {
    use_stream flutter-test-fail.jsonl
    local rc
    for rc in 2 255; do
        printf '%s\n' "$rc" > "$WORK/rc"
        rm -f "$QG_OUT/result.json"
        measure metric=failed
        [ "$(result .status)" = error ] || { echo "exit $rc measured"; return 1; }
        [[ "$(result .error)" == *"exited ${rc}"* ]]
    done
}

@test "text lines, blank lines and event arrays around the events are ignored" {
    { printf 'Resolving dependencies...\n\n[{"event":"x"}]\n  {"indented":1}\n'; cat "$FIX/flutter-test-fail.jsonl"; } > "$WORK/stream"
    printf '1\n' > "$WORK/rc"
    measure metric=failed
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 1 ]
}

@test "a truncated event line is status error, never a measured 0" {
    { cat "$FIX/flutter-test-pass.jsonl"; printf '{"testID":7,"result":"fail\n'; } > "$WORK/stream"
    measure metric=failed
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'no readable event'* ]]
}

@test "metric=coverage on the recorded lcov.info is 50/909 unfiltered and 50/335 = 14.93 with the generated-file filter" {
    measure metric=coverage
    [ "$(result .status)" = measured ]
    [ "$(result .unit)" = percent ]
    [ "$(result .metric)" = 5.50 ]
    measure "metric=coverage include=${FILTER_INC} exclude=${FILTER_EXC}"
    [ "$(result .metric)" = 14.93 ]
}

@test "coverage boundaries: 0/N 0.00, N/N 100.00, 2/3 66.67, 1/8 12.50" {
    local c
    for c in '0 7 0.00' '7 7 100.00' '2 3 66.67' '1 8 12.50'; do
        set -- $c
        lcov_block lib/a.dart "$1" "$2" > "$WORK/lcov"
        rm -f "$QG_OUT/result.json"
        measure metric=coverage
        [ "$(result .status)" = measured ] || { echo "not measured for $c"; return 1; }
        [ "$(jq -c .metric "$QG_OUT/result.json")" = "$3" ] || { echo "$c gave $(jq -c .metric "$QG_OUT/result.json")"; return 1; }
    done
}

@test "include= and exclude= match SF paths after the tree prefix and a leading ./ are stripped" {
    { lcov_block "$QG_TREE/lib/a.dart" 1 4; lcov_block ./lib/b.dart 3 4; lcov_block lib/c.g.dart 0 100
      lcov_block lib/generated/d.dart 0 100; lcov_block test/helper.dart 0 100; } > "$WORK/lcov"
    measure "metric=coverage include=${FILTER_INC} exclude=${FILTER_EXC}"
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 50.00 ]
}

@test "coverage with no line left after the filter is status error" {
    lcov_block lib/a.g.dart 3 4 > "$WORK/lcov"
    measure "metric=coverage exclude=${FILTER_EXC}"
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'no coverage line is left'* ]]
}

@test "a run that writes no lcov.info is status error for coverage and still measures failed" {
    rm -f "$WORK/lcov"
    measure metric=coverage
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'wrote no lcov.info'* ]]
    measure metric=failed
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
}

@test "two rows of one run, metric=failed then metric=coverage, call flutter once and both measure" {
    export QG_RUN_DIR="$WORK/run"; mkdir -p "$QG_RUN_DIR" "$WORK/out2"
    use_stream flutter-test-fail.jsonl; printf '1\n' > "$WORK/rc"
    measure metric=failed
    QG_OUT="$WORK/out2" measure metric=coverage
    [ "$(calls)" = 1 ]
    [ "$(result .metric)" = 1 ]
    [ "$(result .metric "$WORK/out2")" = 5.50 ]
}

@test "the shared run is keyed by target: a second ref runs the suite again and gives 0 then 1" {
    export QG_RUN_DIR="$WORK/run"; mkdir -p "$QG_RUN_DIR"
    measure metric=failed
    [ "$(result .metric)" = 0 ]
    use_stream flutter-test-fail.jsonl; printf '1\n' > "$WORK/rc"
    QG_TARGET="$(git rev-parse HEAD)" measure metric=failed
    [ "$(calls)" = 2 ]
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 1 ]
}

@test "the suite sees no GUARD_* or other QG_* variable, no caller PUB_CACHE, and a TMPDIR outside the tree that is removed" {
    export GUARD_PROBE=1 QG_PROBE=1 QG_SANDBOX_WRITES=lib PUB_CACHE="$WORK/pub" XDG_CACHE_HOME="$WORK/xdg"
    measure metric=failed
    [ "$(result .status)" = measured ]
    [ -s "$WORK/flutter.env" ]
    [ -z "$(grep -E '^(QG_PROBE|QG_SANDBOX|GUARD_|XDG_CACHE_HOME=)' "$WORK/flutter.env")" ]
    grep -qx "PUB_CACHE=$HOME/.pub-cache" "$WORK/flutter.env"
    grep -qx "FLUTTER_ROOT=$WORK/sdk" "$WORK/flutter.env"
    local tmp
    tmp="$(sed -n 's/^TMPDIR=//p' "$WORK/flutter.env")"
    [ -n "$tmp" ]
    [[ "$tmp" != "$QG_TREE"* ]]
    [ ! -e "$tmp" ]
}

@test "a background process the suite leaves in its process group is killed before the driver returns" {
    printf '%s\n' 'sleep 300 > /dev/null 2>&1 < /dev/null & printf "%s\n" "$!" > "$W/sleep.pid"' > "$WORK/extra.sh"
    measure metric=failed
    [ "$(result .status)" = measured ]
    local pid state
    pid="$(cat "$WORK/sleep.pid")"
    [ -n "$pid" ]
    state="$(awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || true)"
    [ -z "$state" ] || [ "$state" = Z ] || { echo "sleep $pid still running, state $state"; kill "$pid"; return 1; }
}

@test "a failing offline pub get is status error and flutter is never called" {
    printf '1\n' > "$WORK/dart.rc"
    measure metric=failed
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'dart pub get --offline'* ]]
    [ "$(calls)" = 0 ]
}
