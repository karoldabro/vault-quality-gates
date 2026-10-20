#!/usr/bin/env bats
# Push pass record: `qg run push --ref <ref>` records a full pass, and `pre-push` accepts it instead
# of measuring while git holds the connection to the remote. Contract:
# vault/architecture/guard-push-pass.md.
#
# Each test pushes through the real hooks to a bare remote, with a copy of the engine under
# $WORK/engine so a test can change an engine file. The push row appends a line to $COUNT on every
# run, so "measured" means $COUNT grew.

load guard-helpers

REF=refs/heads/release/1.0.0

setup() {
    export LC_ALL=C
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT GUARD_SKIP GUARD_CONFIG_REV GUARD_SHA GUARD_BASE
    WORK="$(mktemp -d)"
    COUNT="$WORK/count"
    ENGINE="$WORK/engine"
    mkdir -p "$ENGINE"
    cp -a /code/bin /code/lib /code/drivers "$ENGINE/"
    QG="$ENGINE/bin/qg"
    git init -q --bare "$WORK/remote.git"
    new_repo "$WORK/repo"
    git remote add origin "$WORK/remote.git"
    counter_row 0
    commit_all init
    git -c core.hooksPath=/dev/null push -q origin HEAD:refs/heads/master
    git fetch -q origin
    git checkout -q -b release/1.0.0
    install_pre_push "/code/templates/git-hooks/pre-push"
    new_commit one
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# counter_row <value> — a release row that counts its runs and measures <value> against a ceiling of 0.
counter_row() {
    write_checks "counter"$'\tpush:refs/heads/release/*\tdiff\tshell\t-- '"echo x >> ${COUNT}; echo $1"$'\tdown\t0\trefuse\ta test row'
    write_rules
}

# install_pre_push <template> — the hook a gated repo carries, pointing at the engine copy.
install_pre_push() {
    sed "s|__GUARD_SH__|${ENGINE}/bin/guard.sh|g" "$1" > .git/hooks/pre-push
    chmod +x .git/hooks/pre-push
}

# new_commit <line> — commits a change and records its commit-gate pass, as the commit hook would.
new_commit() {
    printf '%s\n' "$1" >> file.txt
    commit_all "$1"
    ( . "$ENGINE/lib/guard-pass.sh"; guard_pass_write "$(guard_pass_key_of_commit HEAD)" ok )
}

runs() { [ -r "$COUNT" ] && wc -l < "$COUNT" | tr -d ' ' || printf '0'; }
records() { find "$(git rev-parse --path-format=absolute --git-common-dir)/guard-pass/push" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }
record_file() { find "$(git rev-parse --path-format=absolute --git-common-dir)/guard-pass/push" -type f ! -name '.*' | head -1; }
push() { run git push -q origin "HEAD:${1:-$REF}"; }

@test "a push that qg run push --ref recorded is accepted without measuring" {
    run "$QG" run push --ref "$REF"
    [ "$status" -eq 0 ]
    [[ "$output" == *'pass recorded'* ]]
    [ "$(runs)" -eq 1 ]
    push
    [ "$status" -eq 0 ]
    [[ "$output" == *'passed qg run push 0 min ago; not measured again'* ]]
    [ "$(runs)" -eq 1 ]
    [ "$(git ls-remote origin "$REF" | cut -f1)" = "$(git rev-parse HEAD)" ]
}

@test "an amended commit is measured although its parent was recorded" {
    "$QG" run push --ref "$REF"
    printf 'two\n' >> file.txt
    git add -A && git -c core.hooksPath=/dev/null commit -q --amend -m amended
    ( . "$ENGINE/lib/guard-pass.sh"; guard_pass_write "$(guard_pass_key_of_commit HEAD)" ok )
    push
    [ "$status" -eq 0 ]
    [ "$(runs)" -eq 2 ]
}

@test "a push to another ref name is measured" {
    "$QG" run push --ref "$REF"
    push refs/heads/release/2.0.0
    [ "$status" -eq 0 ]
    [[ "$output" != *'not measured again'* ]]
    [ "$(runs)" -eq 2 ]
}

@test "a remote tip that moved after the record makes the push measure" {
    git -c core.hooksPath=/dev/null push -q origin "HEAD:$REF"
    git fetch -q origin
    new_commit two
    mid="$(git rev-parse HEAD)"
    new_commit three
    "$QG" run push --ref "$REF"
    [ "$(records)" -eq 1 ]
    # Someone else fast-forwards the remote ref; the local tracking ref still shows the old tip.
    git -c core.hooksPath=/dev/null push -q origin "${mid}:refs/heads/other"
    git --git-dir="$WORK/remote.git" update-ref "$REF" "$mid"
    push
    [ "$status" -eq 0 ]
    [ "$(runs)" -eq 2 ]
}

@test "an engine file changed after the record makes the push measure" {
    "$QG" run push --ref "$REF"
    printf '# changed\n' >> "$ENGINE/lib/qg-explain.sh"
    push
    [ "$status" -eq 0 ]
    [ "$(runs)" -eq 2 ]
    chmod -x "$ENGINE/drivers/shell.sh"
    "$QG" run push --ref "$REF" || true
    chmod +x "$ENGINE/drivers/shell.sh"
    git -c core.hooksPath=/dev/null push -q origin --delete release/1.0.0
    push
    [ "$(runs)" -eq 4 ]
}

@test "a record older than an hour, dated in the future, or unparsable makes the push measure" {
    local n=0
    for content in "ok $(( $(date +%s) - 3601 ))" "ok $(( $(date +%s) + 600 ))" 'ok' 'override x' "ok 12abc"; do
        "$QG" run push --ref "$REF"
        n=$((n + 1))
        printf '%s\n' "$content" > "$(record_file)"
        push
        [ "$status" -eq 0 ]
        n=$((n + 1))
        [ "$(runs)" -eq "$n" ]
        git -c core.hooksPath=/dev/null push -q origin --delete release/1.0.0
        rm -f "$(record_file)"
    done
}

@test "qg run push with --only, a worse row, an unmeasurable row, or no --ref writes no record" {
    run "$QG" run push --ref "$REF" --only counter
    [ "$status" -eq 0 ]
    [ "$(records)" -eq 0 ]
    run "$QG" run push
    [ "$status" -eq 0 ]
    [[ "$output" == *'qg run push --ref refs/heads/release/1.0.0'* ]]
    [ "$(records)" -eq 0 ]
    counter_row 1; new_commit worse
    run "$QG" run push --ref "$REF"
    [ "$status" -eq 1 ]
    [ "$(records)" -eq 0 ]
    counter_row nan; new_commit unmeasurable
    run "$QG" run push --ref "$REF"
    [ "$status" -eq 2 ]
    [ "$(records)" -eq 0 ]
}

@test "qg run push --ref refuses a baseline loosened against the remote tip and records nothing" {
    write_checks $'level\tpush:refs/heads/release/*\trepo\tshell\t-- echo 3\tdown\t0\trefuse\ta test row'
    printf 'id\tvalue\tcommit\treason\nlevel\t3\t-\t-\n' > quality/baseline.tsv
    new_commit tight
    git -c core.hooksPath=/dev/null push -q origin "HEAD:$REF"
    git fetch -q origin
    printf 'id\tvalue\tcommit\treason\nlevel\t5\t-\t-\n' > quality/baseline.tsv
    new_commit loose
    run "$QG" run push --ref "$REF"
    [ "$status" -eq 1 ]
    [[ "$output" == *'baseline-loosened'* ]]
    [ "$(records)" -eq 0 ]
}

@test "an installed pre-push without --use-pass measures although a record exists" {
    "$QG" run push --ref "$REF"
    [ "$(records)" -eq 1 ]
    install_pre_push /code/tests/fixtures/hooks-43d7082/pre-push
    push
    [ "$status" -eq 0 ]
    [ "$(runs)" -eq 2 ]
}

@test "guard.sh release refuses an unknown flag, so an engine without --use-pass never passes a push" {
    run "$ENGINE/bin/guard.sh" release --bogus "$REF"
    [ "$status" -eq 2 ]
    [[ "$output" == *'release does not take --bogus'* ]]
    sed 's|release --use-pass|release --bogus|' .git/hooks/pre-push > "$WORK/pre-push"
    cp "$WORK/pre-push" .git/hooks/pre-push
    push
    [ "$status" -ne 0 ]
    [ -z "$(git ls-remote origin "$REF")" ]
    [ "$(runs)" -eq 0 ]
}
