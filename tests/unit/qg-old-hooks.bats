#!/usr/bin/env bats
# Repos keep their installed hook copies until a human reinstalls them, so the new engine must give
# the 43d7082 hook bodies (tests/fixtures/hooks-43d7082/) the verdicts the new bodies give: on a
# commit, on a feature push and on a release push.

load guard-helpers

ALWAYS_BAD_RELEASE=$'always-bad\tpush:refs/heads/release/*\tdiff\tshell\t-- echo 1\tdown\t0\trefuse\ta test row'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT GUARD_SKIP GUARD_CONFIG_REV
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# repo_with <hook dir> <name> — a gated repo whose hooks come from <hook dir>, with a remote.
repo_with() {
    gate_repo "$WORK/$2"
    write_checks "$BAD_ROW" "$ALWAYS_BAD_RELEASE"
    printf 'guard_commit_paths: app\nguard_protected_paths: quality\n' > quality/config
    commit_all gate
    local h
    for h in pre-commit pre-push pre-merge-commit pre-applypatch post-rewrite; do
        sed "s|__GUARD_SH__|/code/bin/guard.sh|g" "$1/$h" > ".git/hooks/$h"
        chmod +x ".git/hooks/$h"
    done
    git init -q --bare "$WORK/$2-remote.git"
    git remote add origin "$WORK/$2-remote.git"
    git push -q --no-verify origin HEAD:refs/heads/main 2>/dev/null
}

# verdicts -> one line per scenario, "<scenario> <exit>"
verdicts() {
    local rc
    printf 'BAD\n' > app/a.php; git add app/a.php
    rc=0; git commit -q -m bad >/dev/null 2>&1 || rc=$?; echo "bad-commit $rc"
    git checkout -q HEAD -- app/a.php
    printf 'fine\n' > app/ok.php; git add app/ok.php
    rc=0; git commit -q -m ok >/dev/null 2>&1 || rc=$?; echo "clean-commit $rc"
    rc=0; git push -q origin HEAD:refs/heads/feature/x >/dev/null 2>&1 || rc=$?; echo "feature-push $rc"
    rc=0; git push -q origin HEAD:refs/heads/release/1.0 >/dev/null 2>&1 || rc=$?; echo "release-push $rc"
}

@test "the 43d7082 hook bodies and the new ones reach the same verdicts with the new engine" {
    repo_with /code/tests/fixtures/hooks-43d7082 old
    old="$(verdicts)"
    repo_with /code/templates/git-hooks new
    new="$(verdicts)"
    [ "$old" = "$new" ] || { printf 'old:\n%s\nnew:\n%s\n' "$old" "$new"; return 1; }
    [ "$old" = $'bad-commit 1\nclean-commit 0\nfeature-push 0\nrelease-push 1' ] || { printf '%s\n' "$old"; return 1; }
}
