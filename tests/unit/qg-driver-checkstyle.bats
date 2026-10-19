#!/usr/bin/env bats
# drivers/checkstyle.sh — metric = the <error> elements of the checkstyle report a committed runner
# writes; under lines=added, only those on lines the commit adds.
#
# QG_RUNNER is a fake runner. It appends its argv to $FAKE_ARGV and its stdin to $FAKE_STDIN. With
# FAKE_REUSE set and report= already present it exits 0 at once (a runner reusing the report of an
# earlier row); otherwise it appends a line to $FAKE_TOOL (one tool run), copies $FAKE_REPORT to
# <tree>/$FAKE_DEST when both are set, and exits $FAKE_RC.
#
# The repo comes from gate_repo: app/a.php is committed as one line "clean"; tests stage edits.

load guard-helpers

DRIVER=/code/drivers/checkstyle.sh
REPORT=build/checkstyle.xml

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT FAKE_REUSE FAKE_REPORT FAKE_DEST
    export GUARD_LOCK_WAIT=5
    mkdir -p "$WORK/out"
    fake_runner "$WORK/runner"
    gate_repo "$WORK/repo"
    export QG_REPO="$WORK/repo" QG_TREE="$WORK/repo" QG_TARGET=:index QG_BASES="$(git rev-parse HEAD)"
    export QG_RUNNER="$WORK/runner" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=style-row QG_FILES=/dev/null
    export FAKE_RC=0 FAKE_ARGV="$WORK/argv" FAKE_STDIN="$WORK/stdin" FAKE_TOOL="$WORK/tool"
    export FAKE_REPORT="$WORK/report.xml" FAKE_DEST="$REPORT"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_runner() {
    cat > "$1" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_ARGV"
cat >> "$FAKE_STDIN"
if [ -n "${FAKE_REUSE:-}" ] && [ -s "$1/${FAKE_DEST}" ]; then exit 0; fi
printf 'run\n' >> "$FAKE_TOOL"
if [ -n "${FAKE_REPORT:-}" ] && [ -n "${FAKE_DEST:-}" ]; then mkdir -p "$(dirname "$1/$FAKE_DEST")"; cp "$FAKE_REPORT" "$1/$FAKE_DEST"; fi
exit "${FAKE_RC:-0}"
EOF
    chmod +x "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }
measure() { QG_ARGS="runner=quality/run-style.sh report=${REPORT}${1:+ $1}" "$DRIVER" run > /dev/null 2>&1; }
tool_runs() { [ -e "$FAKE_TOOL" ] && wc -l < "$FAKE_TOOL" | tr -d ' ' || printf 0; }

two_file_report() {  # 3 errors in app/a.php (one without a source, one without a line), 1 in app/b.php
    cat > "$FAKE_REPORT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<checkstyle version="3.0">
<file name="app/a.php">
 <error line="1" column="1" severity="error" message="m1" source="S.one"/>
 <error line="2" column="1" severity="warning" message="m2"/>
 <error column="1" severity="error" message="whole file" source="S.file"/>
</file>
<file name="app/b.php">
 <error line="7" column="1" severity="info" message="m4" source="S.four"/>
</file>
</checkstyle>
EOF
}

@test "describe is JSON naming checkstyle with needs_tree true; explain names the keys and a rule" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = checkstyle ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [[ "$output" == *'runner (required) report (required)'* ]]
    run "$DRIVER" explain dart_code_linter.avoid-nested
    [[ "$output" == *'Rule dart_code_linter.avoid-nested'* ]]
}

@test "a missing runner= or report= is status error and the runner is never called" {
    QG_ARGS="report=${REPORT}" "$DRIVER" run > /dev/null 2>&1
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'runner='* ]]
    QG_ARGS='runner=quality/run-style.sh' "$DRIVER" run > /dev/null 2>&1
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'report='* ]]
    [ ! -e "$FAKE_ARGV" ]
}

@test "bin= or a -- argv in the row is status error and the runner is never called" {
    measure 'bin=/usr/bin/true'
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'bin= and -- argv are not allowed'* ]]
    measure '-- --fix'
    [ "$(result .status)" = error ]
    [ ! -e "$FAKE_ARGV" ]
}

@test "no QG_RUNNER from the engine is status error" {
    unset QG_RUNNER
    measure
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'no QG_RUNNER'* ]]
}

@test "a report= tracked in the index is status error and the runner is never called" {
    two_file_report
    mkdir -p build; cp "$FAKE_REPORT" "$REPORT"; git add "$REPORT"
    measure
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *"${REPORT} is committed"* ]]
    [ ! -e "$FAKE_ARGV" ]
}

@test "a report= tracked at a QG_TARGET commit is status error; untracked at that commit it measures" {
    two_file_report
    mkdir -p build; cp "$FAKE_REPORT" "$REPORT"; commit_all 'track report'
    local with; with="$(git rev-parse HEAD)"
    QG_TARGET="$with" measure
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'is committed'* ]]
    [ ! -e "$FAKE_ARGV" ]
    QG_TARGET="$QG_BASES" measure
    [ "$(result .status)" = measured ]
}

@test "the runner gets <tree> <cache> and an empty stdin, whatever the driver's stdin holds" {
    two_file_report
    printf 'hook stdin\n' > "$WORK/hook-in"
    QG_ARGS="runner=quality/run-style.sh report=${REPORT}" "$DRIVER" run > /dev/null 2>&1 < "$WORK/hook-in"
    [ "$(cat "$FAKE_ARGV")" = "$QG_TREE $QG_CACHE" ]
    [ ! -s "$FAKE_STDIN" ]
}

@test "every <error> of the report is counted, with source, file, line and message in the findings" {
    two_file_report
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 4 ]
    [ "$(result .unit)" = findings ]
    [ "$(result '[.findings[].ruleId] | join(",")')" = 'S.one,checkstyle.error,S.file,S.four' ]
    [ "$(result '[.findings[].file] | join(",")')" = 'app/a.php,app/a.php,app/a.php,app/b.php' ]
    [ "$(result '[.findings[].line | tostring] | join(",")')" = '1,2,null,7' ]
    [ "$(result '.findings[3].message')" = m4 ]
}

@test "a report with no <error> measures 0" {
    printf '<?xml version="1.0"?>\n<checkstyle version="3.0">\n<file name="app/a.php"/>\n</checkstyle>\n' > "$FAKE_REPORT"
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
}

@test "XML entities in messages and file names are undone, &#39; and &apos; included, &amp;lt; once" {
    cat > "$FAKE_REPORT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<checkstyle version="3.0">
<file name="app/a&amp;b.php">
 <error line="3" column="1" severity="error" message="Don&#39;t use &quot;x&quot; &lt; y &gt; z, don&apos;t &amp;lt;" source="S.esc"/>
</file>
</checkstyle>
EOF
    measure
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings[0].message')" = "Don't use \"x\" < y > z, don't &lt;" ]
    [ "$(result '.findings[0].file')" = 'app/a&b.php' ]
}

@test "a runner that exits 1 is status error, even when it wrote a report" {
    two_file_report
    FAKE_RC=1 measure
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'runner exited 1'* ]]
}

@test "a runner that writes no report, an empty one or malformed XML is status error" {
    unset FAKE_REPORT
    measure
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *"the runner wrote no ${REPORT}"* ]]
    export FAKE_REPORT="$WORK/report.xml"
    : > "$FAKE_REPORT"
    measure
    [ "$(result .status)" = error ]
    printf '<checkstyle><file name="a">\n' > "$FAKE_REPORT"
    measure
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'not well-formed XML'* ]]
}

@test "the driver never deletes report=: a runner reusing it across two rows runs the tool once" {
    two_file_report
    export FAKE_REUSE=1
    measure
    [ "$(result .metric)" = 4 ]
    [ -s "$QG_TREE/$REPORT" ]
    mkdir -p "$WORK/out2"
    QG_OUT="$WORK/out2" measure
    [ "$(jq -r .metric "$WORK/out2/result.json")" = 4 ]
    [ "$(wc -l < "$FAKE_ARGV" | tr -d ' ')" = 2 ]
    [ "$(tool_runs)" = 1 ]
    [ -s "$QG_TREE/$REPORT" ]
}

@test "lines=added counts errors on added lines only, equal to guard-added-lines.sh --checkstyle" {
    printf 'clean\nnew two\nnew three\n' > app/a.php
    git add app/a.php
    printf 'app/a.php\0' > "$WORK/files"; export QG_FILES="$WORK/files"
    # Line 1 is unchanged, 2 and 3 are added; app/other.php is not in the commit; the line-less error
    # in the changed file is listed but never counted.
    cat > "$FAKE_REPORT" <<'EOF'
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
    measure lines=added
    [ "$(result .status)" = measured ]
    local v1
    v1="$(/code/bin/guard-added-lines.sh --checkstyle "$FAKE_REPORT" --bases "$QG_BASES" --target :index)"
    [ "$v1" = 2 ]
    [ "$(result .metric)" = "$v1" ]
    [ "$(result '[.findings[] | .ruleId] | join(",")')" = 'S.two,S.three,S.file' ]
}

@test "lines=added maps a tree-absolute file name in the report to the changed file" {
    printf 'clean\nnew two\nnew three\n' > app/a.php
    git add app/a.php
    printf 'app/a.php\0' > "$WORK/files"; export QG_FILES="$WORK/files"
    cat > "$FAKE_REPORT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<checkstyle version="3.0">
<file name="$WORK/repo/app/a.php">
 <error line="1" column="1" severity="error" message="m1" source="S.one"/>
 <error line="3" column="1" severity="warning" message="m3" source="S.three"/>
</file>
</checkstyle>
EOF
    measure lines=added
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings[0].file')" = app/a.php ]
    [ "$(result '.findings[0].line')" = 3 ]
}

@test "without lines=added the same report counts every error, unchanged lines and other files included" {
    printf 'clean\nnew two\n' > app/a.php
    git add app/a.php
    two_file_report
    measure
    [ "$(result .metric)" = 4 ]
    measure lines=added
    [ "$(result .metric)" = 1 ]
}
