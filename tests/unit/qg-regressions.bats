#!/usr/bin/env bats
# Behaviour that must not drift from 43d7082 or from the format contract: shell rows run
# isolated, every v2 cell is required, an option without its value never hangs, plain metrics keep
# their precision, verify refusals name the commit, and a push no row measures still keeps the
# baseline lock.

load guard-helpers

V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT GUARD_SKIP GUARD_CONFIG_REV GUARD_SHA GUARD_BASE
    new_repo "$WORK/repo"
    write_rules
    mkdir -p app sub
    printf 'clean\n' > app/a
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

@test "shell rows run isolated: a cd does not move the artifact, an exit does not skip the parser" {
    write_checks $'cloc-sub\tcommit\tdiff\tshell\tparser=cloc artifact=sub/cloc.json -- cd sub && printf \'{"SUM":{"code":10,"comment":1}}\' > cloc.json\tdown\t1\trefuse\ta test row' \
                 $'grep-exit\tcommit\tdiff\tshell\tparser=exitcode -- grep -q BAD app/a && exit 1; exit 0\tdown\t0\trefuse\ta test row'
    commit_all init
    printf 'x\n' > app/b; git add app/b
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    printf 'BAD\n' > app/a; git add app/a
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ] && [[ "$output" == *'grep-exit'*'worse'* ]]
}

@test "a v2 row with an empty or blank why does not load" {
    for why in '' '   '; do
        { printf '%s\n' "$V2_HEADER"; printf 'x\tcommit\tdiff\tshell\t-- echo 0\tdown\t0\trefuse\t%s\n' "$why"; } > quality/checks.tsv
        run bash -c '. /code/lib/guard-metrics.sh; guard_load_checks quality/checks.tsv'
        [ "$status" -eq 2 ] || { echo "loaded why=[$why]"; return 1; }
    done
}

@test "an option with no value exits 2 at once instead of hanging" {
    { printf '%s\n' "$V2_HEADER"; printf 'x\tcommit\tdiff\tshell\t-- echo 0\tdown\t0\trefuse\twhy\n'; } > quality/checks.tsv
    commit_all init
    local c
    for c in 'bash /code/bin/guard.sh release --only' '/code/bin/qg run commit --only' '/code/bin/qg run push --ref' \
             '/code/bin/qg override --reason' '/code/bin/qg init --profile'; do
        # shellcheck disable=SC2086
        run timeout 10 $c
        [ "$status" -eq 2 ] || { echo "$c -> $status"; return 1; }
    done
}

@test "a plain decimal metric keeps its precision; an exponent becomes a plain number" {
    . /code/lib/guard-metrics.sh
    [ "$(printf '87.1234567' | guard_number_line)" = 87.1234567 ]
    [ "$(printf '12345678901234567890' | guard_number_line)" = 12345678901234567890 ]
    [ "$(printf '1e3' | guard_number_line)" = 1000 ]
    [ "$(printf '2.5E-1' | guard_number_line)" = 0.25 ]
}

@test "a refusal from guard.sh verify names the commit and reproduces it with qg verify" {
    { printf '%s\n' "$V2_HEADER"; printf 'n\tcommit\tdiff\tshell\t-- grep -c BAD app/a || true\tdown\t0\trefuse\tno BAD marker\n'; } > quality/checks.tsv
    commit_all init
    printf 'BAD\n' > app/a; commit_all bad
    sha="$(git rev-parse HEAD)"
    run bash /code/bin/guard.sh verify HEAD~1..HEAD
    [ "$status" -eq 1 ]
    [[ "$output" == *"commit ${sha:0:12} was refused"* ]]
    [[ "$output" == *"reproduce: qg verify ${sha:0:12}^!"* ]]
    [[ "$output" != *'the staged commit'* ]]
}

@test "a push no row measures still refuses a loosened baseline" {
    { printf '%s\n' "$V2_HEADER"; printf 'cov\tpush:refs/heads/release/*\trepo\tshell\t-- echo 80\tup\t0\trefuse\tcoverage never drops\n'; } > quality/checks.tsv
    printf 'id\tvalue\tcommit\treason\ncov\t80\tabc\t-\n' > quality/baseline.tsv
    commit_all init
    base="$(git rev-parse HEAD)"
    printf 'id\tvalue\tcommit\treason\ncov\t70\tabc\t-\n' > quality/baseline.tsv
    commit_all loosen
    GUARD_SHA="$(git rev-parse HEAD)" GUARD_BASE="$base" run bash /code/bin/guard.sh release refs/heads/feature/x
    [ "$status" -eq 1 ] && [[ "$output" == *'baseline-loosened'* ]]
    printf 'id\tvalue\tcommit\treason\ncov\t85\tabc\t-\n' > quality/baseline.tsv
    commit_all tighten
    GUARD_SHA="$(git rev-parse HEAD)" GUARD_BASE="$base" run bash /code/bin/guard.sh release refs/heads/feature/x
    [ "$status" -eq 0 ] && [[ "$output" == *'no gate row runs on refs/heads/feature/x'* ]]
}

@test "a pinned config without quality/checks.tsv is an error, never a pass" {
    commit_all bare
    pin="$(git rev-parse HEAD)"
    { printf '%s\n' "$V2_HEADER"; printf 'x\tpush\tdiff\tshell\t-- echo 0\tdown\t0\trefuse\twhy\n'; } > quality/checks.tsv
    commit_all gated
    GUARD_CONFIG_REV="$pin" GUARD_SHA="$(git rev-parse HEAD)" run bash /code/bin/guard.sh release refs/heads/feature/x
    [ "$status" -eq 2 ]
}

@test "refusal cut keeps the text valid UTF-8" {
    . /code/lib/guard-metrics.sh
    s="$(printf 'ab\xc3\xa9')"           # "abé": cutting after 3 bytes splits the é
    out="$(qg_utf8_trim "${s:0:3}")"
    [ "$out" = ab ]
}
