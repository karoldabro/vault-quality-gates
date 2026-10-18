#!/usr/bin/env bats
# The baseline lock on a v2 checks.tsv: direction comes from the `direction` column by name, so a
# lowered `up` row is loosened and a raised `down` row is loosened, on commit and on push.

load guard-helpers

V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT GUARD_SKIP GUARD_CONFIG_REV
    gate_repo "$WORK/repo"
    { printf '%s\n' "$V2_HEADER"
      printf 'coverage\tpush\trepo\tshell\t-- echo 80\tup\t0.5\trefuse\tcoverage never drops\n'
      printf 'phpstan\tpush\trepo\tshell\t-- echo 10\tdown\t0\trefuse\tstatic errors never grow\n'
    } > quality/checks.tsv
    printf 'id\tvalue\tcommit\treason\ncoverage\t80\tabc\t-\nphpstan\t10\tabc\t-\n' > quality/baseline.tsv
    commit_all v2
    BASE="$(git rev-parse HEAD)"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

set_base() { printf 'id\tvalue\tcommit\treason\ncoverage\t%s\tabc\t-\nphpstan\t%s\tabc\t-\n' "$1" "$2" > quality/baseline.tsv; }

@test "commit: a lowered up row and a raised down row are loosened; the reverse passes" {
    set_base 70 10; git add quality/baseline.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ] && [[ "$output" == *'baseline-loosened'*'coverage 80 -> 70 (lower is worse)'* ]]
    set_base 80 11; git add quality/baseline.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ] && [[ "$output" == *'phpstan 10 -> 11 (higher is worse)'* ]]
    set_base 85 9; git add quality/baseline.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
}

@test "a v2 row with an empty cell or an unknown kind, direction or gate does not load, and is refused when staged" {
    local bad r
    for bad in $'x\tcommit\tdiff\tshell\t\tdown\t0\trefuse\twhy' $'x\tcommit\tdiff\tshell\t-- echo 0\tdown\t0\trefues\twhy' \
               $'x\tcommit\tdif\tshell\t-- echo 0\tdown\t0\trefuse\twhy' $'x\tcommit\tdiff\tshell\t-- echo 0\tsideways\t0\trefuse\twhy'; do
        { printf '%s\n' "$V2_HEADER"; printf '%s\n' "$bad"; } > quality/checks.tsv
        run bash -c '. /code/lib/guard-metrics.sh; guard_load_checks quality/checks.tsv'
        [ "$status" -eq 2 ] && [[ "$output" == *'line 2'* ]] || { echo "loaded: $bad"; return 1; }
        git add quality/checks.tsv
        run bash /code/bin/guard.sh commit
        [ "$status" -eq 1 ] && [[ "$output" == *'gate-config-invalid'* ]] || { echo "not refused: $bad"; return 1; }
    done
}

@test "push: a commit that lowers an up row against GUARD_BASE is refused" {
    set_base 70 10
    commit_all loosen
    GUARD_SHA="$(git rev-parse HEAD)" GUARD_BASE="$BASE" run bash /code/bin/guard.sh release refs/heads/feature/x
    [ "$status" -eq 1 ]
    [[ "$output" == *'baseline-loosened'* ]]
}
