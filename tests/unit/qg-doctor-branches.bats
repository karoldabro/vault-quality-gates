#!/usr/bin/env bats
# qg doctor --all-branches: lists every local branch and remote-tracking ref whose
# quality/checks.tsv is v1, or v2 without quality/config, labels it worktree, upstream or stale,
# prints the newest v2 ref with quality/config as the source, and exits 1 only when a listed ref
# is not stale. It reads refs and objects only. Each commit is built with plumbing, so no hook
# and no checkout is involved.

load guard-helpers

QG=/code/bin/qg
V1_HEAD=$'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate'
V2_HEAD=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset CLAUDECODE AI_AGENT GIT_INDEX_FILE
    git init -q --bare "$WORK/remote.git"
    new_repo "$WORK/repo"
    printf 'readme\n' > README
    commit_all init
    git remote add origin "$WORK/remote.git"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# add_blob <path> <content> — stages <content> at <path> in the current GIT_INDEX_FILE.
add_blob() {
    git update-index --add --cacheinfo "100644,$(printf '%s\n' "$2" | git hash-object -w --stdin),$1"
}

# mk_commit <v1|v2|v2cfg|v1cfg|none|odd> [<unix committer date>] -> the sha of a root commit
# holding that gate config.
mk_commit() {
    (
        export GIT_INDEX_FILE="${WORK}/index.$$.${RANDOM}"
        add_blob README "$1"
        case "$1" in
            v1|v1cfg) add_blob quality/checks.tsv "$V1_HEAD" ;;
            v2|v2cfg) add_blob quality/checks.tsv "$V2_HEAD" ;;
            odd)      add_blob quality/checks.tsv $'id\tsomething\telse' ;;
        esac
        case "$1" in *cfg) add_blob quality/config 'guard_accept_limit: 3' ;; esac
        tree="$(git write-tree)"
        rm -f "$GIT_INDEX_FILE"
        GIT_COMMITTER_DATE="@${2:-1700000000} +0000" GIT_AUTHOR_DATE="@${2:-1700000000} +0000" \
            git commit-tree "$tree" -m "$1"
    )
}

# ref_at <ref> <kind> [<date>] — points <ref> at a new commit of that kind.
ref_at() { git update-ref "$1" "$(mk_commit "$2" "${3:-}")"; }

# track <branch> <remote> <merge ref> — configures the branch's upstream.
track() { git config "branch.$1.remote" "$2"; git config "branch.$1.merge" "$3"; }

# line_of <ref> -> the text line listing <ref>.
line_of() { grep -E "^ +[a-z]+ +$1 " <<<"$output"; }

@test "a v1 checks.tsv on a remote-tracking ref is listed as upstream and exits 1" {
    ref_at refs/remotes/origin/old v1
    run "$QG" doctor --all-branches
    [ "$status" -eq 1 ]
    [[ "$(line_of refs/remotes/origin/old)" =~ ^\ +upstream\ .*\ v1$ ]]
}

@test "a v1 checks.tsv on a local branch with a live upstream is listed and exits 1" {
    ref_at refs/heads/feat v1
    ref_at refs/remotes/origin/feat v2cfg
    track feat origin refs/heads/feat
    run "$QG" doctor --all-branches
    [ "$status" -eq 1 ]
    [[ "$(line_of refs/heads/feat)" =~ ^\ +upstream\  ]]
    [ -z "$(line_of refs/remotes/origin/feat)" ]
    # An upstream on this repo itself (remote .) is live while that local branch exists.
    git update-ref -d refs/remotes/origin/feat
    track feat . "$(git symbolic-ref HEAD)"
    run "$QG" doctor --all-branches
    [ "$status" -eq 1 ]
    [[ "$(line_of refs/heads/feat)" =~ ^\ +upstream\  ]]
}

@test "a v1 checks.tsv on a branch checked out in a linked worktree is listed as worktree and exits 1" {
    ref_at refs/heads/wt v1
    git worktree add -q "$WORK/wt" wt
    run "$QG" doctor --all-branches
    [ "$status" -eq 1 ]
    [[ "$(line_of refs/heads/wt)" =~ ^\ +worktree\  ]]
}

@test "a v1 local branch with no upstream and no worktree is listed as stale and exits 0" {
    ref_at refs/heads/old v1
    run "$QG" doctor --all-branches
    [ "$status" -eq 0 ]
    [[ "$(line_of refs/heads/old)" =~ ^\ +stale\ .*\ v1$ ]]
    [[ "$output" == *'1 refs without a v2 gate config, 1 of them stale'* ]]
}

@test "a v2 checks.tsv without quality/config on a remote-tracking ref is listed and exits 1" {
    ref_at refs/remotes/origin/half v2
    ref_at refs/remotes/origin/done v2cfg
    run "$QG" doctor --all-branches
    [ "$status" -eq 1 ]
    [[ "$(line_of refs/remotes/origin/half)" =~ ^\ +upstream\ .*\ v2\ without\ quality/config$ ]]
    [ -z "$(line_of refs/remotes/origin/done)" ]
}

@test "the newest v2 ref's sha is printed as the source" {
    ref_at refs/heads/older v2cfg 1700000000
    ref_at refs/remotes/origin/newest v2cfg 1700009999
    ref_at refs/heads/middle v2cfg 1700005000
    ref_at refs/heads/old v1 1800000000
    run "$QG" doctor --all-branches
    [[ "$output" == *"source: $(git rev-parse refs/remotes/origin/newest) refs/remotes/origin/newest"* ]]
    run "$QG" doctor --all-branches --json
    [ "$(jq -r '.source' <<<"$output")" = "$(git rev-parse refs/remotes/origin/newest)" ]
}

@test "refs with v2 config or no checks.tsv exit 0 and list nothing" {
    ref_at refs/heads/good v2cfg
    ref_at refs/remotes/origin/good v2cfg
    ref_at refs/remotes/origin/plain none
    git worktree add -q "$WORK/wt" good
    run "$QG" doctor --all-branches
    [ "$status" -eq 0 ]
    ! grep -qE '^ +(worktree|upstream|stale) ' <<<"$output"
    [[ "$output" == *'0 refs without a v2 gate config'* ]]
}

@test "the symbolic origin/HEAD is not listed" {
    ref_at refs/remotes/origin/main v1
    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    run "$QG" doctor --all-branches
    [ "$status" -eq 1 ]
    [ -n "$(line_of refs/remotes/origin/main)" ]
    [[ "$output" != *'refs/remotes/origin/HEAD'* ]]
    run "$QG" doctor --all-branches --json
    [ "$(jq -r '.refs | map(.ref) | join(",")' <<<"$output")" = refs/remotes/origin/main ]
}

@test "--all-branches never fetches and leaves refs and the working tree unchanged" {
    ref_at refs/heads/old v1
    ref_at refs/remotes/origin/gone v1
    # Pushed by URL, so no remote-tracking ref records it: only a fetch would.
    git push -q "$WORK/remote.git" "$(mk_commit v1):refs/heads/only-on-remote"
    [ -z "$(git for-each-ref refs/remotes/origin/only-on-remote)" ]
    git worktree add -q "$WORK/wt" old
    printf 'dirty\n' > README
    printf 'new\n' > untracked.txt
    snapshot() {
        git for-each-ref --format='%(refname) %(objectname) %(symref)'
        git -C "$WORK/remote.git" for-each-ref --format='%(refname) %(objectname)'
        find .git "$WORK/wt" "$WORK/remote.git" -type f -print0 | sort -z | xargs -0 sha1sum
        find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha1sum
    }
    before="$(snapshot)"
    run "$QG" doctor --all-branches
    [ "$status" -eq 1 ]
    run "$QG" doctor --all-branches --json
    [ "$(snapshot)" = "$before" ]
    [ ! -e .git/FETCH_HEAD ]
    [ -z "$(git for-each-ref refs/remotes/origin/only-on-remote)" ]
}

@test "--all-branches --json prints one object per listed ref" {
    ref_at refs/heads/old v1
    ref_at refs/remotes/origin/half v2
    ref_at refs/remotes/origin/cfg v1cfg
    ref_at refs/heads/good v2cfg
    run "$QG" doctor --all-branches --json
    [ "$status" -eq 1 ]
    [ "$(jq -r '.refs | length' <<<"$output")" = 3 ]
    [ "$(jq -c '.refs[] | select(.ref == "refs/heads/old") | [.state, .version, .config, (.sha | length)]' <<<"$output")" = '["stale","v1",false,40]' ]
    [ "$(jq -c '.refs[] | select(.ref == "refs/remotes/origin/half") | [.state, .version, .config]' <<<"$output")" = '["upstream","v2",false]' ]
    [ "$(jq -c '.refs[] | select(.ref == "refs/remotes/origin/cfg") | [.state, .version, .config]' <<<"$output")" = '["upstream","v1",true]' ]
    [ "$(jq -r '.refs[] | select(.ref == "refs/heads/old") | .sha' <<<"$output")" = "$(git rev-parse refs/heads/old)" ]
    [ "$(jq -r '.source' <<<"$output")" = "$(git rev-parse refs/heads/good)" ]
}

@test "a v1 branch checked out in the main worktree is listed as worktree and exits 1" {
    ref_at refs/heads/here v1
    git checkout -q here
    run "$QG" doctor --all-branches
    [ "$status" -eq 1 ]
    [[ "$(line_of refs/heads/here)" =~ ^\ +worktree\  ]]
}

@test "a v1 local branch whose upstream is gone is listed as stale and exits 0" {
    ref_at refs/heads/old v1
    track old origin refs/heads/old
    run "$QG" doctor --all-branches
    [ "$status" -eq 0 ]
    [[ "$(line_of refs/heads/old)" =~ ^\ +stale\  ]]
    # A remote-. upstream naming a missing local branch is gone too.
    track old . refs/heads/no-such-branch
    run "$QG" doctor --all-branches
    [ "$status" -eq 0 ]
    [[ "$(line_of refs/heads/old)" =~ ^\ +stale\  ]]
}

@test "a v1 branch with a live upstream and a worktree is listed once as worktree" {
    ref_at refs/heads/both v1
    ref_at refs/remotes/origin/both v2cfg
    track both origin refs/heads/both
    git worktree add -q "$WORK/wt" both
    run "$QG" doctor --all-branches
    [ "$status" -eq 1 ]
    [ "$(grep -c ' refs/heads/both ' <<<"$output")" = 1 ]
    [[ "$(line_of refs/heads/both)" =~ ^\ +worktree\  ]]
}

@test "one upstream ref beside stale refs lists both and exits 1" {
    ref_at refs/heads/s1 v1
    ref_at refs/heads/s2 v2
    ref_at refs/remotes/origin/live v1
    run "$QG" doctor --all-branches
    [ "$status" -eq 1 ]
    [[ "$(line_of refs/heads/s1)" =~ ^\ +stale\  ]]
    [[ "$(line_of refs/heads/s2)" =~ ^\ +stale\  ]]
    [[ "$(line_of refs/remotes/origin/live)" =~ ^\ +upstream\  ]]
    [[ "$output" == *'3 refs without a v2 gate config, 2 of them stale'* ]]
}

@test "with no v2 ref the doctor prints no v2 source" {
    ref_at refs/heads/old v1
    ref_at refs/heads/half v2
    run "$QG" doctor --all-branches
    [[ "$output" == *'no v2 source'* ]]
    run "$QG" doctor --all-branches --json
    [ "$(jq -r '.source' <<<"$output")" = null ]
}

@test "an unrecognised checks.tsv header is listed as unknown with the exit code of its ref kind" {
    ref_at refs/heads/odd odd
    run "$QG" doctor --all-branches
    [ "$status" -eq 0 ]
    [[ "$(line_of refs/heads/odd)" =~ ^\ +stale\ .*\ unknown$ ]]
    ref_at refs/remotes/origin/odd odd
    run "$QG" doctor --all-branches
    [ "$status" -eq 1 ]
    [[ "$(line_of refs/remotes/origin/odd)" =~ ^\ +upstream\ .*\ unknown$ ]]
}

@test "doctor refuses an unknown option with exit 2" {
    run "$QG" doctor --all-branchez
    [ "$status" -eq 2 ]
    run "$QG" doctor --all-branches extra
    [ "$status" -eq 2 ]
}
