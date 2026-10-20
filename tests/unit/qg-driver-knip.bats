#!/usr/bin/env bats
# drivers/knip.sh — metric = entries in every issue array of every file but `file`, read from the
# first stdout line starting with `{`.
#
# A fake knip records its argv, prints $FAKE_OUT on stdout and exits $FAKE_RC.
# tests/fixtures/drivers/knip.out is knip 6.16.1's stdout on app.givore.com HEAD, two Nuxt log lines
# before the report, unchanged. The v1 `deadcode` computation of app scripts/quality-metric.mjs reads
# 248 on it: `node v1.mjs deadcode tests/fixtures/drivers/knip.out`, where v1.mjs holds that
# function's body verbatim (the test image has no node).

load guard-helpers
load qg-fakes

DRIVER=/code/drivers/knip.sh
FIX=/code/tests/fixtures/drivers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    fakes_setup
    unset QG_RUNNER QG_ARGS QG_RUN_DIR QG_REPO QG_BASES QG_TARGET CLAUDECODE AI_AGENT
    TREE="$WORK/tree"; mkdir -p "$TREE/node_modules/.bin" "$WORK/out"
    fake_bin "$TREE/node_modules/.bin/knip"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=deadcode QG_FILES=/dev/null
    export FAKE_OUT="$WORK/fake.out" FAKE_RC=1 FAKE_ARGV="$WORK/argv"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {  # a knip that records its argv, prints $FAKE_OUT and exits $FAKE_RC
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${FAKE_ARGV:-/dev/null}"' \
        '[ -r "${FAKE_OUT:-}" ] && cat "$FAKE_OUT"' 'exit "${FAKE_RC:-0}"' > "$1"
    chmod +x "$1"
    fake_bake "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }

@test "describe is JSON naming knip with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = knip ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
    run "$DRIVER" explain knip.exports
    [[ "$output" == *'exports'* ]]
}

@test "the recorded app report, Nuxt logs first, at exit 1 equals v1 deadcode: 248" {
    cp "$FIX/knip.out" "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 248 ]
    [ "$(result '.findings | length')" = 248 ]
    [ "$(result .unit)" = issues ]
}

@test "findings carry knip.<type>, the file, the line and the entry name" {
    printf '%s\n' 'log line' \
        '{"issues":[{"file":"a.ts","exports":[{"name":"buildQuery","line":19,"col":10}],"enumMembers":[{"namespace":"Perm","name":"See","line":9}],"files":[]},{"file":"b.ts","files":[{"name":"b.ts"}],"duplicates":[[{"name":"x"},{"name":"y"}]]}]}' \
        > "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 4 ]
    [ "$(result '[.findings[] | "\(.ruleId) \(.file):\(.line) \(.message)"] | join("|")')" = \
        'knip.enumMembers a.ts:9 enumMembers: Perm.See|knip.exports a.ts:19 exports: buildQuery|knip.duplicates b.ts:null duplicates: x, y|knip.files b.ts:null files: b.ts' ]
}

@test "only arrays count: the file key and scalar values add nothing" {
    printf '%s\n' '{"issues":[{"file":"a.ts","files":[{"name":"a.ts"}],"exports":[{"name":"x","line":3}],"other":5,"note":"text"}]}' > "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 2 ]
}

@test "exit 0 with an empty issue list is measured 0" {
    printf '%s\n' '{"issues":[]}' > "$FAKE_OUT"
    FAKE_RC=0 "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
}

@test "the first line starting with { is the report; a later one is ignored" {
    printf '%s\n' 'ℹ Nuxt Icon server bundle mode is set to local' ' {"indented":"not a report"}' \
        '{"issues":[{"file":"a.ts","files":[{"name":"a.ts"}]}]}' \
        '{"issues":[{"file":"b.ts","files":[{"name":"b.ts"}]},{"file":"c.ts","files":[{"name":"c.ts"}]}]}' > "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 1 ]
}

@test "stdout with no line starting with { is status error with metric null" {
    printf '%s\n' 'ℹ Nuxt Icon server bundle mode is set to local' 'Error: something broke' > "$FAKE_OUT"
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'no JSON report'* ]]
}

@test "a { line that is not JSON, or has no issues list, is status error" {
    printf '%s\n' '{"issues":[' > "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    printf '%s\n' '{"level":"info","msg":"starting"}' > "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "exit 2 is status error even with a JSON report" {
    printf '%s\n' '{"issues":[]}' > "$FAKE_OUT"
    FAKE_RC=2 "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'exited 2'* ]]
}

@test "argv is --reporter json --config knip.json; config=, bin= and -- argv replace and extend it" {
    printf '%s\n' '{"issues":[]}' > "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = '--reporter json --config knip.json' ]
    rm -f "$FAKE_ARGV"
    mkdir -p "$TREE/tools"; fake_bin "$TREE/tools/knip"
    QG_ARGS='bin=tools/knip config=quality/knip.json -- --production' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = '--reporter json --config quality/knip.json --production' ]
}

@test "two runs write the same bytes, and permuted issues give the same metric and findings" {
    cp "$FIX/knip.out" "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    cp "$QG_OUT/result.json" "$WORK/first.json"
    "$DRIVER" run > /dev/null
    cmp "$WORK/first.json" "$QG_OUT/result.json"
    grep '^{' "$FIX/knip.out" | jq -c '.issues |= reverse' > "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    cmp "$WORK/first.json" "$QG_OUT/result.json"
}
