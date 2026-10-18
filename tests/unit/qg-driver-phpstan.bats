#!/usr/bin/env bats
# drivers/phpstan.sh — the worked example of vault/architecture/qg-driver-contract.md.
#
# A fake `vendor/bin/phpstan` prints the JSON in $FAKE_JSON and exits $FAKE_RC, so each output
# shape PHPStan produces is fed through the driver and compared with the v1 phpstan-all parser.

load guard-helpers

DRIVER=/code/drivers/phpstan.sh
V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS CLAUDECODE AI_AGENT QG_SKIP_REASON
    export GUARD_LOCK_WAIT=5
    TREE="$WORK/tree"; mkdir -p "$TREE/vendor/bin" "$WORK/out"
    fake_bin "$TREE/vendor/bin/phpstan"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=phpstan-new QG_FILES=/dev/null
    export FAKE_JSON="$WORK/fake.json" FAKE_RC=0
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {  # a phpstan that prints $FAKE_JSON (when set and present) and exits $FAKE_RC
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${FAKE_ARGV:-/dev/null}"' \
        '[ -r "${FAKE_JSON:-}" ] && cat "$FAKE_JSON"' 'echo "phpstan noise on stderr" >&2' 'exit "${FAKE_RC:-0}"' > "$1"
    chmod +x "$1"
}

metric() { jq -r '.metric' "$QG_OUT/result.json"; }
parser_value() { /code/lib/guard-parsers/phpstan-all.sh "$FAKE_JSON" 0; }

@test "describe is JSON naming the driver, its needs and needs_tree" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = phpstan ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    [ "$(jq -r '.requires | type' <<<"$output")" = array ]
}

@test "explain prints text, and a rule-specific text for phpstan.fileless" {
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
    run "$DRIVER" explain phpstan.fileless
    [[ "$output" == *'no longer matches'* ]]
}

@test "metric equals the phpstan-all parser for 0, N, file-less only, files only and both" {
    local j
    for j in '{"totals":{"errors":0,"file_errors":0},"files":[],"errors":[]}' \
             '{"totals":{"errors":0,"file_errors":3},"files":{"a.php":{"errors":3,"messages":[{"message":"m1","line":1,"identifier":"x.y"},{"message":"m2","line":2},{"message":"m3","line":3}]}},"errors":[]}' \
             '{"totals":{"errors":1,"file_errors":0},"files":[],"errors":["Ignored error pattern #x# was not matched in reported errors."]}' \
             '{"totals":{"errors":2,"file_errors":1},"files":{"b.php":{"errors":1,"messages":[{"message":"m","line":9,"identifier":"r.s"}]}},"errors":["e1","e2"]}'; do
        printf '%s' "$j" > "$FAKE_JSON"
        rm -f "$QG_OUT/result.json"
        "$DRIVER" run > /dev/null
        [ "$(jq -r '.status' "$QG_OUT/result.json")" = measured ]
        [ "$(metric)" = "$(parser_value)" ] || { echo "driver $(metric) parser $(parser_value) for $j"; return 1; }
    done
}

@test "file-less errors become findings with ruleId phpstan.fileless and no file" {
    printf '%s' '{"totals":{"errors":1,"file_errors":0},"files":[],"errors":["Ignored error pattern #x# was not matched in reported errors."]}' > "$FAKE_JSON"
    FAKE_RC=1 "$DRIVER" run > /dev/null
    [ "$(jq -r '.findings[0].ruleId' "$QG_OUT/result.json")" = phpstan.fileless ]
    [ "$(jq -r '.findings[0].file' "$QG_OUT/result.json")" = null ]
    [[ "$(jq -r '.findings[0].message' "$QG_OUT/result.json")" == *'was not matched'* ]]
}

@test "a crash with no JSON, or an exit above 1, is status error with a reason, never metric 0" {
    rm -f "$FAKE_JSON"
    FAKE_RC=255 run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(jq -r '.status' "$QG_OUT/result.json")" = error ]
    [ "$(metric)" = null ]
    [[ "$(jq -r '.error' "$QG_OUT/result.json")" == *'exited 255'* ]]
    printf '%s' '{"totals":{"errors":0,"file_errors":0},"files":[],"errors":[]}' > "$FAKE_JSON"
    FAKE_RC=2 "$DRIVER" run > /dev/null
    [ "$(jq -r '.status' "$QG_OUT/result.json")" = error ]
}

@test "a runner is called as <runner> <tree> <cache> <bin> analyse ..., with extra argv after --" {
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s|" "$@" > "$RUNNER_LOG"' 'tree="$1"; shift 2; cd "$tree" && exec "$@"' > "$WORK/runner"
    chmod +x "$WORK/runner"
    printf '%s' '{"totals":{"errors":0,"file_errors":0},"files":[],"errors":[]}' > "$FAKE_JSON"
    RUNNER_LOG="$WORK/runner.log" QG_RUNNER="$WORK/runner" QG_ARGS='runner=quality/bin/in-tree.sh -- --memory-limit=1G' "$DRIVER" run > /dev/null
    [ "$(cat "$WORK/runner.log")" = "${TREE}|${WORK}/cache|vendor/bin/phpstan|analyse|--no-progress|--error-format=json|--memory-limit=1G|" ]
    [ "$(metric)" = 0 ]
}

@test "files=changed analyses only changed .php files, and measures 0 without calling phpstan when none" {
    printf 'docs/a.md\0app/B.php\0app/Gone.php\0' > "$WORK/files"
    mkdir -p "$TREE/app"; : > "$TREE/app/B.php"
    printf '%s' '{"totals":{"errors":0,"file_errors":0},"files":[],"errors":[]}' > "$FAKE_JSON"
    FAKE_ARGV="$WORK/argv" QG_FILES="$WORK/files" QG_ARGS='files=changed' "$DRIVER" run > /dev/null
    [ "$(cat "$WORK/argv")" = 'analyse --no-progress --error-format=json app/B.php' ]
    printf 'docs/a.md\0' > "$WORK/files"
    rm -f "$WORK/argv"
    FAKE_ARGV="$WORK/argv" QG_FILES="$WORK/files" QG_ARGS='files=changed' "$DRIVER" run > /dev/null
    [ ! -e "$WORK/argv" ]
    [ "$(metric)" = 0 ]
}

@test "through the engine: a file-less-only failure is refused with its message, and the runner comes from HEAD" {
    gate_repo "$WORK/repo"
    mkdir -p vendor/bin quality/bin
    fake_bin vendor/bin/phpstan
    printf '%s\n' '#!/usr/bin/env bash' 'tree="$1"; shift 2; cd "$tree" && exec "$@"' > quality/bin/in-tree.sh
    chmod +x quality/bin/in-tree.sh
    { printf '%s\n' "$V2_HEADER"
      printf 'phpstan-new\tcommit\tdiff\tphpstan\trunner=quality/bin/in-tree.sh\tdown\t0\trefuse\tnew PHPStan errors break type safety\n'
    } > quality/checks.tsv
    commit_all v2
    # A working-tree runner that would pass everything must never run.
    printf '%s\n' '#!/usr/bin/env bash' 'echo "{\"totals\":{\"errors\":0,\"file_errors\":0}}"' > quality/bin/in-tree.sh
    printf '%s' '{"totals":{"errors":1,"file_errors":0},"files":[],"errors":["Ignored error pattern #x# was not matched in reported errors."]}' > "$FAKE_JSON"
    printf 'x\n' > app/b.php
    git add app/b.php
    FAKE_RC=1 run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'phpstan-new'*'phpstan.fileless'*'was not matched'* ]]
}
