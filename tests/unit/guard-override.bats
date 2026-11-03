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

# --- the parent walk over a fake proc tree ------------------------------------------------
# mkproc <pid> <ppid> <tty_nr> <comm> <uid> <env|-> writes <pid>/{stat,comm,status,environ} under
# $WORK/proc. "-" leaves environ out, which reads as unreadable whatever uid the suite runs as.
mkproc() {
    local d="$WORK/proc/$1"
    mkdir -p "$d"
    printf '%s (%s) S %s %s %s %s 0 0\n' "$1" "$4" "$2" "$1" "$1" "$3" > "$d/stat"
    printf '%s\n' "$4" > "$d/comm"
    printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$4" "$5" "$5" "$5" "$5" > "$d/status"
    [ "$6" = - ] || printf '%s\0' $6 > "$d/environ"
}

# A WSL2 terminal: init(1) -> SessionLeader(9, root) -> Relay(11) (10, root) -> bash (11, pts/0).
wsl_tree() {
    mkdir -p "$WORK/proc/sys/kernel"
    printf '%s\n' "${1:-5.15.167.4-microsoft-standard-WSL2}" > "$WORK/proc/sys/kernel/osrelease"
    mkdir -p "$WORK/proc/self"
    printf '         0          0 4294967295\n' > "$WORK/proc/self/uid_map"
    mkproc 9 1 0 SessionLeader 0 -
    mkproc 10 9 0 "${2:-Relay(11)}" "${3:-0}" -
    mkproc 11 10 34816 bash 1000 "${4:-HOME=/home/u}"
}

walk() {
    . /code/lib/guard-override.sh
    if _guard_override_walk "$WORK/proc" "$1"; then echo CLEAN; else echo REFUSED; fi
}

@test "walk: a shell under WSL's root-owned Relay is clean, though the Relay's environ is unreadable" {
    wsl_tree
    run walk 11
    [ "$output" = CLEAN ]
}

@test "walk: a WSL1-style osrelease naming Microsoft also counts" {
    wsl_tree 4.4.0-19041-Microsoft
    run walk 11
    [ "$output" = CLEAN ]
}

@test "walk: a Relay not owned by root is refused" {
    wsl_tree '' 'Relay(11)' 1000
    run walk 11
    [ "$output" = REFUSED ]
}

@test "walk: a Relay name on a kernel that is not WSL is refused" {
    wsl_tree 6.8.0-45-generic
    run walk 11
    [ "$output" = REFUSED ]
}

@test "walk: a root process with another name and an unreadable environ is refused" {
    wsl_tree '' 'sshd'
    run walk 11
    [ "$output" = REFUSED ]
}

@test "walk: CLAUDECODE in the shell below the Relay is refused" {
    wsl_tree '' '' '' 'HOME=/home/u CLAUDECODE=1'
    run walk 11
    [ "$output" = REFUSED ]
}

@test "walk: an agent process between the Relay and the probe is refused" {
    wsl_tree
    mkproc 12 11 34816 node 1000 'CLAUDECODE=1'
    mkproc 13 12 0 bash 1000 'HOME=/home/u'
    run walk 13
    [ "$output" = REFUSED ]
}

@test "walk: the start process is never taken for the Relay, so its own environ is read" {
    wsl_tree
    mkproc 20 10 0 'Relay(20)' 0 -
    run walk 20
    [ "$output" = REFUSED ]
}

@test "walk: a Relay whose real uid is not 0 is refused, even with effective uid 0" {
    wsl_tree
    printf 'Name:\tRelay(11)\nUid:\t1000\t0\t0\t0\n' > "$WORK/proc/10/status"
    run walk 11
    [ "$output" = REFUSED ]
}

@test "walk: inside a user namespace a root-owned Relay is refused" {
    wsl_tree
    printf '         0       1000          1\n' > "$WORK/proc/self/uid_map"
    run walk 11
    [ "$output" = REFUSED ]
}
