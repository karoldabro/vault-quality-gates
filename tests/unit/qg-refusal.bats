#!/usr/bin/env bats
# lib/qg-refusal.sh — what a refused commit or push prints. Every failing row carries its why,
# a reproduce command and `qg explain`; a tool's own output is printed once per distinct text;
# when nothing was measured the first lines say so; the footer always says how to pass, and the
# whole text stays within QG_REFUSAL_MAX characters, the rest in qg-last/REFUSAL.txt.

load guard-helpers

V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'
ENV_ROW() { printf '%s\tcommit\tdiff\techo "in-tree.sh: vendor/ does not match HEAD:composer.lock" >&2; exit 2\texitcode\t-\tdown\t0\trefuse' "$1"; }

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT
    new_repo "$WORK/repo"
    write_rules
    mkdir -p app
    printf 'a\n' > app/a.php
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

stage_change() { printf '%s\n' "$RANDOM" >> app/b.php; git add app/b.php; }
refusal_file() { cat "$(git rev-parse --path-format=absolute --git-common-dir)/qg-last/REFUSAL.txt"; }

@test "eight rows failing on one environment error: nothing-measured note, fallback why, one tail, under the cap" {
    local rows=() i
    for i in 1 2 3 4 5 6 7 8; do rows+=("$(ENV_ROW "row-$i")"); done
    write_checks "${rows[@]}"
    commit_all init
    stage_change
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 2 ]
    [[ "$output" == *'Nothing in your code was measured'* ]]
    [ "$(grep -c 'why:       (no reason recorded; run qg migrate)' <<<"$output")" -eq 8 ]
    [ "$(grep -c '  | in-tree.sh: vendor/ does not match' <<<"$output")" -eq 1 ]
    [[ "$output" == *'Output of row-'*', row-'* ]]
    [[ "$output" == *'Fix what the output above names'* ]]
    [ "${#output}" -le 3500 ]
}

@test "a worse v2 row prints its why, its reproduce line and qg explain, and the human override" {
    { printf '%s\n' "$V2_HEADER"
      printf 'todo-count\tcommit\tdiff\tshell\t-- echo 3\tdown\t0\trefuse\tnew TODO markers hide unfinished work\n'
    } > quality/checks.tsv
    commit_all init
    stage_change
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'todo-count'*'worse: measured 3'* ]]
    [[ "$output" == *'why:       new TODO markers hide unfinished work'* ]]
    [[ "$output" == *'reproduce: qg run commit --only todo-count'* ]]
    [[ "$output" == *'details:   qg explain todo-count'* ]]
    [[ "$output" == *'qg override --reason "<why>"'* ]]
    [[ "$output" != *'Nothing in your code was measured'* ]]
}

@test "an agent is told it may not override, and is shown no override command" {
    { printf '%s\n' "$V2_HEADER"; printf 'n\tcommit\tdiff\tshell\t-- echo 1\tdown\t0\trefuse\tkeep it at zero\n'; } > quality/checks.tsv
    commit_all init
    stage_change
    CLAUDECODE=1 run bash /code/bin/guard.sh commit
    [[ "$output" == *'Agents may not override a gate'* ]]
    [[ "$output" != *'qg override'* ]]
}

@test "a long refusal is cut in the middle at 3500 characters; the footer survives; qg last keeps all of it" {
    local rows=() i
    for i in $(seq 1 40); do rows+=("$(printf 'long-row-%02d\tcommit\tdiff\techo %s >&2; exit 2\texitcode\t-\tdown\t0\trefuse' "$i" "unique-text-$i-$(printf 'x%.0s' $(seq 1 60))")"); done
    write_checks "${rows[@]}"
    commit_all init
    stage_change
    run bash /code/bin/guard.sh commit
    [ "${#output}" -le 3500 ]
    [[ "$output" == *'cut here; run `qg last`'* ]]
    [[ "$output" == *'How to pass:'*'qg last prints this refusal again'* ]]
    full="$(refusal_file)"
    [ "${#full}" -gt 3500 ]
    [[ "$full" == *'long-row-40'* ]]
}

@test "a short refusal is not cut, and printing the same results twice gives the same text" {
    write_checks "$(ENV_ROW only)"
    commit_all init
    stage_change
    run bash /code/bin/guard.sh commit
    [[ "$output" != *'cut here'* ]]
    first="$(refusal_file)"
    run bash /code/bin/guard.sh commit
    [ "$(refusal_file)" = "$first" ]
}

@test "a push refusal names the ref, reproduces with --ref, and keeps the hand-run line" {
    { printf '%s\n' "$V2_HEADER"; printf 'p\tpush\tdiff\tshell\t-- echo 1\tdown\t0\trefuse\tpushes stay clean\n'; } > quality/checks.tsv
    commit_all init
    GUARD_SHA="$(git rev-parse HEAD)" run bash /code/bin/guard.sh release refs/heads/feature/x
    [ "$status" -eq 1 ]
    [[ "$output" == *'push refused to refs/heads/feature/x'* ]]
    [[ "$output" == *'reproduce: qg run push --ref refs/heads/feature/x --only p'* ]]
    [[ "$output" == *'Measure again without pushing: GUARD_SHA='* ]]
    [[ "$output" == *'--push <sha>'* ]]
}
