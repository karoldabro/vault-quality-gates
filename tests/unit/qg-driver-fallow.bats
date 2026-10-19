#!/usr/bin/env bats
# drivers/fallow.sh — metric=dupes reads stats.duplicated_lines, metric=boundaries counts
# boundary_violations, metric=complexity-excess sums how far each finding exceeds max-cyclomatic= and
# max-cognitive=. These are app scripts/fallow-parsers.mjs.
#
# A fake fallow records its argv, prints $FAKE_OUT on stdout and exits $FAKE_RC.
# Fixtures, fallow 3.28.0's stdout on app.givore.com HEAD; each v1 number is
# `node v1.mjs <dupes|boundaries|complexity> <file>`, where v1.mjs imports fallow-parsers.mjs and
# runs it with its default limits 15 and 20 (the test image has no node). The same command on the
# uncut output reads the same number.
#   fallow-dupes.json       clone_groups cut to two, stats unchanged     v1 11160
#   fallow-boundaries.json  unchanged                                    v1 0
#   fallow-health.json      every finding without its actions            v1 665

load guard-helpers

DRIVER=/code/drivers/fallow.sh
FIX=/code/tests/fixtures/drivers
LIMITS='max-cyclomatic=15 max-cognitive=20'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR QG_REPO QG_BASES QG_TARGET CLAUDECODE AI_AGENT
    TREE="$WORK/tree"; mkdir -p "$TREE/node_modules/.bin" "$WORK/out"
    fake_bin "$TREE/node_modules/.bin/fallow"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=fallow-row QG_FILES=/dev/null
    export FAKE_OUT="$WORK/fake.out" FAKE_RC=0 FAKE_ARGV="$WORK/argv"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {  # a fallow that records its argv, prints $FAKE_OUT and exits $FAKE_RC
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${FAKE_ARGV:-/dev/null}"' \
        '[ -r "${FAKE_OUT:-}" ] && cat "$FAKE_OUT"' 'exit "${FAKE_RC:-0}"' > "$1"
    chmod +x "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }

health() {  # health <cyclomatic> <cognitive> ... -> a health report with one finding per pair
    local out='[]' i=0
    while [ "$#" -ge 2 ]; do
        out="$(jq -c --argjson c "$1" --argjson g "$2" --argjson i "$i" \
            '. + [{path: "f\($i).ts", name: "fn\($i)", line: ($i + 1), cyclomatic: $c, cognitive: $g}]' <<<"$out")"
        shift 2; i=$((i + 1))
    done
    jq -c '{kind: "health", findings: .}' <<<"$out" > "$FAKE_OUT"
}

expect_error() {  # expect_error <text in .error>
    [ "$(result .status)" = error ] || { echo "status $(result .status)"; return 1; }
    [ "$(result .metric)" = null ] || { echo "metric $(result .metric)"; return 1; }
    [[ "$(result .error)" == *"$1"* ]] || { echo "error $(result .error)"; return 1; }
}

@test "describe is JSON naming fallow with needs_tree true; explain prints text per rule" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = fallow ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
    run "$DRIVER" explain fallow.complexity
    [[ "$output" == *'limit'* ]]
}

@test "a missing or unknown metric= is status error and runs nothing" {
    cp "$FIX/fallow-dupes.json" "$FAKE_OUT"
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    expect_error 'metric='
    QG_ARGS='metric=clones' "$DRIVER" run > /dev/null
    expect_error 'not one of'
    [ ! -e "$FAKE_ARGV" ]
}

@test "metric=dupes on the recorded app report equals fallow-parsers.mjs: 11160" {
    cp "$FIX/fallow-dupes.json" "$FAKE_OUT"
    QG_ARGS='metric=dupes' "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 11160 ]
    [ "$(result .unit)" = lines ]
    [ "$(cat "$FAKE_ARGV")" = 'dupes --config .fallowrc.json --no-cache --format json' ]
    [ "$(result '.findings[0].ruleId')" = fallow.dupes ]
    [ "$(result '.findings | length')" = "$(jq '[.clone_groups[].instances[]] | length' "$FIX/fallow-dupes.json")" ]
}

@test "metric=boundaries on the recorded app report equals fallow-parsers.mjs: 0" {
    cp "$FIX/fallow-boundaries.json" "$FAKE_OUT"
    QG_ARGS='metric=boundaries' "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    [ "$(cat "$FAKE_ARGV")" = 'dead-code --boundary-violations --config .fallowrc.json --no-cache --format json' ]
}

@test "metric=boundaries counts every boundary violation, each a finding at its import" {
    jq -c '.boundary_violations = [
        {from_path: "utils/a.ts", to_path: "api/b.ts", from_zone: "utils", to_zone: "api", import_specifier: "~/api/b", line: 3, col: 0, actions: []},
        {from_path: "api/c.ts", to_path: "components/D.vue", from_zone: "api", to_zone: "ui", import_specifier: "~/components/D.vue", line: 7, col: 0, actions: []}]' \
        "$FIX/fallow-boundaries.json" > "$FAKE_OUT"
    QG_ARGS='metric=boundaries' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 2 ]
    [ "$(result '[.findings[] | "\(.ruleId) \(.file):\(.line)"] | join("|")')" = 'fallow.boundaries api/c.ts:7|fallow.boundaries utils/a.ts:3' ]
}

@test "metric=complexity-excess on the recorded app report equals fallow-parsers.mjs: 665" {
    cp "$FIX/fallow-health.json" "$FAKE_OUT"
    FAKE_RC=1 QG_ARGS="metric=complexity-excess $LIMITS" "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 665 ]
    [ "$(result .unit)" = points ]
    [ "$(cat "$FAKE_ARGV")" = 'health --max-cyclomatic 15 --max-cognitive 20 --config .fallowrc.json --no-cache --format json' ]
}

@test "complexity at 15/20 adds 0, 16/20 and 15/21 add 1, 16/21 adds 2; a missing value counts 0" {
    local pair
    for pair in '15 20 0' '16 20 1' '15 21 1' '16 21 2' '3 4 0' '30 10 15'; do
        set -- $pair
        health "$1" "$2"
        rm -f "$QG_OUT/result.json"
        FAKE_RC=1 QG_ARGS="metric=complexity-excess $LIMITS" "$DRIVER" run > /dev/null
        [ "$(result .metric)" = "$3" ] || { echo "$1/$2 read $(result .metric), want $3"; return 1; }
        [ "$(result '.findings | length')" = "$([ "$3" = 0 ] && echo 0 || echo 1)" ] || { echo "$1/$2 findings"; return 1; }
    done
    printf '%s\n' '{"findings":[{"path":"a.ts","name":"f","line":1,"cognitive":25},{"path":"b.ts","name":"g","line":2,"cyclomatic":null,"cognitive":null}]}' > "$FAKE_OUT"
    FAKE_RC=1 QG_ARGS="metric=complexity-excess $LIMITS" "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 5 ]
}

@test "complexity-excess without max-cyclomatic= or max-cognitive=, or with a non-number, is status error" {
    health 30 30
    QG_ARGS='metric=complexity-excess max-cognitive=20' "$DRIVER" run > /dev/null
    expect_error 'max-cyclomatic='
    QG_ARGS='metric=complexity-excess max-cyclomatic=15' "$DRIVER" run > /dev/null
    expect_error 'max-cognitive='
    QG_ARGS='metric=complexity-excess max-cyclomatic=1e3 max-cognitive=20' "$DRIVER" run > /dev/null
    expect_error 'whole numbers'
    [ ! -e "$FAKE_ARGV" ]
}

@test "a report without the key its metric reads is status error, never 0" {
    printf '%s\n' '{"kind":"dupes","stats":{"total_lines":10}}' > "$FAKE_OUT"
    QG_ARGS='metric=dupes' "$DRIVER" run > /dev/null
    expect_error 'stats.duplicated_lines'
    printf '%s\n' '{"kind":"dead-code","total_issues":0}' > "$FAKE_OUT"
    QG_ARGS='metric=boundaries' "$DRIVER" run > /dev/null
    expect_error 'boundary_violations'
    printf '%s\n' '{"kind":"health","summary":{}}' > "$FAKE_OUT"
    QG_ARGS="metric=complexity-excess $LIMITS" "$DRIVER" run > /dev/null
    expect_error 'findings'
    printf '%s\n' '{"kind":"health","findings":[{"path":"a.ts","cyclomatic":"many"}]}' > "$FAKE_OUT"
    QG_ARGS="metric=complexity-excess $LIMITS" "$DRIVER" run > /dev/null
    expect_error 'not a count'
}

@test "exit 1 with JSON is measured; exit 2 with JSON, and exit 0 or 1 without JSON, are status error" {
    cp "$FIX/fallow-dupes.json" "$FAKE_OUT"
    FAKE_RC=1 QG_ARGS='metric=dupes' "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 11160 ]
    FAKE_RC=2 QG_ARGS='metric=dupes' "$DRIVER" run > /dev/null
    expect_error 'exited 2'
    printf 'thread main panicked\n' > "$FAKE_OUT"
    FAKE_RC=0 QG_ARGS='metric=dupes' "$DRIVER" run > /dev/null
    expect_error 'no JSON report'
    : > "$FAKE_OUT"
    FAKE_RC=1 QG_ARGS='metric=boundaries' "$DRIVER" run > /dev/null
    expect_error 'no JSON report'
}

@test "config=, bin= and -- argv reach fallow" {
    cp "$FIX/fallow-boundaries.json" "$FAKE_OUT"
    mkdir -p "$TREE/tools"; fake_bin "$TREE/tools/fallow"
    QG_ARGS='metric=boundaries bin=tools/fallow config=quality/fallow.json -- --production' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = 'dead-code --boundary-violations --config quality/fallow.json --no-cache --format json --production' ]
}

@test "two runs write the same bytes, and permuted findings give the same metric and findings" {
    cp "$FIX/fallow-health.json" "$FAKE_OUT"
    QG_ARGS="metric=complexity-excess $LIMITS" "$DRIVER" run > /dev/null
    cp "$QG_OUT/result.json" "$WORK/first.json"
    QG_ARGS="metric=complexity-excess $LIMITS" "$DRIVER" run > /dev/null
    cmp "$WORK/first.json" "$QG_OUT/result.json"
    jq -c '.findings |= reverse' "$FIX/fallow-health.json" > "$FAKE_OUT"
    QG_ARGS="metric=complexity-excess $LIMITS" "$DRIVER" run > /dev/null
    cmp "$WORK/first.json" "$QG_OUT/result.json"
}
