#!/usr/bin/env bats
# templates/git-hooks/* and lib/guard-install.sh.
#
# The pre-push tests feed real four-field stdin lines through a pipe and assert the
# WRITER's exit status, not the hook's. A hook that exits before draining stdin leaves
# git writing into a closed pipe: the writer dies with 141 while the hook reports 0,
# so the push fails and nothing says why. Asserting only the hook's status misses it.

setup() {
    export LC_ALL=C
    export GUARD_LIB_DIR=/code/lib
    # bin/guard.sh sources guard-metrics.sh before guard-install.sh; guard_err comes
    # from the first and is called by the second. Load them in the same order here.
    # shellcheck source=../../lib/guard-metrics.sh
    . /code/lib/guard-metrics.sh
    WORK="$(mktemp -d)"
    RAN="$WORK/ran"
    stub_guard 0
    HOOK="$WORK/pre-push"
    sed "s|__GUARD_SH__|${WORK}/guard-stub.sh|g" /code/templates/git-hooks/pre-push > "$HOOK"
    chmod +x "$HOOK"
    mkdir -p "$WORK/repo"
    cd "$WORK/repo" || return 1
    git init -q .
    git config user.email 'test@example.invalid'
    git config user.name 'test'
    printf 'guard_release_pattern: refs/heads/release/*\n' > VAULT.md
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

stub_guard() {  # stub_guard <exit status>
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "STUB %%s GUARD_SHA=%%s\\n" "$*" "${GUARD_SHA:-unset}" >> %s\n' "$WORK/ran"
        printf 'exit %s\n' "$1"
    } > "$WORK/guard-stub.sh"
    chmod +x "$WORK/guard-stub.sh"
}

# push_lines <count> <ref> <local sha> — writes four-field stdin lines into the hook
# and reports both pipeline statuses.
push_through_hook() {
    local count="$1" ref="$2" sha="$3"
    bash -c "
        for i in \$(seq 1 ${count}); do
            printf '%s %s %s %s\n' '${ref}' '${sha}' '${ref}' 'cafebabe'
        done | '${HOOK}' origin
        printf 'writer=%s hook=%s\n' \"\${PIPESTATUS[0]}\" \"\${PIPESTATUS[1]}\"
    "
}

@test "skip path leaves writer at exit 0" {
    run push_through_hook 20000 refs/heads/feature/widget aaaa1111
    [[ "$output" == *'writer=0'* ]]
    [[ "$output" == *'hook=0'* ]]
    [ ! -e "$RAN" ]
}

@test "release ref runs the release suite" {
    run push_through_hook 1 refs/heads/release/1.17.0 aaaa1111
    [[ "$output" == *'hook=0'* ]]
    grep -q 'STUB release refs/heads/release/1.17.0' "$RAN"
    grep -q 'GUARD_SHA=aaaa1111' "$RAN"
}

@test "delete line runs no check and drains" {
    run push_through_hook 5000 refs/heads/release/old 0000000000000000000000000000000000000000
    [[ "$output" == *'writer=0'* ]]
    [[ "$output" == *'hook=0'* ]]
    [ ! -e "$RAN" ]
}

@test "a refusing guard refuses the push" {
    stub_guard 1
    run push_through_hook 1 refs/heads/release/1.17.0 aaaa1111
    [[ "$output" == *'hook=1'* ]]
}

@test "a VAULT.md without the pattern still gates release and names the fallback" {
    rm -f VAULT.md
    run push_through_hook 1 refs/heads/release/9.9.9 aaaa1111
    [[ "$output" == *'refs/heads/release/*'* ]]
    grep -q 'STUB release refs/heads/release/9.9.9' "$RAN"
}

@test "an unreadable guard refuses rather than passing unmeasured" {
    chmod -x "$WORK/guard-stub.sh"
    run push_through_hook 1 refs/heads/release/1.17.0 aaaa1111
    [[ "$output" == *'hook=1'* ]]
    [[ "$output" == *'not executable'* ]]
}

@test "pre-commit never blocks, whatever guard returns" {
    stub_guard 1
    hook="$WORK/pre-commit"
    sed "s|__GUARD_SH__|${WORK}/guard-stub.sh|g" /code/templates/git-hooks/pre-commit > "$hook"
    chmod +x "$hook"
    run "$hook"
    [ "$status" -eq 0 ]
    grep -q 'STUB commit' "$RAN"
}

# --- lib/guard-install.sh ----------------------------------------------------

@test "install writes both hooks and status reports them" {
    . /code/lib/guard-install.sh
    run guard_hooks_install
    [ "$status" -eq 0 ]
    [ -x .git/hooks/pre-push ]
    [ -x .git/hooks/pre-commit ]
    run guard_hooks_status
    [[ "$output" == *'pre-push'*'installed'* ]]
    [[ "$output" == *'pre-commit'*'installed'* ]]
}

@test "install leaves a hook it did not write alone" {
    . /code/lib/guard-install.sh
    mkdir -p .git/hooks
    printf '#!/bin/sh\necho someone elses hook\n' > .git/hooks/pre-push
    chmod +x .git/hooks/pre-push
    run guard_hooks_install
    grep -q 'someone elses hook' .git/hooks/pre-push
    [[ "$output" == *'was not written here'* ]]
}

@test "remove deletes only the hooks it wrote" {
    . /code/lib/guard-install.sh
    guard_hooks_install
    printf '#!/bin/sh\necho foreign\n' > .git/hooks/pre-rebase
    guard_hooks_remove
    [ ! -e .git/hooks/pre-push ]
    [ -e .git/hooks/pre-rebase ]
}
