#!/usr/bin/env bats
# templates/claude-hooks/guard-stop.sh — the Claude Code Stop hook that refuses to let a turn
# end while HEAD carries commits on no remote, in a repo whose committed VAULT.md names the
# plugin.

load guard-helpers

STOP=/code/templates/claude-hooks/guard-stop.sh

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset GUARD_STOP_LIMIT
    git init -q --bare "$WORK/origin.git"
    new_repo "$WORK/repo"
    printf 'plugins: vault-quality-gates\n' > VAULT.md
    commit_all init
    git branch -q -M master
    git remote add origin "$WORK/origin.git"
    git push -q origin master
    git switch -q -c feat/x
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

stop() {  # stop [<stop_hook_active>] [<session id>]
    printf '{"session_id":"%s","cwd":"%s","hook_event_name":"Stop","stop_hook_active":%s}' \
        "${2:-s1}" "$PWD" "${1:-false}" | bash "$STOP"
}

@test "no unpushed commit lets the turn end" {
    run stop
    [ "$status" -eq 0 ]
}

@test "an unpushed commit on a feature branch blocks with the push command" {
    printf 'x\n' > a.txt; commit_all work
    run stop
    [ "$status" -eq 2 ]
    [[ "$output" == *'git push -u origin feat/x'* ]]
    [[ "$output" == *'Never edit quality/baseline.tsv'* ]]
}

@test "stop_hook_active lets the turn end" {
    printf 'x\n' > a.txt; commit_all work
    run stop true
    [ "$status" -eq 0 ]
}

@test "on master it asks for a branch instead of a push" {
    git switch -q master
    printf 'x\n' > a.txt; commit_all work
    run stop
    [ "$status" -eq 2 ]
    [[ "$output" == *'git switch -c'* ]]
    [[ "$output" != *'git push -u origin master'* ]]
}

@test "a detached HEAD asks for a branch" {
    printf 'x\n' > a.txt; commit_all work
    git switch -q --detach HEAD
    run stop
    [ "$status" -eq 2 ]
    [[ "$output" == *'git switch -c'* ]]
}

@test "an upstream pointed at a local branch still blocks" {
    printf 'x\n' > a.txt; commit_all work
    git branch -q -u master
    git branch -q master2 HEAD
    run stop
    [ "$status" -eq 2 ]
}

@test "past the limit it lets the turn end and logs it" {
    printf 'x\n' > a.txt; commit_all work
    export GUARD_STOP_LIMIT=2
    run stop; [ "$status" -eq 2 ]
    run stop; [ "$status" -eq 2 ]
    run stop; [ "$status" -eq 0 ]
    grep -q 'stop hook gave up' "$(git rev-parse --git-common-dir)/guard-bypass.log"
}

@test "a repo that does not name the plugin is left alone" {
    printf 'nothing\n' > VAULT.md; commit_all unplug
    run stop
    [ "$status" -eq 0 ]
}

@test "outside a git repo it exits 0" {
    cd "$WORK"
    run stop
    [ "$status" -eq 0 ]
}
