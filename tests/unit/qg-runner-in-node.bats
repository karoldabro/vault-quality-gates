#!/usr/bin/env bats
# migrations/web/in-node.sh, the runner of the app.givore.com and dashboard.givore.com node rows: the
# commit and push events against a stub tool, the tool-closure lock check, and --tools-diff, the
# count the tools-changed row reads. Every runner call uses a copy of the runner alone in an empty
# folder, as the engine makes one.

load guard-helpers

SRC=/code/migrations/web/in-node.sh

# lock <file> [<name> <version>]... — a pnpm lockfile v9. Its tool closure is eslint, jiti, fsevents,
# @scope/tool, @scope/parser, strip (through the alias strip-cjs), typescript, nuxt, @nuxt/cli and
# citty; left-pad and prod-only sit outside it. Each extra pair adds one more devDependency.
lock() {
    local f="$1"
    shift
    {
        printf '%s\n' "lockfileVersion: '9.0'" '' 'settings:' '  autoInstallPeers: true' '' 'importers:' '' '  .:' \
            '    dependencies:' '      left-pad:' '        specifier: ^1.0.0' '        version: 1.0.0' \
            '      nuxt:' '        specifier: ^4.0.0' '        version: 4.0.0(typescript@5.0.0)' \
            '    devDependencies:' "      '@scope/tool':" '        specifier: ^1.0.0' '        version: 1.0.0' \
            '      eslint:' '        specifier: ^10.0.0' '        version: 10.0.0(jiti@2.0.0)' \
            '      typescript:' '        specifier: ^5.0.0' '        version: 5.0.0'
        local args=("$@")
        while [ "$#" -gt 0 ]; do printf '      %s:\n        specifier: ^%s\n        version: %s\n' "$1" "$2" "$2"; shift 2; done
        printf '%s\n' '' 'packages:' '' '  eslint@10.0.0:' '    resolution: {integrity: sha512-x}' '' 'snapshots:' '' \
            "  '@nuxt/cli@3.0.0':" '    dependencies:' '      citty: 0.1.0' '' \
            "  '@scope/parser@2.0.0': {}" '' \
            "  '@scope/tool@1.0.0':" '    dependencies:' "      '@scope/parser': 2.0.0" '      strip-cjs: strip@1.0.0' '' \
            '  citty@0.1.0: {}' '' \
            '  eslint@10.0.0(jiti@2.0.0):' '    dependencies:' '      jiti: 2.0.0' '    optionalDependencies:' '      fsevents: 2.0.0' '' \
            '  fsevents@2.0.0: {}' '' '  jiti@2.0.0: {}' '' \
            '  left-pad@1.0.0:' '    dependencies:' '      prod-only: 1.0.0' '' \
            '  nuxt@4.0.0(typescript@5.0.0):' '    dependencies:' "      '@nuxt/cli': 3.0.0" '      typescript: 5.0.0' \
            '    transitivePeerDependencies:' '      - left-pad' '' \
            '  prod-only@1.0.0: {}' '' '  strip@1.0.0: {}' '' '  typescript@5.0.0: {}'
        set -- "${args[@]}"
        while [ "$#" -gt 0 ]; do printf '\n  %s@%s: {}\n' "$1" "$2"; shift 2; done
    } > "$f"
}

# edit <file> <sed expression> — rewrites <file> in place.
edit() { sed -e "$2" "$1" > "$1.t" && mv "$1.t" "$1"; }

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset NODE_OPTIONS NODE_PATH GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
    mkdir -p "$WORK/alone"
    cp "$SRC" "$WORK/alone/in-node.sh"
    R="$WORK/alone/in-node.sh"
    LOG="$WORK/tool.log"
    export LOG MARK="$WORK/marker"

    # The main checkout: HEAD carries the lock and the runner; node_modules and .nuxt are installed.
    MAIN="$WORK/main"
    new_repo "$MAIN"
    lock pnpm-lock.yaml
    mkdir -p quality/bin && cp "$SRC" quality/bin/in-node.sh
    commit_all base
    mkdir -p node_modules/.pnpm node_modules/.bin .nuxt
    cp pnpm-lock.yaml node_modules/.pnpm/lock.yaml
    echo main-eslint > .nuxt/eslint.config.mjs
    echo main-strict > .nuxt/tsconfig.app.json
    # The tool records what it sees; it acts on NODE_OPTIONS the way node would act on --require.
    printf '%s\n' '#!/usr/bin/env bash' \
        '[ -n "${NODE_OPTIONS:-}" ] && touch "$MARK"' \
        '{ echo "argv=$*"; echo "pwd=$(pwd -P)"; echo "node_options=${NODE_OPTIONS-unset} node_path=${NODE_PATH-unset}"' \
        '  echo "nuxt=$(cat .nuxt/tsconfig.app.json)"; echo "link=$(readlink node_modules)"' \
        '  echo "tsbuildinfo=$(find . \( -name node_modules -o -name .git \) -prune -o -name "*.tsbuildinfo" -print | sort | tr "\n" " ")"; } >> "$LOG"' \
        'exit "${TOOL_RC:-0}"' > node_modules/.bin/tool
    # nuxt and nuxi leave a marker, so a `nuxt prepare` shows.
    printf '%s\n' '#!/usr/bin/env bash' 'touch "$MARK"' > node_modules/.bin/nuxt
    chmod +x node_modules/.bin/tool node_modules/.bin/nuxt
    cp node_modules/.bin/nuxt node_modules/.bin/nuxi
    mkdir -p "$WORK/bin" && cp node_modules/.bin/nuxt "$WORK/bin/nuxt" && cp node_modules/.bin/nuxt "$WORK/bin/nuxi"
    export PATH="$WORK/bin:$PATH"

    # The staged tree under commit: a loosening nuxt.config.ts, its own loose .nuxt and stale build info.
    TREE="$MAIN/.git/guard-tree"
    mkdir -p "$TREE/.nuxt" "$TREE/sub"
    cp pnpm-lock.yaml "$TREE/pnpm-lock.yaml"
    printf '%s\n' "require('fs').writeFileSync('$MARK', 'x')" "export default { typescript: { strict: false } }" > "$TREE/nuxt.config.ts"
    echo tree-loose > "$TREE/.nuxt/tsconfig.app.json"
    echo tree-eslint > "$TREE/.nuxt/eslint.config.mjs"
    : > "$TREE/tsconfig.tsbuildinfo"
    : > "$TREE/sub/app.tsbuildinfo"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# tree_unchanged — the staged tree as setup made it: no link, its own .nuxt, its build info.
tree_unchanged() {
    [ ! -e "$TREE/node_modules" ] && [ ! -L "$TREE/node_modules" ] \
        && [ "$(cat "$TREE/.nuxt/tsconfig.app.json")" = tree-loose ] \
        && [ -f "$TREE/tsconfig.tsbuildinfo" ] && [ -f "$TREE/sub/app.tsbuildinfo" ]
}

# --- commit -------------------------------------------------------------------------------------

@test "commit: the tool runs in the tree with main's node_modules and a fresh copy of main's .nuxt" {
    cd "$MAIN"
    run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool a 'b c'
    [ "$status" -eq 0 ]
    grep -qx 'argv=a b c' "$LOG"
    grep -qx "pwd=$TREE" "$LOG"
    grep -qx "link=$MAIN/node_modules" "$LOG"
    grep -qx 'nuxt=main-strict' "$LOG"
    grep -qx 'tsbuildinfo=' "$LOG"
}

@test "commit: everything the runner made is gone at exit, the tool's exit code comes back, main is intact" {
    cd "$MAIN"
    TOOL_RC=3 run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 3 ]
    [ ! -e "$TREE/node_modules" ] && [ ! -L "$TREE/node_modules" ]
    [ ! -e "$TREE/.nuxt" ]
    [ -f "$TREE/nuxt.config.ts" ]
    [ -x "$MAIN/node_modules/.bin/tool" ]
    [ "$(cat "$MAIN/.nuxt/tsconfig.app.json")" = main-strict ]
}

@test "commit: a stale node_modules link in the tree is replaced and removed, never its target" {
    mkdir -p "$WORK/old-modules/.bin" && : > "$WORK/old-modules/keep"
    ln -s "$WORK/old-modules" "$TREE/node_modules"
    cd "$MAIN"
    run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 0 ]
    grep -qx "link=$MAIN/node_modules" "$LOG"
    [ ! -L "$TREE/node_modules" ] && [ -f "$WORK/old-modules/keep" ]
}

@test "commit: a node_modules folder in the tree exits 2 and leaves it" {
    mkdir -p "$TREE/node_modules/x"
    cd "$MAIN"
    run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 2 ] && [ ! -s "$LOG" ] && [ -d "$TREE/node_modules/x" ]
}

@test "commit: a staged nuxt.config.ts and a loose tree .nuxt change nothing and write no marker" {
    cd "$MAIN"
    run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 0 ]
    grep -qx 'nuxt=main-strict' "$LOG"
    [ ! -e "$MARK" ]
}

@test "commit: main's .nuxt without eslint.config.mjs or tsconfig.app.json, or no node_modules, exits 2 and leaves the tree" {
    cd "$MAIN"
    for f in eslint.config.mjs tsconfig.app.json; do
        mv ".nuxt/$f" "$WORK/$f"
        run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
        [ "$status" -eq 2 ] && [[ "$output" == *".nuxt/$f does not exist"* ]] && [[ "$output" == *'pnpm install'* ]]
        tree_unchanged
        mv "$WORK/$f" ".nuxt/$f"
    done
    mv node_modules "$WORK/nm"
    run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 2 ] && [[ "$output" == *'node_modules does not exist'* ]]
    tree_unchanged
    [ ! -s "$LOG" ]
}

@test "commit: from a linked worktree with a hook's GIT_DIR, the tree still takes the main checkout's install" {
    cd "$MAIN"
    git worktree add -q "$WORK/wt" HEAD
    cd "$WORK/wt"
    GIT_DIR="$MAIN/.git/worktrees/wt" GIT_INDEX_FILE="$MAIN/.git/worktrees/wt/index" run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 0 ]
    grep -qx "link=$MAIN/node_modules" "$LOG"
    grep -qx 'nuxt=main-strict' "$LOG"
}

# --- either event -------------------------------------------------------------------------------

@test "either: an inherited NODE_OPTIONS or NODE_PATH never reaches the tool" {
    cd "$MAIN"
    NODE_OPTIONS="--require $WORK/evil.js" NODE_PATH="$WORK" run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 0 ]
    grep -qx 'node_options=unset node_path=unset' "$LOG"
    NODE_OPTIONS="--require $WORK/evil.js" run "$R" "$MAIN" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 0 ]
    [ "$(grep -c 'node_options=unset' "$LOG")" -eq 2 ]
    [ ! -e "$MARK" ]
}

@test "either: a tool closure differing from HEAD exits 2 naming the package and the fix" {
    cd "$MAIN"
    for change in 's/eslint@10.0.0/eslint@10.1.0/; s/version: 10.0.0/version: 10.1.0/' \
        's/jiti@2.0.0/jiti@2.1.0/g; s/jiti: 2.0.0/jiti: 2.1.0/' \
        's/nuxt@4.0.0/nuxt@4.1.0/; s/version: 4.0.0/version: 4.1.0/' \
        "s|'@nuxt/cli@3.0.0'|'@nuxt/cli@3.1.0'|; s|'@nuxt/cli': 3.0.0|'@nuxt/cli': 3.1.0|"; do
        cp pnpm-lock.yaml node_modules/.pnpm/lock.yaml
        edit node_modules/.pnpm/lock.yaml "$change"
        for tree in "$TREE" "$MAIN"; do
            run "$R" "$tree" "$WORK/cache" node_modules/.bin/tool
            [ "$status" -eq 2 ] && [[ "$output" == *"fix: run pnpm install in $MAIN"* ]]
        done
        tree_unchanged
    done
    [[ "$output" == *'  @nuxt/cli'* ]]
    [ ! -s "$LOG" ]
}

@test "either: the refusal lists the first 10 package names" {
    cd "$MAIN"
    lock node_modules/.pnpm/lock.yaml a1 1.0.0 a2 1.0.0 a3 1.0.0 a4 1.0.0 a5 1.0.0 a6 1.0.0 a7 1.0.0 a8 1.0.0 a9 1.0.0 b1 1.0.0 b2 1.0.0
    run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 2 ]
    [[ "$output" == *'  a1'* ]] && [[ "$output" == *'  b1'* ]] && [[ "$output" != *'  b2'* ]]
}

@test "either: a change only outside the closure runs" {
    cd "$MAIN"
    edit node_modules/.pnpm/lock.yaml 's/prod-only@1.0.0/prod-only@1.1.0/; s/prod-only: 1.0.0/prod-only: 1.1.0/'
    run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 0 ] && [ -s "$LOG" ]
}

@test "either: a used or HEAD lock missing or not v9 exits 2" {
    cd "$MAIN"
    edit node_modules/.pnpm/lock.yaml "s/^lockfileVersion: '9.0'/lockfileVersion: '6.0'/"
    run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 2 ] && [[ "$output" == *'not a pnpm lockfile v9'* ]]
    rm node_modules/.pnpm/lock.yaml
    run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 2 ]
    cp pnpm-lock.yaml node_modules/.pnpm/lock.yaml
    git rm -q pnpm-lock.yaml && commit_all 'no lock'
    run "$R" "$TREE" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 2 ] && [[ "$output" == *'HEAD has no pnpm-lock.yaml'* ]]
    tree_unchanged
    [ ! -s "$LOG" ]
}

@test "either: fewer than three arguments or a missing tree exits 2" {
    cd "$MAIN"
    run "$R" "$TREE" "$WORK/cache"
    [ "$status" -eq 2 ]
    run "$R" "$WORK/nope" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 2 ]
}

# --- push ---------------------------------------------------------------------------------------

@test "push: in the main checkout the runner links, copies and deletes nothing" {
    cd "$MAIN"
    : > app.tsbuildinfo
    run "$R" "$MAIN" "$WORK/cache" node_modules/.bin/tool x
    [ "$status" -eq 0 ]
    grep -qx "pwd=$MAIN" "$LOG"
    grep -qx 'link=' "$LOG"
    grep -qx 'nuxt=main-strict' "$LOG"
    grep -qx 'tsbuildinfo=./app.tsbuildinfo ' "$LOG"
    [ -d node_modules ] && [ ! -L node_modules ] && [ -f app.tsbuildinfo ] && [ -f .nuxt/eslint.config.mjs ]
}

@test "push: node_modules or .nuxt missing in the tree exits 2" {
    cd "$MAIN"
    mv .nuxt "$WORK/nuxt"
    run "$R" "$MAIN" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 2 ] && [[ "$output" == *"$MAIN/.nuxt does not exist"* ]]
    mv "$WORK/nuxt" .nuxt
    mv node_modules "$WORK/nm"
    run "$R" "$MAIN" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 2 ] && [[ "$output" == *"$MAIN/node_modules does not exist"* ]]
    [ ! -e .nuxt/../node_modules ]
}

@test "push: a tree inside a checkout but not its top level exits 2" {
    cd "$MAIN"
    mkdir -p sub
    run "$R" "$MAIN/sub" "$WORK/cache" node_modules/.bin/tool
    [ "$status" -eq 2 ] && [[ "$output" == *'not its top level'* ]]
    [ ! -e sub/node_modules ]
}

# --- lock closure and --tools-diff --------------------------------------------------------------

@test "closure: devDependencies, nuxt and @nuxt/cli with their transitive and optional packages, aliases resolved" {
    run "$R" --closure "$MAIN/pnpm-lock.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' '@nuxt/cli 3.0.0' '@scope/parser 2.0.0' '@scope/tool 1.0.0' 'citty 0.1.0' 'eslint 10.0.0' \
        'fsevents 2.0.0' 'jiti 2.0.0' 'nuxt 4.0.0' 'strip 1.0.0' 'typescript 5.0.0')" ]
}

# diff_count <sed expression> — writes the tree lock as HEAD's with <expression> applied, runs
# --tools-diff from the main checkout, then the same with the two locks swapped; both must agree.
diff_count() {
    cd "$MAIN" || return 1
    cp pnpm-lock.yaml "$TREE/pnpm-lock.yaml"
    [ -z "$1" ] || edit "$TREE/pnpm-lock.yaml" "$1"
    local fwd back
    fwd="$("$R" --tools-diff "$TREE")" || return 1
    cp "$TREE/pnpm-lock.yaml" "$WORK/new.yaml"
    cp pnpm-lock.yaml "$TREE/pnpm-lock.yaml"
    cp "$WORK/new.yaml" pnpm-lock.yaml && commit_all swapped
    back="$("$R" --tools-diff "$TREE")" || return 1
    git reset -q --hard HEAD~1
    [ "$fwd" = "$back" ] || { echo "forward $fwd, swapped $back"; return 1; }
    echo "$fwd"
}

@test "tools-changed: 0 for identical locks and for changes outside the closure" {
    [ "$(diff_count '')" = 0 ]
    [ "$(diff_count 's/prod-only@1.0.0/prod-only@1.1.0/; s/prod-only: 1.0.0/prod-only: 1.1.0/')" = 0 ]
    [ "$(diff_count 's/left-pad@1.0.0/left-pad@1.1.0/; /left-pad:/,/version:/s/1.0.0/1.1.0/')" = 0 ]
}

@test "tools-changed: one per package name bumped in the closure, scoped names and aliases included" {
    [ "$(diff_count 's/eslint@10.0.0/eslint@10.1.0/; s/version: 10.0.0/version: 10.1.0/')" = 1 ]
    [ "$(diff_count 's/jiti@2.0.0/jiti@2.1.0/g; s/jiti: 2.0.0/jiti: 2.1.0/')" = 1 ]
    [ "$(diff_count 's/fsevents@2.0.0/fsevents@2.1.0/; s/fsevents: 2.0.0/fsevents: 2.1.0/')" = 1 ]
    [ "$(diff_count "s|'@scope/parser@2.0.0'|'@scope/parser@2.1.0'|; s|'@scope/parser': 2.0.0|'@scope/parser': 2.1.0|")" = 1 ]
    [ "$(diff_count 's/strip@1.0.0/strip@1.1.0/g')" = 1 ]
    [ "$(diff_count 's/nuxt@4.0.0/nuxt@4.1.0/; s/version: 4.0.0/version: 4.1.0/')" = 1 ]
    [ "$(diff_count "s|'@nuxt/cli@3.0.0'|'@nuxt/cli@3.1.0'|; s|'@nuxt/cli': 3.0.0|'@nuxt/cli': 3.1.0|")" = 1 ]
    [ "$(diff_count 's/citty@0.1.0/citty@0.2.0/; s/citty: 0.1.0/citty: 0.2.0/')" = 1 ]
    [ "$(diff_count 's/eslint@10.0.0/eslint@10.1.0/; s/version: 10.0.0/version: 10.1.0/; s/jiti@2.0.0/jiti@2.1.0/g; s/jiti: 2.0.0/jiti: 2.1.0/; s/prod-only@1.0.0/prod-only@1.1.0/')" = 2 ]
}

@test "tools-changed: a devDependency added or removed counts 1 in either direction" {
    cd "$MAIN"
    lock "$WORK/added.yaml" new-tool 1.0.0
    cp "$WORK/added.yaml" "$TREE/pnpm-lock.yaml"
    run "$R" --tools-diff "$TREE"
    [ "$status" -eq 0 ] && [ "$output" = 1 ]
    cp pnpm-lock.yaml "$TREE/pnpm-lock.yaml"
    cp "$WORK/added.yaml" pnpm-lock.yaml && commit_all added
    run "$R" --tools-diff "$TREE"
    [ "$status" -eq 0 ] && [ "$output" = 1 ]
}

@test "tools-changed: a peer-suffix-only change counts 0" {
    [ "$(diff_count 's/eslint@10.0.0(jiti@2.0.0)/eslint@10.0.0(jiti@2.0.0)(typescript@5.0.0)/; s/version: 10.0.0(jiti@2.0.0)/version: 10.0.0(jiti@2.0.0)(typescript@5.0.0)/')" = 0 ]
    [ "$(diff_count 's/nuxt@4.0.0(typescript@5.0.0)/nuxt@4.0.0/; s/version: 4.0.0(typescript@5.0.0)/version: 4.0.0/')" = 0 ]
}

@test "tools-changed: a staged lock missing or not v9 is unmeasurable: exit 2, no number" {
    cd "$MAIN"
    edit "$TREE/pnpm-lock.yaml" "s/^lockfileVersion: '9.0'/lockfileVersion: '6.0'/"
    run "$R" --tools-diff "$TREE"
    [ "$status" -eq 2 ] && [[ "$output" == *'not a pnpm lockfile v9'* ]]
    [ -z "$("$R" --tools-diff "$TREE" 2>/dev/null)" ]
    rm "$TREE/pnpm-lock.yaml"
    run "$R" --tools-diff "$TREE"
    [ "$status" -eq 2 ]
    [ -z "$("$R" --tools-diff "$TREE" 2>/dev/null)" ]
}

@test "tools-changed: the row's own call form, HEAD's runner through bash -c, counts the same" {
    cd "$MAIN"
    edit "$TREE/pnpm-lock.yaml" 's/eslint@10.0.0/eslint@10.1.0/; s/version: 10.0.0/version: 10.1.0/'
    run bash -c "$(git show HEAD:quality/bin/in-node.sh)" in-node.sh --tools-diff "$TREE"
    [ "$status" -eq 0 ] && [ "$output" = 1 ]
}
