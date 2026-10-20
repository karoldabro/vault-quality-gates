#!/usr/bin/env bats
# drivers/eslint.sh — metric = messages of one class (errors, problems, listed rules) in ESLint's
# JSON report, or with lines=added those on lines the commit adds.
#
# A fake eslint records its argv NUL-separated, copies $FAKE_JSON to its -o file with the recorded
# checkout path replaced by $FAKE_PREFIX (default: its own folder) and exits $FAKE_RC.
#
# tests/fixtures/drivers/eslint-app.json is real output of eslint 10.5.0 in app.givore.com:
#   pnpm exec eslint -f json -o eslint-app.json --no-warn-ignored api/types/chat.ts \
#     components/announcement/Modal.vue composables/useInfiniteFeed.ts api/core/storage.ts api/config/endpoints.ts
# It holds 3 errors and 15 warnings; 5 messages are of the six `mess` rules.
# The v1 numbers on it, each from the v1 script run against a fake eslint replaying the report:
#   app  node scripts/quality-metric.mjs lint                  3
#   app  node scripts/quality-metric.mjs mess                  5
#   dash bash quality/bin/metric.sh lint                       3
#   app  quality/bin/commit-check.sh lint + guard-added-lines.sh --checkstyle   7   (the repo of commit_repo)
#   dash quality/bin/tree-report.sh lint + guard-added-lines.sh --checkstyle    2   (the repo of commit_repo)

load guard-helpers

DRIVER=/code/drivers/eslint.sh
FIX=/code/tests/fixtures/drivers
MESS='complexity,sonarjs/cognitive-complexity,max-depth,max-lines,max-lines-per-function,max-params'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR QG_REPO QG_BASES QG_TARGET CLAUDECODE AI_AGENT FAKE_PREFIX
    export GUARD_LOCK_WAIT=5
    TREE="$WORK/tree"; mkdir -p "$TREE" "$WORK/out"
    fake_eslint "$TREE"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=lint-row QG_FILES=/dev/null
    export FAKE_JSON="$FIX/eslint-app.json" FAKE_RC=1 FAKE_ARGV="$WORK/argv" FAKE_CALLS="$WORK/calls"
    # Cases run unsandboxed so the fake can record; the sandbox case below runs it.
    export QG_SANDBOX=0
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_eslint() {  # fake_eslint <tree> — node_modules/.bin/eslint in <tree>
    mkdir -p "$1/node_modules/.bin"
    cat > "$1/node_modules/.bin/eslint" <<'EOF'
#!/usr/bin/env bash
if [ -z "${FAKE_CALLS:-}" ]; then
    # qg_sandbox_run starts the tool from an empty environment: take the test's FAKE_* names from the
    # nearest ancestor process that has them. Works only unsandboxed, as setup runs.
    p=$PPID
    while [ "${p:-0}" -gt 1 ]; do
        if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q '^FAKE_CALLS='; then
            while IFS= read -r -d '' kv; do case "$kv" in FAKE_*) export "${kv?}" ;; esac; done < "/proc/$p/environ"
            break
        fi
        p="$(awk '{ print $4 }' "/proc/$p/stat" 2>/dev/null)"
    done
fi
echo call >> "${FAKE_CALLS:-/dev/null}"
: > "${FAKE_ARGV:-/dev/null}"; printf '%s\0' "$@" >> "${FAKE_ARGV:-/dev/null}"
out=''
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
if [ -n "$out" ] && [ -r "${FAKE_JSON:-}" ]; then
    sed "s#/home/kdabrow/workspace/app.givore.com#${FAKE_PREFIX-$(pwd -P)}#g" "$FAKE_JSON" > "$out"
fi
exit "${FAKE_RC:-0}"
EOF
    chmod +x "$1/node_modules/.bin/eslint"
}

# argv — the fake's argv without the leading `-o <private folder>/eslint.json` the driver adds.
argv() { tr '\0' ' ' < "$FAKE_ARGV" | sed 's/ $//; s#^-o [^ ]*/eslint\.json ##'; }
result() { jq -r "$1" "$QG_OUT/result.json"; }
calls() { [ -e "$FAKE_CALLS" ] && wc -l < "$FAKE_CALLS" | tr -d ' ' || echo 0; }

lines() { local i; for ((i = 1; i <= $2; i++)); do printf 'line %d\n' "$i"; done > "$1"; }
change() { local f="$1" l; shift; for l in "$@"; do sed -i "${l}s/.*/changed ${l}/" "$f"; done; }

# commit_repo — QG_TREE becomes a repo holding the five linted files whose staged change adds
# api/types/chat.ts 450-454, Modal.vue 61, useInfiniteFeed.ts 2 and endpoints.ts 1. On the recorded
# report those lines carry 7 messages, 2 of them errors.
commit_repo() {
    new_repo "$WORK/repo"
    mkdir -p api/types api/core api/config components/announcement composables
    lines api/types/chat.ts 606; lines components/announcement/Modal.vue 66; lines composables/useInfiniteFeed.ts 7
    lines api/core/storage.ts 20; lines api/config/endpoints.ts 6
    commit_all base
    export QG_REPO="$WORK/repo" QG_TREE="$WORK/repo" QG_TARGET=:index QG_BASES="$(git rev-parse HEAD)"
    change api/types/chat.ts 450 451 452 453 454; change components/announcement/Modal.vue 61
    change composables/useInfiniteFeed.ts 2; change api/config/endpoints.ts 1
    git add -A
    printf '%s\0' api/types/chat.ts components/announcement/Modal.vue composables/useInfiniteFeed.ts \
        api/config/endpoints.ts > "$WORK/files"
    export QG_FILES="$WORK/files"
    fake_eslint "$WORK/repo"
}

@test "describe is JSON naming eslint with needs_tree true; explain prints text" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = eslint ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [ "$status" -eq 0 ] && [ -n "$output" ]
    run "$DRIVER" explain no-useless-escape
    [[ "$output" == *'no-useless-escape'* ]]
}

@test "errors, problems and rules on the recorded app report equal the v1 numbers" {
    QG_ARGS='metric=errors' "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 3 ]                      # quality-metric.mjs lint, metric.sh lint
    [ "$(jq '[.[].errorCount] | add' "$FAKE_JSON")" = 3 ]
    QG_ARGS="metric=rules rules=${MESS}" "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 5 ]                      # quality-metric.mjs mess
    QG_ARGS='metric=problems' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = "$(jq '[.[] | .errorCount + .warningCount] | add' "$FAKE_JSON")" ]
    [ "$(result .metric)" = 18 ]
}

@test "metric defaults to errors; findings carry rule, tree-relative file, line and level" {
    "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 3 ]
    [ "$(result '[.findings[] | "\(.ruleId) \(.file):\(.line) \(.level)"] | join(",")')" = \
        'no-useless-escape components/announcement/Modal.vue:61 error,import/no-duplicates composables/useInfiniteFeed.ts:1 error,import/no-duplicates composables/useInfiniteFeed.ts:2 error' ]
}

@test "exits 0 and 1 with a report are measured" {
    local rc
    for rc in 0 1; do
        rm -f "$QG_OUT/result.json"
        FAKE_RC=$rc QG_ARGS='metric=problems' "$DRIVER" run > /dev/null
        [ "$(result .status)" = measured ] || { echo "exit $rc not measured"; return 1; }
        [ "$(result .metric)" = 18 ]
    done
}

@test "exit 1 without a report, exit 2 and exit 137 are status error with metric null" {
    FAKE_JSON=/nonexistent FAKE_RC=1 run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'wrote no report'* ]]
    local rc
    for rc in 2 137; do
        rm -f "$QG_OUT/result.json"
        FAKE_RC=$rc "$DRIVER" run > /dev/null
        [ "$(result .status)" = error ] && [ "$(result .metric)" = null ] || { echo "exit $rc measured"; return 1; }
        [[ "$(result .error)" == *"exited ${rc}"* ]]
    done
}

@test "a report left in the tree by an earlier run is never read" {
    cp "$FAKE_JSON" "$TREE/.qg-eslint-lint-row.json"
    FAKE_JSON=/nonexistent FAKE_RC=1 "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "a whole-repo run that lints no file is status error" {
    printf '[]\n' > "$WORK/empty.json"
    FAKE_JSON="$WORK/empty.json" FAKE_RC=0 "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'linted no file'* ]]
}

@test "an unreadable report is status error" {
    printf 'Oops\n' > "$WORK/bad.json"
    FAKE_JSON="$WORK/bad.json" "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "metric=rules without rules= and an unknown metric are status error" {
    QG_ARGS='metric=rules' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'rules='* ]]
    QG_ARGS='metric=warnings' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}

@test "argv is -o <private report> -c <config> -f json -- <paths>; the report is written outside the tree" {
    "$DRIVER" run > /dev/null
    [ "$(argv)" = '-c eslint.config.mjs -f json -- .' ]
    local out
    out="$(tr '\0' '\n' < "$FAKE_ARGV" | sed -n 2p)"
    [ "$(tr '\0' '\n' < "$FAKE_ARGV" | sed -n 1p)" = -o ]
    [[ "$out" == */eslint.json ]] && [[ "$out" != "$TREE"* ]] && [ ! -e "$out" ]
    [ -z "$(find "$TREE" -name '*.json' -newer "$FAKE_ARGV")" ]
    QG_ARGS='config=quality/eslint.config.mjs paths=app,server -- --max-warnings 0' "$DRIVER" run > /dev/null
    [ "$(argv)" = '-c quality/eslint.config.mjs -f json --max-warnings 0 -- app server' ]
}

@test "eslint runs sandboxed: its report reaches the driver and nothing in the tree is written" {
    unset QG_SANDBOX
    # The sandbox hides the test's variables, so this fake has its report and its targets baked in.
    { printf '#!/usr/bin/env bash\nJSON=%q\nESC=%q\n' "$FAKE_JSON" "$WORK/escaped"; cat <<'EOF'
out=''
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
sed "s#/home/kdabrow/workspace/app.givore.com#$(pwd -P)#g" "$JSON" > "$out"
echo 'console output of a config file'
echo x > "$ESC" 2>/dev/null
echo x > planted.json 2>/dev/null
exit 1
EOF
    } > "$TREE/node_modules/.bin/eslint"
    QG_ARGS='metric=problems' "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 18 ]
    [ ! -e "$WORK/escaped" ] && [ ! -e "$TREE/planted.json" ]
}

@test "a tree eslint.config.js exporting [] changes neither argv nor metric" {
    "$DRIVER" run > /dev/null
    local before; before="$(argv) $(result .metric)"
    printf 'export default [];\n' > "$TREE/eslint.config.js"
    "$DRIVER" run > /dev/null
    [ "$(argv) $(result .metric)" = "$before" ]
    [[ "$(argv)" == '-c eslint.config.mjs '* ]]
}

@test "bin= runs that path from the tree" {
    mkdir -p "$TREE/tools"; fake_eslint "$TREE/tools"; mv "$TREE/tools/node_modules/.bin/eslint" "$TREE/tools/lint"
    rm "$TREE/node_modules/.bin/eslint"
    QG_ARGS='bin=tools/lint' "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 3 ]
}

@test "through a runner, no argv word names a path outside the tree" {
    { printf '#!/usr/bin/env bash\nRUNNER_LOG=%q\n' "$WORK/runner.log"; cat <<'EOF'
tree="$1"; shift 2
printf '%s\0' "$@" > "$RUNNER_LOG"
cd "$tree" && exec "$@"
EOF
    } > "$WORK/runner"
    chmod +x "$WORK/runner"
    QG_RUNNER="$WORK/runner" QG_ARGS='runner=quality/bin/in-node.sh metric=problems' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 18 ]
    # The runner gets the child-environment prefix first; the tool argv starts at the /bin/sh that
    # names the report inside the private folder, the one absolute word it may hold.
    tr '\0' '\n' < "$WORK/runner.log" | awk '$0 == "/bin/sh" { f = 1 } f' > "$WORK/tool.argv"
    [ -s "$WORK/tool.argv" ]
    [ "$(grep -v '^/bin/sh$' "$WORK/tool.argv" | grep -c '^/')" = 0 ]
    [ "$(grep -cF "$WORK" "$WORK/tool.argv")" = 0 ]
}

@test "with QG_RUN_DIR, lint-errors and mess rows run eslint once" {
    mkdir -p "$WORK/run"
    QG_RUN_DIR="$WORK/run" QG_ARGS='runner=r metric=errors' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 3 ]
    QG_RUN_DIR="$WORK/run" QG_ARGS="runner=r metric=rules rules=${MESS}" "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 5 ]
    [ "$(calls)" = 1 ]
    QG_RUN_DIR="$WORK/run" QG_ARGS='runner=r metric=errors config=other.mjs' "$DRIVER" run > /dev/null
    [ "$(calls)" = 2 ]
}

@test "two runs write the same bytes; permuted messages give the same metric" {
    QG_ARGS='metric=problems' "$DRIVER" run > /dev/null
    cp "$QG_OUT/result.json" "$WORK/first.json"
    QG_ARGS='metric=problems' "$DRIVER" run > /dev/null
    cmp "$WORK/first.json" "$QG_OUT/result.json"
    jq 'reverse | map(.messages |= reverse)' "$FIX/eslint-app.json" > "$WORK/permuted.json"
    local m
    for m in errors problems "rules rules=${MESS}"; do
        FAKE_JSON="$FIX/eslint-app.json" QG_ARGS="metric=$m" "$DRIVER" run > /dev/null; local a; a="$(result .metric)"
        FAKE_JSON="$WORK/permuted.json" QG_ARGS="metric=$m" "$DRIVER" run > /dev/null
        [ "$(result .metric)" = "$a" ] || { echo "metric=$m moved"; return 1; }
    done
}

@test "files=changed with no file matching include= measures 0 and never calls eslint" {
    printf 'docs/a.md\0README.md\0' > "$WORK/files"
    mkdir -p "$TREE/docs"; : > "$TREE/docs/a.md"; : > "$TREE/README.md"
    QG_FILES="$WORK/files" QG_ARGS='files=changed include=\.(ts|vue)$' "$DRIVER" run > /dev/null
    [ "$(calls)" = 0 ]
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 0 ]
}

@test "files=changed with every changed file ignored measures 0, as v1" {
    printf 'ecosystem.config.cjs\0' > "$WORK/files"; : > "$TREE/ecosystem.config.cjs"
    printf '[]\n' > "$WORK/empty.json"
    FAKE_JSON="$WORK/empty.json" FAKE_RC=0 QG_FILES="$WORK/files" QG_ARGS='files=changed' "$DRIVER" run > /dev/null
    [ "$(calls)" = 1 ]
    [ "$(argv)" = '-c eslint.config.mjs -f json --no-warn-ignored -- ecosystem.config.cjs' ]
    [ "$(result .status)" = measured ] && [ "$(result .metric)" = 0 ]
}

@test "500 changed files with odd names reach argv intact and in order" {
    local i
    : > "$WORK/files"
    mkdir -p "$TREE/src"
    for ((i = 1; i <= 497; i++)); do : > "$TREE/src/f$i.ts"; printf 'src/f%d.ts\0' "$i" >> "$WORK/files"; done
    : > "$TREE/src/-rf.ts"; : > "$TREE/src/a b.ts"; : > "$TREE/src/\$(x)*.ts"
    printf '%s\0' 'src/-rf.ts' 'src/a b.ts' 'src/$(x)*.ts' >> "$WORK/files"
    QG_FILES="$WORK/files" QG_ARGS='files=changed' "$DRIVER" run > /dev/null
    # The fake's argv after the `--` equals the changed list, byte for byte.
    awk 'BEGIN { RS = "\0" } f { printf "%s\0", $0 } $0 == "--" { f = 1 }' "$FAKE_ARGV" > "$WORK/got"
    cmp "$WORK/files" "$WORK/got"
}

@test "lines=added equals commit-check.sh lint (problems, 7) and tree-report.sh lint (errors, 2)" {
    commit_repo
    QG_ARGS='files=changed lines=added metric=problems include=\.(ts|tsx|mts|vue|js|mjs|cjs)$' "$DRIVER" run > /dev/null
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 7 ]
    QG_ARGS='files=changed lines=added metric=errors include=\.(ts|vue|js|mjs|cjs)$' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 2 ]
    [ "$(result '[.findings[] | "\(.file):\(.line)"] | join(",")')" = 'components/announcement/Modal.vue:61,composables/useInfiniteFeed.ts:2' ]
}

@test "lines=added counts the same for absolute, ./ and /app/ report paths" {
    commit_repo
    local p
    for p in "$WORK/repo" . /app; do
        FAKE_PREFIX="$p" QG_ARGS='files=changed lines=added metric=problems' "$DRIVER" run > /dev/null
        [ "$(result .metric)" = 7 ] || { echo "prefix $p read $(result .metric)"; return 1; }
    done
}

@test "lines=added: a finding moved onto an added line adds 1, one off it adds 0" {
    commit_repo
    git reset -q api/types/chat.ts && git checkout -q api/types/chat.ts
    change api/types/chat.ts 307; git add api/types/chat.ts
    QG_ARGS='files=changed lines=added metric=problems' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 3 ]                      # Modal 61, useInfiniteFeed 2, chat 307
    git reset -q api/types/chat.ts && git checkout -q api/types/chat.ts
    change api/types/chat.ts 308; git add api/types/chat.ts
    QG_ARGS='files=changed lines=added metric=problems' "$DRIVER" run > /dev/null
    [ "$(result .metric)" = 2 ]
}

@test "lines=added with a report path outside the tree is status error" {
    commit_repo
    FAKE_PREFIX=/elsewhere QG_ARGS='files=changed lines=added metric=problems' "$DRIVER" run > /dev/null
    [ "$(result .status)" = error ] && [ "$(result .metric)" = null ]
}
