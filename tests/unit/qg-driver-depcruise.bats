#!/usr/bin/env bats
# drivers/depcruise.sh — metric = summary.violations of every severity; any exit code that comes
# with a JSON summary is measured, and a run that cruised no module is an error.
#
# A fake depcruise records its argv, prints $FAKE_OUT on stdout and exits $FAKE_RC.
# tests/fixtures/drivers/depcruise.json is dependency-cruiser 18.4.0's stdout on app.givore.com HEAD,
# cut to its first two modules and without summary.optionsUsed and summary.ruleSetUsed; its two
# violations are unchanged. The v1 `architecture` computation of app scripts/quality-metric.mjs reads
# 2 on it and on the uncut output: `node v1.mjs architecture <file>`, where v1.mjs holds that
# function's body verbatim (the test image has no node).

load guard-helpers

DRIVER=/code/drivers/depcruise.sh
FIX=/code/tests/fixtures/drivers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR QG_REPO QG_BASES QG_TARGET CLAUDECODE AI_AGENT
    TREE="$WORK/tree"; mkdir -p "$TREE/node_modules/.bin" "$WORK/out"
    fake_bin "$TREE/node_modules/.bin/depcruise"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=architecture QG_FILES=/dev/null
    export FAKE_OUT="$WORK/fake.out" FAKE_RC=0 FAKE_ARGV="$WORK/argv"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_bin() {  # a depcruise that records its argv, prints $FAKE_OUT and exits $FAKE_RC
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${FAKE_ARGV:-/dev/null}"' \
        '[ -r "${FAKE_OUT:-}" ] && cat "$FAKE_OUT"' 'exit "${FAKE_RC:-0}"' > "$1"
    chmod +x "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }

summary() {  # summary <totalCruised> <violation count> -> a depcruise report on $FAKE_OUT
    jq -n --argjson t "$1" --argjson n "$2" '{modules: [], summary: {violations: [range($n) | {type: "dependency",
        from: "utils/u\(.).ts", to: "api/a.ts", rule: {severity: "error", name: "utils-are-leaf"}}],
        error: $n, warn: 0, totalCruised: $t}}' > "$FAKE_OUT"
}

@test "describe is JSON naming depcruise with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = depcruise ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
    run "$DRIVER" explain depcruise.no-circular
    [[ "$output" == *'no-circular'* ]]
}

@test "the recorded app report at exit 0 equals v1 architecture: 2, warn-severity violations included" {
    cp "$FIX/depcruise.json" "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 2 ]
    [ "$(result .unit)" = violations ]
    [ "$(result '.findings[0].ruleId')" = depcruise.no-circular ]
    [ "$(result '.findings[0].file')" = api/core/client.ts ]
    [ "$(result '.findings[0].level')" = warning ]
    [[ "$(result '.findings[0].message')" == 'cycle api/core/client.ts -> api/core/retry.ts (cycle api/core/retry.ts -> '* ]]
}

@test "any exit code that comes with a JSON summary is measured" {
    summary 433 3
    local rc
    for rc in 0 1 3 255; do
        rm -f "$QG_OUT/result.json"
        FAKE_RC=$rc "$DRIVER" run > /dev/null
        [ "$(result .status)" = measured ] || { echo "exit $rc not measured"; return 1; }
        [ "$(result .metric)" = 3 ] || { echo "exit $rc metric $(result .metric)"; return 1; }
    done
}

@test "totalCruised 0 is status error with metric null, never 0" {
    summary 0 0
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'cruised no module'* ]]
}

@test "no JSON, empty stdout, or JSON without a summary is status error" {
    printf 'Error: Cannot find module .dependency-cruiser.cjs\n' > "$FAKE_OUT"
    FAKE_RC=1 "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'no JSON summary'* ]]
    : > "$FAKE_OUT"
    FAKE_RC=0 "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    printf '%s\n' '{"modules":[]}' > "$FAKE_OUT"
    FAKE_RC=0 "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "a summary whose violations is not a list, or a second JSON document, is status error" {
    printf '%s\n' '{"summary":{"totalCruised":4,"violations":{"a":1}}}' > "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    summary 433 1
    printf '%s\n' '{"summary":{"totalCruised":4,"violations":[]}}' >> "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "argv is --config .dependency-cruiser.cjs --output-type json .; config=, paths= and -- argv change it" {
    summary 433 0
    "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = '--config .dependency-cruiser.cjs --output-type json .' ]
    rm -f "$FAKE_ARGV"
    QG_ARGS='config=quality/dc.cjs paths=app,server -- --ts-pre-compilation-deps' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = '--config quality/dc.cjs --output-type json --ts-pre-compilation-deps app server' ]
}

@test "two runs write the same bytes, and permuted violations give the same metric and findings" {
    cp "$FIX/depcruise.json" "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    cp "$QG_OUT/result.json" "$WORK/first.json"
    "$DRIVER" run > /dev/null
    cmp "$WORK/first.json" "$QG_OUT/result.json"
    jq '.summary.violations |= reverse' "$FIX/depcruise.json" > "$FAKE_OUT"
    "$DRIVER" run > /dev/null
    cmp "$WORK/first.json" "$QG_OUT/result.json"
}
