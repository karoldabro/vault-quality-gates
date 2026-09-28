#!/usr/bin/env bats
# lib/guard-override.sh — the human-only override and its log.
#
# The container has no controlling terminal, so a plain run is the "no tty" row. script(1) gives
# the child a pseudo-terminal, which is the only way to reach the "honoured" row.

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    mkdir -p "$WORK/repo"
    cd "$WORK/repo" || return 1
    git init -q .
    git config user.email 'test@example.invalid'
    git config user.name 'test'
    unset CLAUDECODE AI_AGENT QG_SKIP_REASON
    # probe.sh prints HONOURED or REFUSED; the env assignments come in as arguments.
    printf '%s\n' '#!/usr/bin/env bash' \
        '. /code/lib/guard-override.sh' \
        'if guard_override_allowed "$@"; then echo HONOURED; else echo REFUSED; fi' > "$WORK/probe.sh"
    chmod +x "$WORK/probe.sh"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# with_tty <env assignment>... — runs probe.sh under a pseudo-terminal with the agent markers
# removed first, then the given assignments applied.
with_tty() {
    local cmd="env -u CLAUDECODE -u AI_AGENT -u QG_SKIP_REASON"
    local a
    for a in "$@"; do cmd+=" $(printf '%q' "$a")"; done
    script -qec "$cmd $WORK/probe.sh" /dev/null
}

without_tty() {
    env -u CLAUDECODE -u AI_AGENT -u QG_SKIP_REASON "$@" "$WORK/probe.sh"
}

@test "the test image has no tty outside script, and one inside it" {
    run bash -c ': < /dev/tty'
    [ "$status" -ne 0 ]
    run script -qec 'bash -c ": < /dev/tty && echo OPENED"' /dev/null
    [[ "$output" == *OPENED* ]]
}

@test "honoured: reason set, tty opens, CLAUDECODE and AI_AGENT unset" {
    run with_tty QG_SKIP_REASON='hotfix for prod outage'
    [[ "$output" == *HONOURED* ]]
}

@test "refused: blank or missing reason even at a tty with no agent markers" {
    run with_tty
    [[ "$output" == *REFUSED* ]]
    run with_tty QG_SKIP_REASON=''
    [[ "$output" == *REFUSED* ]]
    run with_tty QG_SKIP_REASON='   '
    [[ "$output" == *REFUSED* ]]
}

@test "refused: reason set but no tty" {
    run without_tty QG_SKIP_REASON='hotfix'
    [ "$output" = REFUSED ]
}

@test "refused: CLAUDECODE set, including set to an empty string" {
    run with_tty QG_SKIP_REASON='hotfix' CLAUDECODE=1
    [[ "$output" == *REFUSED* ]]
    run with_tty QG_SKIP_REASON='hotfix' CLAUDECODE=
    [[ "$output" == *REFUSED* ]]
}

@test "refused: AI_AGENT set, including set to an empty string" {
    run with_tty QG_SKIP_REASON='hotfix' AI_AGENT=claude
    [[ "$output" == *REFUSED* ]]
    run with_tty QG_SKIP_REASON='hotfix' AI_AGENT=
    [[ "$output" == *REFUSED* ]]
}

@test "an explicit reason argument replaces QG_SKIP_REASON" {
    printf '%s\n' '#!/usr/bin/env bash' '. /code/lib/guard-override.sh' \
        'if guard_override_allowed "  "; then echo HONOURED; else echo REFUSED; fi' > "$WORK/probe.sh"
    run with_tty QG_SKIP_REASON='hotfix'
    [[ "$output" == *REFUSED* ]]
}

@test "checking the override writes no log line" {
    run with_tty QG_SKIP_REASON='hotfix'
    [[ "$output" == *HONOURED* ]]
    [ ! -e .git/guard-bypass.log ]
}

@test "log line carries date, user, HEAD, staged files, reason and message" {
    printf 'a\n' > a.txt && printf 'b\n' > b.txt
    git add a.txt && git commit -qm init
    printf 'c\n' > c.txt && printf 'a2\n' > a.txt
    git add a.txt c.txt
    . /code/lib/guard-override.sh
    QG_SKIP_REASON='prod down' USER=alice guard_override_log 'pre-commit: phpstan worse'
    [ "$(wc -l < .git/guard-bypass.log)" -eq 1 ]
    IFS=$'\t' read -r date user head staged reason message < .git/guard-bypass.log
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
    [ "$user" = alice ]
    [ "$head" = "$(git rev-parse HEAD)" ]
    [ "$staged" = 'a.txt c.txt' ]
    [ "$reason" = 'prod down' ]
    [ "$message" = 'pre-commit: phpstan worse' ]
}

@test "log appends, and a newline or tab in the reason stays on one line" {
    . /code/lib/guard-override.sh
    QG_SKIP_REASON=$'first\nsecond\tthird' guard_override_log one
    QG_SKIP_REASON='again' guard_override_log two
    [ "$(wc -l < .git/guard-bypass.log)" -eq 2 ]
    [ "$(head -1 .git/guard-bypass.log | cut -f3)" = '(none)' ]
    [ "$(head -1 .git/guard-bypass.log | cut -f5)" = 'first second third' ]
    [ "$(tail -1 .git/guard-bypass.log | cut -f6)" = two ]
}

@test "a linked worktree logs into the common git dir" {
    git commit -q --allow-empty -m init
    git worktree add -q "$WORK/wt" -b side
    cd "$WORK/wt" || return 1
    . /code/lib/guard-override.sh
    QG_SKIP_REASON='wt' guard_override_log from-worktree
    [ -f "$WORK/repo/.git/guard-bypass.log" ]
    grep -q from-worktree "$WORK/repo/.git/guard-bypass.log"
}
