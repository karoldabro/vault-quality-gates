#!/usr/bin/env bats
# `guard.sh baseline --only <ids>`: measures the named rows, rewrites only their lines, keeps every
# other line of quality/baseline.tsv byte for byte (an accepted reason included), and writes
# nothing when a named row yields no number.

load guard-helpers

V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT GUARD_SKIP GUARD_ONLY GUARD_CONFIG_REV
    gate_repo "$WORK/repo"
    { printf '%s\n' "$V2_HEADER"
      printf 'coverage\tpush\trepo\tshell\t-- echo 81\tup\t0.5\trefuse\tcoverage never drops\n'
      printf 'clones\tpush\trepo\tshell\t-- echo 400\tdown\t0\trefuse\tduplicated blocks never grow\n'
      printf 'broken\tpush\trepo\tshell\t-- echo not-a-number\tdown\t0\trefuse\ta row whose tool prints no number\n'
      printf 'fresh\tpush\trepo\tshell\t-- echo 7\tdown\t0\trefuse\ta row with no baseline line yet\n'
      printf 'suite\tbaseline\tdiff\tshell\t-- touch "%s/suite-ran"; echo 0\tdown\t0\trefuse\tthe whole suite passes\n' "$WORK"
    } > quality/checks.tsv
    printf 'id\tvalue\tcommit\treason\n# hand-written comment\ncoverage\t80\tabc\t-\nclones\t392\tdef\taccepted by the operator to ship\nbroken\t3\tghi\t-\n' \
        > quality/baseline.tsv
    commit_all v2
    cp quality/baseline.tsv "$WORK/before.tsv"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

@test "--only coverage rewrites only that line; every other line, the accepted reason included, is unchanged" {
    run bash /code/bin/guard.sh baseline --only coverage
    [ "$status" -eq 0 ]
    [ "$(awk -F'\t' '$1 == "coverage" { print $2 }' quality/baseline.tsv)" = 81 ]
    diff <(grep -v '^coverage' "$WORK/before.tsv") <(grep -v '^coverage' quality/baseline.tsv)
    [ ! -e "$WORK/suite-ran" ]
}

@test "--only adds a line for a named row that had none, and invents no line for an unnamed row" {
    run bash /code/bin/guard.sh baseline --only fresh
    [ "$status" -eq 0 ]
    [ "$(awk -F'\t' '$1 == "fresh" { print $2 }' quality/baseline.tsv)" = 7 ]
    [ "$(grep -c . quality/baseline.tsv)" -eq "$(( $(grep -c . "$WORK/before.tsv") + 1 ))" ]
}

@test "--only with one named row unmeasurable exits 2 naming it and leaves the file byte-identical" {
    run bash /code/bin/guard.sh baseline --only coverage,broken
    [ "$status" -eq 2 ]
    [[ "$output" == *'broken'* ]] && [[ "$output" == *'wrote nothing'* ]]
    cmp "$WORK/before.tsv" quality/baseline.tsv
}

@test "--only with an unknown id or an empty list exits 2 and writes nothing" {
    run bash /code/bin/guard.sh baseline --only nosuchrow
    [ "$status" -eq 2 ] && [[ "$output" == *'nosuchrow'* ]]
    run bash /code/bin/guard.sh baseline --only ''
    [ "$status" -eq 2 ]
    cmp "$WORK/before.tsv" quality/baseline.tsv
}

@test "--skip still rewrites every measured row and keeps the skipped one" {
    run bash /code/bin/guard.sh baseline --skip '^(suite|broken)$'
    [ "$status" -eq 0 ]
    [ "$(awk -F'\t' '$1 == "clones" { print $2 "|" $4 }' quality/baseline.tsv)" = '400|-' ]
    [ "$(awk -F'\t' '$1 == "broken" { print $2 }' quality/baseline.tsv)" = 3 ]
}
