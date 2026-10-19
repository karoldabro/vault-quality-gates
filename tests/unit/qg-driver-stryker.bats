#!/usr/bin/env bats
# drivers/stryker.sh — metric = (Killed + Timeout) / (all - Ignored - CompileError) x 100, two
# decimals, compared with app.givore.com scripts/quality-metric.mjs `mutation`.
#
# The expected values are v1's output on the same reports, produced from a scratch folder by
# `jq -n ... > reports/mutation/mutation.json; node scripts/quality-metric.mjs mutation`. The
# status counts 491 Killed, 91 Timeout, 151 Survived, 50 NoCoverage are those of app.givore.com
# reports/mutation/mutation.json, on which v1 printed 74.33 as well.
#
# A fake stryker records its argv and whether $PROBE existed at call time, copies $FAKE_REPORT to
# $FAKE_DEST inside the tree when both are set, and exits $FAKE_RC.

load guard-helpers

DRIVER=/code/drivers/stryker.sh
REPORT=reports/mutation/mutation.json

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT FAKE_REPORT FAKE_DEST PROBE
    TREE="$WORK/tree"; mkdir -p "$TREE/node_modules/.bin" "$TREE/reports/mutation" "$WORK/out"
    fake_bin "$TREE/node_modules/.bin/stryker"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=mutation QG_FILES=/dev/null
    export FAKE_RC=0 FAKE_ARGV="$WORK/argv" FAKE_SEEN="$WORK/seen"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {
    cat > "$1" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_ARGV"
for p in ${PROBE:-}; do if [ -e "$p" ]; then echo "$p=present"; else echo "$p=absent"; fi >> "$FAKE_SEEN"; done
if [ -n "${FAKE_REPORT:-}" ] && [ -n "${FAKE_DEST:-}" ]; then mkdir -p "$(dirname "$FAKE_DEST")"; cp "$FAKE_REPORT" "$FAKE_DEST"; fi
exit "${FAKE_RC:-0}"
EOF
    chmod +x "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }

# mutants <file> "<Status>:<n> ..." — a Stryker report; the mutants alternate between two source files.
mutants() {
    jq -n --arg s "$2" '[$s | split(" ")[] | select(length > 0) | split(":") | . as [$st, $n] | range($n | tonumber)
            | {status: $st, mutatorName: "EqualityOperator", location: {start: {line: 3, column: 1}, end: {line: 3, column: 9}}}]
        | to_entries | group_by(.key % 2)
        | {schemaVersion: "1.0", thresholds: {high: 80, low: 60},
           files: (map({key: (if .[0].key % 2 == 0 then "utils/a.ts" else "utils/b.ts" end), value: {language: "typescript", source: "", mutants: map(.value)}}) | from_entries)}' > "$1"
}

@test "describe is JSON naming stryker with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = stryker ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
}

@test "the metric equals v1 mutation on the same reports, compared as numbers" {
    local row spec want
    while IFS='|' read -r spec want; do
        mutants "$TREE/$REPORT" "$spec"
        rm -f "$QG_OUT/result.json"
        QG_ARGS='run=no' "$DRIVER" run > /dev/null
        [ "$(result .status)" = measured ] && [ "$(result ".metric == $want")" = true ] \
            || { echo "$spec: $(result .status) $(result .metric), v1 $want"; return 1; }
    done <<'EOF'
Killed:3|100
Killed:2 Survived:1|66.67
Killed:1 Survived:31|3.13
Killed:1 Timeout:1 Survived:2 Ignored:5 CompileError:3|50
Killed:1 NoCoverage:7|12.5
Survived:4|0
Killed:491 Timeout:91 Survived:151 NoCoverage:50|74.33
EOF
    [ "$(result .unit)" = percent ]
    [ ! -e "$FAKE_ARGV" ]
}

@test "a tie at the third decimal rounds up, as toFixed does, and trailing zeros are dropped" {
    mutants "$TREE/$REPORT" 'Killed:1 Survived:31'
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    [ "$(jq -c .metric "$QG_OUT/result.json")" = 3.13 ]
    mutants "$TREE/$REPORT" 'Killed:3'
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    [ "$(jq -c .metric "$QG_OUT/result.json")" = 100 ]
}

@test "only Ignored and CompileError mutants, or no mutants, is status error" {
    mutants "$TREE/$REPORT" 'Ignored:2 CompileError:1'
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    printf '{"files":{}}' > "$TREE/$REPORT"
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
}

@test "a missing, empty or malformed report is status error" {
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    : > "$TREE/$REPORT"
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    printf '{"files":{"a.ts":{"mutants":null}}}' > "$TREE/$REPORT"
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    printf 'not json' > "$TREE/$REPORT"
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "run=no only reads: stryker is never called" {
    mutants "$TREE/$REPORT" 'Killed:2 Survived:1'
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    [ ! -e "$FAKE_ARGV" ]
    [ "$(result .status)" = measured ]
}

@test "stryker runs as <bin> run stryker.config.json after the report is deleted, and any exit with a fresh report measures" {
    mutants "$TREE/$REPORT" 'Survived:4'
    mutants "$WORK/fresh.json" 'Killed:2 Survived:1'
    export FAKE_REPORT="$WORK/fresh.json" FAKE_DEST="$TREE/$REPORT" PROBE="$TREE/$REPORT" FAKE_RC=1
    "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = 'run stryker.config.json' ]
    [ "$(cat "$FAKE_SEEN")" = "$TREE/$REPORT=absent" ]
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 66.67 ]
    rm -f "$FAKE_ARGV"
    mkdir -p "$TREE/q"; fake_bin "$TREE/q/st"
    FAKE_DEST="$TREE/q/m.json" FAKE_RC=137 QG_ARGS='bin=q/st config=q/s.json report=q/m.json -- --concurrency 2' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = 'run q/s.json --concurrency 2' ]
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 66.67 ]
}

@test "a run that writes no report is status error; the old report is never read" {
    mutants "$TREE/$REPORT" 'Killed:3'
    "$DRIVER" run > /dev/null
    [ -e "$FAKE_ARGV" ]
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [ ! -e "$TREE/$REPORT" ]
}

@test "surviving and uncovered mutants are findings with file and line" {
    mutants "$TREE/$REPORT" 'Killed:2 Survived:1 NoCoverage:1'
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    [ "$(result '.findings | length')" = 2 ]
    [ "$(result '[.findings[].file] | sort | join(",")')" = 'utils/a.ts,utils/b.ts' ]
    [ "$(result '.findings[0].line')" = 3 ]
    [ "$(result '.findings[0].ruleId')" = EqualityOperator ]
}

@test "permuted mutants give the same metric, and two runs write the same bytes" {
    mutants "$TREE/$REPORT" 'Killed:491 Timeout:91 Survived:151 NoCoverage:50'
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    cp "$QG_OUT/result.json" "$WORK/first.json"
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    cmp "$WORK/first.json" "$QG_OUT/result.json"
    jq '.files |= with_entries(.value.mutants |= reverse)' "$TREE/$REPORT" > "$WORK/rev.json"
    mv "$WORK/rev.json" "$TREE/$REPORT"
    QG_ARGS='run=no' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 74.33 ]
}
