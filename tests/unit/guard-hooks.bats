#!/usr/bin/env bats
# templates/git-hooks/*, lib/guard-hook.sh and lib/guard-install.sh.
#
# The pre-push tests feed real four-field stdin lines through a pipe and assert the
# WRITER's exit status, not the hook's. A hook that exits before draining stdin leaves
# git writing into a closed pipe: the writer dies with 141 while the hook reports 0,
# so the push fails and nothing says why. Asserting only the hook's status misses it.
#
# The hooks run against a stub plugin under $WORK/plugin: bin/guard.sh is a stub that logs
# its call and exits with a chosen status, lib/ links the real libraries, and
# lib/guard-override.sh is a stub honoured only while $WORK/stub-override exists: a hook restarts
# under a clean environment, so a test variable never reaches it.

load guard-helpers

setup() {
    export LC_ALL=C
    export GUARD_LIB_DIR=/code/lib
    unset QG_SKIP_REASON
    # bin/guard.sh sources guard-metrics.sh before guard-install.sh; guard_err comes
    # from the first and is called by the second. Load them in the same order here.
    # shellcheck source=../../lib/guard-metrics.sh
    . /code/lib/guard-metrics.sh
    WORK="$(mktemp -d)"
    RAN="$WORK/ran"
    PLUGIN="$WORK/plugin"
    mkdir -p "$PLUGIN/bin" "$PLUGIN/lib" "$WORK/hooks"
    ln -s /code/lib/* "$PLUGIN/lib/"
    rm -f "$PLUGIN/lib/guard-override.sh"
    printf '%s\n' \
        "guard_override_allowed() { [ -e '$WORK/stub-override' ] && [[ \"\${QG_SKIP_REASON-}\" =~ [^[:space:]] ]]; }" \
        'guard_override_log() { printf '"'LOG %s\\n'"' "$*" >> "$(git rev-parse --git-common-dir)/guard-bypass.log"; }' \
        > "$PLUGIN/lib/guard-override.sh"
    stub_guard 0
    local h
    for h in pre-push pre-commit pre-merge-commit pre-applypatch post-rewrite; do
        sed "s|__GUARD_SH__|${PLUGIN}/bin/guard.sh|g" "/code/templates/git-hooks/${h}" > "$WORK/hooks/${h}"
        chmod +x "$WORK/hooks/${h}"
    done
    HOOK="$WORK/hooks/pre-push"
    new_repo "$WORK/repo"
    printf 'guard_release_pattern: refs/heads/release/*\n' > VAULT.md
    printf 'one\n' > file.txt
    commit_all one
    SHA="$(git rev-parse HEAD)"
    record "$SHA"
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
    } > "$PLUGIN/bin/guard.sh"
    chmod +x "$PLUGIN/bin/guard.sh"
}

record() { ( . /code/lib/guard-pass.sh; guard_pass_write "$(guard_pass_key_of_commit "$1")" "${2:-ok}" ); }
index_key() { ( . /code/lib/guard-pass.sh; guard_pass_key_of_index ); }
record_of_index() { cat "$(git rev-parse --path-format=absolute --git-common-dir)/guard-pass/$(index_key)" 2>/dev/null; }
bypass_log() { cat "$(git rev-parse --path-format=absolute --git-common-dir)/guard-bypass.log" 2>/dev/null; }

# push_through_hook <count> <ref> <local sha> — writes four-field stdin lines into the hook
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

new_commit() { printf '%s\n' "$1" >> file.txt; commit_all "$1"; git rev-parse HEAD; }

# --- pre-push: release gate ---------------------------------------------------

@test "every pushed ref reaches the engine once, and the writer drains" {
    run push_through_hook 20000 refs/heads/feature/widget "$SHA"
    [[ "$output" == *'writer=0'* ]]
    [[ "$output" == *'hook=0'* ]]
    [ "$(grep -c 'STUB release --use-pass refs/heads/feature/widget' "$RAN")" -eq 1 ]
}

@test "an inherited GUARD_SKIP or config pin never reaches the engine" {
    printf '#!/usr/bin/env bash\nprintf "SKIP=%%s REV=%%s\\n" "${GUARD_SKIP-unset}" "${GUARD_CONFIG_REV-unset}" >> %s\n' "$RAN" > "$PLUGIN/bin/guard.sh"
    GUARD_SKIP=. GUARD_CONFIG_REV=abc run push_through_hook 1 refs/heads/release/1.0.0 "$SHA"
    grep -q 'SKIP=unset REV=unset' "$RAN"
}

@test "release ref runs the release suite" {
    run push_through_hook 1 refs/heads/release/1.17.0 "$SHA"
    [[ "$output" == *'hook=0'* ]]
    grep -q 'STUB release --use-pass refs/heads/release/1.17.0' "$RAN"
    grep -q "GUARD_SHA=${SHA}" "$RAN"
}

@test "delete line runs no check and drains" {
    run push_through_hook 5000 refs/heads/release/old 0000000000000000000000000000000000000000
    [[ "$output" == *'writer=0'* ]]
    [[ "$output" == *'hook=0'* ]]
    [ ! -e "$RAN" ]
}

@test "a refusing guard refuses the push" {
    stub_guard 1
    run push_through_hook 1 refs/heads/release/1.17.0 "$SHA"
    [[ "$output" == *'hook=1'* ]]
}

# commit_vault <content> — commits VAULT.md with the content and records the new commit.
commit_vault() {
    printf '%s\n' "$1" > VAULT.md
    commit_all vault
    SHA="$(git rev-parse HEAD)"
    record "$SHA"
}

@test "each pushed ref is measured on its own commit; one refusal refuses the push" {
    second="$(new_commit two)"; record "$second"
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "$3" "$GUARD_SHA" >> %s\n[ "$3" = refs/heads/b ] && exit 1\nexit 0\n' "$RAN" > "$PLUGIN/bin/guard.sh"
    run bash -c "printf '%s\n' 'refs/heads/a $SHA refs/heads/a cafe' 'refs/heads/b $second refs/heads/b cafe' | '$HOOK' origin"
    [ "$status" -eq 1 ]
    grep -qx "refs/heads/a $SHA" "$RAN"
    grep -qx "refs/heads/b $second" "$RAN"
    [[ "$output" == *'qg last'* ]]
}

@test "an unreadable guard refuses rather than passing unmeasured" {
    chmod -x "$PLUGIN/bin/guard.sh"
    run push_through_hook 1 refs/heads/release/1.17.0 "$SHA"
    [[ "$output" == *'hook=1'* ]]
    [[ "$output" == *'not executable'* ]]
}

# --- pre-push: pass records (T3) ----------------------------------------------

@test "a recorded commit passes; an unrecorded one refuses, naming it and verify" {
    c="$(new_commit two)"
    run push_through_hook 1 refs/heads/feature/x "$c"
    [[ "$output" == *'hook=1'* ]]
    [[ "$output" == *"$(git rev-parse --short "$c")"* ]]
    [[ "$output" == *"verify ${c} --not --remotes"* ]]
    record "$c"
    run push_through_hook 1 refs/heads/feature/x "$c"
    [[ "$output" == *'hook=0'* ]]
}

@test "a commit already on a remote is never checked" {
    c="$(new_commit two)"
    git update-ref refs/remotes/origin/main "$c"
    run push_through_hook 1 refs/heads/feature/x "$c"
    [[ "$output" == *'hook=0'* ]]
}

@test "one unrecorded commit among several refs refuses the whole push" {
    git checkout -q -b side
    c="$(new_commit side)"
    run bash -c "printf '%s\n' 'refs/heads/main ${SHA} refs/heads/main cafe' 'refs/heads/side ${c} refs/heads/side cafe' | '${HOOK}' origin"
    [ "$status" -eq 1 ]
}

@test "a cherry-picked commit carries no record and is refused" {
    git checkout -q -b topic
    printf 'topic\n' > other.txt; commit_all topic
    c="$(git rev-parse HEAD)"
    record "$c"
    git checkout -q -
    record "$(new_commit main)"
    git -c core.hooksPath=/dev/null cherry-pick "$c" >/dev/null
    run push_through_hook 1 refs/heads/feature/x "$(git rev-parse HEAD)"
    [[ "$output" == *'hook=1'* ]]
}

@test "a revert back to an old tree does not reuse that tree's record" {
    b="$(new_commit two)"
    record "$b"
    git -c core.hooksPath=/dev/null revert --no-edit "$b" >/dev/null
    [ "$(git rev-parse HEAD^{tree})" = "$(git rev-parse "${SHA}^{tree}")" ]
    run push_through_hook 1 refs/heads/feature/x "$(git rev-parse HEAD)"
    [[ "$output" == *'hook=1'* ]]
}

@test "an override passes an unrecorded push, logs it, and prints the log once" {
    c="$(new_commit two)"
    export QG_SKIP_REASON='hotfix'; touch "$WORK/stub-override"
    run push_through_hook 1 refs/heads/feature/x "$c"
    [[ "$output" == *'hook=0'* ]]
    [[ "$output" == *'LOG pre-push to origin'* ]]
    run push_through_hook 1 refs/heads/feature/x "$SHA"
    [[ "$output" != *'LOG pre-push'* ]]
}

@test "a release push still runs the baseline refusal after an override" {
    c="$(new_commit two)"
    stub_guard 1
    export QG_SKIP_REASON='hotfix'; touch "$WORK/stub-override"
    run push_through_hook 1 refs/heads/release/1.0.0 "$c"
    [[ "$output" == *'hook=1'* ]]
    grep -q 'STUB release --use-pass refs/heads/release/1.0.0' "$RAN"
}

# --- commit hooks (T1) --------------------------------------------------------

stage_change() { printf 'staged\n' >> file.txt; git add file.txt; }

@test "guard exit 0 passes and writes the pass record, for each commit hook" {
    stage_change
    for h in pre-commit pre-merge-commit pre-applypatch; do
        rm -rf .git/guard-pass
        run "$WORK/hooks/$h"
        [ "$status" -eq 0 ]
        [ "$(record_of_index)" = ok ]
    done
}

@test "guard exit 1 or 2 refuses and writes no record, for each commit hook" {
    stage_change
    for rc in 1 2; do
        stub_guard "$rc"
        for h in pre-commit pre-merge-commit pre-applypatch; do
            run "$WORK/hooks/$h"
            [ "$status" -eq 1 ]
            [ -z "$(record_of_index)" ]
        done
    done
}

@test "a missing or non-executable guard refuses, for each commit hook" {
    stage_change
    chmod -x "$PLUGIN/bin/guard.sh"
    for h in pre-commit pre-merge-commit pre-applypatch; do
        run "$WORK/hooks/$h"
        [ "$status" -eq 1 ]
        [[ "$output" == *'missing or not executable'* ]]
    done
    rm -f "$PLUGIN/bin/guard.sh"
    for h in pre-commit pre-merge-commit pre-applypatch; do
        run "$WORK/hooks/$h"
        [ "$status" -eq 1 ]
        [ -z "$(record_of_index)" ]
    done
}

@test "an honoured override passes a refused commit with an override record and a log line" {
    stage_change
    stub_guard 1
    export QG_SKIP_REASON='release blocker'; touch "$WORK/stub-override"
    for h in pre-commit pre-merge-commit pre-applypatch; do
        run "$WORK/hooks/$h"
        [ "$status" -eq 0 ]
        [ "$(record_of_index)" = 'override release blocker' ]
    done
    [ "$(bypass_log | wc -l)" -eq 3 ]
    rm -f "$WORK/stub-override"
    run "$WORK/hooks/pre-commit"
    [ "$status" -eq 1 ]
}

@test "a reason on a clean commit writes no log line and an ok record" {
    stage_change
    export QG_SKIP_REASON='not needed'; touch "$WORK/stub-override"
    run "$WORK/hooks/pre-commit"
    [ "$status" -eq 0 ]
    [ "$(record_of_index)" = ok ]
    [ -z "$(bypass_log)" ]
}

@test "post-rewrite after an amend runs verify on the new commit and never copies a record" {
    c="$(new_commit two)"
    record "$c"
    printf 'amended\n' >> file.txt; git add file.txt
    tree="$(git write-tree)"
    ( . /code/lib/guard-pass.sh; guard_pass_write "$(guard_pass_key "$tree" "$c")" ok )
    git -c core.hooksPath=/dev/null commit -q --amend -m amended
    new="$(git rev-parse HEAD)"
    printf '%s %s\n' "$c" "$new" | "$WORK/hooks/post-rewrite" amend
    grep -qx "STUB verify ${new}^! GUARD_SHA=unset" "$RAN"
    [ -z "$(pass_record_of "$new")" ]
    stub_guard 1
    run bash -c "printf '%s %s\n' '$c' '$new' | '$WORK/hooks/post-rewrite' amend"
    [ "$status" -eq 0 ]
    [[ "$output" == *'did not pass'* ]]
    : > "$RAN"
    printf '%s %s\n' "$SHA" "$new" | "$WORK/hooks/post-rewrite" rebase
    [ ! -s "$RAN" ]
    [ -z "$(pass_record_of "$new")" ]
}

# --- lib/guard-install.sh ----------------------------------------------------

@test "install writes all five hooks and status reports them" {
    . /code/lib/guard-install.sh
    run guard_hooks_install
    [ "$status" -eq 0 ]
    for h in pre-commit pre-merge-commit pre-applypatch pre-push post-rewrite; do
        [ -x ".git/hooks/$h" ]
        grep -q '/code/bin/guard.sh' ".git/hooks/$h"
    done
    run guard_hooks_status
    [ "$(grep -c ' installed ' <<<"$output")" -eq 5 ]
}

@test "install records the local commits not on any remote, and only those" {
    rm -rf .git/guard-pass
    git update-ref refs/remotes/origin/main "$SHA"
    c="$(new_commit local)"
    . /code/lib/guard-install.sh
    run guard_hooks_install
    [[ "$output" == *'recorded 1 local commits'* ]]
    [ "$(pass_record_of "$c")" = ok ]
    [ -z "$(pass_record_of "$SHA")" ]
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
    [ ! -e .git/hooks/post-rewrite ]
    [ -e .git/hooks/pre-rebase ]
}

@test "--claude install merges both entries idempotently and keeps foreign ones" {
    . /code/lib/guard-install.sh
    mkdir -p .claude
    printf '{"model":"x","hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"/other.sh"}]}]}}\n' > .claude/settings.json
    guard_hooks install --claude
    guard_hooks install --claude
    f=.claude/settings.json
    [ "$(jq '.hooks.PreToolUse | length' "$f")" -eq 3 ]
    [ "$(jq -r '.model' "$f")" = x ]
    jq -e '.hooks.PreToolUse[] | select(.matcher == "Read")' "$f" >/dev/null
    [ "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$f")" = /code/templates/claude-hooks/guard-bash.sh ]
    [ "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit|NotebookEdit") | .hooks[0].command' "$f")" = /code/templates/claude-hooks/guard-edit.sh ]
    [ "$(jq '.hooks.Stop // [] | length' "$f")" -eq 0 ]
    run guard_hooks_status
    [[ "$output" == *'guard-bash'*'installed'* ]]
    [[ "$output" == *'guard-edit'*'installed'* ]]
}

@test "pre-commit runs hooks/pre-commit.user first, and its failure refuses the commit" {
    printf '#!/usr/bin/env bash\necho USER >> %s\nexit 1\n' "$RAN" > .git/hooks/pre-commit.user
    chmod +x .git/hooks/pre-commit.user
    printf 'more\n' >> file.txt; git add file.txt
    run "$WORK/hooks/pre-commit"
    [ "$status" -eq 1 ]
    grep -q USER "$RAN"
    run grep -q 'STUB commit' "$RAN"
    [ "$status" -ne 0 ]
}

# --- pre-push: every gated ref is measured -----------------------------------

@test "a two-ref push measures both refs and refuses when the first is worse" {
    BAD="$(new_commit bad)"
    git switch -q -c other "$SHA"
    GOOD="$(new_commit good)"
    record "$BAD"; record "$GOOD"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "STUB %%s GUARD_SHA=%%s GUARD_BASE=%%s\\n" "$*" "${GUARD_SHA:-unset}" "${GUARD_BASE:-unset}" >> %s\n' "$RAN"
        printf '[ "$GUARD_SHA" = %s ] && exit 1\nexit 0\n' "$BAD"
    } > "$PLUGIN/bin/guard.sh"
    chmod +x "$PLUGIN/bin/guard.sh"
    run bash -c "printf '%s\n' 'refs/heads/a ${BAD} refs/heads/release/a 0000000000000000000000000000000000000000' 'refs/heads/b ${GOOD} refs/heads/release/b 0000000000000000000000000000000000000000' | '${HOOK}' origin"
    [ "$status" -eq 1 ]
    [ "$(grep -c '^STUB release' "$RAN")" -eq 2 ]
    grep -q "GUARD_SHA=${BAD} GUARD_BASE=" "$RAN"
}

# --- the clean start keeps what git hands a hook --------------------------------------------

@test "a partial commit's temporary index is what the gate measures after the restart" {
    printf 'other\n' > other.txt; commit_all other
    record "$(git rev-parse HEAD)"
    printf '#!/usr/bin/env bash\ngit diff --cached --name-only >> %s\n' "$RAN" > "$PLUGIN/bin/guard.sh"
    printf 'staged\n' >> file.txt; git add file.txt
    printf 'partial\n' >> other.txt
    run env LEAK_PROBE=1 NODE_OPTIONS=--no-warnings git -c core.hooksPath="$WORK/hooks" commit -q -m partial other.txt
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [ "$(cat "$RAN")" = other.txt ]
    [ "$(git diff --cached --name-only)" = file.txt ]
}

@test "post-rewrite after commit --amend with extra names set still verifies the amended commit" {
    c="$(new_commit two)"
    record "$c"
    printf 'amended\n' >> file.txt; git add file.txt
    run env LEAK_PROBE=1 'BASH_FUNC_f%%=() { :; }' BASH_ENV=/dev/null git -c core.hooksPath="$WORK/hooks" commit -q --amend -m amended
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    new="$(git rev-parse HEAD)"
    [ "$new" != "$c" ]
    grep -qx "STUB verify ${new}^! GUARD_SHA=unset" "$RAN"
}
