#!/usr/bin/env bats
# guard-bash.sh and guard-edit.sh deny only what skips or weakens the commit gate or the push gate,
# and only in a gated repo; qg and guard.sh rules bind everywhere.

setup() {
    HOOKS="${BATS_TEST_DIRNAME}/../../templates/claude-hooks"
    WORK="$(mktemp -d)"
    git init -q -b feature "$WORK/gated"
    mkdir -p "$WORK/gated/.git/hooks"
    printf '#!/bin/sh\n# vault-guard-start\n# vault-guard-end\n' > "$WORK/gated/.git/hooks/pre-commit"
    git init -q -b main "$WORK/plain"
    git init -q -b main "$WORK/gated-main"
    printf '#!/bin/sh\n# vault-guard-start\n' > "$WORK/gated-main/.git/hooks/pre-push"
}

teardown() { rm -rf "$WORK"; }

bash_hook() {  # bash_hook <cwd> <command>
    jq -n --arg c "$2" --arg d "$1" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' | "$HOOKS/guard-bash.sh"
}

edit_hook() {  # edit_hook <cwd> <file>
    jq -n --arg f "$2" --arg d "$1" '{tool_name: "Edit", cwd: $d, tool_input: {file_path: $f}}' | "$HOOKS/guard-edit.sh"
}

@test "guard-bash allows commands that neither commit nor push" {
    local c
    for c in 'git worktree add ../x -b y' 'git branch -r --contains HEAD' 'bash -n quality/bin/in-server.sh' \
             'python3 -I /tmp/probe.py' 'rm -rf a b' 'git -C "$tree" status' 'git commit -m ok' \
             'git push -u origin feature' 'git config user.name x' 'qg run push --ref refs/heads/feature' 'qg explain x'; do
        run bash_hook "$WORK/gated" "$c"
        [ "$status" -eq 0 ] || { echo "denied: $c -> $output"; return 1; }
    done
}

@test "guard-bash denies skipping or weakening the gate in a gated repo" {
    local c
    for c in 'git commit -n -m x' 'git commit -am x --no-verify' 'git commit -anm x' 'git push --no-verify' \
             'git push --force' 'git push -f origin feature' 'git push origin +feature' 'git push origin HEAD:main' \
             'git push origin feature:refs/heads/master' 'git config core.hooksPath /tmp/h' \
             'git -c core.hooksPath=/tmp/h commit -m x' 'HUSKY=0 git commit -m x' 'cd sub && git commit -n -m x' \
             'bash -c "git commit -n -m x"' 'timeout 60 git push --force' 'GUARD_SKIP=. git push' \
             'export QG_ONLY=x' 'printf x > .git/guard-pass/key' 'echo x > .git/hooks/pre-commit' \
             'cp /tmp/x quality/config' 'echo x >> "$(git rev-parse --git-common-dir)/qg-override"'; do
        run bash_hook "$WORK/gated" "$c"
        [ "$status" -eq 2 ] || { echo "allowed: $c"; return 1; }
    done
}

@test "guard-bash denies a bare git push from a deploy branch" {
    run bash_hook "$WORK/gated-main" 'git push'
    [ "$status" -eq 2 ] && [[ "$output" == *'deploys'* ]]
}

@test "guard-bash lets git rules pass in a repo without the gate hook" {
    run bash_hook "$WORK/plain" 'git commit -n -m x'
    [ "$status" -eq 0 ]
    run bash_hook "$WORK/gated" "git -C $WORK/plain push --force"
    [ "$status" -eq 0 ]
    run bash_hook "$WORK/plain" "git -C $WORK/gated push --force"
    [ "$status" -eq 2 ]
}

@test "guard-bash denies gate-changing qg and guard.sh subcommands in every repo" {
    local c
    for c in 'qg override --reason x' 'qg baseline' 'qg accept' 'qg grant --agent 1h override' 'qg hooks install --claude --user' \
             'guard.sh hooks install'; do
        run bash_hook "$WORK/plain" "$c"
        [ "$status" -eq 2 ] || { echo "allowed: $c"; return 1; }
    done
    run bash_hook "$WORK/plain" 'qg grant --status'
    [ "$status" -eq 0 ]
}

@test "guard-edit denies the git dir, husky and gate files in a gated repo only" {
    local f
    for f in .git/hooks/pre-commit .git/config .husky/pre-commit quality/config quality/drivers/x.sh \
             quality/baseline.tsv quality/checks.tsv; do
        run edit_hook "$WORK/gated" "$WORK/gated/$f"
        [ "$status" -eq 2 ] || { echo "allowed: $f"; return 1; }
    done
    for f in src/a.php quality/bin/in-server.sh templates/claude-hooks/guard_bash.py; do
        run edit_hook "$WORK/gated" "$WORK/gated/$f"
        [ "$status" -eq 0 ] || { echo "denied: $f -> $output"; return 1; }
    done
    run edit_hook "$WORK/plain" "$WORK/plain/quality/config"
    [ "$status" -eq 0 ]
}
