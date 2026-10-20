#!/usr/bin/env bats
# bin/guard.sh and templates/claude-hooks/guard_bash.py — the environment variables the gate reads.
#
# GUARD_SKIP drops rows and GUARD_CONFIG_REV picks the config that judges. An inherited GUARD_SKIP
# never reaches a run; only `baseline --skip` sets it. GUARD_CONFIG_REV is honoured outside an
# agent session (the agent factory) and ignored when CLAUDECODE or AI_AGENT is present, even empty.

load guard-helpers

COV_ROW=$'cov\trelease\trepo\techo 80\t-\t-\tup\t0\trefuse'
HOOKS=/code/templates/claude-hooks

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON GUARD_CONFIG_REV GUARD_SHA GUARD_BASE GUARD_SKIP CLAUDECODE AI_AGENT
    gate_repo "$WORK/repo"
    write_checks "$BAD_ROW" "$COV_ROW"
    printf 'id\tvalue\tcommit\treason\ncov\t80\tabc\t-\n' > quality/baseline.tsv
    commit_all baseline
    BASE="$(git rev-parse HEAD)"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

hook() {
    jq -nc --arg c "$1" --arg d "$PWD" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
        | "$HOOKS/guard-bash.sh" > /dev/null 2>&1
}

@test "commit: an inherited GUARD_SKIP skips no row" {
    printf 'BAD\n' > app/a.php
    git add app/a.php
    for skip in . 'bad-in-tree' '.*' 'b.*'; do
        GUARD_SKIP="$skip" run bash /code/bin/guard.sh commit
        [ "$status" -eq 1 ] || { echo "GUARD_SKIP=$skip passed"; return 1; }
        [[ "$output" == *'bad-in-tree'* ]]
        [[ "$output" != *'skipped'* ]]
    done
}

@test "release: an inherited GUARD_SKIP skips no row" {
    write_checks "$BAD_ROW" $'cov\trelease\trepo\techo 70\t-\t-\tup\t0\trefuse'
    commit_all 'coverage drops to 70'
    for skip in . cov '.*'; do
        GUARD_SKIP="$skip" GUARD_SHA="$(git rev-parse HEAD)" GUARD_BASE="$BASE" run bash /code/bin/guard.sh release refs/heads/release/x
        [ "$status" -eq 1 ] || { echo "GUARD_SKIP=$skip passed"; return 1; }
        [[ "$output" == *'cov'*'80'*'70'* ]]
    done
}

@test "baseline --skip still keeps the skipped row's existing value" {
    write_checks $'cov\trelease\trepo\techo 80\t-\t-\tup\t0\trefuse' $'dup\trelease\trepo\techo 5\t-\t-\tdown\t0\trefuse'
    printf 'id\tvalue\tcommit\treason\ncov\t60\told\t-\ndup\t9\told\t-\n' > quality/baseline.tsv
    commit_all two-rows
    run bash /code/bin/guard.sh baseline --skip '^cov$'
    [ "$status" -eq 0 ]
    grep -qP '^cov\t60\told\t-$' quality/baseline.tsv
    grep -qP '^dup\t5\t' quality/baseline.tsv
}

@test "GUARD_CONFIG_REV is honoured without agent markers and ignored with either, even empty" {
    write_checks "$COV_ROW"
    commit_all 'drop the bad row'
    printf 'BAD\n' > app/a.php
    commit_all 'bad code'
    GUARD_CONFIG_REV="$BASE" run bash /code/bin/guard.sh verify HEAD~1..HEAD
    [ "$status" -eq 1 ]
    for marker in CLAUDECODE=1 CLAUDECODE= AI_AGENT=1 AI_AGENT=; do
        rm -rf "$(git rev-parse --path-format=absolute --git-common-dir)/guard-pass"
        run env "$marker" GUARD_CONFIG_REV="$BASE" bash /code/bin/guard.sh verify HEAD~1..HEAD
        [ "$status" -eq 0 ] || { echo "$marker: pin honoured"; return 1; }
    done
}

@test "an agent may not set or export a gate variable beside any command" {
    local bad='' c
    for c in 'GUARD_SKIP=. git push' 'export GUARD_SKIP=.; git push' 'env GUARD_SKIP=. git push -u origin x' \
             'GUARD_CONFIG_REV=HEAD~40 git push' 'GUARD_CONFIG_REV=HEAD~1 git commit -m x' \
             'declare -x GUARD_CONFIG_AT=abc; git commit -m x' 'QG_ANYTHING=1 git commit -m x' \
             'bash -c "GUARD_SKIP=. git push"' 'GUARD_SHA=abc make release' 'sh -c "export GUARD_SKIP=x"'; do
        hook "$c" && bad+=$'\n'"allowed: $c"
    done
    [ -z "$bad" ] || { printf '%s\n' "$bad"; return 1; }
}

@test "reading a gate variable and the plain commands stay allowed" {
    local bad='' c
    for c in 'git push -u origin feat/x' 'git commit -m "fix the GUARD_SKIP handling"' 'echo $GUARD_SKIP' \
             'grep -rn GUARD_CONFIG_REV lib' 'env | grep GUARD_'; do
        hook "$c" || bad+=$'\n'"denied: $c"
    done
    [ -z "$bad" ] || { printf '%s\n' "$bad"; return 1; }
}

# --- the clean start of every entry (lib/qg-clean-env.sh) -------------------------------------
#
# Each "same verdict" case commits through the real installed hooks with a row the injected name
# would pass if it reached the gate, and a control showing the injection works in a plain shell.

# A commit row the tree refuses (BAD in app/), unless NODE_OPTIONS or LEAK_PROBE reaches it, or a
# BASH_ENV file or exported function replaces wc. It also starts python3, which a leaked
# PYTHONPATH would make import $WORK/py/sitecustomize.py.
LEAK_ROW=$'bad-in-tree\tcommit\tdiff\tpython3 -c 1 >/dev/null 2>&1; { [ -n "${NODE_OPTIONS:-}${LEAK_PROBE:-}" ] && echo 0; } || grep -rl BAD {{tree}}/app 2>/dev/null | wc -l\t-\t-\tdown\t0\trefuse'
PROBE='{ [ -n "${NODE_OPTIONS:-}${LEAK_PROBE:-}" ] && echo 0; } || printf "BAD\n" | wc -l'
SYSTEM_PATH=/usr/local/bin:/usr/bin:/bin
V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

install_hooks() { bash /code/bin/guard.sh hooks install > /dev/null; }
# at_tty <command> — runs it under a pseudo-terminal with the agent markers removed.
at_tty() { script -qec "env -u CLAUDECODE -u AI_AGENT -u QG_SKIP_REASON bash -c $(printf '%q' "$1")" /dev/null; }

leak_setup() {
    write_checks "$LEAK_ROW" "$COV_ROW"
    commit_all leak-row
    install_hooks
    mkdir -p "$WORK/py"
    printf 'open("%s/py-marker", "w").close()\n' "$WORK" > "$WORK/py/sitecustomize.py"
    printf 'wc() { echo 0; }\n' > "$WORK/bash-env.sh"
    printf 'BAD\n' > app/a.php
    git add app/a.php
}

# fake_path — $WORK/fake holds bash, env, awk and git that leave a marker and run the real one.
fake_path() {
    local p
    mkdir -p "$WORK/fake"
    for p in bash env awk git; do
        printf '#!/bin/sh\n: > %s/fake-%s\nexec %s "$@"\n' "$WORK" "$p" "$(command -v "$p")" > "$WORK/fake/$p"
        chmod +x "$WORK/fake/$p"
    done
}

# plugin_copy <dir> — a writable git checkout of the plugin, to hold the machine tool-path file.
plugin_copy() {
    mkdir -p "$1"
    cp -r /code/bin /code/lib /code/templates /code/drivers /code/extend "$1/"
    git -C "$1" init -q .
    git -C "$1" -c user.email=t@e -c user.name=t add -A
    git -C "$1" -c user.email=t@e -c user.name=t commit -q -m plugin
}

# child_path <tool-path file content> — the PATH a row run by the copied plugin's guard.sh sees.
child_path() {
    [ -d "$WORK/plugin" ] || plugin_copy "$WORK/plugin"
    printf '%s' "$1" > "$WORK/plugin/.git/qg-tool-path"
    write_checks "path-probe"$'\tcommit\tdiff\t'"printf '%s' \"\$PATH\" > $WORK/child-path; echo 0"$'\t-\t-\tdown\t0\trefuse'
    commit_all probe
    printf 'x\n' >> app/b.php; git add app/b.php
    rm -f "$WORK/child-path"
    "$WORK/plugin/bin/guard.sh" commit > /dev/null 2>&1
    cat "$WORK/child-path"
}

# stub_plugin — $WORK/plugin with a stub bin/guard.sh that logs "<args>" to $WORK/ran and refuses
# refs/heads/c, the real libraries, and the hooks installed from the templates into $WORK/hooks.
stub_plugin() {
    local h
    mkdir -p "$WORK/plugin/bin" "$WORK/plugin/lib" "$WORK/hooks"
    ln -s /code/lib/* "$WORK/plugin/lib/"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %s/ran\nenv >> %s/stub-env\n[ "$3" = refs/heads/c ] && { echo "refused $3" >&2; exit 1; }\nexit 0\n' \
        "$WORK" "$WORK" > "$WORK/plugin/bin/guard.sh"
    chmod +x "$WORK/plugin/bin/guard.sh"
    for h in pre-push pre-commit pre-merge-commit pre-applypatch post-rewrite; do
        sed "s|__GUARD_SH__|$WORK/plugin/bin/guard.sh|g" "/code/templates/git-hooks/$h" > "$WORK/hooks/$h"
        chmod +x "$WORK/hooks/$h"
    done
}

record_all() {
    local c
    for c in $(git rev-list --all); do ( . /code/lib/guard-pass.sh; guard_pass_write "$(guard_pass_key_of_commit "$c")" ok ); done
}

@test "a git hook reaches the same verdict with BASH_ENV, BASH_FUNC_ or NODE_OPTIONS set" {
    leak_setup
    [ "$(env 'BASH_FUNC_wc%%=() { echo 0; }' bash -c "$PROBE")" = 0 ]
    [ "$(BASH_ENV="$WORK/bash-env.sh" bash -c "$PROBE")" = 0 ]
    [ "$(NODE_OPTIONS=--no-warnings bash -c "$PROBE")" = 0 ]
    [ "$(bash -c "$PROBE")" = 1 ]
    local head inj; head="$(git rev-parse HEAD)"
    run git commit -q -m plain
    [ "$status" -ne 0 ]
    for inj in 'BASH_FUNC_wc%%=() { echo 0; }' "BASH_ENV=$WORK/bash-env.sh" 'NODE_OPTIONS=--no-warnings'; do
        run env "$inj" git commit -q -m injected
        [ "$status" -ne 0 ] || { echo "$inj passed the commit"; return 1; }
        [ "$(git rev-parse HEAD)" = "$head" ]
    done
}

@test "a git hook reaches the same verdict with LD_PRELOAD or PYTHONPATH set" {
    leak_setup
    PYTHONPATH="$WORK/py" python3 -c 1
    [ -e "$WORK/py-marker" ]
    rm -f "$WORK/py-marker"
    local head; head="$(git rev-parse HEAD)"
    run env LD_PRELOAD=/nonexistent/qg-preload.so git commit -q -m injected
    [ "$status" -ne 0 ]
    run env PYTHONPATH="$WORK/py" git commit -q -m injected
    [ "$status" -ne 0 ]
    [ "$(git rev-parse HEAD)" = "$head" ]
    [ ! -e "$WORK/py-marker" ]
}

@test "a git hook reaches the same verdict with a fake bash, env, awk or git earlier on PATH" {
    leak_setup
    fake_path
    PATH="$WORK/fake:$PATH" bash -c 'awk "BEGIN{}"; git --version; env true' > /dev/null
    [ -e "$WORK/fake-bash" ] && [ -e "$WORK/fake-awk" ] && [ -e "$WORK/fake-git" ] && [ -e "$WORK/fake-env" ]
    rm -f "$WORK"/fake-*
    local head; head="$(git rev-parse HEAD)"
    run env PATH="$WORK/fake:$PATH" /usr/bin/git commit -q -m injected
    [ "$status" -ne 0 ]
    [ "$(git rev-parse HEAD)" = "$head" ]
    run ls "$WORK"/fake-*
    [ "$status" -ne 0 ] || { echo "a fake program ran: $output"; return 1; }
}

@test "a git hook ignores GUARD_CONFIG_REV" {
    write_checks "$COV_ROW"
    commit_all 'no bad row'
    local old; old="$(git rev-parse HEAD)"
    write_checks "$BAD_ROW" "$COV_ROW"
    commit_all 'bad row back'
    install_hooks
    printf 'BAD\n' > app/a.php; git add app/a.php
    GUARD_CONFIG_REV="$old" run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    local head; head="$(git rev-parse HEAD)"
    GUARD_CONFIG_REV="$old" run git commit -q -m pinned
    [ "$status" -ne 0 ]
    [ "$(git rev-parse HEAD)" = "$head" ]
}

@test "a driver and a repo runner started by a hook see none of the caller's extra names" {
    local names='^(LEAK_PROBE|NODE_OPTIONS|BASH_ENV|BASH_FUNC_)'
    mkdir -p quality/drivers
    { printf '#!/usr/bin/env bash\n'
      printf 'case "$1" in describe) echo "{\\"name\\":\\"probe\\",\\"requires\\":[],\\"needs_tree\\":false}";;\n'
      printf '  run) n="$(env | grep -c -E "%s")"; echo "{\\"schema\\":\\"qg.result/1\\",\\"status\\":\\"measured\\",\\"metric\\":$n,\\"findings\\":[],\\"error\\":null}" > "$QG_OUT/result.json";;\n' "$names"
      printf '  *) exit 2;; esac\n'
    } > quality/drivers/probe.sh
    chmod +x quality/drivers/probe.sh
    { printf '%s\n' "$V2_HEADER"
      printf 'leak-driver\tcommit\tdiff\tprobe\t-\tdown\t0\trefuse\tthe driver sees no caller name\n'
      printf 'leak-runner\tcommit\tdiff\tshell\t-- env | grep -c -E "%s" || true\tdown\t0\trefuse\tthe runner sees no caller name\n' "$names"
    } > quality/checks.tsv
    commit_all probe
    install_hooks
    [ "$(env LEAK_PROBE=1 bash -c "env | grep -c -E '$names'")" -ge 1 ]
    printf 'x\n' > app/b.php; git add app/b.php
    run env LEAK_PROBE=1 NODE_OPTIONS=--no-warnings 'BASH_FUNC_f%%=() { :; }' BASH_ENV=/dev/null git commit -q -m probe
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [ "$(git log -1 --format=%s)" = probe ]
}

@test "the skip reason from a human at a terminal still passes one commit" {
    install_hooks
    printf 'BAD\n' > app/a.php; git add app/a.php
    run at_tty "LEAK_PROBE=1 QG_SKIP_REASON='human hotfix' git commit -q -m skipped; echo rc=\$?"
    [[ "$output" == *'rc=0'* ]]
    [ "$(git log -1 --format=%s)" = skipped ]
    grep -q 'human hotfix' "$(git rev-parse --git-common-dir)/guard-bypass.log"
    printf 'BAD again\n' > app/c.php; git add app/c.php
    run at_tty 'git commit -q -m unskipped; echo rc=$?'
    [[ "$output" == *'rc=1'* ]]
}

@test "the skip reason with CLAUDECODE set is refused" {
    install_hooks
    printf 'BAD\n' > app/a.php; git add app/a.php
    local head; head="$(git rev-parse HEAD)"
    run at_tty "CLAUDECODE=1 QG_SKIP_REASON='agent says so' git commit -q -m skipped; echo rc=\$?"
    [[ "$output" == *'rc=1'* ]]
    [ "$(git rev-parse HEAD)" = "$head" ]
}

@test "pre-push still reads every ref on stdin after the clean restart" {
    stub_plugin
    fake_path
    printf 'wc() { echo 0; }\n' > "$WORK/bash-env.sh"
    local a b c z=0000000000000000000000000000000000000000
    printf 'a\n' > a.txt; commit_all a; a="$(git rev-parse HEAD)"
    printf 'b\n' > b.txt; commit_all b; b="$(git rev-parse HEAD)"
    printf 'c\n' > c.txt; commit_all c; c="$(git rev-parse HEAD)"
    record_all
    run env 'BASH_FUNC_wc%%=() { echo 0; }' BASH_ENV="$WORK/bash-env.sh" NODE_OPTIONS=--no-warnings PATH="$WORK/fake:$PATH" \
        "$WORK/hooks/pre-push" origin <<<"refs/heads/a $a refs/heads/a $z
refs/heads/b $b refs/heads/b $z
refs/heads/c $c refs/heads/c $z"
    [ "$status" -eq 1 ]
    [[ "$output" == *'refused refs/heads/c'* ]]
    grep -q 'release --use-pass refs/heads/a' "$WORK/ran"
    grep -q 'release --use-pass refs/heads/b' "$WORK/ran"
    grep -q 'release --use-pass refs/heads/c' "$WORK/ran"
    run ls "$WORK"/fake-*
    [ "$status" -ne 0 ]
}

@test "each entry restarts at most once and finishes under a 30 s timeout" {
    stub_plugin
    printf 'x\n' >> app/a.php; git add app/a.php
    local e
    for e in "$WORK/hooks/pre-commit" '/code/bin/guard.sh report' '/code/bin/qg help' '/code/bin/qg list'; do
        # shellcheck disable=SC2086
        run timeout 30 env LEAK_PROBE=1 'BASH_FUNC_f%%=() { :; }' $e
        [ "$status" -ne 124 ] || { echo "$e did not finish"; return 1; }
        [[ "$output" != *'after the clean restart'* ]] || { echo "$e restarted twice: $output"; return 1; }
    done
    # A process that claims the restart happened but still holds another name stops instead of looping.
    run timeout 30 env QG_CLEAN_ENV=1 LEAK_PROBE=1 /code/bin/guard.sh report
    [ "$status" -eq 2 ]
    [[ "$output" == *'LEAK_PROBE after the clean restart'* ]]
    run timeout 30 env -i HOME="$HOME" PATH="$SYSTEM_PATH" QG_CLEAN_ENV=1 /code/bin/qg help
    [ "$status" -eq 0 ]
}

@test "qg with extra names set reaches the same verdict as without them" {
    leak_setup
    fake_path
    printf '#!/bin/sh\n: > %s/fsmonitor-ran\n' "$WORK" > "$WORK/fsmonitor.sh"
    chmod +x "$WORK/fsmonitor.sh"
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0="$WORK/fsmonitor.sh" git status > /dev/null 2>&1
    [ -e "$WORK/fsmonitor-ran" ]
    rm -f "$WORK/fsmonitor-ran"
    local plain injected
    plain="$(/code/bin/qg run commit --json | jq -r '.rows[] | "\(.id)|\(.value)|\(.status)"')"
    [[ "$plain" == *'bad-in-tree|1|worse'* ]]
    injected="$(env 'BASH_FUNC_wc%%=() { echo 0; }' BASH_ENV="$WORK/bash-env.sh" NODE_OPTIONS=--no-warnings LEAK_PROBE=1 \
        PYTHONPATH="$WORK/py" PATH="$WORK/fake:$PATH" QG_CALLER_PATH=/forged \
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0="$WORK/fsmonitor.sh" \
        /code/bin/qg run commit --json | jq -r '.rows[] | "\(.id)|\(.value)|\(.status)"')"
    [ "$plain" = "$injected" ]
    [ ! -e "$WORK/fsmonitor-ran" ]
    [ ! -e "$WORK/py-marker" ]
}

@test "a caller's QG_SANDBOX=0 does not unsandbox a driver started by a hook" {
    mkdir -p quality/drivers
    { printf '#!/usr/bin/env bash\n'
      printf 'case "$1" in describe) echo "{\\"name\\":\\"quiet\\",\\"requires\\":[],\\"needs_tree\\":false}";;\n'
      printf '  run) echo "{\\"schema\\":\\"qg.result/1\\",\\"status\\":\\"measured\\",\\"metric\\":0,\\"findings\\":[],\\"error\\":null}" > "$QG_OUT/result.json";;\n'
      printf '  *) exit 2;; esac\n'
    } > quality/drivers/quiet.sh
    chmod +x quality/drivers/quiet.sh
    { printf '%s\n' "$V2_HEADER"
      printf 'quiet-row\tcommit\tdiff\tquiet\t-\tdown\t0\trefuse\ta driver that measures nothing\n'
    } > quality/checks.tsv
    commit_all quiet
    install_hooks
    printf 'clean\n' > app/b.php; git add app/b.php
    run env QG_SANDBOX=0 git commit -q -m sandboxed
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    grep -q 'sandbox: armed' "$(git rev-parse --git-common-dir)/qg-last/quiet-row/output.txt"
}

@test "a lone BASH_FUNC_x%% or X%=1 name in the caller environment still forces the clean restart" {
    stub_plugin
    printf 'x\n' >> app/a.php; git add app/a.php
    local inj
    for inj in 'BASH_FUNC_x%%=() { :; }' 'X%=1'; do
        rm -f "$WORK/stub-env"
        run env -i HOME="$HOME" PATH="$SYSTEM_PATH" "$inj" "$WORK/hooks/pre-commit"
        [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
        [ -s "$WORK/stub-env" ]
        run grep -E '^(BASH_FUNC_x|X%)' "$WORK/stub-env"
        [ "$status" -ne 0 ] || { echo "$inj reached the engine: $output"; return 1; }
    done
}

@test "bin/guard.sh called directly honours GUARD_CONFIG_REV without agent markers" {
    write_checks "$COV_ROW"
    commit_all 'drop the bad row'
    printf 'BAD\n' > app/a.php
    commit_all 'bad code'
    run env LEAK_PROBE=1 GUARD_CONFIG_REV="$BASE" /code/bin/guard.sh verify HEAD~1..HEAD
    [ "$status" -eq 1 ]
    rm -rf "$(git rev-parse --path-format=absolute --git-common-dir)/guard-pass"
    run env LEAK_PROBE=1 /code/bin/guard.sh verify HEAD~1..HEAD
    [ "$status" -eq 0 ]
}

@test "the skip reason given to bin/guard.sh directly skips nothing" {
    printf 'BAD\n' > app/a.php; git add app/a.php
    run at_tty "QG_SKIP_REASON='human hotfix' /code/bin/guard.sh commit > /dev/null 2>&1; echo rc=\$?"
    [[ "$output" == *'rc=1'* ]]
}

@test "a child of guard.sh sees PATH equal to the system folders plus the tool-path entries" {
    mkdir -p "$WORK/tools-a" "$WORK/tools-b"
    run child_path "$WORK/tools-a"$'\n'"$WORK/tools-b"$'\n'
    [ "$output" = "${SYSTEM_PATH}:$WORK/tools-a:$WORK/tools-b" ]
    rm -f "$WORK/plugin/.git/qg-tool-path"
    run child_path ''
    [ "$output" = "$SYSTEM_PATH" ]
}

@test "an absolute tool-path entry outside any work tree follows the system folders once on PATH" {
    mkdir -p "$WORK/tools"
    ln -s "$WORK/tools" "$WORK/tools-link"
    run child_path "$WORK/tools"$'\n'"$WORK/tools/"$'\n'"$WORK/tools-link"$'\n'
    [ "$output" = "${SYSTEM_PATH}:$WORK/tools" ]
}

@test "relative, empty, missing, file and in-work-tree tool-path entries are dropped from PATH" {
    mkdir -p "$WORK/tools"
    : > "$WORK/afile"
    run child_path $'rel/bin\n\n'"$WORK/missing"$'\n'"$WORK/afile"$'\n'"$WORK/repo/app"$'\n'"$WORK/tools"$'\n'
    [ "$output" = "${SYSTEM_PATH}:$WORK/tools" ]
    run bash -c ". '$WORK/plugin/lib/qg-toolpath.sh'; qg_tool_path_bad"
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 5 ]
    [[ "$output" == *$'rel/bin\tnot an absolute path'* ]]
    [[ "$output" == *$'\tempty entry'* ]]
    [[ "$output" == *"$WORK/missing"$'\tdoes not exist'* ]]
    [[ "$output" == *"$WORK/afile"$'\tnot a folder'* ]]
    [[ "$output" == *"$WORK/repo/app"$'\tinside a git work tree'* ]]
}
