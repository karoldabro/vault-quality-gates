#!/usr/bin/env bats
# bin/guard.sh commit|verify, lib/guard-tree.sh and bin/guard-protected-paths.sh.
#
# The gate measures a copy of the index, never the working tree, and reads its own
# configuration from HEAD. Each test builds a throwaway repo under mktemp -d.

load guard-helpers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

install_hooks() { ( export GUARD_LIB_DIR=/code/lib; . /code/lib/guard-metrics.sh; . /code/lib/guard-install.sh; guard_hooks_install >/dev/null ); }
tree_dir() { printf '%s/guard-tree' "$(git rev-parse --path-format=absolute --git-common-dir)"; }
sync_to() { ( . /code/lib/guard-tree.sh; guard_tree_sync "$1" "$(tree_dir)" ); }

# assert_tree_is <tree-ish> — the synced directory holds exactly the tree: same paths, modes
# and blob hashes, and no other file.
assert_tree_is() {
    local dir entry meta path mode sha actual want have
    dir="$(tree_dir)"
    while IFS= read -r -d '' entry; do
        meta="${entry%%$'\t'*}" path="${entry#*$'\t'}"
        read -r mode _ sha <<<"$meta"
        if [ "$mode" = 120000 ]; then
            [ -L "$dir/$path" ] || { echo "not a symlink: $path"; return 1; }
            actual="$(printf '%s' "$(readlink "$dir/$path")" | git hash-object --stdin)"
        else
            [ -f "$dir/$path" ] && [ ! -L "$dir/$path" ] || { echo "missing file: $path"; return 1; }
            if [ "$mode" = 100755 ]; then [ -x "$dir/$path" ] || { echo "not executable: $path"; return 1; }
            else [ ! -x "$dir/$path" ] || { echo "executable: $path"; return 1; }; fi
            actual="$(git hash-object "$dir/$path")"
        fi
        [ "$actual" = "$sha" ] || { echo "content differs: $path"; return 1; }
    done < <(git ls-tree -r -z "$1")
    want="$(git ls-tree -r -z "$1" | tr -dc '\0' | wc -c)"
    have="$(find "$dir" \( -type f -o -type l \) -print0 | tr -dc '\0' | wc -c)"
    [ "$want" -eq "$have" ] || { echo "tree has ${want} entries, directory has ${have} files"; return 1; }
}

# --- the tree equals the index ------------------------------------------------

@test "unstaged bad code does not reach the measured tree" {
    gate_repo "$WORK/repo"
    printf 'fine\n' > app/b.php
    git add app/b.php
    printf 'BAD\n' > app/a.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    [ -f "$(tree_dir)/app/b.php" ]
    run grep -q BAD "$(tree_dir)/app/a.php"
    [ "$status" -ne 0 ]
}

@test "staged bad code is refused and named" {
    gate_repo "$WORK/repo"
    printf 'BAD\n' > app/a.php
    git add app/a.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'bad-in-tree'* ]]
}

@test "unstaged or staged loosening of checks.tsv and VAULT.md changes nothing" {
    gate_repo "$WORK/repo"
    printf 'BAD\n' > app/a.php
    git add app/a.php
    write_checks $'bad-in-tree\tcommit\tdiff\ttrue\t-\t-\tdown\t0\trefuse'
    printf 'guard_commit_paths: nothing\n' > VAULT.md
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    git add quality/checks.tsv VAULT.md
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'bad-in-tree'* ]]
    [[ "$output" == *'gate-config-touched'* ]]
}

@test "an unstaged edit of a script the row runs from the tree changes nothing" {
    new_repo "$WORK/repo"
    mkdir -p quality/bin app
    printf '#!/usr/bin/env bash\ngrep -rl BAD "$1/app" | wc -l\n' > quality/bin/in-tree.sh
    write_checks $'bad-in-tree\tcommit\tdiff\tbash {{tree}}/quality/bin/in-tree.sh {{tree}}\t-\t-\tdown\t0\trefuse'
    write_rules
    printf 'ok\n' > app/a.php
    commit_all init
    printf '#!/usr/bin/env bash\necho 0\n' > quality/bin/in-tree.sh
    printf 'BAD\n' > app/a.php
    git add app/a.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
}

@test "commit -a and commit <path> measure the index git builds for them" {
    gate_repo "$WORK/repo"
    install_hooks
    printf 'BAD\n' > app/a.php
    run git commit -q -a -m bad
    [ "$status" -ne 0 ]
    run git commit -q -m bad app/a.php
    [ "$status" -ne 0 ]
    [ "$(git rev-list --count HEAD)" -eq 1 ]
    printf 'clean\n' > app/a.php
    printf 'fine\n' > app/c.php
    git add app/c.php
    printf 'BAD\n' > app/a.php
    run git commit -q -m 'clean staged, bad unstaged'
    [ "$status" -eq 0 ]
    [ "$(pass_record_of HEAD)" = ok ]
}

@test "a docs-only commit skips every tree row" {
    gate_repo "$WORK/repo"
    write_checks $'tree-row\tcommit\tdiff\tfalse {{tree}}\texitcode\t-\tdown\t0\trefuse'
    commit_all 'a tree row that always fails'
    printf 'text\n' > docs/readme.md
    git add docs/readme.md
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    grep -q 'tree-row.*no changed path matches guard_commit_paths' quality-reports/REPORT.md
    [ ! -d "$(tree_dir)" ]
}

@test "a first commit reads its configuration from the index" {
    new_repo "$WORK/repo"
    write_checks "$BAD_ROW"
    write_rules
    mkdir -p app
    printf 'clean\n' > app/a.php
    git add -A
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    printf 'BAD\n' > app/a.php
    git add app/a.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
}

@test "a linked worktree measures its own index and records its pass in the common dir" {
    gate_repo "$WORK/repo"
    install_hooks
    git worktree add -q "$WORK/wt" -b side
    cd "$WORK/wt"
    printf 'BAD\n' > app/a.php
    git add app/a.php
    run git commit -q -m bad
    [ "$status" -ne 0 ]
    printf 'clean too\n' > app/a.php
    git add app/a.php
    run git commit -q -m clean
    [ "$status" -eq 0 ]
    [ "$(pass_record_of HEAD)" = ok ]
    [ -d "$WORK/repo/.git/guard-tree" ]
    grep -q 'clean too' "$WORK/repo/.git/guard-tree/app/a.php"
}

# --- T7: the synced tree depends only on the last tree-ish ----------------------

@test "deleted files and old reports leave the tree, also after the private index is lost" {
    gate_repo "$WORK/repo"
    printf 'x\n' > app/gone.php
    commit_all two
    sync_to HEAD
    mkdir -p "$(tree_dir)/quality-reports"
    printf 'old\n' > "$(tree_dir)/quality-reports/commit-phpstan.json"
    sync_to HEAD~1
    assert_tree_is HEAD~1
    sync_to HEAD
    rm -f "$(tree_dir).index"
    printf 'stale\n' > "$(tree_dir)/app/stale.php"
    sync_to HEAD~1
    assert_tree_is HEAD~1
}

@test "seeded random add, modify, delete, rename, chmod, symlink and file-to-dir keep the invariant" {
    new_repo "$WORK/repo"
    RANDOM=20260928
    local step op n names=()
    for step in $(seq 1 40); do
        n="f$((RANDOM % 6))"
        op=$((RANDOM % 7))
        case "$op" in
            0) rm -rf "$n"; printf '%s\n' "$step" > "$n" ;;
            1) if [ -f "$n" ] && [ ! -L "$n" ]; then printf 'more %s\n' "$step" >> "$n"; fi ;;
            2) rm -rf "$n" ;;
            3) if [ -f "$n" ] && [ ! -L "$n" ]; then mv "$n" "r${step}"; fi ;;
            4) if [ -f "$n" ] && [ ! -L "$n" ]; then chmod +x "$n"; fi ;;
            5) rm -rf "$n"; ln -s "target-${step}" "$n" ;;
            6) rm -rf "$n"; mkdir -p "$n"; printf 'inside\n' > "$n/child" ;;
        esac
        if [ $((step % 9)) -eq 0 ]; then
            printf 'odd\n' > "with space ${step}"
            printf 'nl\n' > "new
line ${step}"
        fi
        git add -A
        tree="$(git write-tree)"
        sync_to "$tree"
        assert_tree_is "$tree"
    done
    git rm -rq --cached .
    tree="$(git write-tree)"
    sync_to "$tree"
    assert_tree_is "$tree"
}

# --- T8: configuration comes from HEAD, and the rows decide the exit -----------

@test "HEAD without quality/checks.tsv exits 2 naming it" {
    new_repo "$WORK/repo"
    write_rules
    commit_all init
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 2 ]
    [[ "$output" == *'quality/checks.tsv'* ]]
}

@test "HEAD without quality/rules.tsv exits 2 naming it, even when the working tree has one" {
    new_repo "$WORK/repo"
    write_checks "$BAD_ROW"
    commit_all init
    write_rules
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 2 ]
    [[ "$output" == *'quality/rules.tsv'* ]]
}

@test "the printer never turns a failing row into exit 0" {
    gate_repo "$WORK/repo"
    printf 'broken map\n' > quality/rules.tsv
    commit_all 'malformed map'
    printf 'BAD\n' > app/a.php
    git add app/a.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'rules.tsv is unreadable'* ]]
}

@test "a held tree lock is unmeasurable, not a pass" {
    gate_repo "$WORK/repo"
    printf 'fine\n' > app/b.php
    git add app/b.php
    exec 8>"$(git rev-parse --path-format=absolute --git-common-dir)/guard-tree.lock"
    flock 8
    GUARD_LOCK_WAIT=1 run bash /code/bin/guard.sh commit
    exec 8>&-
    [ "$status" -eq 2 ]
    [[ "$output" == *'lock still held'* ]]
}

# --- T4: merges count only what differs from every parent ----------------------

@test "a merge whose other parent changed protected config and the baseline passes" {
    gate_repo "$WORK/repo"
    install_hooks
    git checkout -q -b other
    printf 'level: 1\n' > phpstan.neon
    printf 'parameters:\n\tignoreErrors:\n\t\t-\n\t\t\tmessage: x\n\t\t\tcount: 1\n\t\t\tpath: app/a.php\n' > phpstan-baseline.neon
    commit_all 'upstream config'
    git checkout -q -
    printf 'fine\n' > app/main.php
    git add app/main.php
    git commit -q -m main
    run git merge -q --no-edit other
    [ "$status" -eq 0 ]
    [ "$(git rev-list --parents -n 1 HEAD | wc -w)" -eq 3 ]
    [ "$(pass_record_of HEAD)" = ok ]
}

@test "merge --no-commit then commit uses both parents; an evil-merge line counts 1" {
    gate_repo "$WORK/repo"
    git checkout -q -b other
    printf 'line\n// @phpstan-ignore-next-line\n' > app/up.php
    printf 'level: 1\n' > phpstan.neon
    commit_all upstream
    git checkout -q -
    printf 'fine\n' > app/main.php
    commit_all main
    git -c core.hooksPath=/dev/null merge -q --no-commit --no-ff other
    run bash /code/bin/guard-protected-paths.sh
    [ "$output" = 0 ]
    run bash /code/bin/guard-added-lines.sh --grep '@phpstan-ignore'
    [ "$output" = 0 ]
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    printf '<?php // @phpstan-ignore-line\n' > app/evil.php
    git add app/evil.php
    run bash /code/bin/guard-added-lines.sh --grep '@phpstan-ignore'
    [ "$output" = 1 ]
}

@test "an octopus merge reads every parent, and reordered or repeated bases count alike" {
    gate_repo "$WORK/repo"
    main="$(git symbolic-ref --short HEAD)"
    git checkout -q -b one; printf 'a\n// @phpstan-ignore-line\n' > app/one.php; commit_all one
    git checkout -q "$main"; git checkout -q -b two; printf 'b\n' > app/two.php; commit_all two
    git checkout -q "$main"; printf 'c\n' > app/three.php; commit_all three
    git -c core.hooksPath=/dev/null merge -q --no-commit one two
    [ "$( . /code/lib/guard-pass.sh; guard_commit_parents | wc -l)" -eq 3 ]
    run bash /code/bin/guard-added-lines.sh --grep '@phpstan-ignore'
    [ "$output" = 0 ]
    a="$(git rev-parse HEAD)" b="$(git rev-parse one)" c="$(git rev-parse two)"
    run bash /code/bin/guard-added-lines.sh --added --bases "$a $b $c"
    forward="$output"
    run bash /code/bin/guard-added-lines.sh --added --bases "$c $a $b $a"
    [ "$output" = "$forward" ]
    run bash /code/bin/guard-added-lines.sh --added --bases "$a"
    [ "$(wc -l <<<"$output")" -ge "$(wc -l <<<"$forward")" ]
}

# --- guard.sh verify and guard_protected_paths ------------------------------------

@test "verify refuses a cherry-picked suppression and records a clean commit" {
    gate_repo "$WORK/repo"
    git checkout -q -b topic
    printf 'x\n// @phpstan-ignore-next-line\n' > app/s.php; commit_all suppress
    printf 'clean\n' > app/c.php; commit_all clean
    git checkout -q -
    git -c core.hooksPath=/dev/null cherry-pick topic~1 >/dev/null
    run bash /code/bin/guard.sh verify -1 HEAD
    [ "$status" -eq 1 ]
    [[ "$output" == *'suppressions-added app/s.php:2'* ]]
    [ -z "$(pass_record_of HEAD)" ]
    git -c core.hooksPath=/dev/null cherry-pick topic >/dev/null
    run bash /code/bin/guard.sh verify -1 HEAD
    [ "$status" -eq 0 ]
    [ "$(pass_record_of HEAD)" = ok ]
}

@test "protected paths match whole paths and directory boundaries only" {
    gate_repo "$WORK/repo"
    printf 'x\n' > phpstan.neon.dist
    mkdir -p quality-reports; printf 'x\n' > quality-reports/r.json
    git add -f phpstan.neon.dist quality-reports/r.json
    run bash /code/bin/guard-protected-paths.sh
    [ "$output" = 0 ]
    printf 'x\n' > quality/new.tsv
    git add quality/new.tsv
    run bash /code/bin/guard-protected-paths.sh
    [ "$output" = 1 ]
}

@test "a protected path git would C-quote is still matched" {
    gate_repo "$WORK/repo"
    printf 'x\n' > 'quality/a"b.tsv'
    printf 'y\n' > "$(printf 'quality/c\nd.tsv')"
    git add quality
    run bash /code/bin/guard-protected-paths.sh
    [ "$output" -ge 2 ]
    GUARD_LIST=1 run bash /code/bin/guard-protected-paths.sh
    [[ "$output" == *'quality/a"b.tsv'* ]]
}

@test "amend carries the pass to the new commit" {
    gate_repo "$WORK/repo"
    install_hooks
    printf 'fine\n' > app/b.php
    git add app/b.php
    git commit -q -m first
    [ "$(pass_record_of HEAD)" = ok ]
    printf 'finer\n' > app/b.php
    git add app/b.php
    git commit -q --amend -m amended
    [ "$(pass_record_of HEAD)" = ok ]
}

@test "post-rewrite records an amend only when verify passes it against its own parents" {
    gate_repo "$WORK/repo"
    install_hooks
    printf 'fine\n' > app/b.php
    git add app/b.php
    git commit -q -m first
    printf '// @phpstan-ignore-next-line\n' >> app/b.php
    git add app/b.php
    git commit -q --no-verify --amend -m suppressed 2>/dev/null
    [ -z "$(pass_record_of HEAD)" ]
    printf 'fine again\n' > app/b.php
    git add app/b.php
    git commit -q --no-verify --amend -m clean 2>/dev/null
    [ "$(pass_record_of HEAD)" = ok ]
}

@test "the tree lock is still held while the refusal reads the reports" {
    gate_repo "$WORK/repo"
    plugin="$WORK/plugin"
    mkdir -p "$plugin/bin"
    cp -r /code/lib "$plugin/lib"
    cp /code/bin/*.sh "$plugin/bin/"
    lock="$(git rev-parse --path-format=absolute --git-common-dir)/guard-tree.lock"
    printf '#!/usr/bin/env bash\nif flock -n %s true; then echo LOCK-FREE; else echo LOCK-HELD; fi\n' "$lock" > "$plugin/bin/guard-report-errors.sh"
    chmod +x "$plugin/bin/guard-report-errors.sh"
    printf 'BAD\n' > app/a.php
    git add app/a.php
    run bash "$plugin/bin/guard.sh" commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'LOCK-HELD'* ]]
}
