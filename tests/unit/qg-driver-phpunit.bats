#!/usr/bin/env bats
# drivers/phpunit.sh — metric=failed from a JUnit report, compared with the v1 junit parser;
# metric=coverage from a Clover report, compared with the v1 clover parser.
#
# A fake phpunit records its argv and the byte size of each $PROBE file at call time, copies
# $FAKE_REPORT to $FAKE_DEST inside the tree when both are set, and exits $FAKE_RC.

load guard-helpers

DRIVER=/code/drivers/phpunit.sh
JUNIT=storage/coverage/junit.xml
CLOVER=storage/coverage/clover.xml

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT FAKE_REPORT FAKE_DEST PROBE
    TREE="$WORK/tree"; mkdir -p "$TREE/vendor/bin" "$TREE/storage/coverage" "$WORK/out"
    fake_bin "$TREE/vendor/bin/phpunit"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=phpunit-row QG_FILES=/dev/null
    export FAKE_RC=0 FAKE_ARGV="$WORK/argv" FAKE_SIZES="$WORK/sizes"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {
    cat > "$1" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_ARGV"
for p in ${PROBE:-}; do printf '%s=%s\n' "$p" "$(wc -c < "$p")" >> "$FAKE_SIZES"; done
if [ -n "${FAKE_REPORT:-}" ] && [ -n "${FAKE_DEST:-}" ]; then mkdir -p "$(dirname "$FAKE_DEST")"; cp "$FAKE_REPORT" "$FAKE_DEST"; fi
exit "${FAKE_RC:-0}"
EOF
    chmod +x "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }

junit() {  # junit <file> <tests> <failures> <errors> — a JUnit report with nested suites
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="all" tests="$2" assertions="9" errors="$4" failures="$3" skipped="0" time="0.1">
    <testsuite name="Tests\\Unit\\ATest" file="/app/tests/Unit/ATest.php" tests="$2" errors="$4" failures="$3">
      <testcase name="test_ok" file="/app/tests/Unit/ATest.php" line="10" class="Tests\\Unit\\ATest"/>
      <testcase name="test_fails" file="/app/tests/Unit/ATest.php" line="20" class="Tests\\Unit\\ATest"><failure type="x">boom</failure></testcase>
      <testcase name="test_errors" file="/app/tests/Unit/ATest.php" line="30" class="Tests\\Unit\\ATest"><error type="y">bang</error></testcase>
    </testsuite>
  </testsuite>
</testsuites>
EOF
}

clover() {  # clover <file> <statements> <covered>
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<coverage generated="1">
  <project timestamp="1">
    <file name="/app/app/A.php"><metrics statements="1" coveredstatements="1"/></file>
    <metrics files="1" loc="10" ncloc="8" classes="1" methods="1" coveredmethods="1" statements="$2" coveredstatements="$3" elements="$2" coveredelements="$3"/>
  </project>
</coverage>
EOF
}

@test "describe is JSON naming phpunit with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = phpunit ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain phpunit.failure
    [[ "$output" == *'--filter'* ]]
}

@test "a missing metric= is status error naming metric=, and phpunit is never called" {
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'metric='* ]]
    [ ! -e "$FAKE_ARGV" ]
}

@test "an unknown metric is status error" {
    QG_ARGS='metric=passed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
}

@test "metric=failed equals the v1 junit parser: failures + errors of the first testsuite" {
    local t
    for t in '5 0 0' '5 2 0' '5 0 3' '7 2 1'; do
        # shellcheck disable=SC2086
        junit "$TREE/$JUNIT" $t
        rm -f "$QG_OUT/result.json"
        QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
        [ "$(result .status)" = measured ] || { echo "not measured for $t"; return 1; }
        [ "$(result .metric)" = "$(/code/lib/guard-parsers/junit.sh "$TREE/$JUNIT")" ] \
            || { echo "driver $(result .metric) parser $(/code/lib/guard-parsers/junit.sh "$TREE/$JUNIT") for $t"; return 1; }
    done
    [ "$(result .metric)" = 3 ] && [ "$(result .unit)" = tests ]
}

@test "a hostile or non-numeric failures, errors or statements attribute is status error and runs nothing" {
    junit "$TREE/$JUNIT" 3 0 0
    sed -i 's|failures="0"|failures="x[$(touch '"$WORK"'/pwned)0]"|' "$TREE/$JUNIT"
    grep -q 'pwned' "$TREE/$JUNIT"
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ ! -e "$WORK/pwned" ]
    junit "$TREE/$JUNIT" 3 0 0
    sed -i 's/errors="0"/errors="abc"/' "$TREE/$JUNIT"
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    clover "$TREE/$CLOVER" 10 5
    sed -i 's/coveredstatements="5"/coveredstatements="5e3"/' "$TREE/$CLOVER"
    QG_ARGS='metric=coverage run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
}

@test "zero tests, an empty file, no <testsuite> and a missing report are status error" {
    junit "$TREE/$JUNIT" 0 0 0
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [[ "$(result .error)" == *'zero tests'* ]]
    : > "$TREE/$JUNIT"
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [[ "$(result .error)" == *'empty'* ]]
    printf '<?xml version="1.0"?>\n<testsuites/>\n' > "$TREE/$JUNIT"
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [[ "$(result .error)" == *'no <testsuite>'* ]]
    rm -f "$TREE/$JUNIT"
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [[ "$(result .error)" == *'does not exist'* ]]
    [ "$(result .metric)" = null ]
}

@test "metric=coverage equals the v1 clover parser for 0/N, N/N and 2/3" {
    local c want
    for c in '10 0 0.00' '10 10 100.00' '3 2 66.67'; do
        set -- $c
        clover "$TREE/$CLOVER" "$1" "$2"
        rm -f "$QG_OUT/result.json"
        QG_ARGS='metric=coverage run=no' "$DRIVER" run > /dev/null
        want="$(/code/lib/guard-parsers/clover.sh "$TREE/$CLOVER")"
        [ "$(result .status)" = measured ] || { echo "not measured for $c"; return 1; }
        [ "$want" = "$3" ]
        [ "$(jq -c .metric "$QG_OUT/result.json")" = "$(jq -c . <<<"$want")" ] \
            || { echo "driver $(jq -c .metric "$QG_OUT/result.json") parser $want"; return 1; }
    done
    [ "$(result .unit)" = percent ]
}

@test "metric=coverage with zero statements, or no project metrics, is status error" {
    clover "$TREE/$CLOVER" 0 0
    QG_ARGS='metric=coverage run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [[ "$(result .error)" == *'zero statements'* ]]
    printf '<?xml version="1.0"?>\n<coverage><project/></coverage>\n' > "$TREE/$CLOVER"
    QG_ARGS='metric=coverage run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
}

@test "junit= and clover= name the report read" {
    mkdir -p "$TREE/build"; junit "$TREE/build/j.xml" 4 1 0
    QG_ARGS='metric=failed run=no junit=build/j.xml' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 1 ]
    clover "$TREE/build/c.xml" 4 1
    QG_ARGS='metric=coverage run=no clover=build/c.xml' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = "$(/code/lib/guard-parsers/clover.sh "$TREE/build/c.xml")" ]
}

@test "run=no reads the report, never calls phpunit and never empties reset files" {
    junit "$TREE/$JUNIT" 5 1 0
    mkdir -p "$TREE/storage/logs"; printf 'kept\n' > "$TREE/storage/logs/q.log"
    QG_ARGS='metric=failed run=no reset=storage/logs/q.log' "$DRIVER" run > /dev/null
    [ ! -e "$FAKE_ARGV" ]
    [ "$(cat "$TREE/storage/logs/q.log")" = kept ]
    [ "$(result .metric)" = 1 ]
}

@test "without run=no each reset= file is emptied before phpunit runs, and its report is read" {
    mkdir -p "$TREE/storage/logs"
    printf 'old\n' > "$TREE/storage/logs/a.log"; printf 'old\n' > "$TREE/storage/logs/b.log"
    junit "$WORK/report.xml" 6 0 2
    FAKE_REPORT="$WORK/report.xml" FAKE_DEST="$JUNIT" FAKE_RC=2 PROBE='storage/logs/a.log storage/logs/b.log storage/new/c.log' \
        QG_ARGS='metric=failed reset=storage/logs/a.log,storage/logs/b.log,storage/new/c.log -- --testsuite Unit' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_SIZES")" = $'storage/logs/a.log=0\nstorage/logs/b.log=0\nstorage/new/c.log=0' ]
    [ "$(cat "$FAKE_ARGV")" = '--testsuite Unit' ]
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 2 ]
}

@test "without run=no the old report is deleted first, so a phpunit that writes none is status error" {
    junit "$TREE/$JUNIT" 5 0 0
    QG_ARGS='metric=failed' "$DRIVER" run > /dev/null
    [ -e "$FAKE_ARGV" ]
    [ ! -e "$TREE/$JUNIT" ]
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'wrote no report'* ]]
}

@test "an exit code above 2 is status error even when phpunit wrote a report" {
    junit "$WORK/report.xml" 5 0 0
    FAKE_REPORT="$WORK/report.xml" FAKE_DEST="$JUNIT" FAKE_RC=255 QG_ARGS='metric=failed' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'exited 255'* ]]
}

@test "findings list each failing or errored testcase with its file and line" {
    junit "$TREE/$JUNIT" 3 1 1
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result '.findings | length')" = 2 ]
    [ "$(result '.findings[0].ruleId')" = phpunit.failure ]
    [ "$(result '.findings[0].message')" = 'failed: test_fails' ]
    [ "$(result '.findings[0].file')" = tests/Unit/ATest.php ]
    [ "$(result '.findings[0].line')" = 20 ]
    [ "$(result '.findings[1].message')" = 'failed: test_errors' ]
    [ "$(result '.findings[1].line')" = 30 ]
}
