#!/usr/bin/env bats
# bin/qg-sandbox and qg_sandbox_run (lib/qg-sandbox.sh): a sandboxed tool writes only its private
# folder, /dev/null, its declared tree paths and the existing SDK stamps; it opens no Unix socket,
# signals nothing outside, holds no descriptor above 2, and sees only the listed environment.
#
# The stub tool is tests/unit/qg-sandbox-probe.py: it tries one act and prints what happened, so a
# test reads the outcome from stdout, the only way out of the sandbox. Every refusal case also runs
# the act unsandboxed or outside, so a passing case proves the sandbox stopped it.

load guard-helpers

LIB=/code/lib/qg-sandbox.sh
PROBE=/code/tests/unit/qg-sandbox-probe.py

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    WORK="$(cd "$WORK" && pwd -P)"
    unset QG_SANDBOX QG_SANDBOX_WRITES QG_SANDBOX_SDK QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT
    TREE="$WORK/tree"; mkdir -p "$TREE" "$WORK/out" "$WORK/home"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=row HOME="$WORK/home"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && { chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"; }
    return 0
}

# sb <bash code> — runs the code with lib/qg-sandbox.sh sourced; prints QG_SANDBOX_ERROR after it.
sb() { bash -c ". $LIB; $1"'; rc=$?; [ -z "$QG_SANDBOX_ERROR" ] || echo "SANDBOX-ERROR: $QG_SANDBOX_ERROR"; exit "$rc"'; }

# probe <act> [<arg>...] — the stub tool under qg_sandbox_run in QG_TREE.
probe() { sb "qg_sandbox_run --cwd \"\$QG_TREE\" -- python3 -I $PROBE $(printf '%q ' "$@")"; }

# fake_sdk <root> — a Flutter SDK layout with two stamps, a lockfile and the two SDK markers.
fake_sdk() {
    mkdir -p "$1/bin/cache" "$1/bin/internal" "$1/packages/flutter_tools"
    : > "$1/bin/cache/engine.stamp"; : > "$1/bin/cache/flutter_tools.stamp"; : > "$1/bin/cache/lockfile"
    : > "$1/bin/internal/engine.version"; : > "$1/bin/cache/flutter_tools.snapshot"
}

@test "a sandboxed tool cannot write under the caller's .pub-cache" {
    mkdir -p "$HOME/.pub-cache/hosted"
    run probe write "$HOME/.pub-cache/hosted/x" "$HOME/.pub-cache/new"
    [ "$status" -eq 0 ]
    [[ "$output" == *"denied $HOME/.pub-cache/hosted/x"* ]]
    [[ "$output" == *"denied $HOME/.pub-cache/new"* ]]
    [ -z "$(ls -A "$HOME/.pub-cache/hosted")" ]
    QG_SANDBOX=0 run probe write "$HOME/.pub-cache/hosted/x"
    [[ "$output" == *"ok $HOME/.pub-cache/hosted/x"* ]]
}

@test "a sandboxed tool cannot write an SDK file other than bin/cache stamps and lockfile" {
    fake_sdk "$WORK/sdk"
    export QG_SANDBOX_SDK="$WORK/sdk"
    run probe write "$WORK/sdk/bin/cache/new.stamp" "$WORK/sdk/bin/cache/engine.stamp.tmp.42" \
        "$WORK/sdk/bin/internal/engine.version" "$WORK/sdk/bin/cache/flutter_tools.snapshot" "$WORK/sdk/packages/flutter_tools/x"
    [ "$(grep -c '^denied ' <<<"$output")" -eq 5 ]
    [ ! -e "$WORK/sdk/bin/cache/new.stamp" ] && [ ! -e "$WORK/sdk/bin/cache/engine.stamp.tmp.42" ]
    [ ! -s "$WORK/sdk/bin/internal/engine.version" ]
}

@test "a sandboxed tool can rewrite an existing bin/cache stamp and lockfile" {
    fake_sdk "$WORK/sdk"
    export QG_SANDBOX_SDK="$WORK/sdk"
    run probe write "$WORK/sdk/bin/cache/engine.stamp" "$WORK/sdk/bin/cache/flutter_tools.stamp" "$WORK/sdk/bin/cache/lockfile"
    [ "$(grep -c '^ok ' <<<"$output")" -eq 3 ]
    [ -s "$WORK/sdk/bin/cache/lockfile" ]
}

@test "a sandboxed tool cannot write .git, .claude or .mcp.json of a main worktree" {
    new_repo "$TREE"
    mkdir -p .claude; : > .claude/settings.json; : > .mcp.json
    commit_all init
    export QG_SANDBOX_WRITES=build
    run probe write .git/config .git/hooks/pre-commit .claude/settings.json .claude/new .mcp.json build/ok
    [ "$(grep -c '^denied ' <<<"$output")" -eq 5 ]
    [[ "$output" == *'ok build/ok'* ]]
    [ ! -e .git/hooks/pre-commit ] && [ ! -s .mcp.json ] && [ ! -e .claude/new ]
}

@test "a sandboxed tool cannot write the .git file, .claude or .npmrc of a linked worktree" {
    new_repo "$WORK/main"
    commit_all init
    git worktree add -q "$TREE/wt" -b side
    export QG_TREE="$TREE/wt" QG_SANDBOX_WRITES=build
    mkdir -p "$TREE/wt/.claude"; : > "$TREE/wt/.npmrc"
    run sb "qg_sandbox_run --cwd \"\$QG_TREE\" -- python3 -I $PROBE write .git .claude/settings.json .npmrc build/ok"
    [ "$(grep -c '^denied ' <<<"$output")" -eq 3 ]
    [[ "$output" == *'ok build/ok'* ]]
    [ ! -s "$TREE/wt/.npmrc" ]
    git -C "$TREE/wt" status --short >/dev/null
}

@test "a sandboxed tool writes only its declared paths and report folder" {
    mkdir -p "$TREE/src"
    export QG_SANDBOX_WRITES='coverage node_modules/.vite'
    run probe write coverage/lcov.info node_modules/.vite/x src/a.ts top.txt
    [[ "$output" == *'ok coverage/lcov.info'* ]] && [[ "$output" == *'ok node_modules/.vite/x'* ]]
    [[ "$output" == *'denied src/a.ts'* ]] && [[ "$output" == *'denied top.txt'* ]]
    [ ! -e "$TREE/src/a.ts" ] && [ ! -e "$TREE/top.txt" ]
}

@test "a declared path that is a symlink or resolves outside the tree is refused" {
    mkdir -p "$WORK/outside"
    ln -s "$WORK/outside" "$TREE/coverage"
    QG_SANDBOX_WRITES=coverage run probe write coverage/x
    [ "$status" -eq 125 ]
    [[ "$output" == *'SANDBOX-ERROR: qg-sandbox: declared path coverage passes through the symlink'* ]]
    [[ "$output" != *'ok '* ]]
    QG_SANDBOX_WRITES='a/../../outside' run probe write ../outside/x
    [ "$status" -eq 125 ]
    [[ "$output" == *'leaves the tree'* ]]
    [ -z "$(ls -A "$WORK/outside")" ]
}

@test "a declared path under node_modules other than .vite and .cache is refused" {
    QG_SANDBOX_WRITES='node_modules/.bin' run probe write node_modules/.bin/x
    [ "$status" -eq 125 ] && [[ "$output" == *'declared path node_modules/.bin lies under node_modules'* ]]
    QG_SANDBOX_WRITES='node_modules/vitest' run probe write x
    [ "$status" -eq 125 ]
    QG_SANDBOX_WRITES='node_modules/.cache' run probe write node_modules/.cache/x
    [ "$status" -eq 0 ] && [[ "$output" == *'ok node_modules/.cache/x'* ]]
}

@test "a sandboxed tool cannot write QG_OUT" {
    run probe write "$QG_OUT/result.json"
    [[ "$output" == *"denied $QG_OUT/result.json"* ]]
    [ ! -e "$QG_OUT/result.json" ]
}

@test "a sandboxed tool cannot open a Unix socket through socket" {
    run probe unix
    [ "$output" = 'unix errno 13' ]
    QG_SANDBOX=0 run probe unix
    [ "$output" = 'unix ok' ]
}

@test "a sandboxed tool cannot open a Unix socket through the 32-bit socketcall entry" {
    [ "$(uname -m)" = x86_64 ] || skip 'the 32-bit entry exists on x86_64 only'
    run python3 -I "$PROBE" int80
    [[ "$output" == *'int80 returned '[0-9]* ]] || skip "this kernel has no 32-bit entry: $output"
    run probe int80
    [ "$status" -ne 0 ]
    [[ "$output" == *'int80 calling'* ]]
    [[ "$output" != *'int80 returned'* ]]
}

@test "the 32-bit entry kills the process before any socket opens" {
    [ "$(uname -m)" = x86_64 ] || skip 'the 32-bit entry exists on x86_64 only'
    run python3 -I "$PROBE" int80
    [[ "$output" == *'int80 returned '[0-9]* ]] || skip "this kernel has no 32-bit entry: $output"
    run probe int80
    # SIGSYS from SECCOMP_RET_KILL_PROCESS: 128 + 31.
    [ "$status" -eq 159 ]
    [[ "$output" != *'int80 returned'* ]]
}

@test "a sandboxed tool sees no descriptor above 2" {
    run sb "exec 3>\"\$QG_OUT/three\" 9>\"\$QG_OUT/nine\" 255>\"\$QG_OUT/last\"; qg_sandbox_run -- python3 -I $PROBE fds 0 1 2 3 9 255"
    [ "$output" = $'open 0\nopen 1\nopen 2\nclosed 3\nclosed 9\nclosed 255' ]
    run sb "exec 9>\"\$QG_OUT/nine\"; QG_SANDBOX=0 qg_sandbox_run -- python3 -I $PROBE fds 9"
    [ "$output" = 'open 9' ]
}

@test "a sandboxed tool cannot signal a process outside the sandbox" {
    sleep 30 &
    local pid=$!
    run probe kill "$pid"
    [ "$output" = 'kill errno 1' ]
    kill -0 "$pid"
    kill "$pid"
}

@test "a sandbox that never arms is status error and the tool never runs" {
    printf '#!/bin/sh\nexec %q --max-abi 5 "$@"\n' /code/bin/qg-sandbox > "$WORK/weak"; chmod +x "$WORK/weak"
    run bash -c ". /code/lib/qg-driver-kit.sh; QG_SANDBOX_BIN=$WORK/weak
        qg_tool - 0 sh -c 'echo ran > $WORK/sentinel' || qg_fail probe count \"\$QG_ERROR\""
    [ "$(jq -r .status "$QG_OUT/result.json")" = error ]
    [[ "$(jq -r .error "$QG_OUT/result.json")" == 'qg-sandbox: the sandbox did not arm, so the tool never ran' ]]
    [ ! -e "$WORK/sentinel" ]
    [[ "$output" == *'Landlock ABI 5 is below 6'* ]]
}

# probe_driver <describe json> — a copy of the plugin whose built-in driver `probe` sources the kit and
# runs one tool through qg_tool: it writes made.txt in the tree and prints its environment.
probe_driver() {
    mkdir -p "$WORK/plugin/drivers"
    cp -R /code/lib /code/bin "$WORK/plugin/"
    { printf '#!/usr/bin/env bash\n. "$(dirname "$0")/../lib/qg-driver-kit.sh"\n'
      printf 'case "$1" in describe) printf "%%s\\n" %q;;\n' "$1"
      printf '  run) qg_tool - "0 1" sh -c "echo x > made.txt; env | sort"; cat "$QG_OUT/stdout"\n'
      printf '       qg_result probe measured 0 count - -;;\n'
      printf '  *) exit 2;; esac\n'
    } > "$WORK/plugin/drivers/probe.sh"
    chmod +x "$WORK/plugin/drivers/probe.sh"
}

# run_driver — guard_run_driver on one probe row in a repo at $TREE; prints the row log.
run_driver() {
    local row tmp
    row="$(printf '%s\t' r commit diff probe - down 0 refuse why - - -)"
    tmp="$WORK/run.$RANDOM"; mkdir -p "$tmp"
    ( cd "$TREE" && SECRET_TOKEN=leak bash -c '. "$1/lib/qg-driver.sh"; REPO_ROOT="$PWD"; GUARD_TREE_DIR="$PWD"
        guard_run_driver "$2" HEAD /dev/null "$3" > /dev/null' _ "$WORK/plugin" "$row" "$tmp" )
    cat "$tmp/output"
}

@test "a driver without sandbox in describe runs sandboxed" {
    new_repo "$TREE"; commit_all init
    probe_driver '{"name":"probe","needs_tree":true}'
    run run_driver
    [ ! -e "$TREE/made.txt" ]
    [[ "$output" == *'Permission denied'* ]]
}

@test "a sandboxed run logs sandbox: armed in its row log" {
    new_repo "$TREE"; commit_all init
    probe_driver '{"name":"probe","needs_tree":true,"sandbox":true}'
    run run_driver
    [ "$(tail -1 <<<"$output")" = 'sandbox: armed' ]
}

@test "a driver with sandbox false runs unsandboxed" {
    new_repo "$TREE"; commit_all init
    probe_driver '{"name":"probe","needs_tree":true,"sandbox":false}'
    run run_driver
    [ -e "$TREE/made.txt" ]
}

@test "an unsandboxed driver still gets the clean child environment and no armed line" {
    new_repo "$TREE"; commit_all init
    probe_driver '{"name":"probe","needs_tree":true,"sandbox":false}'
    run run_driver
    [[ "$output" != *'SECRET_TOKEN'* ]]
    [[ "$output" == *'QG_PRIVATE='* ]]
    [[ "$output" != *'sandbox: armed'* ]]
}

@test "qg_sandbox_run with QG_SANDBOX unset runs sandboxed with no tree writes" {
    unset QG_SANDBOX QG_SANDBOX_WRITES
    run probe write x.txt
    [ "$output" = 'denied x.txt' ]
    QG_SANDBOX=0 run probe write x.txt
    [ "$output" = 'ok x.txt' ]
}

@test "with --max-abi 5 the wrapper never arms and with 6 it arms with scoping" {
    sleep 30 &
    local pid=$!
    run /code/bin/qg-sandbox --max-abi 5 --write "$WORK/out" --armed "$WORK/out/armed" -- python3 -I "$PROBE" kill "$pid"
    [ "$status" -eq 125 ] && [ ! -e "$WORK/out/armed" ]
    [[ "$output" == *'Landlock ABI 5 is below 6'* ]]
    run /code/bin/qg-sandbox --max-abi 6 --write "$WORK/out" --armed "$WORK/out/armed" -- python3 -I "$PROBE" kill "$pid"
    [ "$status" -eq 0 ] && [ -e "$WORK/out/armed" ]
    [ "$output" = 'kill errno 1' ]
    kill "$pid"
}

@test "syscall 0x40000000 and io_uring_setup return ENOSYS while 0x3fffffff is not filtered" {
    local outside
    outside="$(python3 -I "$PROBE" nr 0x3fffffff)"
    run probe nr 0x3fffffff
    [ "$output" = "$outside" ]
    run probe nr 0x40000000
    [ "$output" = 'nr errno 38' ]
    run probe nr 425
    [ "$output" = 'nr errno 38' ]
}

@test "socket with AF_UNIX in the low 32 bits and high bits set is still refused" {
    run probe unixhigh
    [ "$output" = 'unixhigh errno 13' ]
    QG_SANDBOX=0 run probe unixhigh
    [ "$output" = 'unixhigh ok' ]
}

@test "AF_INET, AF_INET6 and socketpair AF_UNIX still work inside the sandbox" {
    local outside
    outside="$(python3 -I "$PROBE" inet)"
    run probe inet
    [ "$output" = "$outside" ]
    [[ "$output" == *'inet ok'* ]] && [[ "$output" == *'socketpair ok'* ]]
}

@test "a missing declared folder is created inside the tree before the run" {
    QG_SANDBOX_WRITES='reports/mutation' run probe write reports/mutation/m.json
    [ "$output" = 'ok reports/mutation/m.json' ]
    [ -d "$TREE/reports/mutation" ] && [ ! -L "$TREE/reports" ]
}

@test "an absolute or dot-dot declared path is refused and nothing is created outside the tree" {
    QG_SANDBOX_WRITES="$WORK/abs" run probe write "$WORK/abs/x"
    [ "$status" -eq 125 ] && [[ "$output" == *"declared path $WORK/abs is absolute"* ]]
    QG_SANDBOX_WRITES='../escape' run probe write ../escape/x
    [ "$status" -eq 125 ] && [[ "$output" == *'leaves the tree'* ]]
    [ ! -e "$WORK/abs" ] && [ ! -e "$WORK/escape" ]
}

@test "a declared path under a symlinked parent folder is refused" {
    mkdir -p "$WORK/elsewhere"
    ln -s "$WORK/elsewhere" "$TREE/build"
    QG_SANDBOX_WRITES='build/reports' run probe write build/reports/x
    [ "$status" -eq 125 ] && [[ "$output" == *'passes through the symlink'* ]]
    [ ! -e "$WORK/elsewhere/reports" ]
}

@test "a declared path naming .git, ., or node_modules is refused and an empty entry is skipped" {
    local w
    for w in .git lib/.git/x . node_modules; do
        QG_SANDBOX_WRITES="$w" run probe write x
        [ "$status" -eq 125 ] || { echo "$w was granted"; return 1; }
    done
    QG_SANDBOX_WRITES='  coverage   ' run probe write coverage/x
    [ "$status" -eq 0 ] && [ "$output" = 'ok coverage/x' ]
}

@test "without QG_SANDBOX_SDK the child gets no FLUTTER_ROOT and no SDK grant" {
    fake_sdk "$WORK/sdk"
    run sb "qg_sandbox_run -- env"
    [[ "$output" != *'FLUTTER_ROOT='* ]] && [[ "$output" != *'FLUTTER_ALREADY_LOCKED='* ]]
    run probe write "$WORK/sdk/bin/cache/engine.stamp"
    [ "$output" = "denied $WORK/sdk/bin/cache/engine.stamp" ]
    QG_SANDBOX_SDK="$WORK/sdk" run sb "qg_sandbox_run -- env"
    [[ "$output" == *"FLUTTER_ROOT=$WORK/sdk"* ]] && [[ "$output" == *'FLUTTER_ALREADY_LOCKED=true'* ]]
}

@test "every write target outside the grant set fails and every one inside succeeds" {
    fake_sdk "$WORK/sdk"
    mkdir -p "$TREE/src" "$WORK/elsewhere"
    export QG_SANDBOX_SDK="$WORK/sdk" QG_SANDBOX_WRITES='coverage .nuxt'
    run sb "qg_sandbox_run --cwd \"\$QG_TREE\" -- sh -c 'python3 -I $PROBE write \"\$QG_PRIVATE/p\" /dev/null coverage/c .nuxt/n \
        $WORK/sdk/bin/cache/engine.stamp $WORK/sdk/bin/cache/lockfile src/s top $WORK/elsewhere/e $WORK/out/o \
        $WORK/sdk/bin/cache/fresh.stamp $HOME/h /tmp/qg-sandbox-escape-\$\$'"
    [ "$(grep -c '^ok ' <<<"$output")" -eq 6 ]
    [ "$(grep -c '^denied ' <<<"$output")" -eq 7 ]
    ! grep -E '^ok .*(src/s|top|elsewhere|out/o|fresh|/h$|escape)' <<<"$output" || return 1
}

@test "the tool sentinel never exists without the armed marker" {
    local abi
    for abi in 5 6; do
        printf '#!/bin/sh\nexec %q --max-abi %s "$@"\n' /code/bin/qg-sandbox "$abi" > "$WORK/wrap"; chmod +x "$WORK/wrap"
        rm -f "$TREE/coverage/sentinel"
        QG_SANDBOX_WRITES=coverage run bash -c ". $LIB; QG_SANDBOX_BIN=$WORK/wrap
            qg_sandbox_run --cwd \"\$QG_TREE\" -- sh -c 'echo s > coverage/sentinel'; echo \"armed=\$QG_SANDBOX_ARMED\""
        if [ -e "$TREE/coverage/sentinel" ]; then [[ "$output" == *'armed=1'* ]] || return 1
        else [[ "$output" == *'armed='* ]]; fi
    done
    [ "$abi" = 6 ] && [ -e "$TREE/coverage/sentinel" ]
}

@test "the child sees only the listed names whatever the parent exports, with QG_SANDBOX 0 or 1" {
    local v names
    unset LANG
    export SECRET_TOKEN=x NODE_OPTIONS=--require=x GIT_DIR=/x QG_ARGS=a QG_FILES=/dev/null \
        QG_RUNNER=r QG_RUN_DIR="$WORK" QG_CONFIG_REV=c QG_BASE=b QG_BASES=b QG_TARGET=t QG_REPO=r QG_SANDBOX_WRITES=
    for v in 0 1; do
        names="$(QG_SANDBOX="$v" sb "qg_sandbox_run -- env" | cut -d= -f1 | sort | tr '\n' ' ')"
        [ "$names" = 'HOME LC_ALL PATH PUB_CACHE QG_ARGS QG_BASE QG_BASES QG_CACHE QG_CONFIG_REV QG_FILES QG_OUT QG_PRIVATE QG_REPO QG_ROW QG_RUNNER QG_RUN_DIR QG_TARGET QG_TREE TMPDIR ' ] \
            || { echo "QG_SANDBOX=$v: $names"; return 1; }
    done
    QG_SANDBOX=1 run sb "qg_sandbox_run -- env"
    [[ "$output" == *"PUB_CACHE=$HOME/.pub-cache"* ]]
}

@test "the private folder is removed after a pass, a failure and an unarmed run" {
    mkdir -p "$WORK/tmp"
    export TMPDIR="$WORK/tmp"
    run sb 'qg_sandbox_run -- sh -c "echo \$QG_PRIVATE; mkdir \$QG_PRIVATE/ro; chmod 500 \$QG_PRIVATE/ro"'
    [ "$status" -eq 0 ] && [ ! -e "$output" ]
    run sb 'qg_sandbox_run -- sh -c "exit 3"'
    [ "$status" -eq 3 ]
    printf '#!/bin/sh\nexit 0\n' > "$WORK/never"; chmod +x "$WORK/never"
    run bash -c ". $LIB; QG_SANDBOX_BIN=$WORK/never; qg_sandbox_run -- true; echo \"rc=\$? \$QG_SANDBOX_ERROR\""
    [[ "$output" == 'rc=125 qg-sandbox: the sandbox did not arm'* ]]
    [ -z "$(ls -A "$WORK/tmp")" ]
}

@test "the same repo driver on the same tree gives the same row sandboxed and unsandboxed" {
    printf 'a\nb\nc\n' > "$TREE/a.txt"
    cat > "$WORK/driver" <<'EOF'
#!/usr/bin/env bash
n="$(cat "$QG_TREE"/*.txt | wc -l)"
printf '{"schema":"qg.result/1","driver":"lines","status":"measured","metric":%d,"findings":[],"error":null}\n' "$n" > "$QG_OUT/result.json"
EOF
    chmod +x "$WORK/driver"
    sb "QG_SANDBOX=1 qg_sandbox_run --out -- $WORK/driver"
    mv "$QG_OUT/result.json" "$WORK/sandboxed.json"
    sb "QG_SANDBOX=0 qg_sandbox_run --out -- $WORK/driver"
    [ "$(jq -c . "$WORK/sandboxed.json")" = "$(jq -c . "$QG_OUT/result.json")" ]
    [ "$(jq -r .metric "$QG_OUT/result.json")" = 3 ]
}

@test "a commit tree whose runner links node_modules measures nuxt-typecheck sandboxed" {
    # The main checkout holds node_modules and .nuxt; the staged tree has neither, as in commit mode.
    mkdir -p "$WORK/main/node_modules/.bin" "$WORK/main/node_modules/.cache" "$WORK/main/.nuxt"
    { printf '#!/usr/bin/env bash\n'
      printf 'echo x > .nuxt/types.d.ts && echo "nuxt dir written"\n'
      printf 'echo y > node_modules/.cache/escaped 2>/dev/null || echo "linked cache refused"\n'
      printf 'echo "app.vue(1,1): error TS2322: wrong type"\nexit 1\n'
    } > "$WORK/main/node_modules/.bin/nuxt"
    chmod +x "$WORK/main/node_modules/.bin/nuxt"
    # The runner does what in-node.sh does in commit mode, then runs the sandboxed argv.
    { printf '#!/usr/bin/env bash\ntree="$1"; shift 2\n'
      printf '[ ! -e "$tree/node_modules" ] || { echo "node_modules is already in the tree" >&2; exit 2; }\n'
      printf 'ln -s %q "$tree/node_modules" && rm -rf "$tree/.nuxt" && cp -R %q "$tree/.nuxt" || exit 2\n' \
          "$WORK/main/node_modules" "$WORK/main/.nuxt"
      printf 'cd "$tree" && exec "$@"\n'
    } > "$WORK/runner"
    chmod +x "$WORK/runner"
    export QG_RUNNER="$WORK/runner" QG_SANDBOX_WRITES="$(/code/drivers/nuxt-typecheck.sh describe | jq -r '.writes | join(" ")')"
    QG_ARGS='runner=quality/bin/in-node.sh' run /code/drivers/nuxt-typecheck.sh run
    [ "$(jq -r .status "$QG_OUT/result.json")" = measured ] || { echo "$output"; return 1; }
    [ "$(jq -r .metric "$QG_OUT/result.json")" = 1 ]
    [ -L "$TREE/node_modules" ] && [ -s "$TREE/.nuxt/types.d.ts" ]
    [ ! -e "$WORK/main/node_modules/.cache/escaped" ]
    [[ "$output" == *'node_modules/.cache is reached through a symlink; not writable'* ]]
}

@test "the armed record never follows a symlink a repo driver plants" {
    new_repo "$TREE"; commit_all init
    mkdir -p "$WORK/plugin/drivers"
    cp -R /code/lib /code/bin "$WORK/plugin/"
    : > "$WORK/target"
    # A repo driver may write QG_OUT; it plants links where an armed record could be appended.
    mkdir -p quality/drivers
    { printf '#!/usr/bin/env bash\ncase "$1" in describe) echo "{\\"name\\":\\"mine\\",\\"needs_tree\\":false}";;\n'
      printf '  run) ln -s %q "$QG_OUT/.qg-sandbox.log"; ln -s %q "$QG_OUT/../sandbox.log" 2>/dev/null\n' "$WORK/target" "$WORK/target"
      printf '       echo "{\\"schema\\":\\"qg.result/1\\",\\"status\\":\\"measured\\",\\"metric\\":0,\\"findings\\":[],\\"error\\":null}" > "$QG_OUT/result.json";;\n'
      printf '  *) exit 2;; esac\n'
    } > quality/drivers/mine.sh
    chmod +x quality/drivers/mine.sh
    commit_all driver
    local row tmp
    row="$(printf '%s\t' r commit diff mine - down 0 refuse why - - -)"
    tmp="$WORK/run"; mkdir -p "$tmp"
    bash -c '. "$1/lib/qg-driver.sh"; REPO_ROOT="$PWD"; GUARD_TREE_DIR="$PWD"; GUARD_CONFIG_REV="$(git rev-parse HEAD)"
        guard_cfg_show() { git show "${GUARD_CONFIG_REV}:$1"; }
        guard_run_driver "$2" HEAD /dev/null "$3"' _ "$WORK/plugin" "$row" "$tmp"
    [ ! -s "$WORK/target" ]
    [ "$(tail -1 "$tmp/output")" = 'sandbox: armed' ]
    [ ! -L "$tmp/sandbox.log" ]
}

@test "socketpair is refused unless it is SOCK_STREAM, whatever its CLOEXEC and NONBLOCK flags" {
    run probe dgrampair
    [ "$output" = $'dgram errno 13\nseqpacket errno 13\nstream-cloexec ok' ]
    QG_SANDBOX=0 run probe dgrampair
    [ "$output" = $'dgram ok\nseqpacket ok\nstream-cloexec ok' ]
}

@test "chown and setting or removing an extended attribute are refused; chmod and utime are not" {
    mkdir -p "$TREE/out"; : > "$TREE/out/f"
    QG_SANDBOX_WRITES=out run probe owner out/f
    [ "$output" = $'chown errno 1\nlchown errno 1\nsetxattr errno 1\nremovexattr errno 1\nchmod ok\nutime ok' ]
    # The control: unsandboxed, chown to oneself succeeds.
    QG_SANDBOX=0 run probe owner "$TREE/out/f"
    [[ "$output" == *'chown ok'* ]]
}

@test "a descendant that starts its own session is killed when the tool exits" {
    QG_SANDBOX_WRITES=rec run probe escape rec/escaped.pid
    [ "$output" = 'escape started' ] || { echo "$output"; return 1; }
    local pid state
    pid="$(cat "$TREE/rec/escaped.pid")"
    [ -n "$pid" ]
    state="$(awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || true)"
    [ -z "$state" ] || [ "$state" = Z ] || { kill "$pid"; echo "escaped $pid still running"; return 1; }
}

@test "a declared path that exists as a file is refused, and a hard-linked file grant is refused" {
    : > "$TREE/coverage"
    QG_SANDBOX_WRITES=coverage run probe write x
    [ "$status" -eq 125 ] && [[ "$output" == *'declared path coverage is not a folder'* ]]
    : > "$WORK/one"; ln "$WORK/one" "$WORK/two"
    run /code/bin/qg-sandbox --write "$WORK/out" --write "$WORK/one" --armed "$WORK/out/armed" -- true
    [ "$status" -eq 125 ] && [ ! -e "$WORK/out/armed" ]
    [[ "$output" == *"grant $WORK/one is a file with 2 links"* ]]
}

@test "a tool that kills its sandbox parent cannot leave a session-escaped grandchild alive" {
    mkdir -p "$TREE/rec"
    # The tool starts a grandchild in its own session, records its pid, then signals its parent.
    { printf '#!/usr/bin/env bash\n'
      printf 'setsid sleep 4242 > /dev/null 2>&1 < /dev/null & echo "$!" > rec/grandchild.pid\n'
      printf 'sleep 0.2\nkill -KILL "$PPID" 2>/dev/null && echo "parent killed" || echo "parent kill refused"\n'
      printf 'kill -STOP "$PPID" 2>/dev/null && echo "parent stopped" || echo "parent stop refused"\nexit 3\n'
    } > "$TREE/tool"
    chmod +x "$TREE/tool"
    QG_SANDBOX_WRITES=rec run timeout 30 bash -c ". $LIB; qg_sandbox_run --cwd \"\$QG_TREE\" -- ./tool"
    [ "$status" -eq 3 ]
    [[ "$output" == *'parent kill refused'* ]] && [[ "$output" == *'parent stop refused'* ]]
    local pid state
    pid="$(cat "$TREE/rec/grandchild.pid")"
    [ -n "$pid" ]
    state="$(awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || true)"
    [ -z "$state" ] || [ "$state" = Z ] || { kill -KILL "$pid"; echo "grandchild $pid still running"; return 1; }
}

@test "a runner that prepares nothing still gets its report folder created and writable" {
    { printf '#!/usr/bin/env bash\ntree="$1"; shift 2\ncd "$tree" && exec "$@"\n'; } > "$WORK/runner"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "<testsuites/>" > quality-reports/junit.xml' > "$TREE/vitest"
    chmod +x "$WORK/runner" "$TREE/vitest"
    [ ! -e "$TREE/quality-reports" ]
    QG_RUNNER="$WORK/runner" run bash -c ". /code/lib/qg-driver-kit.sh
        qg_tool quality-reports/junit.xml '0 1' ./vitest || { echo \"ERR: \$QG_ERROR\"; exit 3; }"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -s "$TREE/quality-reports/junit.xml" ] && [ -d "$TREE/quality-reports" ] && [ ! -L "$TREE/quality-reports" ]
}

@test "a file moves or links across folders inside a grant, as pub's precompile does" {
    QG_SANDBOX_WRITES=.dart_tool run probe rename .dart_tool/pub/bin
    [ "$output" = 'rename ok' ]
    [ -s "$TREE/.dart_tool/pub/bin/f" ]
    # Out of the grant the move is still refused.
    mkdir -p "$TREE/src/tmp"; : > "$TREE/src/tmp/f"
    run probe rename src
    [ "$output" != 'rename ok' ]
}
