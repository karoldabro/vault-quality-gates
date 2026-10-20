#!/usr/bin/env bats
# drivers/phpinsights.sh — PHP Insights: metric = summary.<metric>, compared with the v1
# insights parser and its #selector.
#
# A fake phpinsights records its argv, prints $FAKE_OUT (the trimmed real report in
# tests/fixtures/drivers/phpinsights.json, or the recorded crash) and exits $FAKE_RC.

load guard-helpers
load qg-fakes

DRIVER=/code/drivers/phpinsights.sh
FIX=/code/tests/fixtures/drivers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    fakes_setup
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT
    TREE="$WORK/tree"; mkdir -p "$TREE/vendor/bin" "$WORK/out"
    fake_bin "$TREE/vendor/bin/phpinsights"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=insights-row QG_FILES=/dev/null
    export QG_TARGET=:index FAKE_OUT="$WORK/fake.out" FAKE_RC=0 FAKE_ARGV="$WORK/argv"
    cp "$FIX/phpinsights.json" "$FAKE_OUT"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {  # a phpinsights that records its argv, prints $FAKE_OUT and exits $FAKE_RC
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${FAKE_ARGV:-/dev/null}"' \
        '[ -r "${FAKE_OUT:-}" ] && cat "$FAKE_OUT"' 'exit "${FAKE_RC:-0}"' > "$1"
    chmod +x "$1"
    fake_bake "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }

@test "describe is JSON naming phpinsights with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = phpinsights ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
}

@test "metric code, complexity, architecture and style each equal the v1 insights parser with that selector" {
    local m v1
    for m in code complexity architecture style; do
        rm -f "$QG_OUT/result.json"
        QG_ARGS="metric=$m" "$DRIVER" run > /dev/null
        v1="$(/code/lib/guard-parsers/insights.sh "$FAKE_OUT#$m")"
        [ "$(result .status)" = measured ] || { echo "$m not measured"; return 1; }
        [ "$(result .metric)" = "$v1" ] || { echo "$m driver $(result .metric) parser $v1"; return 1; }
        [ "$(result .unit)" = score ]
    done
    [ "$v1" = 84.3 ]
}

@test "the default metric is code" {
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = "$(/code/lib/guard-parsers/insights.sh "$FAKE_OUT")" ]
    [ "$(result .metric)" = 68.4 ]
}

@test "exit 1 with the JSON report (scores below its own minimum) is still measured" {
    FAKE_RC=1 QG_ARGS=metric=complexity "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 83.3 ]
}

@test "an unknown metric is status error, and the tool is never called" {
    QG_ARGS='metric=security' run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'metric=security'* ]]
    [ ! -e "$FAKE_ARGV" ]
}

@test "a report missing summary.<metric> is status error" {
    jq -c 'del(.summary.style)' "$FIX/phpinsights.json" > "$FAKE_OUT"
    QG_ARGS='metric=style' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'summary.style'* ]]
}

@test "a crash (exit 1, phpinsights-crash.txt, no JSON) is status error" {
    cp "$FIX/phpinsights-crash.txt" "$FAKE_OUT"
    FAKE_RC=1 run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'no JSON report'* ]]
}

@test "exit 2 is status error even with a report" {
    FAKE_RC=2 "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
}

@test "argv is analyse <paths> --format=json --no-interaction, with --config-path when given" {
    QG_ARGS='paths=src config=quality/insights.php' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = 'analyse src --format=json --no-interaction --config-path=quality/insights.php' ]
}

@test "with QG_RUN_DIR, four rows differing only in metric= on one target call the tool once" {
    mkdir -p "$WORK/run"
    local m
    for m in code complexity architecture style; do
        QG_RUN_DIR="$WORK/run" QG_ARGS="metric=$m paths=app" "$DRIVER" run > /dev/null
        [ "$(result .status)" = measured ]
        [ "$(result .metric)" = "$(/code/lib/guard-parsers/insights.sh "$FAKE_OUT#$m")" ]
    done
    [ "$(wc -l < "$FAKE_ARGV")" -eq 1 ]
}

@test "without QG_RUN_DIR every row runs the tool" {
    QG_ARGS=metric=code "$DRIVER" run > /dev/null
    QG_ARGS=metric=style "$DRIVER" run > /dev/null
    [ "$(wc -l < "$FAKE_ARGV")" -eq 2 ]
}

@test "findings of the metric's category carry paths prefixed with the analysed dir" {
    QG_ARGS=metric=code "$DRIVER" run > /dev/null
    [ "$(result '.findings | length')" = 3 ]
    [ "$(result '.findings[0].file')" = app/Http/Resources/FeatureRequestResource.php ]
    [ "$(result '.findings[0].line')" = 72 ]
    [[ "$(result '.findings[0].message')" == 'Forbidden public property: Do not use public properties'* ]]
    QG_ARGS=metric=complexity "$DRIVER" run > /dev/null
    [ "$(result '.findings[0].file')" = app/Casts/VectorCast.php ]
    [ "$(result '.findings[0].line')" = null ]
}
