#!/usr/bin/env bats
# lib/guard-metrics.sh — loading checks, reading baselines, comparing, parsing.
#
# Every absence is asserted with `run` and a status check, never `! grep`, which is
# exempt from set -e and passes decoratively.
#
# Every test that writes builds its tree under mktemp -d. /code is mounted read-only,
# so a write assertion against it would pass without proving anything.

setup() {
    export LC_ALL=C
    export GUARD_LIB_DIR=/code/lib
    # shellcheck source=../../lib/guard-metrics.sh
    . /code/lib/guard-metrics.sh
    FIX=/code/tests/fixtures/guard
    WORK="$(mktemp -d)"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

write_baseline() {  # write_baseline <path> <id> <value> <reason>
    printf 'id\tvalue\tcommit\treason\n%s\t%s\tabc1234\t%s\n' "$2" "$3" "$4" > "$1"
}

init_repo() {  # init_repo <dir>
    mkdir -p "$1/quality"
    cd "$1" || return 1
    git init -q .
    git config user.email 'test@example.invalid'
    git config user.name 'test'
}

# --- SC-1: a worse metric refuses, and says why ------------------------------

@test "worse than baseline exits 1" {
    write_baseline "$WORK/baseline.tsv" phpstan-errors 100 -
    run guard_compare phpstan-errors repo 150 down 0 refuse "$WORK/baseline.tsv"
    [ "$status" -eq 1 ]
}

@test "refusal names metric values and tolerance" {
    write_baseline "$WORK/baseline.tsv" phpstan-errors 100 -
    guard_compare phpstan-errors repo 150 down 0 refuse "$WORK/baseline.tsv" || true
    line="${GUARD_RESULTS[0]}"
    [[ "$line" == phpstan-errors\|* ]]
    [[ "$line" == *'|150|'* ]]
    [[ "$line" == *'|100|'* ]]
    [[ "$line" == *'baseline 100, tolerated 0'* ]]
}

@test "delta equal to threshold passes" {
    write_baseline "$WORK/baseline.tsv" coverage 100 -
    run guard_compare coverage repo 105 down 5 refuse "$WORK/baseline.tsv"
    [ "$status" -eq 0 ]
}

@test "a gate of record never refuses, however much worse" {
    write_baseline "$WORK/baseline.tsv" insights-style 90 -
    run guard_compare insights-style repo 10 up 0 record "$WORK/baseline.tsv"
    [ "$status" -eq 0 ]
}

@test "no baseline row records the number and judges nothing" {
    write_baseline "$WORK/baseline.tsv" other 100 -
    guard_compare newcomer repo 42 down 0 refuse "$WORK/baseline.tsv"
    [[ "${GUARD_RESULTS[0]}" == *'|recorded|no baseline row'* ]]
}

# --- SC-2: unmeasurable is exit 2, never a recorded value --------------------

@test "null msi exits 2" {
    run guard_parse_row infection "$FIX/infection-log.json" 0
    [ "$status" -eq 2 ]
}

@test "a real msi parses to its number" {
    run guard_parse_row infection "$FIX/infection-log-scored.json" 0
    [ "$status" -eq 0 ]
    [ "$output" = '62.5' ]
}

@test "absent artifact exits 2" {
    run guard_parse_row clover "$WORK/does-not-exist.xml" 0
    [ "$status" -eq 2 ]
}

@test "empty parser output exits 2" {
    mkdir -p "$WORK/lib/guard-parsers"
    cp /code/lib/guard-parsers/_lib.sh "$WORK/lib/guard-parsers/_lib.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/lib/guard-parsers/silent.sh"
    chmod +x "$WORK/lib/guard-parsers/silent.sh"
    GUARD_LIB_DIR="$WORK/lib" run guard_parse_row silent "$WORK/anything" 0
    [ "$status" -eq 2 ]
}

@test "command exit 127 exits 2" {
    run guard_parse_row exitcode - 127
    [ "$status" -eq 2 ]
}

@test "a clean command status parses to 0 and a finding to 1" {
    run guard_parse_row exitcode - 0
    [ "$status" -eq 0 ]
    [ "$output" = '0' ]
    run guard_parse_row exitcode - 1
    [ "$status" -eq 0 ]
    [ "$output" = '1' ]
}

@test "non-numeric baseline value exits 2" {
    write_baseline "$WORK/baseline.tsv" coverage 'n/a' -
    run guard_baseline_value "$WORK/baseline.tsv" coverage
    [ "$status" -eq 2 ]
    run guard_compare coverage repo 80 up 0 refuse "$WORK/baseline.tsv"
    [ "$status" -eq 2 ]
}

@test "wrong field count exits 2" {
    { printf '%s\n' "$GUARD_CHECKS_HEADER"; printf 'a\tb\tc\td\te\tf\tg\th\n'; } > "$WORK/checks.tsv"
    run guard_load_checks "$WORK/checks.tsv"
    [ "$status" -eq 2 ]
}

@test "line 1 not the header exits 2" {
    { printf '# id\tscope\tkind\n'; printf '%s\n' "$GUARD_CHECKS_HEADER"; } > "$WORK/checks.tsv"
    run guard_load_checks "$WORK/checks.tsv"
    [ "$status" -eq 2 ]
}

@test "a file of comments alone yields no rows" {
    { printf '%s\n' "$GUARD_CHECKS_HEADER"; printf '# nothing configured yet\n'; } > "$WORK/checks.tsv"
    guard_load_checks "$WORK/checks.tsv"
    [ "${#GUARD_ROWS[@]}" -eq 0 ]
}

@test "an absent row is rendered and never executed" {
    write_baseline "$WORK/baseline.tsv" mutation 50 -
    : > "$WORK/files"
    row=$'mutation\t-\tabsent\tfalse\t-\t-\t-\t-\t-'
    run guard_run_row "$row" "$WORK/baseline.tsv" HEAD "$WORK/files"
    [ "$status" -eq 0 ]
    guard_run_row "$row" "$WORK/baseline.tsv" HEAD "$WORK/files"
    [[ "${GUARD_RESULTS[0]}" == *'|absent|'* ]]
}

# --- SC-4: a lowered baseline is a refusal, not a pass -----------------------

@test "lowered baseline without reason exits 1" {
    init_repo "$WORK/repo"
    printf '%s\n' "$GUARD_CHECKS_HEADER" > quality/checks.tsv
    printf 'coverage\trelease\trepo\ttrue\tclover\ta\tup\t0\trefuse\n' >> quality/checks.tsv
    write_baseline quality/baseline.tsv coverage 80 -
    git add -A && git commit -qm base
    sha="$(git rev-parse HEAD)"
    write_baseline quality/baseline.tsv coverage 70 -
    run guard_baseline_diff quality/baseline.tsv refs/heads/release/1.0 "$sha" quality/checks.tsv
    [ "$status" -eq 1 ]
}

@test "lowered baseline with reason passes" {
    init_repo "$WORK/repo"
    printf '%s\n' "$GUARD_CHECKS_HEADER" > quality/checks.tsv
    printf 'coverage\trelease\trepo\ttrue\tclover\ta\tup\t0\trefuse\n' >> quality/checks.tsv
    write_baseline quality/baseline.tsv coverage 80 -
    git add -A && git commit -qm base
    sha="$(git rev-parse HEAD)"
    write_baseline quality/baseline.tsv coverage 70 'agreed: the suite lost a package'
    run guard_baseline_diff quality/baseline.tsv refs/heads/release/1.0 "$sha" quality/checks.tsv
    [ "$status" -eq 0 ]
}

@test "all-zeroes remote sha skips and returns 0" {
    init_repo "$WORK/repo"
    write_baseline quality/baseline.tsv coverage 80 -
    printf '%s\n' "$GUARD_CHECKS_HEADER" > quality/checks.tsv
    run guard_baseline_diff quality/baseline.tsv refs/heads/release/1.0 \
        0000000000000000000000000000000000000000 quality/checks.tsv
    [ "$status" -eq 0 ]
    [[ "$output" == *'skipped'* ]]
}

@test "accept writes a reason and bare accept refuses without one" {
    init_repo "$WORK/repo"
    printf '%s\n' "$GUARD_CHECKS_HEADER" > quality/checks.tsv
    write_baseline quality/baseline.tsv coverage 80 -
    before="$(cat quality/baseline.tsv)"
    run bash /code/bin/guard.sh accept coverage
    [ "$status" -eq 2 ]
    [ "$(cat quality/baseline.tsv)" = "$before" ]
    run bash /code/bin/guard.sh accept coverage --reason 'agreed 2026-09-15'
    [ "$status" -eq 0 ]
    grep -q 'agreed 2026-09-15' quality/baseline.tsv
    [ "$(guard_accept_count quality/baseline.tsv)" -eq 1 ]
}

# --- SC-7: the gate measures the pushed commit, not the working tree ---------

@test "uncommitted edit does not change the measured value" {
    init_repo "$WORK/repo"
    printf 'one\ntwo\nthree\n' > data.txt
    printf '%s\n' "$GUARD_CHECKS_HEADER" > quality/checks.tsv
    printf 'lines\tboth\tdiff\twc -l < data.txt\t-\t-\tdown\t1000\trefuse\n' >> quality/checks.tsv
    git add -A && git commit -qm base
    printf 'four\nfive\nsix\nseven\neight\n' >> data.txt
    [ "$(wc -l < data.txt)" -eq 8 ]

    export GUARD_SHA="$(git rev-parse HEAD)"
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    grep -qE '^\| lines \| 3 \|' quality-reports/REPORT.md
}

# --- consumer: the {{files}} substitution ------------------------------------

@test "files substitution keeps a path containing a space whole" {
    printf 'app/A.php\0app/B C.php\0' > "$WORK/files"
    cmd="$(guard_substitute '{{files}} | xargs -0 -n1 echo PATH=' HEAD "$WORK/files")"
    run bash -c "$cmd"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '^PATH=')" -eq 2 ]
    [[ "$output" == *'PATH= app/B C.php'* ]]
}

# --- SC-5: the tolerance comparison is load-bearing --------------------------

@test "planted removal of the tolerance comparison turns the suite red" {
    cp /code/lib/guard-metrics.sh "$WORK/planted.sh"
    sed -i 's/BEGIN { print r + t }/BEGIN { print r }/' "$WORK/planted.sh"
    run grep -c 'print r + t' "$WORK/planted.sh"
    [ "$status" -ne 0 ]

    write_baseline "$WORK/baseline.tsv" coverage 100 -
    # The same input "delta equal to threshold passes" asserts is clean.
    run bash -c ". '$WORK/planted.sh'; guard_compare coverage repo 105 down 5 refuse '$WORK/baseline.tsv'"
    [ "$status" -eq 1 ]
}
