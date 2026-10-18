#!/usr/bin/env bats
# drivers/composer-dependency-analyser.sh — metric = the packages under `Found <n> <metric>`,
# compared with the v1 cda parser and its #selector.
#
# A fake analyser prints $FAKE_OUT (the real recorded console output in tests/fixtures/drivers/,
# ANSI colours included, or an inline one) and exits $FAKE_RC.

load guard-helpers

DRIVER=/code/drivers/composer-dependency-analyser.sh
FIX=/code/tests/fixtures/drivers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT
    TREE="$WORK/tree"; mkdir -p "$TREE/vendor/bin" "$WORK/out"
    fake_bin "$TREE/vendor/bin/composer-dependency-analyser"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=cda-row QG_FILES=/dev/null
    export QG_TARGET=:index FAKE_OUT="$WORK/fake.out" FAKE_RC=1 FAKE_ARGV="$WORK/argv"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {  # an analyser that records its argv, prints $FAKE_OUT and exits $FAKE_RC
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${FAKE_ARGV:-/dev/null}"' \
        '[ -r "${FAKE_OUT:-}" ] && cat "$FAKE_OUT"' 'exit "${FAKE_RC:-0}"' > "$1"
    chmod +x "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }

@test "describe is JSON naming the driver with needs_tree true; explain prints text per class" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = composer-dependency-analyser ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
    run "$DRIVER" explain cda.unused
    [[ "$output" == *'Remove it'* ]]
}

@test "cda-shadow.txt with metric=shadow is 26 and equals the v1 cda parser" {
    cp "$FIX/cda-shadow.txt" "$FAKE_OUT"
    QG_ARGS=metric=shadow run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 26 ]
    [ "$(result .metric)" = "$(/code/lib/guard-parsers/cda.sh "$FAKE_OUT#shadow")" ]
    [ "$(result .unit)" = packages ]
}

@test "the default metric is shadow" {
    cp "$FIX/cda-shadow.txt" "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 26 ]
}

@test "metric=unused on the shadow-only output is 0, as the v1 parser says" {
    cp "$FIX/cda-shadow.txt" "$FAKE_OUT"
    QG_ARGS=metric=unused "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    [ "$(result .metric)" = "$(/code/lib/guard-parsers/cda.sh "$FAKE_OUT#unused")" ]
    [ "$(result '.findings | length')" = 0 ]
}

@test "No composer issues found at exit 0 is measured 0" {
    printf '\n\033[32mNo composer issues found\033[0m\n\n(scanned 10 files in 0.1 s)\n' > "$FAKE_OUT"
    FAKE_RC=0 "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    [ "$(result .metric)" = "$(/code/lib/guard-parsers/cda.sh "$FAKE_OUT")" ]
}

@test "cda-badconfig.txt (exit 1, no result line) is status error with metric null" {
    cp "$FIX/cda-badconfig.txt" "$FAKE_OUT"
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'no result line'* ]]
}

@test "exit 2 is status error even with a result line" {
    cp "$FIX/cda-shadow.txt" "$FAKE_OUT"
    FAKE_RC=2 "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ]
}

@test "ANSI-coloured and plain outputs give the same number and the same findings" {
    cp "$FIX/cda-shadow.txt" "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    cp "$QG_OUT/result.json" "$WORK/ansi.json"
    sed 's/\x1b\[[0-9;]*m//g' "$FIX/cda-shadow.txt" > "$FAKE_OUT"
    ! grep -q $'\x1b' "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = "$(jq -r .metric "$WORK/ansi.json")" ]
    [ "$(jq -c .findings "$QG_OUT/result.json")" = "$(jq -c .findings "$WORK/ansi.json")" ]
}

@test "shadow findings name each package with the file and line of its first use" {
    cp "$FIX/cda-shadow.txt" "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result '.findings | length')" = 26 ]
    [ "$(result '.findings[0].ruleId')" = cda.shadow ]
    [[ "$(result '.findings[0].message')" == 'dragonmantank/cron-expression (shadow): '* ]]
    [ "$(result '.findings[0].file')" = tests/Feature/Premium/EntitlementReconcileSweepTest.php ]
    [ "$(result '.findings[0].line')" = 249 ]
    [[ "$(result '.findings[25].message')" == 'zircote/swagger-php (shadow): '* ]]
    [ "$(result '.findings[25].file')" = app/Http/Resources/ImageResource.php ]
}

@test "unused findings name every package of the block, with no file or line" {
    # The analyser lists unused packages one per line with no usage line and one blank line after
    # the block.
    printf '%b' '\n\033[31mFound 2 unused dependencies!\033[0m\n' \
        '\033[37m(those are listed in composer.json, but no usage was found in scanned paths)\033[0m\n\n' \
        '  \xe2\x80\xa2 \033[33mlaravel/tinker\033[0m\n' '  \xe2\x80\xa2 \033[33mguzzlehttp/guzzle\033[0m\n\n' \
        '\033[37m(scanned\033[0m 10 \033[37mfiles in\033[0m 0.1 \033[37ms)\033[0m\n' > "$FAKE_OUT"
    QG_ARGS=metric=unused "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 2 ]
    [ "$(result .metric)" = "$(/code/lib/guard-parsers/cda.sh "$FAKE_OUT#unused")" ]
    [ "$(result '[.findings[].message] | join("|")')" = 'laravel/tinker (unused)|guzzlehttp/guzzle (unused)' ]
    [ "$(result '.findings[0].file')" = null ] && [ "$(result '.findings[0].line')" = null ]
}

@test "dev-in-prod and prod-only-in-dev read the tool's own headings; an unknown metric is status error" {
    # The analyser's console formatter prints these headings for the two classes.
    printf '%b' '\nFound 2 dev dependencies in production code!\n\n  \xe2\x80\xa2 a/one\n  \xe2\x80\xa2 a/two\n\n' \
        'Found 1 prod dependencies used only in dev paths!\n\n  \xe2\x80\xa2 b/one\n\n' > "$FAKE_OUT"
    QG_ARGS=metric=dev-in-prod "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 2 ] && [ "$(result '.findings | length')" = 2 ]
    QG_ARGS=metric=prod-only-in-dev "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 1 ]
    QG_ARGS=metric=shdow "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [[ "$(result .error)" == *'shdow'* ]]
}

@test "with QG_RUN_DIR, rows differing only in metric= call the analyser once" {
    mkdir -p "$WORK/run"
    cp "$FIX/cda-shadow.txt" "$FAKE_OUT"
    QG_RUN_DIR="$WORK/run" QG_ARGS=metric=shadow "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 26 ]
    QG_RUN_DIR="$WORK/run" QG_ARGS=metric=unused "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 0 ]
    [ "$(wc -l < "$FAKE_ARGV")" -eq 1 ]
}
