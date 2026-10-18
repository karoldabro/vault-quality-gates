#!/usr/bin/env bats
# The one-shot override token (lib/guard-override.sh qg_override_write / qg_override_take) through
# the real installed hooks. script(1) gives a pseudo-terminal: the only way to be "a human at a
# terminal" in the test image. The token passes exactly the tree (commit) or sha (push) it names,
# once, within QG_OVERRIDE_TTL seconds, and only when the committing process is not an agent.

load guard-helpers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT
    gate_repo "$WORK/repo"
    ( export GUARD_LIB_DIR=/code/lib; . /code/lib/guard-metrics.sh; . /code/lib/guard-install.sh; guard_hooks_install >/dev/null )
    printf 'BAD\n' > app/a.php
    git add app/a.php
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

token() { printf '%s/qg-override' "$(git rev-parse --path-format=absolute --git-common-dir)"; }
# at_tty <command> — runs it under a pseudo-terminal with the agent markers removed.
at_tty() { script -qec "env -u CLAUDECODE -u AI_AGENT -u QG_SKIP_REASON bash -c $(printf '%q' "$1")" /dev/null; }
write_token() { at_tty ". /code/lib/guard-override.sh; qg_override_write $(printf '%q' "$1") ${2:-}"; }
commit_at_tty() { at_tty "git commit -q -m override-test 2>&1; echo rc=\$?"; }

@test "the token is written only with a reason, a terminal and no agent marker" {
    run write_token 'gate misreads vendor'
    [ -s "$(token)" ]
    rm -f "$(token)"
    run bash -c '. /code/lib/guard-override.sh; qg_override_write "no tty"'
    [ "$status" -eq 1 ] && [ ! -e "$(token)" ]
    run at_tty 'export CLAUDECODE=; . /code/lib/guard-override.sh; qg_override_write "agent"'
    [ ! -e "$(token)" ]
    run at_tty 'export AI_AGENT=1; . /code/lib/guard-override.sh; qg_override_write "agent"'
    [ ! -e "$(token)" ]
    run write_token '   '
    [ ! -e "$(token)" ]
}

@test "a token passes the refused commit of exactly that staged content, once, and logs it" {
    write_token 'tool broken, checked by hand'
    run commit_at_tty
    [[ "$output" == *'rc=0'* ]]
    [[ "$output" == *'override honoured and logged: tool broken, checked by hand'* ]]
    [ ! -e "$(token)" ]
    grep -q 'tool broken, checked by hand' "$(git rev-parse --git-common-dir)/guard-bypass.log"
    printf 'BAD again\n' > app/c.php; git add app/c.php
    run commit_at_tty
    [[ "$output" == *'rc=1'* ]]
}

@test "a token for other staged content is ignored and named" {
    write_token 'for the first tree'
    printf 'more\n' > app/extra.php; git add app/extra.php
    run commit_at_tty
    [[ "$output" == *'rc=1'* ]]
    [[ "$output" == *'token was ignored'*'not what is being committed'* ]]
}

@test "an agent's commit never consumes a valid token, and the token stays" {
    write_token 'human reason'
    run at_tty 'export CLAUDECODE=1; git commit -q -m agent 2>&1; echo rc=$?'
    [[ "$output" == *'rc=1'* ]]
    [[ "$output" == *'not a human at a terminal'* ]]
    [ -s "$(token)" ]
}

@test "a token older than 10 minutes, from the future, or malformed is ignored and deleted" {
    local tree now
    tree="$(git write-tree)"; now="$(date +%s)"
    printf 'r\tu\t%s\tcommit\t%s\n' "$((now - 601))" "$tree" > "$(token)"
    run commit_at_tty
    [[ "$output" == *'rc=1'* && "$output" == *'older than 10 minutes'* ]]
    [ ! -e "$(token)" ]
    printf 'r\tu\t%s\tcommit\t%s\n' "$((now + 3600))" "$tree" > "$(token)"
    run commit_at_tty
    [[ "$output" == *'in the future'* ]]
    printf 'r\tu\tnot-a-time\tcommit\t%s\n' "$tree" > "$(token)"
    run commit_at_tty
    [[ "$output" == *'malformed'* ]]
    printf 'r\tu\t%s\tcommit\t%s\textra\n' "$now" "$tree" > "$(token)"
    run commit_at_tty
    [[ "$output" == *'malformed'* ]]
}

@test "a token 590 seconds old still passes" {
    printf 'r\tu\t%s\tcommit\t%s\n' "$(( $(date +%s) - 590 ))" "$(git write-tree)" > "$(token)"
    run commit_at_tty
    [[ "$output" == *'rc=0'* ]]
}

@test "a commit token never passes a push, and a push token never passes a commit" {
    write_token 'commit only'
    run at_tty '. /code/lib/guard-override.sh; qg_override_take push "$(git rev-parse HEAD)"; echo rc=$?'
    [[ "$output" == *'rc=1'* && "$output" == *'written for a commit, not a push'* ]]
    rm -f "$(token)"
    write_token 'push only' "--push HEAD"
    run commit_at_tty
    [[ "$output" == *'rc=1'* && "$output" == *'written for a push, not a commit'* ]]
}

@test "a push token passes only its exact full sha" {
    write_token 'push it' "--push HEAD"
    full="$(git rev-parse HEAD)"
    run at_tty ". /code/lib/guard-override.sh; qg_override_take push ${full:0:12}; echo rc=\$?"
    [[ "$output" == *'rc=1'* ]]
    run at_tty ". /code/lib/guard-override.sh; qg_override_take push $full; echo rc=\$?"
    [[ "$output" == *'rc=0'* ]]
}
