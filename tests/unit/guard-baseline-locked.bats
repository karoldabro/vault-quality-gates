#!/usr/bin/env bats
# The built-in baseline lock: `guard.sh commit` and `verify` refuse a commit that loosens
# quality/baseline.tsv or deletes quality/checks.tsv or quality/rules.tsv against its parent,
# and `guard.sh release` refuses a pushed commit that loosens it against GUARD_BASE. The
# configuration that judges a commit is its parent's, or GUARD_CONFIG_REV when that is set.

load guard-helpers

COV_ROW=$'cov\trelease\trepo\techo 80\t-\t-\tup\t0\trefuse'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON GUARD_CONFIG_REV GUARD_SHA GUARD_BASE
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

set_cov() { printf 'id\tvalue\tcommit\treason\ncov\t%s\tabc\t%s\n' "$1" "${2:--}" > quality/baseline.tsv; }

@test "commit: a lowered up-metric is refused and the refusal names the row and the restore command" {
    set_cov 70
    git add quality/baseline.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'baseline-loosened'* ]]
    [[ "$output" == *'cov 80 -> 70'* ]]
    [[ "$output" == *'git checkout HEAD -- quality/baseline.tsv'* ]]
}

@test "commit: a lowered value with a reason typed into column 4 is still refused" {
    set_cov 70 'agreed with nobody'
    git add quality/baseline.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
}

@test "commit: a tighter value passes" {
    set_cov 85
    git add quality/baseline.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
}

@test "commit: deleting quality/rules.tsv is refused" {
    git rm -q quality/rules.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'gate-config-deleted'* ]]
}

@test "verify: a commit made with hooks off that loosens the baseline is refused" {
    set_cov 70
    commit_all loosen
    run bash /code/bin/guard.sh verify "${BASE}..HEAD"
    [ "$status" -eq 1 ]
    [[ "$output" == *'refused'* ]]
}

@test "verify: a commit that loosens checks.tsv is judged by its parent's rows" {
    write_checks "$COV_ROW"
    commit_all 'drop the bad row'
    printf 'BAD\n' > app/a.php
    commit_all 'bad code'
    run bash /code/bin/guard.sh verify HEAD~1..HEAD
    [ "$status" -eq 0 ]
    GUARD_CONFIG_REV="$BASE" run bash /code/bin/guard.sh verify HEAD~1..HEAD
    [ "$status" -eq 1 ]
}

@test "release: a pushed commit that loosens the baseline against GUARD_BASE is refused" {
    set_cov 70
    commit_all loosen
    GUARD_SHA="$(git rev-parse HEAD)" GUARD_BASE="$BASE" run bash /code/bin/guard.sh release refs/heads/feat/x
    [ "$status" -eq 1 ]
    [[ "$output" == *'baseline-loosened'* ]]
    [[ "$output" != *'accept'* ]]
    [[ "$output" == *'Measure again without pushing: GUARD_SHA='* ]]
}

@test "release: an unchanged baseline passes" {
    GUARD_SHA="$(git rev-parse HEAD)" GUARD_BASE="$BASE" run bash /code/bin/guard.sh release refs/heads/feat/x
    [ "$status" -eq 0 ]
}

@test "release: with guard_measure_worktree false a dirty tree is refused" {
    printf 'guard_commit_paths: app\nguard_protected_paths: quality\nguard_measure_worktree: false\n' > VAULT.md
    commit_all measure-worktree
    printf 'edit\n' >> app/a.php
    GUARD_SHA="$(git rev-parse HEAD)" run bash /code/bin/guard.sh release refs/heads/feat/x
    [ "$status" -eq 2 ]
    [[ "$output" == *'uncommitted changes'* ]]
}

@test "release: with guard_measure_worktree false a dirty file outside guard_commit_paths does not block" {
    printf 'guard_commit_paths: app\nguard_protected_paths: quality\nguard_measure_worktree: false\n' > VAULT.md
    mkdir -p docs; printf 'x\n' > docs/graph.json
    commit_all measure-worktree
    printf 'rewritten\n' > docs/graph.json
    GUARD_SHA="$(git rev-parse HEAD)" run bash /code/bin/guard.sh release refs/heads/feat/x
    [ "$status" -eq 0 ]
}
