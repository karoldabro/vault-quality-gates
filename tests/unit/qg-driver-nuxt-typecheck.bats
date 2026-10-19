#!/usr/bin/env bats
# drivers/nuxt-typecheck.sh — metric = occurrences of `error TS<code>` over stdout and stderr, or
# with lines=added the parsed errors on lines the commit adds.
#
# A fake tool records its argv, prints $FAKE_STDOUT and $FAKE_STDERR and exits $FAKE_RC.
#
# The recordings are real output in a copy of app.givore.com HEAD (`git archive`, the live
# node_modules linked, .nuxt copied) with three type errors seeded at composables/useReferrals.ts
# 74-75 and pages/join.vue 12; the copy's folder is replaced by the live checkout's in the .err files:
#   nuxt-typecheck-app.{out,err}   node node_modules/nuxt/bin/nuxt.mjs typecheck      exit 1
#   vue-tsc-app.{out,err}          node node_modules/vue-tsc/bin/vue-tsc.js -b --noEmit --pretty false   exit 2
# Both print 45 `error TS` lines, one occurrence each. The v1 numbers, each from the v1 script run
# against a fake tool replaying the recording:
#   app  node scripts/quality-metric.mjs typecheck (nuxt)                               45
#   dash bash quality/bin/metric.sh typecheck (nuxt)                                    45
#   app  quality/bin/commit-check.sh typecheck (vue-tsc) + guard-added-lines.sh --checkstyle   3
#   dash quality/bin/tree-report.sh typecheck (nuxt) + guard-added-lines.sh --checkstyle       3

load guard-helpers

DRIVER=/code/drivers/nuxt-typecheck.sh
FIX=/code/tests/fixtures/drivers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR QG_REPO QG_BASES QG_TARGET CLAUDECODE AI_AGENT
    export GUARD_LOCK_WAIT=5
    TREE="$WORK/tree"; mkdir -p "$TREE/node_modules/.bin" "$WORK/out"
    fake_tool "$TREE/node_modules/.bin/nuxt"
    fake_tool "$TREE/node_modules/.bin/vue-tsc"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=typecheck-row QG_FILES=/dev/null
    export FAKE_STDOUT="$FIX/nuxt-typecheck-app.out" FAKE_STDERR="$FIX/nuxt-typecheck-app.err" FAKE_RC=1
    export FAKE_ARGV="$WORK/argv"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_tool() {  # a tool that records "<name> <argv>", prints $FAKE_STDOUT and $FAKE_STDERR, exits $FAKE_RC
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s %s\n" "$(basename "$0")" "$*" >> "${FAKE_ARGV:-/dev/null}"' \
        '[ -r "${FAKE_STDOUT:-}" ] && cat "$FAKE_STDOUT"' '[ -r "${FAKE_STDERR:-}" ] && cat "$FAKE_STDERR" >&2' \
        'exit "${FAKE_RC:-0}"' > "$1"
    chmod +x "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }

lines() { local i; for ((i = 1; i <= $2; i++)); do printf 'line %d\n' "$i"; done > "$1"; }
change() { local f="$1" l; shift; for l in "$@"; do sed -i "${l}s/.*/changed ${l}/" "$f"; done; }

# commit_repo — QG_TREE becomes a repo whose staged change adds composables/useReferrals.ts 74-75
# and pages/join.vue 12, the three seeded errors of the recordings.
commit_repo() {
    new_repo "$WORK/repo"
    mkdir -p composables pages
    lines composables/useReferrals.ts 80; lines pages/join.vue 20
    commit_all base
    export QG_REPO="$WORK/repo" QG_TREE="$WORK/repo" QG_TARGET=:index QG_BASES="$(git rev-parse HEAD)"
    change composables/useReferrals.ts 74 75; change pages/join.vue 12
    git add -A
    printf '%s\0' composables/useReferrals.ts pages/join.vue > "$WORK/files"
    export QG_FILES="$WORK/files"
    mkdir -p node_modules/.bin
    fake_tool node_modules/.bin/nuxt; fake_tool node_modules/.bin/vue-tsc
}

@test "describe is JSON naming nuxt-typecheck with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = nuxt-typecheck ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
    run "$DRIVER" explain TS2322
    [[ "$output" == *'TS2322'* ]]
}

@test "the recorded nuxt typecheck output reads 45, as quality-metric.mjs and metric.sh typecheck" {
    "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 45 ]
    [ "$(cat "$FAKE_STDOUT" "$FAKE_STDERR" | grep -cE 'error TS[0-9]+')" = 45 ]
    [ "$(result '.findings | length')" = 45 ]
}

@test "findings carry the TS code, tree-relative file, line and message" {
    "$DRIVER" run > /dev/null
    [ "$(result '.findings[] | select(.file == "pages/join.vue") | "\(.ruleId) \(.line) \(.level) \(.message)"')" = \
        "TS2322 12 error Type 'string' is not assignable to type 'number'." ]
}

@test "the default argv is typecheck; any -- argv replaces it" {
    "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = 'nuxt typecheck' ]
    rm -f "$FAKE_ARGV"
    QG_ARGS='bin=node_modules/.bin/vue-tsc -- -b --noEmit --pretty false' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = 'vue-tsc -b --noEmit --pretty false' ]
}

@test "occurrences are counted over both streams, two on one line counting two" {
    printf 'a.ts(1,1): error TS2322: x\nb.ts(2,1): error TS2345: y; see error TS2322 too\n' > "$WORK/o"
    printf 'c.ts(3,1): error TS1005: z\n' > "$WORK/e"
    FAKE_STDOUT="$WORK/o" FAKE_STDERR="$WORK/e" "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 4 ]
    [ "$(result '.findings | length')" = 3 ]
}

@test "exit 0 with no error TS reads 0" {
    printf 'Nuxt typecheck: no errors\n' > "$WORK/o"
    FAKE_STDOUT="$WORK/o" FAKE_STDERR=/dev/null FAKE_RC=0 "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 0 ]
}

@test "a non-zero exit with no error TS is status error, never 0" {
    printf 'ERROR  Cannot find module vue-tsc\n' > "$WORK/e"
    local rc
    for rc in 1 2; do
        rm -f "$QG_OUT/result.json"
        FAKE_STDOUT=/dev/null FAKE_STDERR="$WORK/e" FAKE_RC=$rc "$DRIVER" run > /dev/null
        [ "$(result .status)" = error ] && [ "$(result .metric)" = null ] || { echo "exit $rc measured"; return 1; }
        [[ "$(result .error)" == *"exited ${rc} with no error TS"* ]]
    done
}

@test "exit 137 is status error even with error TS lines" {
    FAKE_RC=137 "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "files=changed with no file matching include= measures 0 and runs nothing" {
    printf 'docs/a.md\0' > "$WORK/files"; mkdir -p "$TREE/docs"; : > "$TREE/docs/a.md"
    QG_FILES="$WORK/files" QG_ARGS='files=changed include=\.(ts|vue)$' "$DRIVER" run > /dev/null
    [ ! -e "$FAKE_ARGV" ]
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 0 ]
}

@test "files=changed with a match runs the tool on the whole project, naming no file" {
    printf 'app/x.ts\0' > "$WORK/files"; mkdir -p "$TREE/app"; : > "$TREE/app/x.ts"
    QG_FILES="$WORK/files" QG_ARGS='files=changed include=\.(ts|vue)$' "$DRIVER" run > /dev/null
    [ "$(cat "$FAKE_ARGV")" = 'nuxt typecheck' ]
    [ "$(result .metric)" = 45 ]
}

@test "lines=added on recorded vue-tsc output equals commit-check.sh typecheck (3)" {
    commit_repo
    FAKE_STDOUT="$FIX/vue-tsc-app.out" FAKE_STDERR="$FIX/vue-tsc-app.err" FAKE_RC=2 \
        QG_ARGS='files=changed include=\.(ts|tsx|mts|vue|js|mjs|cjs)$ lines=added bin=node_modules/.bin/vue-tsc -- -b --noEmit --pretty false' \
        "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 3 ]
    [ "$(result '[.findings[] | "\(.file):\(.line)"] | join(",")')" = 'composables/useReferrals.ts:74,composables/useReferrals.ts:75,pages/join.vue:12' ]
}

@test "lines=added on recorded nuxt typecheck output equals tree-report.sh typecheck (3)" {
    commit_repo
    QG_ARGS='lines=added' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 3 ]
}

@test "lines=added counts the same for relative, ./, /app/ and absolute tree paths" {
    commit_repo
    local p
    for p in '' './' '/app/' "$WORK/repo/"; do
        sed "s#^composables/#${p}composables/#; s#^pages/#${p}pages/#" "$FIX/nuxt-typecheck-app.out" > "$WORK/o"
        FAKE_STDOUT="$WORK/o" QG_ARGS='lines=added' "$DRIVER" run > /dev/null
        [ "$(result .metric)" = 3 ] || { echo "prefix '$p' read $(result .metric)"; return 1; }
    done
}

@test "a path with parentheses parses whole" {
    commit_repo
    mkdir -p 'pages/(group)'; lines 'pages/(group)/x.vue' 5; commit_all more
    export QG_BASES="$(git rev-parse HEAD)"
    change 'pages/(group)/x.vue' 3; git add -A
    printf 'pages/(group)/x.vue(3,7): error TS2322: Type (a) is wrong.\n' > "$WORK/o"
    FAKE_STDOUT="$WORK/o" QG_ARGS='lines=added' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings[0].file')" = 'pages/(group)/x.vue' ]
    [ "$(result '.findings[0].message')" = 'Type (a) is wrong.' ]
}

@test "two runs write the same bytes; permuted output lines give the same metric" {
    "$DRIVER" run > /dev/null
    cp "$QG_OUT/result.json" "$WORK/first.json"
    "$DRIVER" run > /dev/null
    cmp "$WORK/first.json" "$QG_OUT/result.json"
    tac "$FIX/nuxt-typecheck-app.out" > "$WORK/o"
    FAKE_STDOUT="$WORK/o" "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 45 ]
}

@test "through a runner, no argv word names a path outside the tree" {
    cat > "$WORK/runner" <<'EOF'
#!/usr/bin/env bash
tree="$1"; shift 2
printf '%s\n' "$@" > "$RUNNER_LOG"
cd "$tree" && exec "$@"
EOF
    chmod +x "$WORK/runner"
    RUNNER_LOG="$WORK/runner.log" QG_RUNNER="$WORK/runner" QG_ARGS='runner=quality/bin/in-node.sh' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 45 ]
    [ "$(grep -c '^/' "$WORK/runner.log")" = 0 ]
}
