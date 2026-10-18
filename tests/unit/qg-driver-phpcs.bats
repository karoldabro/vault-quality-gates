#!/usr/bin/env bats
# drivers/phpcs.sh — PHP_CodeSniffer: metric = totals.errors + totals.warnings, or with
# lines=added the messages on lines the commit adds.
#
# A fake phpcs records its argv, prints $FAKE_OUT (a real recorded phpcs output from
# tests/fixtures/drivers/ or an inline report) and exits $FAKE_RC.

load guard-helpers

DRIVER=/code/drivers/phpcs.sh
FIX=/code/tests/fixtures/drivers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR QG_REPO QG_BASES QG_TARGET CLAUDECODE AI_AGENT
    export GUARD_LOCK_WAIT=5
    TREE="$WORK/tree"; mkdir -p "$TREE/vendor/bin" "$WORK/out"
    fake_bin "$TREE/vendor/bin/phpcs"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=phpcs-row QG_FILES=/dev/null
    export FAKE_OUT="$WORK/fake.out" FAKE_RC=0 FAKE_ARGV="$WORK/argv"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {  # a phpcs that records its argv, prints $FAKE_OUT and exits $FAKE_RC
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${FAKE_ARGV:-/dev/null}"' \
        '[ -r "${FAKE_OUT:-}" ] && cat "$FAKE_OUT"' 'exit "${FAKE_RC:-0}"' > "$1"
    chmod +x "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }

@test "describe is JSON naming phpcs with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = phpcs ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
    run "$DRIVER" explain Generic.Files.LineLength
    [[ "$output" == *'Generic.Files.LineLength'* ]]
}

@test "phpcs-bad.json at exit 1 is measured 1, phpcs-good.json at exit 0 is measured 0" {
    cp "$FIX/phpcs-bad.json" "$FAKE_OUT"
    FAKE_RC=1 "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 1 ]
    cp "$FIX/phpcs-good.json" "$FAKE_OUT"
    FAKE_RC=0 "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 0 ]
}

@test "exits 0, 1 and 2 with a JSON report are measured as totals.errors + totals.warnings" {
    printf '%s\n' '{"totals":{"errors":3,"warnings":4,"fixable":2},"files":{}}' > "$FAKE_OUT"
    local rc
    for rc in 0 1 2; do
        rm -f "$QG_OUT/result.json"
        FAKE_RC=$rc "$DRIVER" run > /dev/null
        [ "$(result .status)" = measured ] || { echo "exit $rc not measured"; return 1; }
        [ "$(result .metric)" = 7 ] || { echo "exit $rc metric $(result .metric)"; return 1; }
    done
}

@test "findings carry the sniff, file, line and level of each message" {
    cp "$FIX/phpcs-bad.json" "$FAKE_OUT"
    FAKE_RC=1 "$DRIVER" run > /dev/null
    [ "$(result '.findings[0].ruleId')" = SlevomatCodingStandard.Variables.UnusedVariable.UnusedVariable ]
    [ "$(result '.findings[0].file')" = Bad.php ]
    [ "$(result '.findings[0].line')" = 4 ]
    [ "$(result '.findings[0].level')" = error ]
}

@test "exit 3 (phpcs-crash.txt) is status error with metric null" {
    cp "$FIX/phpcs-crash.txt" "$FAKE_OUT"
    FAKE_RC=3 run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'exited 3'* ]]
}

@test "exit 2 without a JSON report is status error, never metric 0" {
    printf 'PHP Fatal error: something\n' > "$FAKE_OUT"
    FAKE_RC=2 "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'no JSON report'* ]]
}

@test "argv carries --report=json --basepath=. and --standard=<standard> when given" {
    cp "$FIX/phpcs-good.json" "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = '--report=json --basepath=.' ]
    rm -f "$FAKE_ARGV"
    QG_ARGS='standard=quality/phpcs.xml paths=app,src -- -q' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = '--report=json --basepath=. --standard=quality/phpcs.xml -q app src' ]
}

@test "files=changed with no matching .php measures 0 and never calls phpcs" {
    printf 'docs/a.md\0app/Gone.php\0' > "$WORK/files"
    cp "$FIX/phpcs-bad.json" "$FAKE_OUT"
    QG_FILES="$WORK/files" QG_ARGS='files=changed' "$DRIVER" run > /dev/null
    [ ! -e "$FAKE_ARGV" ]
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
}

@test "lines=added counts only messages on added lines, equal to guard-added-lines.sh --checkstyle" {
    gate_repo "$WORK/repo"
    printf 'clean\nnew two\nnew three\n' > app/a.php
    git add app/a.php
    export QG_REPO="$WORK/repo" QG_TREE="$WORK/repo" QG_TARGET=:index QG_BASES="$(git rev-parse HEAD)"
    printf 'app/a.php\0' > "$WORK/files"; export QG_FILES="$WORK/files"
    fake_bin "$WORK/phpcs"
    # Line 1 is unchanged, lines 2 and 3 are added, app/other.php is not in the commit, and the
    # line-less message is printed but never counted.
    # phpcs prints its JSON report on one line; the heredoc is compacted to that shape.
    jq -c . > "$FAKE_OUT" <<'EOF'
{"totals":{"errors":4,"warnings":1,"fixable":0},"files":{
 "app/a.php":{"errors":3,"warnings":1,"messages":[
  {"message":"m1","source":"S.one","type":"ERROR","line":1,"column":1},
  {"message":"m2","source":"S.two","type":"ERROR","line":2,"column":1},
  {"message":"m3","source":"S.three","type":"WARNING","line":3,"column":1},
  {"message":"whole file","source":"S.file","type":"ERROR","column":1}]},
 "app/other.php":{"errors":1,"warnings":0,"messages":[
  {"message":"m4","source":"S.four","type":"ERROR","line":2,"column":1}]}}}
EOF
    cat > "$WORK/equivalent.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<checkstyle version="3.0">
<file name="app/a.php">
 <error line="1" column="1" severity="error" message="m1" source="S.one"/>
 <error line="2" column="1" severity="error" message="m2" source="S.two"/>
 <error line="3" column="1" severity="warning" message="m3" source="S.three"/>
 <error column="1" severity="error" message="whole file" source="S.file"/>
</file>
<file name="app/other.php">
 <error line="2" column="1" severity="error" message="m4" source="S.four"/>
</file>
</checkstyle>
EOF
    FAKE_RC=1 QG_ARGS="bin=$WORK/phpcs lines=added" "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    local v1
    v1="$(/code/bin/guard-added-lines.sh --checkstyle "$WORK/equivalent.xml" --bases "$QG_BASES" --target :index)"
    [ "$v1" = 2 ]
    [ "$(result .metric)" = "$v1" ]
    [ "$(result '[.findings[] | .ruleId] | join(",")')" = 'S.two,S.three,S.file' ]
}
