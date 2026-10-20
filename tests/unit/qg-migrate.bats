#!/usr/bin/env bats
# lib/qg-migrate.sh — `qg migrate` rewrites a v1 checks.tsv in the v2 format with the same
# verdicts, and `qg init` gates a new repo from a profile. Neither commits.

load guard-helpers
load qg-doctor-helpers

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

# protected_of -> the guard_protected_paths value quality/config holds, one path per line, sorted.
protected_of() { sed -n 's/^guard_protected_paths:[[:space:]]*//p' quality/config | tr ' ' '\n' | sed '/^$/d' | sort; }

GATE_FILES=$'quality/baseline.tsv\nquality/checks.tsv\nquality/config\nquality/drivers\nquality/rules.tsv'

# framework <dir> -> a fake vault framework at <dir> whose bin/doc-lint.sh is executable.
framework() { mkdir -p "$1/bin" "$1/lib"; printf '#!/bin/sh\nexit 0\n' > "$1/bin/doc-lint.sh"; chmod +x "$1/bin/doc-lint.sh"; }

@test "init protects exactly the gate files and leaves other quality files unprotected" {
    local p
    for p in php nuxt flutter hugo; do
        new_repo "$WORK/$p"
        mkdir -p quality && printf 'dashboard\n' > quality/history.jsonl
        "$QG" init --profile "$p" >/dev/null 2>&1
        [ "$(protected_of)" = "$GATE_FILES" ] || { echo "$p: $(protected_of)"; return 1; }
    done
    write_rules
    commit_all init
    printf 'more\n' >> quality/history.jsonl
    git add quality/history.jsonl
    run bash /code/bin/guard.sh commit
    [[ "$output" != *'gate-config-touched'*'worse'* ]]
}

@test "init --profile docs protects .doc-lint and every tracked .doc-lint and writes an absolute guard_doc_lint" {
    framework "$WORK/fw"
    new_repo "$WORK/repo"
    mkdir -p plans support && printf 'DUP1\n' > plans/.doc-lint && printf 'LONG1\n' > support/.doc-lint
    printf 'LONG1\n' > untracked.doc-lint-not
    commit_all skip
    printf 'LONG1\n' > notes.doc-lint
    VAULT_FRAMEWORK_PATH="$WORK/fw" run "$QG" init --profile docs
    [ "$status" -eq 0 ]
    [ "$(protected_of)" = "$(printf '%s\n.doc-lint\nplans/.doc-lint\nsupport/.doc-lint' "$GATE_FILES" | sort)" ]
    [ "$(sed -n 's/^guard_doc_lint:[[:space:]]*//p' quality/config)" = "$WORK/fw/bin/doc-lint.sh" ]
}

@test "init --profile docs warns when the doc-lint it names is not executable" {
    new_repo "$WORK/repo"
    VAULT_FRAMEWORK_PATH="$WORK/nowhere" run "$QG" init --profile docs
    [ "$status" -eq 0 ]
    [[ "$output" == *"$WORK/nowhere/bin/doc-lint.sh is not executable"* ]]
    grep -q "^guard_doc_lint: $WORK/nowhere/bin/doc-lint.sh\$" quality/config
}

@test "init --profile docs --force with an existing quality/config writes nothing to it and warns naming guard_doc_lint" {
    framework "$WORK/fw"
    new_repo "$WORK/repo"
    mkdir -p quality && printf 'guard_protected_paths: quality\n' > quality/config
    cp quality/config "$WORK/before"
    : > quality/checks.tsv
    VAULT_FRAMEWORK_PATH="$WORK/fw" run "$QG" init --profile docs --force
    [ "$status" -eq 0 ]
    cmp quality/config "$WORK/before"
    [[ "$output" == *'has no guard_doc_lint'* ]] && [[ "$output" == *'left as it is'* ]]
}

@test "init prints Next as hooks install, then commit, then qg doctor" {
    new_repo "$WORK/repo"
    run "$QG" init --profile hugo
    [ "$status" -eq 0 ]
    next="$(printf '%s\n' "$output" | sed -n '/^Next:/,$p')"
    [[ "$next" == *'1. qg hooks install'*'2. git add quality'*'commit'*'3. qg doctor'* ]]
    run "$QG" help init
    [[ "$output" == *'qg hooks install [--claude], git add quality and commit, then qg doctor'* ]]
}

@test "init --profile docs: with hooks installed, qg doctor names HEAD has no quality/checks.tsv before the init commit and exits 0 after it" {
    framework "$WORK/fw"
    new_repo "$WORK/repo"
    printf 'notes\n' > README.md && commit_all first
    healthy_setup
    VAULT_FRAMEWORK_PATH="$WORK/fw" "$QG" init --profile docs >/dev/null 2>&1
    "$QG" hooks install >/dev/null
    run "$QG" doctor
    [ "$status" -eq 1 ] && [[ "$output" == *'HEAD has no quality/checks.tsv'* ]]
    git add quality && git -c core.hooksPath=/dev/null commit -q -m 'gate documents'
    run "$QG" doctor
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "init --profile hugo: qg doctor exits 0 after the init commit" {
    new_repo "$WORK/repo"
    printf 'site\n' > README.md && commit_all first
    healthy_setup
    "$QG" init --profile hugo >/dev/null 2>&1
    "$QG" hooks install >/dev/null
    git add quality && git -c core.hooksPath=/dev/null commit -q -m 'gate the site build'
    run "$QG" doctor
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "init --profile hugo writes no guard_doc_lint and protects only the five gate files" {
    new_repo "$WORK/repo"
    printf 'LONG1\n' > .doc-lint && commit_all skip
    "$QG" init --profile hugo >/dev/null 2>&1
    ! grep -q '^guard_doc_lint:' quality/config
    [ "$(protected_of)" = "$GATE_FILES" ]
}

@test "init --profile docs with VAULT_FRAMEWORK_PATH unset, relative or ending in / writes an absolute guard_doc_lint" {
    framework "$WORK/fw"
    new_repo "$WORK/a"
    ( unset VAULT_FRAMEWORK_PATH; "$QG" init --profile docs >/dev/null 2>&1 )
    grep -q "^guard_doc_lint: ${HOME}/workspace/vault/bin/doc-lint.sh\$" quality/config
    new_repo "$WORK/b"
    VAULT_FRAMEWORK_PATH=../fw "$QG" init --profile docs >/dev/null 2>&1
    grep -q "^guard_doc_lint: $WORK/fw/bin/doc-lint.sh\$" quality/config
    new_repo "$WORK/c"
    VAULT_FRAMEWORK_PATH="$WORK/fw/" "$QG" init --profile docs >/dev/null 2>&1
    grep -q "^guard_doc_lint: $WORK/fw/bin/doc-lint.sh\$" quality/config
}

@test "init --profile docs skips a tracked .doc-lint path holding a space and warns naming it" {
    framework "$WORK/fw"
    new_repo "$WORK/repo"
    mkdir -p "my plans" && printf 'DUP1\n' > "my plans/.doc-lint" && commit_all skip
    VAULT_FRAMEWORK_PATH="$WORK/fw" run "$QG" init --profile docs
    [[ "$output" == *'my plans/.doc-lint holds a space'* ]]
    ! protected_of | grep -q 'my'
}
