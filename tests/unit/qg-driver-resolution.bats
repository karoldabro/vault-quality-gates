#!/usr/bin/env bats
# Which driver a v2 row runs: a built-in under drivers/, else the repo's own
# quality/drivers/<name>.sh as committed at the config revision — never the working tree, never
# a repo driver named like a built-in. A commit that adds or changes a repo driver is refused
# (gate-config-changed) until a human overrides.

load guard-helpers

V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5 SENTINEL="$WORK/sentinel"
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT GUARD_CONFIG_REV
    gate_repo "$WORK/repo"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# repo_driver <name> <metric> [<touch sentinel>] — quality/drivers/<name>.sh reporting <metric>
repo_driver() {
    mkdir -p quality/drivers
    { printf '#!/usr/bin/env bash\n'
      printf 'case "$1" in describe) echo "{\\"name\\":\\"%s\\",\\"requires\\":[],\\"needs_tree\\":false}";;\n' "$1"
      printf '  run) %s echo "{\\"schema\\":\\"qg.result/1\\",\\"status\\":\\"measured\\",\\"metric\\":%s,\\"findings\\":[],\\"error\\":null}" > "$QG_OUT/result.json";;\n' "${3:+touch \"\$SENTINEL\";}" "$2"
      printf '  *) exit 2;; esac\n'
    } > "quality/drivers/$1.sh"
    chmod +x "quality/drivers/$1.sh"
}

v2_checks() {  # v2_checks <driver>
    { printf '%s\n' "$V2_HEADER"
      printf 'custom\tcommit\tdiff\t%s\t-\tdown\t0\trefuse\ta custom gate\n' "$1"
    } > quality/checks.tsv
}

@test "a committed repo driver runs; its value is compared" {
    repo_driver mine 1
    v2_checks mine
    commit_all custom
    printf 'x\n' > app/b.php; git add app/b.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'custom'* ]]
}

@test "a working-tree edit to a committed repo driver never runs" {
    repo_driver mine 0
    v2_checks mine
    commit_all custom
    repo_driver mine 0 touch
    printf 'x\n' > app/b.php; git add app/b.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    [ ! -e "$SENTINEL" ]
}

@test "a driver that exists only in the working tree never runs, and the row is refused as unknown" {
    write_checks "$BAD_ROW"
    commit_all v1
    v2_checks ghost
    repo_driver ghost 0 touch
    git add quality/checks.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'gate-config-invalid'*'no driver "ghost"'* ]]
    [ ! -e "$SENTINEL" ]
}

@test "a repo driver named like a built-in is refused; it never replaces the built-in" {
    repo_driver phpstan 0 touch
    v2_checks phpstan
    run bash -c 'git add -A && git -c core.hooksPath=/dev/null commit -q -m shadow && bash /code/bin/guard.sh verify HEAD~1..HEAD'
    printf 'x\n' > app/b.php; git add app/b.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 2 ]
    [[ "$output" == *'has the name of a built-in driver'* ]]
    [ ! -e "$SENTINEL" ]
}

@test "a commit that adds or changes a repo driver or quality/config is refused" {
    repo_driver mine 0
    git add quality/drivers/mine.sh
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'gate-config-changed'*'quality/drivers/mine.sh'* ]]
    git reset -q
    printf 'guard_commit_paths: app\n' > quality/config
    git add quality/config
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'gate-config-changed'*'quality/config'* ]]
}

@test "a staged v2 checks.tsv with why = - or a bad on cell is refused before it can judge anything" {
    { printf '%s\n' "$V2_HEADER"; printf 'x\tcommit\tdiff\tshell\t-- echo 0\tdown\t0\trefuse\t-\n'; } > quality/checks.tsv
    git add quality/checks.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'gate-config-invalid'*'no why'* ]]
    { printf '%s\n' "$V2_HEADER"; printf 'x\tcommit,\tdiff\tshell\t-- echo 0\tdown\t0\trefuse\tbecause\n'; } > quality/checks.tsv
    git add quality/checks.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'gate-config-invalid'*'empty token'* ]]
}
