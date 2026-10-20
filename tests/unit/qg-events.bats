#!/usr/bin/env bats
# lib/qg-events.sh — the `on` grammar and row selection per event.

setup() {
    export LC_ALL=C
    . /code/lib/qg-events.sh
}

@test "valid cells are accepted" {
    local c
    for c in - commit push baseline 'push:refs/heads/release/*' 'commit,push' 'commit,push:refs/heads/*,baseline' 'push:refs/heads/a|b'; do
        qg_on_valid "$c" || { echo "refused: $c"; return 1; }
    done
}

@test "malformed cells are refused with a reason" {
    local c
    for c in '' ' ' ',commit' 'commit,' 'commit,,push' 'COMMIT' 'push:' 'pull' 'commit, push' 'release' '-,commit'; do
        run qg_on_valid "$c"
        [ "$status" -eq 1 ] || { echo "accepted: [$c]"; return 1; }
        [ -n "$output" ]
    done
}

@test "truth table: each token against commit, push with a ref, and baseline" {
    qg_row_runs_on commit commit
    ! qg_row_runs_on commit push refs/heads/x
    ! qg_row_runs_on commit baseline
    qg_row_runs_on push push refs/heads/x
    ! qg_row_runs_on push commit
    qg_row_runs_on baseline baseline
    ! qg_row_runs_on baseline push refs/heads/x
    ! qg_row_runs_on - commit
    ! qg_row_runs_on - push refs/heads/x
    ! qg_row_runs_on - baseline
    qg_row_runs_on 'commit,push:refs/heads/release/*' commit
    qg_row_runs_on 'commit,push:refs/heads/release/*' push refs/heads/release/1.0
}

@test "globs follow [[ == ]]: * ? [ match, | is literal, a bare prefix does not match" {
    qg_row_runs_on 'push:refs/heads/release/*' push refs/heads/release/1.2.3
    ! qg_row_runs_on 'push:refs/heads/release/*' push refs/heads/realse/1
    ! qg_row_runs_on 'push:refs/heads/release/*' push refs/heads/release
    qg_row_runs_on 'push:refs/heads/v?' push refs/heads/v1
    qg_row_runs_on 'push:refs/heads/[ab]' push refs/heads/b
    ! qg_row_runs_on 'push:refs/heads/a|b' push refs/heads/a
    qg_row_runs_on 'push:refs/heads/a|b' push 'refs/heads/a|b'
}

@test "push with no ref (a hand run) matches every push token" {
    qg_row_runs_on 'push:refs/heads/release/*' push
    qg_row_runs_on 'push:refs/heads/release/*' push -
    qg_row_runs_on push push -
    ! qg_row_runs_on commit push -
}
