#!/usr/bin/env bats
# bin/guard-baseline-growth.sh — per-entry growth of the tool baselines, never a net total.

load guard-helpers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    new_repo "$WORK/repo"
    mkdir -p app quality
    printf 'x\n' > app/A.php
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

growth() { bash /code/bin/guard-baseline-growth.sh "$@"; }

# neon <entry>... — a PHPStan baseline; each entry is "path@identifier@message@count".
neon() {
    local e path id msg count
    printf 'parameters:\n\tignoreErrors:\n'
    for e in "$@"; do
        IFS='@' read -r path id msg count <<<"$e"
        printf '\t\t-\n\t\t\tmessage: %s\n\t\t\tidentifier: %s\n\t\t\tcount: %s\n\t\t\tpath: %s\n\n' "$msg" "$id" "$count" "$path"
    done
}

A1="app/A.php@missingType.return@'#^Method A\\:\\:a\\(\\) has no return type\\.\$#'@1"
B1="app/B.php@argument.type@'#^Parameter \\\$param1 of foo expects int\\.\$#'@1"
B2="app/B.php@argument.type@'#^Parameter \\\$param2 of foo expects int\\.\$#'@1"
CC15="app/C.php@complexity.functionTooComplex@'#^Cognitive complexity for \"C\\:\\:run\\(\\)\" is (1[0-5]|[0-9]), keep it under 10\\.\$#'@1"
CC12="app/C.php@complexity.functionTooComplex@'#^Cognitive complexity for \"C\\:\\:run\\(\\)\" is (1[0-2]|[0-9]), keep it under 10\\.\$#'@1"

# The ratchet's exact output (recycling-api quality/bin/baseline-complexity-ratchet.php).
ratchet() { printf "app/C.php@complexity.functionLike@'#^Cognitive complexity for \"App\\\\\\\\C\\\\:\\\\:run\\\\(\\\\)\" is %s, keep it under 10\$#'@1" "$1"; }
RATCHET11="$(ratchet '(?:[0-9]|1[0-1])')"
RATCHET29="$(ratchet '(?:[0-9]|1[0-9]|2[0-9])')"
RATCHET1204="$(ratchet '(?:[0-9]|[1-9][0-9]|[1-9][0-9]{2}|1[0-1][0-9]{2}|120[0-4])')"
RATCHETANY="$(ratchet '.*')"

stage_neon() { neon "$@" > phpstan-baseline.neon; git add phpstan-baseline.neon; }

@test "PHPStan's empty baseline form is accepted; an entry after it is refused" {
    printf 'parameters:\n\tignoreErrors: []\n' > phpstan-baseline.neon
    commit_all base
    run growth
    [ "$status" -eq 0 ]
    [ "$output" = 0 ]
    printf 'parameters:\n\tignoreErrors: []\n\t\t-\n' > phpstan-baseline.neon
    git add phpstan-baseline.neon
    run growth
    [ "$status" -eq 2 ]
}

@test "one new entry counts 1; a subset counts 0" {
    neon "$A1" "$B1" > phpstan-baseline.neon
    commit_all base
    stage_neon "$A1" "$B1" "$B2"
    run growth
    [ "$output" = 1 ]
    stage_neon "$A1"
    run growth
    [ "$output" = 0 ]
}

@test "a fixed error does not pay for a new one: a swap counts 1" {
    neon "$A1" "$B1" > phpstan-baseline.neon
    commit_all base
    stage_neon "$A1" "$B2"
    run growth
    [ "$output" = 1 ]
    GUARD_LIST=1 run growth
    [[ "$output" == *'param2'* ]]
}

@test "a count rise is growth" {
    neon "$A1" > phpstan-baseline.neon
    commit_all base
    stage_neon "${A1%@1}@2"
    run growth
    [ "$output" = 1 ]
}

@test "a lowered complexity score counts 0; a raised one counts 1" {
    neon "$CC15" > phpstan-baseline.neon
    commit_all base
    stage_neon "$CC12"
    run growth
    [ "$output" = 0 ]
    neon "$CC12" > phpstan-baseline.neon
    commit_all lowered
    stage_neon "$CC15"
    run growth
    [ "$output" = 1 ]
    stage_neon "${CC12%@1}@2"
    run growth
    [ "$output" = 1 ]
}

@test "an entry that follows its renamed file counts 0" {
    printf '<?php\nclass B {}\n' > app/B.php
    neon "$B1" > phpstan-baseline.neon
    commit_all base
    git mv app/B.php app/Bee.php
    stage_neon "app/Bee.php@argument.type@'#^Parameter \\\$param1 of foo expects int\\.\$#'@1"
    run growth
    [ "$output" = 0 ]
}

@test "an empty base or an empty target counts 0" {
    commit_all 'no baseline yet'
    stage_neon "$A1"
    run growth
    [ "$output" = 0 ]
    neon "$A1" > phpstan-baseline.neon
    commit_all base
    git rm -q --cached phpstan-baseline.neon
    run growth
    [ "$output" = 0 ]
}

@test "growth against several parents is never higher than against one" {
    neon "$A1" > phpstan-baseline.neon
    commit_all base
    main="$(git symbolic-ref --short HEAD)"
    git checkout -q -b other
    neon "$A1" "$B1" > phpstan-baseline.neon
    commit_all upstream
    git checkout -q "$main"
    stage_neon "$A1" "$B1" "$B2"
    run growth --bases "$(git rev-parse HEAD)"
    [ "$output" = 2 ]
    run growth --bases "$(git rev-parse HEAD) $(git rev-parse other)"
    [ "$output" = 1 ]
    run growth --bases "$(git rev-parse other) $(git rev-parse HEAD) $(git rev-parse other)"
    [ "$output" = 1 ]
}

@test "a PHPMD baseline entry is (file, rule, method)" {
    printf '<?xml version="1.0"?>\n<phpmd-baseline>\n  <violation rule="PHPMD\\Rule\\Design\\TooManyMethods" file="app/A.php"/>\n</phpmd-baseline>\n' > quality/phpmd-baseline.xml
    commit_all base
    { printf '<?xml version="1.0"?>\n<phpmd-baseline>\n'
      printf '  <violation rule="PHPMD\\Rule\\Design\\TooManyMethods" file="app/A.php"/>\n'
      printf '  <violation rule="PHPMD\\Rule\\CleanCode\\ElseExpression" file="app/A.php" method="run"/>\n'
      printf '</phpmd-baseline>\n'; } > quality/phpmd-baseline.xml
    git add quality/phpmd-baseline.xml
    run growth --phpmd quality/phpmd-baseline.xml
    [ "$output" = 1 ]
}

@test "the ratchet's (?:...) form: raised counts 1, lowered counts 0, {n} and .* read as ranges" {
    neon "$RATCHET11" > phpstan-baseline.neon
    commit_all base
    stage_neon "$RATCHET29"
    run growth
    [ "$output" = 1 ]
    stage_neon "$RATCHET1204"
    run growth
    [ "$output" = 1 ]
    stage_neon "$RATCHETANY"
    run growth
    [ "$output" = 1 ]
    neon "$RATCHET29" > phpstan-baseline.neon
    commit_all raised
    stage_neon "$RATCHET11"
    run growth
    [ "$output" = 0 ]
}

@test "a string entry, an inline map or another neon key in the target is unmeasurable" {
    neon "$A1" > phpstan-baseline.neon
    commit_all base
    local extra
    for extra in $'\t\t- \'#.*#\'' $'\t\t- {message: \'#.*#\', path: app/D.php}' $'\texcludePaths:' $'\tlevel: 0' 'includes:'; do
        { neon "$A1"; printf '%s\n' "$extra"; } > phpstan-baseline.neon
        git add phpstan-baseline.neon
        run growth
        [ "$status" -eq 2 ]
        [[ "$output" == *'phpstan-baseline.neon line 9'* ]]
        [ -z "$(grep -x '[0-9][0-9]*' <<<"$output")" ]
    done
    stage_neon "${A1%@1}@"
    run growth
    [ "$status" -eq 2 ]
    [[ "$output" == *'count'* ]]
}

# long_neon <tail> — one entry whose message is a ''' block, the form PHPStan writes for
# a message with a newline.
long_neon() {
    printf 'parameters:\n\tignoreErrors:\n\t\t-\n'
    printf "\t\t\tmessage: '''\n\t\t\t\t#^Call to deprecated method get\\\\(\\\\):\n\t\t\t\t%s\$#\n\t\t\t'''\n" "$1"
    printf '\t\t\tidentifier: method.deprecated\n\t\t\tcount: 1\n\t\t\tpath: app/A.php\n'
}

@test "a multi-line message is one entry keyed by its whole text" {
    long_neon 'use input() instead' > phpstan-baseline.neon
    commit_all base
    long_neon 'use input() instead' > phpstan-baseline.neon
    git add phpstan-baseline.neon
    run growth
    [ "$status" -eq 0 ]
    [ "$output" = 0 ]
    long_neon 'use anything instead' > phpstan-baseline.neon
    git add phpstan-baseline.neon
    run growth
    [ "$output" = 1 ]
    printf "parameters:\n\tignoreErrors:\n\t\t-\n\t\t\tmessage: '''\n\t\t\t\tnever closed\n" > phpstan-baseline.neon
    git add phpstan-baseline.neon
    run growth
    [ "$status" -eq 2 ]
}

@test "a PHPMD baseline line the generator never writes is unmeasurable" {
    printf '<?xml version="1.0"?>\n<phpmd-baseline>\n  <violation rule="PHPMD\\Rule\\Design\\TooManyMethods" file="app/A.php"/>\n</phpmd-baseline>\n' > quality/phpmd-baseline.xml
    commit_all base
    local extra
    for extra in '  <violation rule="R" file="app/A.php" method="a" extra="x"/>' \
                 '  <violation file="app/A.php" rule="R"/>' '  <!-- note -->' '  <violation rule="R" file="app/B.php"></violation>'; do
        { printf '<?xml version="1.0"?>\n<phpmd-baseline>\n'; printf '%s\n' "$extra"; printf '</phpmd-baseline>\n'; } > quality/phpmd-baseline.xml
        git add quality/phpmd-baseline.xml
        run growth --phpmd quality/phpmd-baseline.xml
        [ "$status" -eq 2 ]
        [[ "$output" == *'quality/phpmd-baseline.xml line 3'* ]]
    done
}

@test "the generator's shape, a leading comment and blank lines included, staged against itself counts 0" {
    { printf '# generated\n'; neon "$A1" "$B1" "$CC15" "$RATCHET11"; } > phpstan-baseline.neon
    commit_all base
    git add phpstan-baseline.neon
    run growth
    [ "$status" -eq 0 ]
    [ "$output" = 0 ]
}
