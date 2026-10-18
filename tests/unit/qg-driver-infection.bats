#!/usr/bin/env bats
# drivers/infection.sh — metric = the Mutation Score Indicator from Infection's summaryJson,
# compared with the v1 infection parser.
#
# A fake infection records its argv, copies $FAKE_SUMMARY to $FAKE_DEST inside the tree when both
# are set, and exits $FAKE_RC.

load guard-helpers

DRIVER=/code/drivers/infection.sh
SUMMARY=build/infection-summary.json

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT FAKE_SUMMARY FAKE_DEST
    TREE="$WORK/tree"; mkdir -p "$TREE/vendor/bin" "$TREE/build" "$WORK/out"
    fake_bin "$TREE/vendor/bin/infection"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=infection-row QG_FILES=/dev/null
    export FAKE_RC=0 FAKE_ARGV="$WORK/argv"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {
    cat > "$1" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_ARGV"
if [ -n "${FAKE_SUMMARY:-}" ] && [ -n "${FAKE_DEST:-}" ]; then cp "$FAKE_SUMMARY" "$FAKE_DEST"; fi
exit "${FAKE_RC:-0}"
EOF
    chmod +x "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }
parser_value() { /code/lib/guard-parsers/infection.sh "$TREE/$SUMMARY"; }
measure() { QG_ARGS="summary=$SUMMARY run=no ${1:-}" "$DRIVER" run > /dev/null; }

@test "describe is JSON naming infection with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = infection ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain PlusEqual
    [[ "$output" == *'PlusEqual'* ]]
}

@test "msi from .stats.msi equals the v1 parser" {
    printf '%s\n' '{"stats":{"totalMutantsCount":10,"killedCount":8,"escapedCount":2,"msi":80.5,"mutationCodeCoverage":90}}' > "$TREE/$SUMMARY"
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 80.5 ]
    [ "$(result .metric)" = "$(parser_value)" ]
    [ "$(result .unit)" = percent ]
}

@test "msi from top-level .msi equals the v1 parser" {
    printf '%s\n' '{"totalMutantsCount":10,"msi":71,"mcc":80}' > "$TREE/$SUMMARY"
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 71 ]
    [ "$(result .metric)" = "$(parser_value)" ]
}

@test "msi 0 is the number 0, never a missing score" {
    printf '%s\n' '{"stats":{"msi":0}}' > "$TREE/$SUMMARY"
    measure
    [ "$(result .status)" = measured ]
    [ "$(jq -c .metric "$QG_OUT/result.json")" = 0 ]
    [ "$(parser_value)" = 0 ]
}

@test "a null msi, or none at all, is status error with metric null, as v1 refuses it" {
    printf '%s\n' '{"stats":{"msi":null}}' > "$TREE/$SUMMARY"
    measure
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'msi is null'* ]]
    run /code/lib/guard-parsers/infection.sh "$TREE/$SUMMARY"
    [ "$status" -eq 2 ]
    printf '%s\n' '{"stats":{}}' > "$TREE/$SUMMARY"
    measure
    [ "$(result .status)" = error ]
}

@test "a missing summary= is status error naming summary=, and infection is never called" {
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'summary='* ]]
    [ ! -e "$FAKE_ARGV" ]
}

@test "run=no never calls infection; a missing summary file is status error" {
    measure
    [ ! -e "$FAKE_ARGV" ]
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'does not exist'* ]]
}

@test "without run=no infection runs with the extra argv, exit 1 is measured, and its summary is read" {
    printf '%s\n' '{"stats":{"msi":42.1}}' > "$WORK/summary.json"
    FAKE_SUMMARY="$WORK/summary.json" FAKE_DEST="$SUMMARY" FAKE_RC=1 \
        QG_ARGS="summary=$SUMMARY -- --threads=4 --min-msi=90" "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = '--threads=4 --min-msi=90' ]
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 42.1 ]
}

@test "without run=no the old summary is deleted first, so an infection that writes none is status error" {
    printf '%s\n' '{"stats":{"msi":99}}' > "$TREE/$SUMMARY"
    QG_ARGS="summary=$SUMMARY" "$DRIVER" run > /dev/null
    [ -e "$FAKE_ARGV" ]
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "exit 2 is status error even when a summary was written" {
    printf '%s\n' '{"stats":{"msi":50}}' > "$WORK/summary.json"
    FAKE_SUMMARY="$WORK/summary.json" FAKE_DEST="$SUMMARY" FAKE_RC=2 QG_ARGS="summary=$SUMMARY" "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'exited 2'* ]]
}

@test "log= with escaped mutants gives one finding per escaped mutant" {
    printf '%s\n' '{"stats":{"msi":60}}' > "$TREE/$SUMMARY"
    cat > "$TREE/build/infection.json" <<'EOF'
{"stats":{"msi":60},"escaped":[
 {"mutator":{"mutatorName":"PlusEqual","originalFilePath":"/app/app/Services/A.php","originalStartLine":12},"diff":"-a\n+b"},
 {"mutator":{"mutatorName":"GreaterThan","originalFilePath":"app/Services/B.php","originalStartLine":7},"diff":"-c\n+d"}],
 "killed":[{"mutator":{"mutatorName":"Minus","originalFilePath":"app/C.php","originalStartLine":1}}]}
EOF
    measure 'log=build/infection.json'
    [ "$(result .metric)" = 60 ]
    [ "$(result '.findings | length')" = 2 ]
    [ "$(result '.findings[0].ruleId')" = PlusEqual ]
    [ "$(result '.findings[0].file')" = app/Services/A.php ]
    [ "$(result '.findings[0].line')" = 12 ]
    [[ "$(result '.findings[0].message')" == 'escaped mutant: PlusEqual' ]]
    [ "$(result '.findings[1].file')" = app/Services/B.php ]
}

@test "without log= there are no findings" {
    printf '%s\n' '{"stats":{"msi":60}}' > "$TREE/$SUMMARY"
    measure
    [ "$(result '.findings | length')" = 0 ]
}
