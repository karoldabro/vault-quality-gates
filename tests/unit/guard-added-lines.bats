#!/usr/bin/env bats
# bin/guard-added-lines.sh — which lines a commit adds, and the findings that sit on them.

load guard-helpers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    new_repo "$WORK/repo"
    mkdir -p app
    seq 1 40 | sed 's/^/legacy line /' > app/Legacy.php
    commit_all init
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

added() { bash /code/bin/guard-added-lines.sh "$@"; }

# checkstyle <file> <line>... — a report with one error per given line of the file.
checkstyle() {
    local file="$1" line; shift
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<checkstyle version="3.7.2">\n<file name="%s">\n' "$file"
    for line in "$@"; do
        printf ' <error line="%s" column="1" severity="error" message="Found &quot;x&quot;" source="Squiz.PHP.CommentedOutCode.Found"/>\n' "$line"
    done
    printf '</file>\n</checkstyle>\n'
}

@test "an inserted line is added; the legacy lines below it are not" {
    sed -i '10i new code' app/Legacy.php
    git add app/Legacy.php
    run added --added
    [ "$output" = "$(printf 'app/Legacy.php\t10\tnew code')" ]
    checkstyle app/Legacy.php 10 11 30 > "$WORK/cs.xml"
    run added --checkstyle "$WORK/cs.xml"
    [ "$output" = 1 ]
}

@test "a checkstyle report with /app/-prefixed paths maps onto the repo path" {
    sed -i '5i new code' app/Legacy.php
    git add app/Legacy.php
    checkstyle /app/app/Legacy.php 5 6 > "$WORK/cs.xml"
    run added --checkstyle "$WORK/cs.xml"
    [ "$output" = 1 ]
}

@test "a renamed file counts only its changed lines" {
    git mv app/Legacy.php app/Moved.php
    sed -i '20s/.*/changed line/' app/Moved.php
    git add app/Moved.php
    checkstyle app/Moved.php 1 2 20 > "$WORK/cs.xml"
    run added --checkstyle "$WORK/cs.xml"
    [ "$output" = 1 ]
}

@test "a low-similarity rename does not count its legacy lines" {
    git mv app/Legacy.php app/Rewritten.php
    # 18 of 40 lines rewritten: git scores it 42% similar, below its default 50%.
    sed -i '1,18s/.*/rewritten &/' app/Rewritten.php
    git add app/Rewritten.php
    checkstyle app/Rewritten.php 30 35 > "$WORK/cs.xml"
    run added --checkstyle "$WORK/cs.xml"
    [ "$output" = 0 ]
}

@test "fixing a missing final newline adds nothing" {
    printf 'a\nb\nlast' > app/NoEol.php
    commit_all 'no final newline'
    printf 'a\nb\nlast\n' > app/NoEol.php
    git add app/NoEol.php
    run added --added
    [ -z "$output" ]
    run added --grep 'last'
    [ "$output" = 0 ]
}

@test "a moved suppression counts 1" {
    sed -i '3i // @phpstan-ignore-next-line' app/Legacy.php
    commit_all 'legacy suppression'
    sed -i '3d' app/Legacy.php
    sed -i '30i // @phpstan-ignore-next-line' app/Legacy.php
    git add app/Legacy.php
    run added --grep '@phpstan-ignore'
    [ "$output" = 1 ]
    GUARD_LIST=1 run added --grep '@phpstan-ignore'
    [ "$output" = 'app/Legacy.php:30 // @phpstan-ignore-next-line' ]
}

@test "suppression text in markdown or in a rule fixture counts 0" {
    mkdir -p docs tests/PHPStan/Rules/Fixtures/Rule
    printf 'use @phpstan-ignore sparingly\n' > docs/rules.md
    printf '<?php // @phpstan-ignore-line\n' > tests/PHPStan/Rules/Fixtures/Rule/Bad.php
    git add docs/rules.md tests/PHPStan/Rules/Fixtures/Rule/Bad.php
    run added --grep '@phpstan-ignore|@SuppressWarnings'
    [ "$output" = 0 ]
    printf '<?php // @SuppressWarnings(PHPMD)\n' > app/New.php
    git add app/New.php
    run added --grep '@phpstan-ignore|@SuppressWarnings'
    [ "$output" = 1 ]
}

@test "a commit target measures that commit against the given base" {
    sed -i '1i // @phpstan-ignore-line' app/Legacy.php
    commit_all suppression
    run added --grep '@phpstan-ignore' --target HEAD --bases "$(git rev-parse HEAD~1)"
    [ "$output" = 1 ]
    run added --grep '@phpstan-ignore' --target HEAD --bases "$(git rev-parse HEAD)"
    [ "$output" = 0 ]
}

@test "a path git C-quotes (a quote, a backslash, a tab) still counts; a tab prints as a space" {
    for name in 'app/a"b.php' 'app/c\d.php' "$(printf 'app/e\tf.php')"; do
        printf '<?php // @phpstan-ignore-line\n' > "$name"
        git add -- "$name"
    done
    run added --grep '@phpstan-ignore'
    [ "$output" = 3 ]
    GUARD_LIST=1 run added --grep '@phpstan-ignore'
    [[ "$output" == *'app/a"b.php:1 '* ]]
    [[ "$output" == *'app/c\d.php:1 '* ]]
    [[ "$output" == *'app/e f.php:1 '* ]]
}

@test "an unreadable report or a missing mode exits 2" {
    run added --checkstyle "$WORK/none.xml"
    [ "$status" -eq 2 ]
    run added
    [ "$status" -eq 2 ]
}
