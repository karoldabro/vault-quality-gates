#!/usr/bin/env bats
# templates/claude-hooks/* — the agent guards for the surfaces qg adds: the qg command, the
# override token, quality/drivers/ and quality/config, the git directory, and the Stop hook's
# test for a gated repo. 2 denies, 0 allows.

HOOKS=/code/templates/claude-hooks

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    mkdir -p "$WORK/repo/quality" "$HOME"
    cd "$WORK/repo" || return 1
    git init -q .
    git config user.email 'test@example.invalid'
    git config user.name 'test'
    git commit -q --allow-empty -m init
    BAD=''
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

bash_case() {
    local want="$1" cmd="$2" rc=0
    jq -nc --arg c "$cmd" --arg d "$PWD" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
        | "$HOOKS/guard-bash.sh" > /dev/null 2>&1 || rc=$?
    [ "$want" = deny ] && [ "$rc" -ne 2 ] && BAD+=$'\n'"not denied (exit $rc): $cmd"
    [ "$want" = allow ] && [ "$rc" -ne 0 ] && BAD+=$'\n'"not allowed (exit $rc): $cmd"
    return 0
}

edit_case() {
    local want="$1" path="$2" rc=0
    jq -nc --arg p "$path" --arg d "$PWD" '{tool_name:"Write",cwd:$d,tool_input:{file_path:$p}}' \
        | "$HOOKS/guard-edit.sh" > /dev/null 2>&1 || rc=$?
    [ "$want" = deny ] && [ "$rc" -ne 2 ] && BAD+=$'\n'"edit not denied (exit $rc): $path"
    [ "$want" = allow ] && [ "$rc" -ne 0 ] && BAD+=$'\n'"edit not allowed (exit $rc): $path"
    return 0
}

no_bad() { [ -z "$BAD" ] || { printf '%s\n' "$BAD" >&2; return 1; }; }

@test "qg: reads and runs are allowed; every command that changes the gate is denied, by any path and option order" {
    local c
    for c in 'qg' 'qg help' 'qg list --json' 'qg explain phpstan-new' 'qg last' 'qg drivers' 'qg doctor' \
             'qg run commit' 'qg --json run push --ref refs/heads/x' 'qg config get guard_commit_paths' 'qg hooks status' \
             '/code/bin/qg explain x' 'qg verify HEAD~1..HEAD'; do
        bash_case allow "$c"
    done
    for c in 'qg override --reason x' 'qg --json override --reason x' 'qg hooks install --claude' 'qg hooks remove' \
             'qg baseline' 'qg accept cov --reason x' 'qg migrate --draft' 'qg init --profile docs' \
             '/code/bin/qg override --reason x' 'nice -n 5 qg hooks remove' 'bash -c "qg baseline"' 'cd /tmp && qg accept x'; do
        bash_case deny "$c"
    done
    no_bad
}

@test "the override token and the run records cannot be written by any writer" {
    local c
    for c in 'printf x > .git/qg-override' 'tee .git/qg-override <<< x' 'cp /tmp/t .git/qg-override' \
             'echo x >> "$(git rev-parse --git-common-dir)/qg-override"' 'rm -rf .git/qg-last' 'touch .git/anything-new' \
             'mkdir .git/x'; do
        bash_case deny "$c"
    done
    bash_case allow 'cat .git/qg-last/REFUSAL.txt'
    no_bad
}

@test "a linked worktree's git dir and the common dir are both protected" {
    git worktree add -q "$WORK/wt" -b wt
    cd "$WORK/wt" || return 1
    bash_case deny "printf x > $WORK/repo/.git/worktrees/wt/x"
    bash_case deny "printf x > $WORK/repo/.git/qg-override"
    no_bad
}

@test "another repo's git directory is protected too, by absolute path or after cd" {
    # The hook exempts scratch repos under /tmp; real repos live elsewhere, so build these under /var/tmp.
    [ -w /var/tmp ] || skip '/var/tmp is not writable in this image'
    local real; real="$(mktemp -d -p /var/tmp)"
    mkdir -p "$real/other" && git -C "$real/other" init -q . \
        && git -C "$real/other" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
    mkdir -p "$real/plain"; cd "$real/plain" || return 1
    bash_case deny "printf 'a b' > $real/other/.git/info/grafts"
    bash_case deny "printf x > $real/other/.git/refs/heads/feat-x"
    bash_case deny "cd $real/other && printf 'a b' > .git/info/grafts"
    bash_case allow "printf x > $real/other/notes.txt"
    rm -rf "$real"
    no_bad
}

@test "git hash-object -w -t commit and git mktree are denied; a read-only hash-object is not" {
    bash_case deny 'git hash-object -t commit -w --stdin < /tmp/c'
    bash_case deny 'git hash-object -w -tcommit --stdin < /tmp/c'
    bash_case deny 'git mktree < /tmp/t'
    bash_case allow 'git hash-object README.md'
    bash_case allow 'git hash-object -w --stdin < /tmp/blob'
    no_bad
}

@test "quality/drivers/ and quality/config cannot be written by Bash or the edit tools; the rest of quality/ can" {
    local c
    for c in 'printf x > quality/config' 'mkdir -p quality/drivers && cp /tmp/x quality/drivers/phpstan.sh' \
             'echo x > quality/drivers/mine.sh' 'mv /tmp/c quality/config'; do
        bash_case deny "$c"
    done
    bash_case allow 'printf x > quality/notes.md'
    bash_case allow 'printf x > /tmp/elsewhere/quality/config'
    edit_case deny "$WORK/repo/quality/config"
    edit_case deny "$WORK/repo/quality/drivers/mine.sh"
    edit_case allow "$WORK/repo/quality/README.md"
    edit_case allow "$WORK/repo/quality/configuration.md"
    no_bad
}

@test "the Stop hook treats a repo with committed quality/checks.tsv and rules.tsv as gated" {
    printf 'x\n' > quality/checks.tsv; printf 'x\n' > quality/rules.tsv
    git add -A; git commit -q -m gate
    run bash -c "jq -nc --arg d '$PWD' '{cwd:\$d}' | $HOOKS/guard-stop.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *'on no remote'* ]]
    [[ "$output" == *'quality/config, quality/drivers/'* ]]
}

@test "the Stop hook leaves a repo without the gate's files alone" {
    printf 'x\n' > quality/checks.tsv
    git add -A; git commit -q -m only-checks
    run bash -c "jq -nc --arg d '$PWD' '{cwd:\$d}' | $HOOKS/guard-stop.sh"
    [ "$status" -eq 0 ]
}
