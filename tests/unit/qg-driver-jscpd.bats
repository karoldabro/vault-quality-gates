#!/usr/bin/env bats
# drivers/jscpd.sh — metric = .statistics.total.percentage (two decimals) or .clones of the whole-repo
# jscpd report, compared with the v1 parser lib/guard-parsers/jscpd.sh.
#
# The real-report fixture is cut from app.givore.com quality-reports/jscpd/jscpd-report.json: its
# statistics.total and its first clone. v1 on the uncut file: the parser printed 2.32 and, with
# #clones, 147.
#
# The test image has no pnpm: a fake `pnpm` first on PATH, an installed-jscpd fake and a fake runner
# record their argv in $WORK/argv and write $WORK/jscpd.json as jscpd-report.json into the --output
# directory they are given. pnpm runs with an empty environment, so its fake finds $WORK beside itself.

load guard-helpers

DRIVER=/code/drivers/jscpd.sh

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT
    TREE="$WORK/tree"; mkdir -p "$TREE/node_modules/.bin" "$TREE/quality" "$WORK/out" "$WORK/path"
    fake_jscpd "$WORK/path/pnpm"
    fake_jscpd "$TREE/node_modules/.bin/jscpd"
    export PATH="$WORK/path:$PATH" FAKE_WORK="$WORK"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=duplication QG_FILES=/dev/null
    FAKE_ARGV="$WORK/argv"
    real_report > "$WORK/jscpd.json"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_jscpd() {
    cat > "$1" <<'EOF'
#!/usr/bin/env bash
# Under env -i FAKE_WORK is gone; the pnpm fake sits in $WORK/path.
w="${FAKE_WORK:-$(cd "$(dirname "$0")/.." && pwd)}"
printf '%s\n' "$*" >> "$w/argv"
out=''
while [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done
[ -n "$out" ] || exit 9
mkdir -p "$out" && cp "$w/jscpd.json" "$out/jscpd-report.json"
EOF
    chmod +x "$1"
}

fake_runner() {  # fake_runner <file> — called as <runner> <tree> <cache> <argv...>; runs nothing
    cat > "$1" <<'EOF'
#!/usr/bin/env bash
tree="$1"; shift 2
printf 'runner %s\n' "$*" >> "$FAKE_WORK/argv"
out=''
while [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done
mkdir -p "$tree/$out" && cp "$FAKE_WORK/jscpd.json" "$tree/$out/jscpd-report.json"
EOF
    chmod +x "$1"
}

real_report() {  # statistics.total and the first clone of app.givore.com quality-reports/jscpd/jscpd-report.json
    cat <<'EOF'
{"statistics": {"total": {"clones": 147, "duplicatedLines": 2737, "duplicatedTokens": 13834, "lines": 117860,
  "newClones": 0, "newDuplicatedLines": 0, "percentage": 2.3222467334125234, "percentageTokens": 3.455312474242511,
  "sources": 796, "tokens": 400369}},
 "duplicates": [{"format": "typescript", "lines": 12, "fragment": "",
  "firstFile": {"name": "components/A.vue", "start": 10, "end": 21},
  "secondFile": {"name": "components/B.vue", "start": 30, "end": 41}}]}
EOF
}

result() { jq -r "$1" "$QG_OUT/result.json"; }

@test "describe is JSON naming jscpd with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = jscpd ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
}

@test "metric=percentage and metric=clones equal the v1 jscpd parser on the real app.givore.com report" {
    QG_ARGS='metric=percentage' "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ] && [ "$(result .unit)" = percent ]
    [ "$(result .metric)" = 2.32 ]
    [ "$(result .metric)" = "$(/code/lib/guard-parsers/jscpd.sh "$WORK/jscpd.json")" ]
    QG_ARGS='metric=clones' "$DRIVER" run > /dev/null
    [ "$(result .unit)" = clones ]
    [ "$(result .metric)" = 147 ]
    [ "$(result .metric)" = "$(/code/lib/guard-parsers/jscpd.sh "$WORK/jscpd.json#clones")" ]
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 2.32 ]
}

@test "without bin= pnpm receives dlx jscpd@5.3.2 <tree>/. and config= as -c <tree>/<config>" {
    QG_ARGS='metric=clones' "$DRIVER" run > /dev/null
    [[ "$(cat "$FAKE_ARGV")" == "dlx jscpd@5.3.2 $TREE/. --reporters json --output "*"/out --silent --no-colors" ]]
    rm -f "$FAKE_ARGV"
    QG_ARGS='metric=clones version=5.0.9 config=quality/jscpd.json paths=app,server' "$DRIVER" run > /dev/null
    [[ "$(cat "$FAKE_ARGV")" == "dlx jscpd@5.0.9 $TREE/app $TREE/server -c $TREE/quality/jscpd.json --reporters json --output "* ]]
}

@test "two rows of one run that differ only in metric= make one jscpd call" {
    export QG_RUN_DIR="$WORK/run"; mkdir -p "$QG_RUN_DIR"
    QG_ARGS='metric=percentage config=quality/jscpd.json' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 2.32 ]
    QG_ARGS='metric=clones config=quality/jscpd.json' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 147 ]
    [ "$(wc -l < "$FAKE_ARGV")" -eq 1 ]
    QG_ARGS='metric=clones config=quality/other.json' "$DRIVER" run > /dev/null
    [ "$(wc -l < "$FAKE_ARGV")" -eq 2 ]
}

@test "bin= with a runner runs the installed jscpd through it, calls no pnpm dlx, and passes config= as -c" {
    fake_runner "$WORK/runner"
    QG_RUNNER="$WORK/runner" QG_ARGS='bin=node_modules/.bin/jscpd metric=clones config=quality/jscpd.json' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = 'runner node_modules/.bin/jscpd . -c quality/jscpd.json --reporters json --output .qg-jscpd-duplication --silent --no-colors' ]
    ! grep -q 'dlx' "$FAKE_ARGV"
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 147 ]
    [ ! -e "$TREE/.qg-jscpd-duplication" ]
}

@test "bin= without a runner runs that path from the tree" {
    QG_ARGS='bin=node_modules/.bin/jscpd config=quality/jscpd.json' "$DRIVER" run > /dev/null
    # The installed fake records its argv without its own name; pnpm is never called.
    [ "$(cat "$FAKE_ARGV")" = '. -c quality/jscpd.json --reporters json --output .qg-jscpd-duplication --silent --no-colors' ]
    [ "$(result .metric)" = 2.32 ]
    [ ! -e "$TREE/.qg-jscpd-duplication" ]
}

@test "an unknown metric is status error and runs nothing" {
    QG_ARGS='metric=lines' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [ ! -e "$FAKE_ARGV" ]
}

@test "a non-zero exit, no report, or a report without the statistic is status error" {
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$WORK/path/pnpm"
    "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [[ "$(result .error)" == *'exited 1'* ]]
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$WORK/path/pnpm"
    "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    fake_jscpd "$WORK/path/pnpm"
    printf '{"statistics":{"total":{"clones":"7"}},"duplicates":[]}' > "$WORK/jscpd.json"
    QG_ARGS='metric=clones' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    QG_ARGS='metric=percentage' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "each clone is a finding on its first side, named relative to the tree" {
    jq --arg t "$TREE" '.duplicates[0].firstFile.name = ($t + "/components/A.vue")' "$WORK/jscpd.json" > "$WORK/j" && mv "$WORK/j" "$WORK/jscpd.json"
    "$DRIVER" run > /dev/null
    [ "$(result '.findings | length')" = 1 ]
    [ "$(result '.findings[0].file')" = components/A.vue ]
    [ "$(result '.findings[0].line')" = 10 ]
    [ "$(result '.findings[0].message')" = 'Lines 10-21 duplicate components/B.vue:30-41' ]
}

@test "two runs on the same report write the same bytes" {
    "$DRIVER" run > /dev/null
    cp "$QG_OUT/result.json" "$WORK/first.json"
    "$DRIVER" run > /dev/null
    cmp "$WORK/first.json" "$QG_OUT/result.json"
}
