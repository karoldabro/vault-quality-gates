#!/usr/bin/env bats
# drivers/phpmd.sh — PHPMD: metric = violations, compared with the v1 phpmd parser.
#
# A fake phpmd records its argv, prints $FAKE_OUT (a real recorded PHPMD output from
# tests/fixtures/drivers/ or an inline report) and exits $FAKE_RC.

load guard-helpers
load qg-fakes

DRIVER=/code/drivers/phpmd.sh
FIX=/code/tests/fixtures/drivers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    fakes_setup
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT
    TREE="$WORK/tree"; mkdir -p "$TREE/vendor/bin" "$WORK/out" "$WORK/path"
    fake_bin "$TREE/vendor/bin/phpmd"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=phpmd-row QG_FILES=/dev/null
    export FAKE_OUT="$WORK/fake.out" FAKE_RC=0 FAKE_ARGV="$WORK/argv"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {  # a tool that records its argv, prints $FAKE_OUT and exits $FAKE_RC
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${FAKE_ARGV:-/dev/null}"' \
        '[ -r "${FAKE_OUT:-}" ] && cat "$FAKE_OUT"' 'exit "${FAKE_RC:-0}"' > "$1"
    chmod +x "$1"
    fake_bake "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }
parser_value() { /code/lib/guard-parsers/phpmd.sh "$FAKE_OUT"; }
ARGS='ruleset=quality/phpmd.xml paths=app'

@test "describe is JSON naming phpmd with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = phpmd ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
    run "$DRIVER" explain ShortMethodName
    [[ "$output" == *'ShortMethodName'* ]]
}

@test "phpmd-bad.json at exit 2 and phpmd-good.json at exit 0 are measured and equal the v1 parser" {
    cp "$FIX/phpmd-bad.json" "$FAKE_OUT"
    FAKE_RC=2 QG_ARGS="$ARGS" "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = "$(parser_value)" ] && [ "$(result .metric)" = 1 ]
    cp "$FIX/phpmd-good.json" "$FAKE_OUT"
    FAKE_RC=0 QG_ARGS="$ARGS" "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = "$(parser_value)" ] && [ "$(result .metric)" = 0 ]
}

@test "several files and violations, in either order, equal the v1 parser" {
    local base
    base="$(jq -c '.files[0].violations[0]' "$FIX/phpmd-bad.json")"
    jq -n --argjson v "$base" '{files: [{file: "a.php", violations: [$v, ($v | .rule = "Two"), ($v | .beginLine = 9)]},
        {file: "b.php", violations: [($v | .rule = "Three")]}, {file: "c.php", violations: []}]}' > "$WORK/a.json"
    jq '.files |= (reverse | map(.violations |= reverse))' "$WORK/a.json" > "$WORK/b.json"
    local j
    for j in "$WORK/a.json" "$WORK/b.json"; do
        cp "$j" "$FAKE_OUT"
        FAKE_RC=2 QG_ARGS="$ARGS" "$DRIVER" run > /dev/null
        [ "$(result .metric)" = "$(parser_value)" ] || { echo "driver $(result .metric) parser $(parser_value)"; return 1; }
        [ "$(result .metric)" = 4 ]
    done
}

@test "findings carry rule, file, beginLine and the external info url" {
    cp "$FIX/phpmd-bad.json" "$FAKE_OUT"
    FAKE_RC=2 QG_ARGS="$ARGS" "$DRIVER" run > /dev/null
    [ "$(result '.findings[0].ruleId')" = ShortMethodName ]
    [ "$(result '.findings[0].file')" = /tmp/qg/Bad.php ]
    [ "$(result '.findings[0].line')" = 4 ]
    [ "$(result '.findings[0].doc')" = 'https://phpmd.org/rules/naming.html#shortmethodname' ]
}

@test "exit 1 (phpmd-crash.txt) and exit 3 are status error with metric null" {
    cp "$FIX/phpmd-crash.txt" "$FAKE_OUT"
    FAKE_RC=1 QG_ARGS="$ARGS" run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'exited 1'* ]]
    cp "$FIX/phpmd-good.json" "$FAKE_OUT"
    FAKE_RC=3 QG_ARGS="$ARGS" "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "a report with a non-empty errors[] is status error naming the file, as v1 refuses it" {
    jq '.errors = [{"fileName": "app/Broken.php", "message": "Unexpected token"}]' "$FIX/phpmd-bad.json" > "$FAKE_OUT"
    FAKE_RC=2 QG_ARGS="$ARGS" "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'app/Broken.php'* ]]
    run /code/lib/guard-parsers/phpmd.sh "$FAKE_OUT"
    [ "$status" -eq 2 ]
}

@test "exit 0 with no JSON report is status error" {
    printf 'nothing here\n' > "$FAKE_OUT"
    QG_ARGS="$ARGS" "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'no JSON report'* ]]
}

@test "a missing ruleset= is status error naming ruleset=, and phpmd is never called" {
    cp "$FIX/phpmd-good.json" "$FAKE_OUT"
    QG_ARGS='paths=app' run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'ruleset='* ]]
    [ ! -e "$FAKE_ARGV" ]
}

@test "argv is <paths> json <ruleset>, then --baseline-file and the extra argv" {
    cp "$FIX/phpmd-good.json" "$FAKE_OUT"
    QG_ARGS='ruleset=quality/phpmd.xml paths=app,src baseline=quality/phpmd.baseline.xml -- --strict' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = 'app,src json quality/phpmd.xml --baseline-file quality/phpmd.baseline.xml --strict' ]
}

@test "phpini=error_reporting=24575 runs php -d error_reporting=24575 <bin>" {
    fake_bin "$WORK/path/php"
    cp "$FIX/phpmd-good.json" "$FAKE_OUT"
    PATH="$WORK/path:$PATH" QG_ARGS="$ARGS phpini=error_reporting=24575" "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = '-d error_reporting=24575 vendor/bin/phpmd app json quality/phpmd.xml' ]
    [ "$(result .status)" = measured ]
}

@test "files=changed joins the changed .php files with commas" {
    mkdir -p "$TREE/app"; : > "$TREE/app/A.php"; : > "$TREE/app/B.php"
    printf 'app/A.php\0docs/x.md\0app/B.php\0app/Gone.php\0' > "$WORK/files"
    cp "$FIX/phpmd-good.json" "$FAKE_OUT"
    QG_FILES="$WORK/files" QG_ARGS='ruleset=r.xml files=changed' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = 'app/A.php,app/B.php json r.xml' ]
}

@test "files=changed with an empty file set measures 0 and never calls phpmd" {
    printf 'docs/x.md\0' > "$WORK/files"
    cp "$FIX/phpmd-bad.json" "$FAKE_OUT"
    QG_FILES="$WORK/files" QG_ARGS='ruleset=r.xml files=changed' "$DRIVER" run > /dev/null
    [ ! -e "$FAKE_ARGV" ]
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 0 ]
}

@test "neither files=changed nor paths= is status error, and phpmd is never called" {
    cp "$FIX/phpmd-good.json" "$FAKE_OUT"
    QG_ARGS='ruleset=r.xml' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'files=changed or paths='* ]]
    [ ! -e "$FAKE_ARGV" ]
}
