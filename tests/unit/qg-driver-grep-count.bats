#!/usr/bin/env bats
# drivers/grep-count.sh — files or lines an ERE matches under paths=, or lines a committed awk script
# prints, after exclude=. Plain temp trees: no tool is faked.
#
# The tree ($WORK/tree) holds lib/a.dart (2 TODO lines, one "foo bar"), lib/b.dart (1 TODO line),
# lib/a.g.dart (1 TODO line), lib/generated/l10n.dart (1 TODO line), lib/notes.txt (1 TODO line) and
# empty.txt. The config repo ($WORK/repo) holds the awk scripts, committed at QG_CONFIG_REV.

load guard-helpers

DRIVER=/code/drivers/grep-count.sh

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR QG_BASES CLAUDECODE AI_AGENT
    new_repo "$WORK/repo"
    mkdir -p quality
    printf '%s\n' '/TODO/ { print FILENAME ":" FNR ":" $0 }' > quality/todo.awk
    printf '%s\n' '{ print FILENAME ":" FNR }' > quality/every.awk
    printf '%s\n' '{ print FILENAME ":" FNR }' 'END { print "end:0" }' > quality/end.awk
    commit_all init
    TREE="$WORK/tree"
    mkdir -p "$TREE/lib/generated" "$WORK/out"
    printf 'a\n// TODO one\nfoo bar\nfoo\n// TODO two\n' > "$TREE/lib/a.dart"
    printf '// TODO b\nbar\n' > "$TREE/lib/b.dart"
    printf '// TODO gen\n' > "$TREE/lib/a.g.dart"
    printf '// TODO l10n\n' > "$TREE/lib/generated/l10n.dart"
    printf 'TODO txt\n' > "$TREE/lib/notes.txt"
    : > "$TREE/empty.txt"
    export QG_REPO="$WORK/repo" QG_TREE="$TREE" QG_TARGET=:index QG_CONFIG_REV="$(git rev-parse HEAD)"
    export QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=todo-row QG_FILES=/dev/null
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

result() { jq -r "$1" "$QG_OUT/result.json"; }
measure() { QG_ARGS="$1" "$DRIVER" run > /dev/null 2>&1 < /dev/null; }

@test "describe is JSON naming grep-count with needs_tree true; explain names the keys" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = grep-count ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [[ "$output" == *'paths (required)'* ]]
}

@test "a missing paths= is status error" {
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'paths='* ]]
}

@test "a missing path or an empty file in paths= is status error, never a measured 0" {
    measure 'paths=lib,nope -- TODO'
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'path nope is missing or empty'* ]]
    measure 'paths=./nope/ -- TODO'
    [[ "$(result .error)" == *'path nope is missing or empty'* ]]
    measure 'paths=empty.txt -- TODO'
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'path empty.txt is missing or empty'* ]]
}

@test "files mode, the default, counts each file with a match once, generated files included" {
    measure 'paths=lib -- TODO'
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 5 ]
    [ "$(result .unit)" = files ]
    [ "$(result '[.findings[].file] | sort | join(",")')" = 'lib/a.dart,lib/a.g.dart,lib/b.dart,lib/generated/l10n.dart,lib/notes.txt' ]
    [ "$(result '.findings[0].line')" = null ]
    [ "$(result '.findings[0].message')" = matched ]
    [ "$(result '.findings[0].ruleId')" = grep-count.todo-row ]
}

@test "count=lines counts matching lines and each finding carries file, line and text" {
    measure 'paths=lib count=lines -- TODO'
    [ "$(result .metric)" = 6 ]
    [ "$(result .unit)" = lines ]
    [ "$(result '[.findings[] | select(.file == "lib/a.dart") | "\(.line):\(.message)"] | join("|")')" = '2:// TODO one|5:// TODO two' ]
}

@test "count=lines over a single file still names the file in every finding" {
    measure 'paths=lib/a.dart count=lines -- TODO'
    [ "$(result .metric)" = 2 ]
    [ "$(result '[.findings[].file] | unique | join(",")')" = lib/a.dart ]
    [ "$(result '.findings[0].line')" = 2 ]
}

@test "paths= spelled lib, lib/ and ./lib give one count, and . finds the same files without a ./ prefix" {
    local p
    for p in lib lib/ ./lib; do
        rm -f "$QG_OUT/result.json"
        measure "paths=$p count=lines -- TODO"
        [ "$(result .metric)" = 6 ] || { echo "paths=$p gave $(result .metric)"; return 1; }
    done
    measure 'paths=. -- TODO'
    [ "$(result .metric)" = 5 ]
    [ "$(result '[.findings[].file | select(startswith("./"))] | length')" = 0 ]
    measure 'paths=. count=lines -- TODO'
    [ "$(result .metric)" = 6 ]
    [ "$(result '[.findings[].file] | unique | join(",")')" = 'lib/a.dart,lib/a.g.dart,lib/b.dart,lib/generated/l10n.dart,lib/notes.txt' ]
}

@test "paths=./ and paths=lib/ keep exclude= anchored on the tree-relative path in every mode" {
    local args
    for args in 'paths=./ exclude=^lib/(generated/|notes) -- TODO' 'paths=./ count=lines exclude=^lib/(generated/|notes) -- TODO' \
        'paths=./ awk=quality/todo.awk exclude=^lib/(generated/|notes)' 'paths=lib/ count=lines exclude=^lib/(generated/|notes) -- TODO' \
        'paths=lib/ awk=quality/todo.awk exclude=^lib/(generated/|notes)'; do
        rm -f "$QG_OUT/result.json"
        measure "$args"
        [ "$(result '[.findings[].file] | unique | join(",")')" = 'lib/a.dart,lib/a.g.dart,lib/b.dart' ] \
            || { echo "$args gave $(result '[.findings[].file] | unique | join(",")')"; return 1; }
    done
}

@test "the pattern after -- is taken whole, spaces included" {
    measure 'paths=lib count=lines -- foo bar'
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings[0].message')" = 'foo bar' ]
}

@test "name= keeps only files whose base name matches the glob" {
    measure 'paths=lib name=*.txt -- TODO'
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings[0].file')" = lib/notes.txt ]
}

@test "an anchored exclude= in lines mode equals the v1 grep -n | grep -vE \"<re>:\" filter" {
    local v1
    v1="$(cd "$TREE" && grep -rn -E 'TODO' lib | grep -vE '\.g\.dart:' | grep -vE '^lib/generated/' | wc -l | tr -d ' ')"
    [ "$v1" = 4 ]
    measure 'paths=lib count=lines exclude=\.g\.dart$|^lib/generated/ -- TODO'
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = "$v1" ]
}

@test "exclude= matches the tree-relative path in files mode, also when the path searched is ." {
    measure 'paths=. exclude=^lib/generated/|\.g\.dart$ -- TODO'
    [ "$(result .metric)" = 3 ]
    [ "$(result '[.findings[].file] | sort | join(",")')" = 'lib/a.dart,lib/b.dart,lib/notes.txt' ]
}

@test "with no pattern and no awk= files and lines modes are status error" {
    measure 'paths=lib'
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'needs a pattern'* ]]
    measure 'paths=lib count=lines'
    [ "$(result .status)" = error ]
}

@test "an unknown count= is status error" {
    measure 'paths=lib count=words -- TODO'
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'count=words'* ]]
}

@test "a pattern grep rejects (exit 2) is status error, never a measured 0" {
    measure 'paths=lib -- ('
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'grep exited 2'* ]]
}

@test "awk= counts the lines the committed script prints, with file and line in each finding" {
    measure 'paths=lib awk=quality/todo.awk'
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 6 ]
    [ "$(result .unit)" = lines ]
    [ "$(result '[.findings[] | select(.file == "lib/b.dart") | "\(.line):\(.message)"] | join("|")')" = '1:// TODO b' ]
}

@test "exclude= and name= apply in awk mode" {
    measure 'paths=./lib/ awk=quality/todo.awk name=*.dart exclude=\.g\.dart$|^lib/generated/'
    [ "$(result .metric)" = 3 ]
    [ "$(result '[.findings[].file] | unique | join(",")')" = 'lib/a.dart,lib/b.dart' ]
}

@test "awk= with no file left never reads the driver's stdin and measures 0" {
    printf 'stdin line 1\nstdin line 2\n' > "$WORK/stdin"
    QG_ARGS='paths=lib awk=quality/every.awk name=*.nothing' "$DRIVER" run > /dev/null 2>&1 < "$WORK/stdin"
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    QG_ARGS='paths=lib awk=quality/every.awk exclude=.' "$DRIVER" run > /dev/null 2>&1 < "$WORK/stdin"
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
}

@test "awk= with no file left never runs awk at all: an END block prints nothing" {
    measure 'paths=lib awk=quality/end.awk name=*.nothing'
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    measure 'paths=lib/b.dart awk=quality/end.awk'
    [ "$(result .metric)" = 3 ]
}

@test "the awk script is read at QG_CONFIG_REV: an uncommitted edit and a later commit change nothing" {
    printf '%s\n' '{ print FILENAME ":" FNR }' > "$WORK/repo/quality/todo.awk"
    measure 'paths=lib awk=quality/todo.awk'
    [ "$(result .metric)" = 6 ]
    ( cd "$WORK/repo" && commit_all 'loosen' )
    measure 'paths=lib awk=quality/todo.awk'
    [ "$(result .metric)" = 6 ]
}

@test "an awk script not committed at the config revision is status error" {
    printf '%s\n' '{ print }' > "$WORK/repo/quality/new.awk"
    measure 'paths=lib awk=quality/new.awk'
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'not committed at the config revision'* ]]
}

@test "an awk script that fails is status error" {
    printf '%s\n' 'BEGIN { exit 2 }' > "$WORK/repo/quality/bad.awk"
    ( cd "$WORK/repo" && commit_all bad )
    QG_CONFIG_REV="$(git -C "$WORK/repo" rev-parse HEAD)" measure 'paths=lib awk=quality/bad.awk'
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'awk -f quality/bad.awk failed'* ]]
}

@test "the metric counts every hit while findings stop at 200" {
    local i
    for ((i = 0; i < 250; i++)); do printf 'TODO %d\n' "$i"; done > "$TREE/lib/many.txt"
    measure 'paths=lib/many.txt count=lines -- TODO'
    [ "$(result .metric)" = 250 ]
    [ "$(result '.findings | length')" = 200 ]
}
