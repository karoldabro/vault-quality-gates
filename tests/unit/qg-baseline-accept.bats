#!/usr/bin/env bats
# A looser quality/baseline.tsv that `qg baseline` wrote at a terminal passes the commit gate and
# the push gate (lib/guard-baseline-accept.sh). A hand edit, a baseline written with no terminal,
# and an accepted file edited afterwards stay refused. Every push goes through the real installed
# hooks to a bare remote; script(1) gives the pseudo-terminal that makes a run "a human".

load guard-helpers

QG=/code/bin/qg

setup() {
    export LC_ALL=C
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT GUARD_SKIP GUARD_CONFIG_REV GUARD_SHA GUARD_BASE
    WORK="$(mktemp -d)"
    git init -q --bare "$WORK/remote.git"
    new_repo "$WORK/repo"
    git checkout -q -b main
    git remote add origin "$WORK/remote.git"
    # The push row reads the score from outside the repo, so a test lowers it without a commit.
    printf '80\n' > "$WORK/score"
    write_checks "cov"$'\t'"release"$'\t'"repo"$'\t'"cat ${WORK}/score"$'\t-\t-\tup\t0\trefuse'
    write_rules
    printf 'guard_release_pattern: refs/heads/main\n' > VAULT.md
    printf 'id\tvalue\tcommit\treason\ncov\t80\tabc\t-\n' > quality/baseline.tsv
    commit_all init
    git -c core.hooksPath=/dev/null push -q origin HEAD:refs/heads/main
    git fetch -q origin
    ( export GUARD_LIB_DIR=/code/lib; . /code/lib/guard-metrics.sh; . /code/lib/guard-install.sh; guard_hooks_install >/dev/null )
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# at_tty <command> — runs it under a pseudo-terminal with the agent markers removed.
at_tty() { script -qec "env -u CLAUDECODE -u AI_AGENT -u QG_SKIP_REASON bash -c $(printf '%q' "$1")" /dev/null; }
records() { cat "$(git rev-parse --path-format=absolute --git-common-dir)/qg-baseline-accept" 2>/dev/null; }
remote_main() { git ls-remote origin refs/heads/main | cut -f1; }
set_cov() { printf 'id\tvalue\tcommit\treason\ncov\t%s\tabc\t-\n' "$1" > quality/baseline.tsv; }

@test "the operator path: lower a score, qg baseline at a terminal, commit, push without --no-verify" {
    printf '70\n' > "$WORK/score"
    run at_tty "$QG baseline --reason 'first real feature lowers the score' 2>&1; echo rc=\$?"
    [[ "$output" == *'rc=0'* ]]
    [[ "$output" == *'accepted as the new floor'* ]]
    [ "$(records | wc -l)" -eq 1 ]
    git add quality/baseline.tsv
    run at_tty 'git commit -q -m "lower the floor" 2>&1; echo rc=$?'
    [[ "$output" == *'rc=0'* ]]
    run git push -q origin HEAD:refs/heads/main
    [ "$status" -eq 0 ]
    [ "$(remote_main)" = "$(git rev-parse HEAD)" ]
    grep -q 'qg baseline accepted quality/baseline.tsv' "$(git rev-parse --git-common-dir)/guard-bypass.log"
}

@test "qg run push passes an accepted looser baseline and records a pass that git push takes" {
    printf '70\n' > "$WORK/score"
    at_tty "$QG baseline" >/dev/null
    git add quality/baseline.tsv
    at_tty 'git commit -q -m lower' >/dev/null
    run "$QG" run push --ref refs/heads/main
    [ "$status" -eq 0 ]
    [[ "$output" == *'pass recorded'* ]]
    run git push -q origin HEAD:refs/heads/main
    [ "$status" -eq 0 ]
    [[ "$output" == *'not measured again'* ]]
}

@test "a hand-lowered baseline is refused at commit, and its push names qg baseline, never --push" {
    set_cov 70
    git add quality/baseline.tsv
    run at_tty 'git commit -q -m hand 2>&1; echo rc=$?'
    [[ "$output" == *'rc=1'* ]]
    [[ "$output" == *'baseline-loosened'*'qg baseline --reason'* ]]
    run at_tty 'QG_SKIP_REASON=forced git commit -q -m hand 2>&1; echo rc=$?'
    [[ "$output" == *'rc=0'* ]]
    run git push -q origin HEAD:refs/heads/main
    [ "$status" -ne 0 ]
    [[ "$output" == *'baseline-loosened'*'worse'* ]]
    [[ "$output" == *'qg baseline --reason'* ]]
    [[ "$output" != *'--push <sha>'* ]]
    [ "$(remote_main)" != "$(git rev-parse HEAD)" ]
}

@test "a baseline written with no terminal is not accepted, and its commit is refused" {
    printf '70\n' > "$WORK/score"
    run bash /code/bin/guard.sh baseline
    [ "$status" -eq 0 ]
    [[ "$output" == *'not accepted as a new floor'* ]]
    [ -z "$(records)" ]
    git add quality/baseline.tsv
    run at_tty 'git commit -q -m lower 2>&1; echo rc=$?'
    [[ "$output" == *'rc=1'* ]]
}

@test "an agent marker at a terminal writes no record" {
    printf '70\n' > "$WORK/score"
    run at_tty 'export CLAUDECODE=1; bash /code/bin/guard.sh baseline 2>&1'
    [[ "$output" == *'not accepted as a new floor'* ]]
    [ -z "$(records)" ]
}

@test "an accepted file edited afterwards is a different file and is refused" {
    printf '70\n' > "$WORK/score"
    at_tty "$QG baseline" >/dev/null
    set_cov 60
    git add quality/baseline.tsv
    run at_tty 'git commit -q -m lower-more 2>&1; echo rc=$?'
    [[ "$output" == *'rc=1'* ]]
    [[ "$output" == *'cov 80 -> 60'* ]]
}

@test "a tighter baseline needs no record" {
    printf '90\n' > "$WORK/score"
    run bash /code/bin/guard.sh baseline
    git add quality/baseline.tsv
    run at_tty 'git commit -q -m tighter 2>&1; echo rc=$?'
    [[ "$output" == *'rc=0'* ]]
    run git push -q origin HEAD:refs/heads/main
    [ "$status" -eq 0 ]
}

@test "baseline refuses an unknown option, a blank reason, and an option with no value" {
    run bash /code/bin/guard.sh baseline --frobnicate x
    [ "$status" -eq 2 ]
    run bash /code/bin/guard.sh baseline --reason '  '
    [ "$status" -eq 2 ]
    run bash /code/bin/guard.sh baseline --reason
    [ "$status" -eq 2 ]
}
