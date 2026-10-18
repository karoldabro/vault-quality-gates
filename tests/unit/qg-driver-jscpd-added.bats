#!/usr/bin/env bats
# drivers/jscpd-added.sh — metric = clone sides, each counted once, that lie in a changed file and
# cover a line the commit adds. The counting rule is recycling-api's
# quality/bin/jscpd-added.sh piped into bin/guard-added-lines.sh --checkstyle.
#
# The test image has no pnpm: a fake `pnpm` first on PATH records its argv and writes
# $FAKE_JSCPD as jscpd-report.json into the --output directory it is given.
#
# The repo: app/One.php has 30 committed lines and 10 staged added lines (31-40); app/Two.php and
# app/Three.php are committed and unchanged.

load guard-helpers

DRIVER=/code/drivers/jscpd-added.sh

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT
    export GUARD_LOCK_WAIT=5
    mkdir -p "$WORK/out" "$WORK/path"
    fake_pnpm "$WORK/path/pnpm"
    export PATH="$WORK/path:$PATH"
    export QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=dup-row QG_FILES=/dev/null
    export FAKE_JSCPD="$WORK/jscpd.json" FAKE_ARGV="$WORK/argv" FAKE_SEEN="$WORK/seen"
    gate_repo "$WORK/repo"
    lines 1 30 > app/One.php; lines 1 20 > app/Two.php; lines 1 20 > app/Three.php
    commit_all base
    export QG_REPO="$WORK/repo" QG_TREE="$WORK/repo" QG_TARGET=:index QG_BASES="$(git rev-parse HEAD)"
    lines 1 40 > app/One.php
    git add app/One.php
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

lines() { local i; for ((i = $1; i <= $2; i++)); do printf 'line %d\n' "$i"; done; }

fake_pnpm() {
    cat > "$1" <<'EOF'
#!/usr/bin/env bash
# The driver runs pnpm with an empty environment, so the fake finds its files beside itself.
w="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$*" >> "$w/argv"
out=''
while [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done
[ -n "$out" ] || exit 9
mkdir -p "$out" && cp "$w/jscpd.json" "$out/jscpd-report.json"
printf '%s|%s|%s\n' "$PWD" "$out" "$(sed -n 's/^registry=//p' .npmrc 2>/dev/null)" >> "$w/seen"
EOF
    chmod +x "$1"
}

clone() {  # clone <file> <start> <end> <file> <start> <end> — one duplicate of a jscpd report
    jq -n --arg a "$1" --argjson as "$2" --argjson ae "$3" --arg b "$4" --argjson bs "$5" --argjson be "$6" \
        '{format: "php", lines: ($ae - $as + 1), firstFile: {name: $a, start: $as, end: $ae}, secondFile: {name: $b, start: $bs, end: $be}}'
}

report() { jq -s '{duplicates: .}' > "$FAKE_JSCPD"; }  # stdin: clone objects

result() { jq -r "$1" "$QG_OUT/result.json"; }

@test "describe is JSON naming jscpd-added with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = jscpd-added ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
}

@test "no added line under paths= measures 0 and never calls pnpm" {
    git reset -q app/One.php && git checkout -q app/One.php
    printf 'notes\n' > docs/x.md; git add docs/x.md
    clone app/One.php 1 10 app/Two.php 1 10 | report
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ ! -e "$FAKE_ARGV" ]
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 0 ]
}

@test "added lines outside include= measure 0 and never call pnpm" {
    clone app/One.php 31 40 app/Two.php 1 10 | report
    QG_ARGS='include=\.js$' "$DRIVER" run > /dev/null
    [ ! -e "$FAKE_ARGV" ]
    [ "$(result .metric)" = 0 ]
    QG_ARGS='exclude=^app/One' "$DRIVER" run > /dev/null
    [ ! -e "$FAKE_ARGV" ]
    [ "$(result .metric)" = 0 ]
}

@test "a clone side that ends before the first added line counts 0" {
    clone app/One.php 10 30 app/Two.php 1 20 | report
    "$DRIVER" run > /dev/null
    [ -e "$FAKE_ARGV" ]
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 0 ]
}

@test "a clone side that starts on the first added line counts 1, placed on that line" {
    clone app/One.php 31 35 app/Two.php 1 5 | report
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings[0].file')" = app/One.php ]
    [ "$(result '.findings[0].line')" = 31 ]
    [ "$(result '.findings[0].ruleId')" = jscpd.duplicateBlock ]
    [[ "$(result '.findings[0].message')" == 'Lines 31-35 duplicate app/Two.php:1-5;'* ]]
}

@test "a side that straddles the first added line counts once, on the first added line inside it" {
    clone app/One.php 25 33 app/Two.php 1 9 | report
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings[0].line')" = 31 ]
}

@test "both sides of a clone on added lines count 2" {
    clone app/One.php 31 34 app/One.php 36 39 | report
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 2 ]
    [ "$(result '[.findings[].line] | join(",")')" = '31,36' ]
}

@test "a clone between unchanged files counts 0" {
    clone app/Two.php 1 10 app/Three.php 1 10 | report
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 0 ]
}

@test "a side reported twice is counted once; names relative to the scanned dir or the tree are the same file" {
    { clone One.php 31 35 Two.php 1 5; clone "$WORK/repo/app/One.php" 31 35 ./app/Three.php 1 5
      clone app/Two.php 1 10 app/Three.php 1 10; } | report
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings[0].file')" = app/One.php ]
}

@test "pnpm receives dlx jscpd@5.3.2 <tree>/app ... --absolute --reporters json --output <empty folder>/out" {
    clone app/One.php 31 35 app/Two.php 1 5 | report
    "$DRIVER" run > /dev/null
    local out; out="$(cut -d'|' -f2 "$FAKE_SEEN")"
    [ "$(cat "$FAKE_ARGV")" = "dlx jscpd@5.3.2 $WORK/repo/app --absolute --reporters json --output $out --silent --no-colors" ]
    rm -f "$FAKE_ARGV" "$FAKE_SEEN"
    QG_ARGS='version=4.0.0 min-lines=10 min-tokens=70 format=php ignore=**/Docs/** -- --exitCode 0' "$DRIVER" run > /dev/null
    out="$(cut -d'|' -f2 "$FAKE_SEEN")"
    [ "$(cat "$FAKE_ARGV")" = "dlx jscpd@4.0.0 $WORK/repo/app --min-lines 10 --min-tokens 70 --format php --ignore **/Docs/** --absolute --reporters json --output $out --silent --no-colors --exitCode 0" ]
}

@test "jscpd runs from an empty folder outside the tree, with the public registry, and the folder is removed" {
    clone app/One.php 31 35 app/Two.php 1 5 | report
    printf 'registry=https://evil.invalid/\n' > "$WORK/repo/.npmrc"
    "$DRIVER" run > /dev/null
    local cwd out reg
    IFS='|' read -r cwd out reg < "$FAKE_SEEN"
    [[ "$cwd" != "$WORK/repo"* ]] && [ "$out" = "$cwd/out" ]
    [ "$reg" = https://registry.npmjs.org/ ]
    [ ! -e "$cwd" ]
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 1 ]
}

@test "a jscpd that writes no report is status error, and the output dir is still removed" {
    printf '%s\n' '#!/usr/bin/env bash' 'w="$(cd "$(dirname "$0")/.." && pwd)"' 'printf "%s\n" "$*" >> "$w/argv"' 'pwd > "$w/seen"' 'exit 0' > "$WORK/path/pnpm"
    "$DRIVER" run > /dev/null
    [ -e "$FAKE_ARGV" ]
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [ ! -e "$(cat "$FAKE_SEEN")" ]
}

@test "a non-zero jscpd exit is status error" {
    clone app/One.php 31 35 app/Two.php 1 5 | report
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$WORK/path/pnpm"
    "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'exited 1'* ]]
}
