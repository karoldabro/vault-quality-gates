#!/usr/bin/env bats
# Driver findings reach the person refused: the push refusal and `qg explain` print them through
# bin/guard-report-errors.sh, at most 10 per row then `<id> +N more`. A malformed rules.tsv never
# hides the refusal, and a repo with no rules.tsv prints findings without pointers.

load guard-helpers

V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT GUARD_CONFIG_REV GUARD_SKIP
    gate_repo "$WORK/repo"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# finder_driver <findings> — quality/drivers/finder.sh measuring <findings> findings, each with a
# file, a line, a rule and a message.
finder_driver() {
    mkdir -p quality/drivers
    { printf '#!/usr/bin/env bash\n'
      printf 'case "$1" in describe) echo "{\\"name\\":\\"finder\\",\\"requires\\":[],\\"needs_tree\\":false}";;\n'
      printf '  explain) echo "finds things";;\n'
      printf '  run) jq -n --argjson n %s %s > "$QG_OUT/result.json";;\n' "$1" \
          "'{schema:\"qg.result/1\",driver:\"finder\",status:\"measured\",metric:\$n,unit:\"findings\",findings:[range(\$n)|{ruleId:\"r.x\",file:\"app/f\\(.).php\",line:(.+1),level:\"error\",message:\"finding \\(.)\",doc:null}],error:null,reproduce:null}'"
      printf '  *) exit 2;; esac\n'
    } > quality/drivers/finder.sh
    chmod +x quality/drivers/finder.sh
}

push_checks() {
    { printf '%s\n' "$V2_HEADER"
      printf 'found\tpush\tdiff\tfinder\t-\tdown\t0\trefuse\tthe finder finds nothing on a pushed commit\n'
    } > quality/checks.tsv
}

push() { GUARD_SHA="$(git rev-parse HEAD)" run bash /code/bin/guard.sh release refs/heads/feature/x; }

@test "a push refused by a driver row prints its findings as <id> <file>:<line> <rule> <message>" {
    finder_driver 2; push_checks; commit_all finder
    push
    [ "$status" -eq 1 ]
    [[ "$output" == *'found app/f0.php:1 r.x finding 0'* ]]
    [[ "$output" == *'found app/f1.php:2 r.x finding 1'* ]]
}

@test "13 findings print 10, then '<id> +3 more (qg explain <id>)'" {
    finder_driver 13; push_checks; commit_all finder
    push
    [ "$status" -eq 1 ]
    [ "$(grep -c '^found app/' <<<"$output")" -eq 10 ]
    [[ "$output" == *'found +3 more (qg explain found)'* ]]
    [[ "$output" != *'finding 10'* ]]
}

@test "two rows of 11 findings each cap at 10, and each '+1 more' line follows its own row" {
    finder_driver 11; push_checks
    printf 'again\tpush\tdiff\tfinder\t-\tdown\t0\trefuse\ta second row with the same findings\n' >> quality/checks.tsv
    commit_all two
    push
    [ "$status" -eq 1 ]
    local lines; lines="$(grep -E '^(found|again) ' <<<"$output")"
    [ "$(grep -c '^found app/' <<<"$lines")" -eq 10 ] && [ "$(grep -c '^again app/' <<<"$lines")" -eq 10 ]
    # The line after a row's last finding is its own overflow line.
    [ "$(grep -A1 '^found app/f9.php' <<<"$lines" | tail -1)" = 'found +1 more (qg explain found)' ]
    [ "$(grep -A1 '^again app/f9.php' <<<"$lines" | tail -1)" = 'again +1 more (qg explain again)' ]
}

@test "a malformed quality/rules.tsv still prints the refusal and says the catalog is unreadable" {
    finder_driver 1; push_checks
    printf 'not the header\n' > quality/rules.tsv
    commit_all finder
    push
    [ "$status" -eq 1 ]
    [[ "$output" == *'push refused'* ]]
    [[ "$output" == *'quality/rules.tsv is unreadable'* ]]
    [[ "$output" == *'How to pass'* ]]
}

@test "a repo with no quality/rules.tsv prints findings without pointers" {
    finder_driver 1; push_checks
    git rm -q quality/rules.tsv
    commit_all finder
    push
    [ "$status" -eq 1 ]
    [[ "$output" == *'found app/f0.php:1 r.x finding 0'* ]]
    [[ "$output" != *'unreadable'* ]]
}

@test "qg explain prints a driver row's last findings through the printer, 10 then +N more" {
    finder_driver 12; push_checks; commit_all finder
    push
    run bash /code/bin/qg explain found
    [ "$status" -eq 0 ]
    [ "$(grep -c '^  found app/' <<<"$output")" -eq 10 ]
    [[ "$output" == *'found +2 more (qg explain found)'* ]]
}

@test "guard-report-errors --limit with 0 and exactly 10 findings prints no '+N more' line" {
    finder_driver 10; push_checks; commit_all finder
    push
    [ "$(grep -c '^found app/' <<<"$output")" -eq 10 ]
    [[ "$output" != *'more (qg explain'* ]]
    finder_driver 0; commit_all none
    push
    [ "$status" -eq 0 ]
}
