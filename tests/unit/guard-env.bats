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
        GUARD_SKIP="$skip" GUARD_SHA="$(git rev-parse HEAD)" GUARD_BASE="$BASE" run bash /code/bin/guard.sh release refs/heads/feat/x
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
