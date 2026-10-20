#!/usr/bin/env bats
# checks/_qg-cases.sh: qg_cases reads the TAP output of a suite and passes only when every named
# case is reported `ok` with no directive. A copy of checks/ beside a fake tests/run.sh, which
# prints canned TAP text, stands in for the Docker run.

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    mkdir -p "$WORK/checks" "$WORK/tests/unit"
    cp /code/checks/_qg-cases.sh "$WORK/checks/"
    : > "$WORK/tests/unit/fake.bats"
    printf '#!/usr/bin/env bash\ncat "$(dirname "$0")/tap.txt"\n' > "$WORK/tests/run.sh"
    chmod +x "$WORK/tests/run.sh"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# tap <line>... — the fake suite's output.
tap() { printf '%s\n' '1..2' "$@" > "$WORK/tests/tap.txt"; }

# cases <case>... — runs qg_cases on fake.bats from the copy.
cases() { bash -c '. "$1/checks/_qg-cases.sh"; shift; qg_cases fake.bats "$@"' _ "$WORK" "$@"; }

# The backlog names this case "... ok with # skip or # TODO ...". A TAP line holding `# skip` is
# itself a skip directive, so the name spells the directives without the hash.
@test "a named case reported ok with a skip or TODO directive counts as FAILING and exits 1" {
    tap 'ok 1 the first case # skip not written yet' 'ok 2 the second case'
    run cases 'the first case' 'the second case'
    [ "$status" -eq 1 ]
    [[ "$output" == *'FAILING  fake.bats: the first case'* ]]
    tap 'ok 1 the first case # TODO later' 'ok 2 the second case'
    run cases 'the first case'
    [ "$status" -eq 1 ]
    [[ "$output" == *'FAILING  fake.bats: the first case'* ]]
    tap 'ok 1 the first case # SKIP upper case' 'ok 2 the second case'
    run cases 'the first case'
    [ "$status" -eq 1 ]
}

@test "a named case reported ok without a directive passes and exits 0" {
    tap 'ok 1 the first case' 'ok 2 the second case # skip unrelated'
    run cases 'the first case'
    [ "$status" -eq 0 ]
    [[ "$output" == *'1 of 1 cases passing'* ]]
}

@test "a named case missing from the output is ABSENT and exits 1" {
    tap 'ok 1 the first case' 'ok 2 the second case'
    run cases 'the first case' 'a case nobody wrote'
    [ "$status" -eq 1 ]
    [[ "$output" == *'ABSENT   fake.bats: a case nobody wrote'* ]]
}

@test "a named case reported not ok is FAILING and exits 1" {
    tap 'not ok 1 the first case' '# (in test file fake.bats, line 3)' 'ok 2 the second case'
    run cases 'the first case' 'the second case'
    [ "$status" -eq 1 ]
    [[ "$output" == *'FAILING  fake.bats: the first case'* ]]
    [[ "$output" == *'1 of 2 cases failing or absent'* ]]
}
