#!/usr/bin/env bats
# bin/guard.sh release <ref> — which rows a push runs. The engine picks rows by their `on` cell;
# a v1 row's `on` comes from guard_release_pattern in the measured commit. A ref no row runs on
# exits 0 before the config-presence and tree checks.

load guard-helpers

# A push row that always measures 1 against a ceiling of 0: refused whenever it runs.
V1_PUSH=$'always-bad\trelease\tdiff\techo 1\t-\t-\tdown\t0\trefuse'
V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_SKIP_REASON GUARD_CONFIG_REV GUARD_SHA GUARD_BASE GUARD_SKIP CLAUDECODE AI_AGENT
    new_repo "$WORK/repo"
    write_rules
    printf 'one\n' > file.txt
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

release() { GUARD_SHA="$(git rev-parse HEAD)" run bash /code/bin/guard.sh release "$1"; }

v1_repo() {  # v1_repo <VAULT.md line or empty>
    write_checks "$V1_PUSH"
    [ -n "$1" ] && printf '%s\n' "$1" > VAULT.md
    commit_all v1
}

@test "v1: a ref inside guard_release_pattern runs the row; one outside runs nothing" {
    v1_repo 'guard_release_pattern: refs/heads/release/*'
    release refs/heads/release/1.0.0
    [ "$status" -eq 1 ]
    release refs/heads/feature/x
    [ "$status" -eq 0 ]
    [[ "$output" == *'no gate row runs on refs/heads/feature/x'* ]]
}

@test "v1: a Prettier-escaped pattern and each alternative of a|b gate their refs" {
    v1_repo 'guard_release_pattern: refs/heads/release/\*|refs/heads/realse/*'
    release refs/heads/release/2.0.0
    [ "$status" -eq 1 ]
    release refs/heads/realse/2.0.1
    [ "$status" -eq 1 ]
    release refs/heads/feature/x
    [ "$status" -eq 0 ]
}

@test "v1: no guard_release_pattern gates refs/heads/release/*" {
    v1_repo ''
    release refs/heads/release/9.9.9
    [ "$status" -eq 1 ]
    release refs/heads/main
    [ "$status" -eq 0 ]
}

@test "v1: the pattern comes from the measured commit, not the working tree" {
    v1_repo 'guard_release_pattern: refs/heads/rel/*'
    printf 'guard_release_pattern: refs/heads/release/*\n' > VAULT.md
    release refs/heads/release/3.0.0
    [ "$status" -eq 0 ]
    release refs/heads/rel/3.0.0
    [ "$status" -eq 1 ]
}

@test "v1: quality/config replaces VAULT.md when present" {
    v1_repo 'guard_release_pattern: refs/heads/release/*'
    printf 'guard_release_pattern: refs/heads/ship/*\n' > quality/config
    commit_all config
    release refs/heads/release/1.0.0
    [ "$status" -eq 0 ]
    release refs/heads/ship/1.0.0
    [ "$status" -eq 1 ]
}

@test "v2: push runs on every ref; push:<glob> only on matching refs" {
    { printf '%s\n' "$V2_HEADER"
      printf 'any\tpush\tdiff\tshell\t-- echo 0\tdown\t0\trefuse\tevery push is checked\n'
      printf 'rel\tpush:refs/heads/release/*\tdiff\tshell\t-- echo 1\tdown\t0\trefuse\trelease pushes are checked\n'
    } > quality/checks.tsv
    commit_all v2
    release refs/heads/feature/x
    [ "$status" -eq 0 ]
    [[ "$output" == *'measuring 1 rows'* ]]
    release refs/heads/release/1.0.0
    [ "$status" -eq 1 ]
}

@test "a ref whose commit has no quality/checks.tsv is accepted with a note; a hand run without a ref is not" {
    commit_all bare
    release refs/heads/release/1.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *'has no quality/checks.tsv'* ]]
    GUARD_SHA="$(git rev-parse HEAD)" run bash /code/bin/guard.sh release
    [ "$status" -eq 2 ]
}

@test "guard_measure_worktree false: no tree check when no row runs; refused when one does" {
    v1_repo $'guard_release_pattern: refs/heads/release/*\nguard_measure_worktree: false'
    first="$(git rev-parse HEAD)"
    printf 'two\n' >> file.txt
    commit_all two
    tip="$(git rev-parse HEAD)"
    git checkout -q "$first"
    printf 'dirty\n' >> file.txt
    GUARD_SHA="$tip" run bash /code/bin/guard.sh release refs/heads/feature/x
    [ "$status" -eq 0 ]
    GUARD_SHA="$tip" run bash /code/bin/guard.sh release refs/heads/release/1.0.0
    [ "$status" -eq 2 ]
    [[ "$output" == *'HEAD is not the pushed commit'* ]]
}

@test "the 43d7082 call form still works: GUARD_SHA and GUARD_BASE with a ref" {
    v1_repo 'guard_release_pattern: refs/heads/release/*'
    GUARD_SHA="$(git rev-parse HEAD)" GUARD_BASE="$(git rev-parse HEAD)" run bash /code/bin/guard.sh release refs/heads/release/1.0.0
    [ "$status" -eq 1 ]
    [[ "$output" == *'always-bad'* ]]
}
