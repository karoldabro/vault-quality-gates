#!/usr/bin/env bats
# drivers/vitest.sh — metric=failed from the <testsuites> root of a JUnit report, compared with
# app.givore.com scripts/quality-metric.mjs `tests-failing`; metric=coverage from a Clover report,
# compared with the v1 clover parser.
#
# The real-report fixtures are cut from app.givore.com: the <testsuites> root of
# quality-reports/junit.xml (v1 reads only the root) and the project <metrics> of coverage/clover.xml.
# v1 on the uncut files, from a scratch copy: `node scripts/quality-metric.mjs tests-failing` printed 0;
# lib/guard-parsers/clover.sh printed 44.22.
#
# A fake vitest records its argv and whether $PROBE existed at call time, copies $FAKE_REPORT to
# $FAKE_DEST inside the tree when both are set, and exits $FAKE_RC.

load guard-helpers

DRIVER=/code/drivers/vitest.sh
JUNIT=quality-reports/junit.xml
CLOVER=coverage/clover.xml

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT FAKE_REPORT FAKE_DEST PROBE
    TREE="$WORK/tree"; mkdir -p "$TREE/node_modules/.bin" "$TREE/quality-reports" "$TREE/coverage" "$WORK/out"
    fake_bin "$TREE/node_modules/.bin/vitest"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=vitest-row QG_FILES=/dev/null
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

junit() {  # junit <file> <tests> <failures> <errors> — a vitest JUnit report; its suites disagree with the root
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8" ?>
<testsuites name="vitest tests" tests="$2" failures="$3" errors="$4" time="1.5">
    <testsuite name="test/unit/a.spec.ts" timestamp="2026-10-13T13:01:13.017Z" hostname="h" tests="2" failures="0" errors="0" skipped="0" time="0.1">
        <testcase classname="test/unit/a.spec.ts" name="a &gt; passes" time="0.002">
        </testcase>
        <testcase classname="test/unit/a.spec.ts" name="a &gt; fails" time="0.002">
            <failure message="expected 1 to be 2" type="AssertionError">boom</failure>
        </testcase>
    </testsuite>
</testsuites>
EOF
}

real_junit() {  # the root and first suite of app.givore.com quality-reports/junit.xml
    cat > "$1" <<'EOF'
<?xml version="1.0" encoding="UTF-8" ?>
<testsuites name="vitest tests" tests="2939" failures="0" errors="0" time="281.306044335">
    <testsuite name="test/unit/access.spec.ts" timestamp="2026-10-13T13:01:13.017Z" hostname="kdabrow-MS-7971" tests="10" failures="0" errors="0" skipped="0" time="1.323998008">
        <testcase classname="test/unit/access.spec.ts" name="resolveGate &gt; renders default when there are no criteria (passthrough)" time="0.002278447">
        </testcase>
    </testsuite>
</testsuites>
EOF
}

real_clover() {  # the project metrics and one file of app.givore.com coverage/clover.xml
    cat > "$1" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<coverage generated="1791896473792" clover="3.2.0">
  <project timestamp="1791896473792" name="All files">
    <metrics statements="11511" coveredstatements="5090" conditionals="7465" coveredconditionals="3238" methods="2981" coveredmethods="1266" elements="21957" coveredelements="9594" complexity="0" loc="11511" ncloc="11511" packages="45" files="362" classes="362"/>
    <package name="api">
      <metrics statements="59" coveredstatements="59" conditionals="39" coveredconditionals="39" methods="14" coveredmethods="14"/>
      <file name="client.ts" path="/app/api/client.ts">
        <metrics statements="59" coveredstatements="59" conditionals="39" coveredconditionals="39" methods="14" coveredmethods="14"/>
        <line num="116" count="31" type="stmt"/>
      </file>
    </package>
  </project>
</coverage>
EOF
}

@test "describe is JSON naming vitest with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = vitest ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain vitest.failure
    [[ "$output" == *'vitest run'* ]]
}

@test "a missing or unknown metric= is status error, and vitest is never called" {
    "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [[ "$(result .error)" == *'metric='* ]]
    QG_ARGS='metric=passed' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [ ! -e "$FAKE_ARGV" ]
}

@test "metric=failed is failures + errors of the <testsuites> root, not of a suite: 0, 1, 3" {
    local t want
    for t in '5 0 0:0' '5 1 0:1' '5 2 1:3' '5 0 3:3'; do
        want="${t#*:}"
        # shellcheck disable=SC2086
        junit "$TREE/$JUNIT" ${t%:*}
        rm -f "$QG_OUT/result.json"
        QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
        [ "$(result .status)" = measured ] && [ "$(result .metric)" = "$want" ] \
            || { echo "root ${t%:*}: $(result .status) $(result .metric), want $want"; return 1; }
    done
    [ "$(result .unit)" = tests ]
    [ ! -e "$FAKE_ARGV" ]
}

@test "the real app.givore.com junit root reads 0, as v1 tests-failing does" {
    real_junit "$TREE/$JUNIT"
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 0 ]
}

@test "zero tests, no <testsuites> root, or a root without errors is status error" {
    junit "$TREE/$JUNIT" 0 0 0
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [[ "$(result .error)" == *'zero tests'* ]]
    printf '<?xml version="1.0"?>\n<testsuite name="x" tests="3" failures="1" errors="0"/>\n' > "$TREE/$JUNIT"
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    junit "$TREE/$JUNIT" 5 1 0
    sed -i '2s/ errors="0"//' "$TREE/$JUNIT"
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "a hostile or non-numeric root attribute is status error and runs nothing" {
    junit "$TREE/$JUNIT" 3 0 0
    sed -i '2s|failures="0"|failures="x[$(touch '"$WORK"'/pwned)0]"|' "$TREE/$JUNIT"
    grep -q 'pwned' "$TREE/$JUNIT"
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ ! -e "$WORK/pwned" ]
    junit "$TREE/$JUNIT" 3 0 0
    sed -i '2s/errors="0"/errors="1234567890"/' "$TREE/$JUNIT"
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
}

@test "a missing or empty report with run=no is status error" {
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    : > "$TREE/$JUNIT"
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    QG_ARGS='metric=coverage run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "vitest runs as <bin> --config vitest.config.ts <argv>, after the junit is deleted" {
    junit "$TREE/$JUNIT" 5 4 0
    junit "$WORK/fresh.xml" 5 0 0
    export FAKE_REPORT="$WORK/fresh.xml" FAKE_DEST="$TREE/$JUNIT" PROBE="$TREE/$JUNIT"
    QG_ARGS='metric=failed -- run --coverage --reporter=junit --outputFile.junit=quality-reports/junit.xml' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = '--config vitest.config.ts run --coverage --reporter=junit --outputFile.junit=quality-reports/junit.xml' ]
    [ "$(cat "$FAKE_SEEN")" = "$TREE/$JUNIT=absent" ]
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 0 ]
    rm -f "$FAKE_ARGV"
    mkdir -p "$TREE/tools"; fake_bin "$TREE/tools/vt"
    QG_ARGS='metric=failed bin=tools/vt config=quality/vitest.ci.ts' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = '--config quality/vitest.ci.ts' ]
}

@test "a run that exits 1 with no failure in the root reads 1; with failures it reads their count" {
    junit "$WORK/fresh.xml" 5 0 0
    export FAKE_REPORT="$WORK/fresh.xml" FAKE_DEST="$TREE/$JUNIT" FAKE_RC=1
    QG_ARGS='metric=failed' "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 1 ]
    junit "$WORK/fresh.xml" 5 2 1
    QG_ARGS='metric=failed' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 3 ]
    FAKE_RC=0 QG_ARGS='metric=failed' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 3 ]
}

@test "run=no adds nothing for an exit code and never calls vitest" {
    junit "$TREE/$JUNIT" 5 0 0
    FAKE_RC=1 QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 0 ]
    [ ! -e "$FAKE_ARGV" ]
}

@test "a run that writes no junit, or exits 2, is status error; the old junit is never read" {
    junit "$TREE/$JUNIT" 5 0 0
    QG_ARGS='metric=failed' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [ ! -e "$TREE/$JUNIT" ]
    junit "$WORK/fresh.xml" 5 0 0
    export FAKE_REPORT="$WORK/fresh.xml" FAKE_DEST="$TREE/$JUNIT" FAKE_RC=2
    QG_ARGS='metric=failed' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [[ "$(result .error)" == *'exited 2'* ]]
}

@test "each failing testcase is a finding on its classname file" {
    junit "$TREE/$JUNIT" 5 1 0
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    [ "$(result '.findings | length')" = 1 ]
    [ "$(result '.findings[0].file')" = test/unit/a.spec.ts ]
    [ "$(result '.findings[0].ruleId')" = vitest.failure ]
    [ "$(result '.findings[0].message')" = 'failed: a &gt; fails' ]
}

@test "metric=coverage equals the v1 clover parser on the real app.givore.com report: 44.22" {
    real_clover "$TREE/$CLOVER"
    QG_ARGS='metric=coverage run=no' "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ] && [ "$(result .unit)" = percent ]
    [ "$(result .metric)" = 44.22 ]
    [ "$(result .metric)" = "$(/code/lib/guard-parsers/clover.sh "$TREE/$CLOVER")" ]
    mkdir -p "$TREE/q"; mv "$TREE/$CLOVER" "$TREE/q/c.xml"
    QG_ARGS='metric=coverage run=no clover=q/c.xml' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 44.22 ]
}

@test "metric=coverage with a run deletes the old clover first and reads the fresh one" {
    real_clover "$TREE/$CLOVER"
    real_clover "$WORK/fresh.xml"
    sed -i '4s/coveredstatements="5090"/coveredstatements="11511"/' "$WORK/fresh.xml"
    export FAKE_REPORT="$WORK/fresh.xml" FAKE_DEST="$TREE/$CLOVER" PROBE="$TREE/$CLOVER"
    QG_ARGS='metric=coverage' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_SEEN")" = "$TREE/$CLOVER=absent" ]
    [ "$(result '.metric == 100')" = true ]
}

@test "two runs on the same report write the same bytes" {
    junit "$TREE/$JUNIT" 5 2 1
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    cp "$QG_OUT/result.json" "$WORK/first.json"
    QG_ARGS='metric=failed run=no' "$DRIVER" run > /dev/null
    cmp "$WORK/first.json" "$QG_OUT/result.json"
}
