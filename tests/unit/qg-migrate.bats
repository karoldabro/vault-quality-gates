#!/usr/bin/env bats
# lib/qg-migrate.sh — `qg migrate` rewrites a v1 checks.tsv in the v2 format with the same
# verdicts, and `qg init` gates a new repo from a profile. Neither commits.

load guard-helpers

QG=/code/bin/qg

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# results <checks file> -> "id status value" per row of a commit run with that config committed
results() {
    git -c core.hooksPath=/dev/null commit -q --allow-empty -m cfg
    printf '%s\n' "$RANDOM" >> app/z.php; git add app/z.php
    bash /code/bin/guard.sh commit >/dev/null 2>&1 || true
    cut -d'|' -f1,2,4 "$(git rev-parse --path-format=absolute --git-common-dir)/qg-last/RESULTS.txt" | sort
}

@test "without --draft it lists the rows that need a why and writes nothing" {
    gate_repo "$WORK/repo"
    before="$(cat quality/checks.tsv)"
    run "$QG" migrate
    [ "$status" -eq 1 ]
    [[ "$output" == *'bad-in-tree'*'suppressions-added'* ]]
    [ "$(cat quality/checks.tsv)" = "$before" ]
}

@test "--draft writes v2 with TODO whys that the gate refuses, and the same verdicts once whys are filled" {
    gate_repo "$WORK/repo"
    printf 'guard_commit_paths: app\nguard_protected_paths: quality phpstan.neon VAULT.md\nguard_release_pattern: refs/heads/rel/*\n' > VAULT.md
    write_checks "$BAD_ROW" "$SUPPRESS_ROW" "$PROTECT_ROW" "$GROWTH_ROW" $'cov\trelease\trepo\techo 80\t-\t-\tup\t0\trefuse' \
        $'mutation\t-\tabsent\t-\t-\tno mutation tool here\t-\t-\t-'
    git add -A; git -c core.hooksPath=/dev/null commit -q -m v1
    printf 'BAD\n' > app/a.php
    v1="$(results)"
    git checkout -q app/a.php 2>/dev/null; git reset -q --hard
    run "$QG" migrate --draft
    [ "$status" -eq 0 ]
    [ "$(head -1 quality/checks.tsv)" = $'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy' ]
    grep -q $'^cov\tpush:refs/heads/rel/\\*\trepo\tshell\t-- echo 80\t' quality/checks.tsv
    grep -q $'^mutation\t-\tabsent\t-\t-\t-\t-\t-\tno mutation tool here$' quality/checks.tsv
    grep -q '^guard_protected_paths: quality phpstan.neon VAULT.md$' quality/config
    run bash -c '. /code/lib/guard-metrics.sh; guard_load_checks quality/checks.tsv'
    [ "$status" -eq 2 ] && [[ "$output" == *'has no why'* ]]
    awk -F'\t' -v OFS='\t' '$9 ~ /^TODO/ { $9 = "a reason" } { print }' quality/checks.tsv > "$WORK/c" && cp "$WORK/c" quality/checks.tsv
    rm -f quality/checks.v1.tsv.bak
    git add -A; git -c core.hooksPath=/dev/null commit -q -m v2
    printf 'BAD\n' > app/a.php
    v2="$(results)"
    [ "$v1" = "$v2" ] || { printf 'v1:\n%s\nv2:\n%s\n' "$v1" "$v2"; return 1; }
}

@test "migrate refuses a repo that is already v2" {
    new_repo "$WORK/repo"
    mkdir -p quality; cp /code/templates/init/docs.tsv quality/checks.tsv
    run "$QG" migrate --draft
    [ "$status" -eq 2 ] && [[ "$output" == *'not v1'* ]]
}

@test "init writes a loadable config for every profile and refuses to overwrite without --force" {
    local p
    for p in docs php nuxt flutter hugo; do
        new_repo "$WORK/$p"
        run "$QG" init --profile "$p"
        [ "$status" -eq 0 ] || { echo "$p: $output"; return 1; }
        run bash -c '. /code/lib/guard-metrics.sh; guard_load_checks quality/checks.tsv'
        [ "$status" -eq 0 ] || { echo "$p does not load: $output"; return 1; }
        [ -r quality/rules.tsv ] && [ -r quality/baseline.tsv ] && [ -r quality/config ]
        run "$QG" init --profile "$p"
        [ "$status" -eq 2 ] && [[ "$output" == *'--force'* ]]
    done
    run "$QG" init --profile nope
    [ "$status" -eq 2 ] && [[ "$output" == *'docs'*'php'* ]]
}

@test "the docs profile gates a conflict marker on any file type" {
    new_repo "$WORK/repo"
    "$QG" init --profile docs >/dev/null
    git add -A; git -c core.hooksPath=/dev/null commit -q -m init
    printf 'text\n<<<<<<< HEAD\nmine\n' > notes.txt
    git add notes.txt
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'conflict-markers'*'worse: measured 1'* ]]
}
