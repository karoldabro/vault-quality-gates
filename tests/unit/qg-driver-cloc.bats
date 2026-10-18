#!/usr/bin/env bats
# drivers/cloc.sh — metric=comment-ratio = SUM.comment / SUM.code to three places, compared with
# the v1 cloc parser; metric=code and metric=comment are the line counts.
#
# The test image has no cloc: a fake one, passed as bin=, records its argv, prints $FAKE_OUT (the
# real recorded tests/fixtures/drivers/cloc.json or an inline report) and exits $FAKE_RC.

load guard-helpers

DRIVER=/code/drivers/cloc.sh
FIX=/code/tests/fixtures/drivers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT
    TREE="$WORK/tree"; mkdir -p "$TREE" "$WORK/out"
    fake_bin "$WORK/cloc"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=cloc-row QG_FILES=/dev/null
    export FAKE_OUT="$WORK/fake.out" FAKE_RC=0 FAKE_ARGV="$WORK/argv"
    cp "$FIX/cloc.json" "$FAKE_OUT"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {  # a cloc that records its argv, prints $FAKE_OUT and exits $FAKE_RC
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${FAKE_ARGV:-/dev/null}"' \
        '[ -r "${FAKE_OUT:-}" ] && cat "$FAKE_OUT"' 'exit "${FAKE_RC:-0}"' > "$1"
    chmod +x "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }
measure() { QG_ARGS="bin=$WORK/cloc ${1:-}" "$DRIVER" run > /dev/null; }
parser_value() { /code/lib/guard-parsers/cloc.sh "$FAKE_OUT"; }

@test "describe is JSON naming cloc with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = cloc ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
}

@test "metric=comment-ratio on the real cloc.json equals the v1 cloc parser" {
    measure metric=comment-ratio
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = "$(parser_value)" ]
    [ "$(result .metric)" = 0.274 ]
    [ "$(result .unit)" = ratio ]
}

@test "the default metric is comment-ratio" {
    measure
    [ "$(result .metric)" = "$(parser_value)" ]
}

@test "argv is --json --quiet --timeout 0, the extra argv, then paths= (default .)" {
    measure
    [ "$(cat "$FAKE_ARGV")" = '--json --quiet --timeout 0 .' ]
    rm -f "$FAKE_ARGV"
    measure 'paths=app,src -- --exclude-dir=vendor'
    [ "$(cat "$FAKE_ARGV")" = '--json --quiet --timeout 0 --exclude-dir=vendor app src' ]
}

@test "SUM.code 0 is status error with metric null, as v1 refuses it" {
    printf '%s\n' '{"header":{},"SUM":{"blank":3,"comment":4,"code":0,"nFiles":1}}' > "$FAKE_OUT"
    measure
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'zero lines of code'* ]]
    run /code/lib/guard-parsers/cloc.sh "$FAKE_OUT"
    [ "$status" -eq 2 ]
}

@test "an empty {} (cloc on a missing path) is status error, for every metric" {
    printf '{}\n' > "$FAKE_OUT"
    local m
    for m in comment-ratio code comment; do
        rm -f "$QG_OUT/result.json"
        measure "metric=$m"
        [ "$(result .status)" = error ] || { echo "$m measured"; return 1; }
    done
}

@test "no output at all is status error" {
    rm -f "$FAKE_OUT"
    measure
    [ "$(result .status)" = error ]
}

@test "a non-zero exit is status error" {
    FAKE_RC=1 measure
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'exited 1'* ]]
}

@test "comment 0 is a measured ratio of 0" {
    printf '%s\n' '{"SUM":{"blank":1,"comment":0,"code":50,"nFiles":1}}' > "$FAKE_OUT"
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    [ "$(result .metric)" = "$(parser_value)" ]
}

@test "1/2000 and 1/2001 round exactly as the v1 parser" {
    printf '%s\n' '{"SUM":{"comment":1,"code":2000}}' > "$FAKE_OUT"
    measure
    [ "$(result .metric)" = "$(parser_value)" ] && [ "$(result .metric)" = 0.001 ]
    printf '%s\n' '{"SUM":{"comment":1,"code":2001}}' > "$FAKE_OUT"
    measure
    [ "$(result .metric)" = "$(parser_value)" ] && [ "$(result .metric)" = 0 ]
}

@test "metric=code gives SUM.code and metric=comment gives SUM.comment, in lines" {
    measure metric=code
    [ "$(result .metric)" = 78717 ] && [ "$(result .unit)" = lines ]
    measure metric=comment
    [ "$(result .metric)" = 21551 ]
}

@test "an unknown metric is status error" {
    measure metric=blank
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'metric=blank'* ]]
}
