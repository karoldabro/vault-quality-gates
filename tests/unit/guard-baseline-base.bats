#!/usr/bin/env bats
# `guard.sh baseline` substitutes {{base}} with the commit a push compares against (the merge-base
# with the default branch), so a {{base}} row writes the number the push gate measures.

load guard-helpers

V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT GUARD_SKIP GUARD_ONLY GUARD_CONFIG_REV
    gate_repo "$WORK/repo"
    git branch -M master
    { printf '%s\n' "$V2_HEADER"
      printf 'branch-edits\tpush:refs/heads/release/*\trepo\tshell\t-- git diff --name-only {{base}}...HEAD -- docs | wc -l\tdown\t0\trefuse\tfiles the branch edited\n'
    } > quality/checks.tsv
    printf 'id\tvalue\tcommit\treason\nbranch-edits\t9\tabc\t-\n' > quality/baseline.tsv
    commit_all v2
    git checkout -q -b release/1.0
    printf 'x\n' > docs/one.md
    commit_all 'edit on the branch'
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

@test "baseline measures a {{base}} row against the default branch, as a push does" {
    run bash /code/bin/guard.sh baseline
    [ "$status" -eq 0 ]
    [ "$(awk -F'\t' '$1 == "branch-edits" { print $2 }' quality/baseline.tsv)" = 1 ]
    commit_all rebaseline
    run bash /code/bin/guard.sh release refs/heads/release/1.0
    [ "$status" -eq 0 ]
}
