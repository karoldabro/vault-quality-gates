#!/usr/bin/env bats
# drivers/pint.sh — Laravel Pint in test mode: metric = files Pint would change.
#
# A fake `vendor/bin/pint` prints $FAKE_OUT (a real recorded Pint output from
# tests/fixtures/drivers/) and exits $FAKE_RC. Pint exits 1 both on a finding and on a crash, so
# only the JSON report may decide the value.

load guard-helpers
load qg-fakes

DRIVER=/code/drivers/pint.sh
FIX=/code/tests/fixtures/drivers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    fakes_setup
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT
    TREE="$WORK/tree"; mkdir -p "$TREE/vendor/bin" "$WORK/out"
    fake_bin "$TREE/vendor/bin/pint"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=pint-row QG_FILES=/dev/null
    export FAKE_OUT="$WORK/fake.out" FAKE_RC=1 FAKE_ARGV="$WORK/argv"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {  # a pint that records its argv, prints $FAKE_OUT and exits $FAKE_RC
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${FAKE_ARGV:-/dev/null}"' \
        '[ -r "${FAKE_OUT:-}" ] && cat "$FAKE_OUT"' 'exit "${FAKE_RC:-0}"' > "$1"
    chmod +x "$1"
    fake_bake "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }

@test "describe is JSON naming pint with needs_tree true" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = pint ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
}

@test "explain prints text, with and without a rule id" {
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
    run "$DRIVER" explain pint
    [ "$status" -eq 0 ] && [ -n "$output" ]
}

@test "pint-bad.json at exit 1 is measured with metric 1, the failing file count" {
    cp "$FIX/pint-bad.json" "$FAKE_OUT"
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 1 ]
    [ "$(result .unit)" = files ]
}

@test "pint-good.json, which this config also flags, is measured 1, not 0" {
    cp "$FIX/pint-good.json" "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 1 ]
}

@test "a two-file report is metric 2" {
    jq -c --slurpfile g "$FIX/pint-good.json" '.files += $g[0].files' "$FIX/pint-bad.json" > "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 2 ]
    [ "$(result '.findings | length')" = 2 ]
}

@test "an exit-0 report with no files is measured 0" {
    printf '%s\n' '{"files":[],"time":{"total":0},"memory":0}' > "$FAKE_OUT"
    FAKE_RC=0 "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
}

@test "each finding names its fixers and carries no diff" {
    cp "$FIX/pint-bad.json" "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result '.findings[0].ruleId')" = pint ]
    [ "$(result '.findings[0].file')" = /tmp/qg/Bad.php ]
    [[ "$(result '.findings[0].message')" == *'class_definition'*'blank_line_before_statement'* ]]
    ! grep -q -e '+++' -e '"diff"' "$QG_OUT/result.json"
}

@test "exit 1 with no JSON (pint-crash.txt) is status error with metric null" {
    cp "$FIX/pint-crash.txt" "$FAKE_OUT"
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'no JSON report'* ]]
}

@test "exit 2, even with a JSON report, is status error" {
    cp "$FIX/pint-bad.json" "$FAKE_OUT"
    FAKE_RC=2 "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'exited 2'* ]]
}

@test "argv is --test -v --format=json, then the changed .php files under files=changed" {
    printf 'docs/a.md\0app/B.php\0app/Gone.php\0' > "$WORK/files"
    mkdir -p "$TREE/app"; : > "$TREE/app/B.php"
    cp "$FIX/pint-bad.json" "$FAKE_OUT"
    QG_FILES="$WORK/files" QG_ARGS='files=changed' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = '--test -v --format=json app/B.php' ]
}

@test "files=changed with no matching .php measures 0 and never calls pint" {
    printf 'docs/a.md\0app/Gone.php\0' > "$WORK/files"
    cp "$FIX/pint-bad.json" "$FAKE_OUT"
    QG_FILES="$WORK/files" QG_ARGS='files=changed' "$DRIVER" run > /dev/null
    [ ! -e "$FAKE_ARGV" ]
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
}
