#!/usr/bin/env bats
# bin/guard-report-errors.sh — the refusal text a committing agent reads.

load guard-helpers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    new_repo "$WORK/repo"
    mkdir -p app tests/app
    seq 1 20 | sed 's/^/legacy /' > app/Legacy.php
    write_rules $'swallowed-exception\tcustom\tSwallowedExceptionRule\tgivore.swallowedException' \
                $'commented-out-code\tphpcs\tSquiz.PHP.CommentedOutCode\tSquiz.PHP.CommentedOutCode' \
                $'too-long-method\tphpmd\tExcessiveMethodLength\tExcessiveMethodLength'
    write_checks \
        $'phpstan-new\tcommit\tdiff\ttrue\tphpstan-all\t{{tree}}/phpstan.json\tdown\t0\trefuse' \
        $'phpmd-new\tcommit\tdiff\ttrue\tphpmd\t{{tree}}/phpmd.json\tdown\t0\trefuse' \
        $'phpcs-new\tcommit\tdiff\t{{guard}}/guard-added-lines.sh --checkstyle {{tree}}/phpcs.xml\t-\t{{tree}}/phpcs.xml\tdown\t0\trefuse' \
        "$SUPPRESS_ROW" "$GROWTH_ROW" "$PROTECT_ROW"
    printf 'guard_protected_paths: quality\n' > VAULT.md
    commit_all init
    TREE="$WORK/tree"
    mkdir -p "$TREE"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

report() { bash /code/bin/guard-report-errors.sh --tree "$TREE" --map - "$@"; }

phpstan_json() {
    cat > "$TREE/phpstan.json" <<'JSON'
{"totals":{"errors":1,"file_errors":3},
 "files":{
  "/app/app/New.php":{"errors":2,"messages":[
    {"message":"Catch swallows the exception.","line":7,"ignorable":true,"identifier":"givore.swallowedException"},
    {"message":"Unknown thing App\\Foo.","line":9,"ignorable":true,"identifier":"class.notFound"}]},
  "/app/tests/app/Foo.php":{"errors":1,"messages":[
    {"message":"Catch swallows the exception.","line":3,"ignorable":true,"identifier":"givore.swallowedException"}]}},
 "errors":["Internal error: the container could not boot"]}
JSON
}

@test "PHPStan: one line per error, file-less included, line count equals the metric" {
    phpstan_json
    run report --rows phpstan-new
    [ "$status" -eq 0 ]
    [ "$(wc -l <<<"$output")" -eq "$(bash /code/lib/guard-parsers/phpstan-all.sh "$TREE/phpstan.json" 0)" ]
    [[ "$output" == *'phpstan-new app/New.php:7 givore.swallowedException Catch swallows the exception. → quality/RULES.md "### swallowed-exception"'* ]]
    [[ "$output" == *'phpstan-new (no file) Internal error: the container could not boot'* ]]
    [[ "$output" == *'Unknown thing App\Foo.'* ]]
}

@test "a leading /app/ is stripped once: /app/tests/app/Foo.php prints tests/app/Foo.php" {
    phpstan_json
    run report --rows phpstan-new
    [[ "$output" == *'phpstan-new tests/app/Foo.php:3 '* ]]
}

@test "every printed path exists in the staged tree, /app/tests/app/Foo.php included" {
    printf '<?php\n' > app/New.php
    printf '<?php\n' > tests/app/Foo.php
    git add app/New.php tests/app/Foo.php
    phpstan_json
    run report --rows phpstan-new
    [ "$status" -eq 0 ]
    checked=0
    while read -r _ loc _; do
        [ "$loc" != '(no' ] || continue
        git cat-file -e ":${loc%:*}" || { echo "not staged: ${loc%:*}"; return 1; }
        checked=$((checked + 1))
    done <<<"$output"
    [ "$checked" -eq 3 ]
}

@test "an identifier with no map row prints without a pointer" {
    phpstan_json
    run report --rows phpstan-new
    line="$(grep 'class.notFound' <<<"$output")"
    [[ "$line" != *'RULES.md'* ]]
}

@test "an error in a baselined file names the added lines; an unmatched ignore names the regeneration" {
    printf 'parameters:\n\tignoreErrors:\n\t\t-\n\t\t\tmessage: x\n\t\t\tcount: 1\n\t\t\tpath: app/Legacy.php\n' > phpstan-baseline.neon
    commit_all baseline
    sed -i '5i new one' app/Legacy.php
    sed -i '6i new two' app/Legacy.php
    git add app/Legacy.php
    cat > "$TREE/phpstan.json" <<'JSON'
{"totals":{"errors":1,"file_errors":1},
 "files":{"/app/app/Legacy.php":{"errors":1,"messages":[{"message":"Swallowed.","line":2,"identifier":"givore.swallowedException"}]}},
 "errors":["Ignored error pattern #^x$# in path /app/app/Gone.php was not matched in reported errors."]}
JSON
    run report --rows phpstan-new
    [[ "$output" == *'app/Legacy.php:2 givore.swallowedException Swallowed. (baseline count exceeded; your added lines are 5-6)'* ]]
    [[ "$output" == *'(run composer stan:baseline)'* ]]
}

@test "PHPMD: one line per violation, mapped by rule name" {
    cat > "$TREE/phpmd.json" <<'JSON'
{"version":"2.15.0","files":[{"file":"/app/app/New.php","violations":[
  {"beginLine":12,"endLine":99,"rule":"ExcessiveMethodLength","description":"The method run() has 88 lines of code."}]}]}
JSON
    run report --rows phpmd-new
    [ "$output" = 'phpmd-new app/New.php:12 ExcessiveMethodLength The method run() has 88 lines of code. → quality/RULES.md "### too-long-method"' ]
}

@test "checkstyle: a legacy hit is not printed; a sniff code resolves by prefix" {
    sed -i '3i // $old = code();' app/Legacy.php
    git add app/Legacy.php
    cat > "$TREE/phpcs.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<checkstyle version="3.7.2">
<file name="/app/app/Legacy.php">
 <error line="3" column="1" severity="warning" message="This comment is 60% valid code" source="Squiz.PHP.CommentedOutCode.Found"/>
 <error line="15" column="1" severity="warning" message="Legacy hit" source="Squiz.PHP.CommentedOutCode.Found"/>
</file>
</checkstyle>
XML
    run report --rows phpcs-new
    [ "$output" = 'phpcs-new app/Legacy.php:3 Squiz.PHP.CommentedOutCode.Found This comment is 60% valid code → quality/RULES.md "### commented-out-code"' ]
    [ "$(wc -l <<<"$output")" -eq "$(bash /code/bin/guard-added-lines.sh --checkstyle "$TREE/phpcs.xml")" ]
}

@test "the three gate rows print their fixed actions" {
    printf 'x\n// @phpstan-ignore-next-line\n' > app/S.php
    printf 'loosened\n' > quality/extra.tsv
    printf 'parameters:\n\tignoreErrors:\n\t\t-\n\t\t\tmessage: y\n\t\t\tcount: 1\n\t\t\tpath: app/S.php\n' > phpstan-baseline.neon
    git add app/S.php quality/extra.tsv
    run report --rows 'suppressions-added gate-config-touched baseline-growth'
    [[ "$output" == *'suppressions-added app/S.php:2 // @phpstan-ignore-next-line → remove the suppression and fix the code'* ]]
    [[ "$output" == *'gate-config-touched quality/extra.tsv → stop: a human commits this with QG_SKIP_REASON'* ]]
    [[ "$output" != *'baseline-growth'* ]]
    git add phpstan-baseline.neon
    commit_all 'baseline without the entry first'
    printf 'parameters:\n\tignoreErrors:\n\t\t-\n\t\t\tmessage: y\n\t\t\tcount: 2\n\t\t\tpath: app/S.php\n' > phpstan-baseline.neon
    git add phpstan-baseline.neon
    run report --rows baseline-growth
    [ "$output" = 'baseline-growth app/S.php - y (phpstan-baseline.neon) → fix the code, do not regenerate the baseline to hide it' ]
}

@test "a malformed map exits 2; a row with no readable artifact prints nothing" {
    printf 'id\ttool\n' > "$WORK/bad.tsv"
    run bash /code/bin/guard-report-errors.sh --rows phpstan-new --tree "$TREE" --map "$WORK/bad.tsv"
    [ "$status" -eq 2 ]
    run report --rows phpstan-new
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
