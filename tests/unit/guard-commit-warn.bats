#!/usr/bin/env bats
# lib/guard-commit.sh — a `warn` row prints its hits and never changes the exit status.

load guard-helpers

# Each row counts the checkstyle errors of a staged report that sit on added lines.
WARN_ROW=$'lint-warn-new\tcommit\tdiff\t"{{guard}}/guard-added-lines.sh" --checkstyle "{{tree}}/reports/warn.xml" --bases "{{bases}}" --target "{{target}}"\t-\t{{tree}}/reports/warn.xml\tdown\t0\twarn'
REFUSE_ROW=$'lint-refuse-new\tcommit\tdiff\t"{{guard}}/guard-added-lines.sh" --checkstyle "{{tree}}/reports/refuse.xml" --bases "{{bases}}" --target "{{target}}"\t-\t{{tree}}/reports/refuse.xml\tdown\t0\trefuse'
WARN_HEADING='vault-guard: warnings (the commit goes through)'
WARN_LINE='lint-warn-new lib/a.dart:2 avoid_print Avoid print. → quality/RULES.md "### debug-print"'
REFUSE_LINE='lint-refuse-new lib/a.dart:3 compile_error Expected ";". → quality/RULES.md "### compile-error"'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON
    new_repo "$WORK/repo"
    write_checks "$WARN_ROW" "$REFUSE_ROW"
    write_rules $'debug-print\tcore\tavoid_print\tavoid_print' $'compile-error\tcore\tcompile_error\tcompile_error'
    mkdir -p lib reports
    printf 'legacy one\nlegacy two\nlegacy three\n' > lib/a.dart
    report reports/warn.xml
    report reports/refuse.xml
    commit_all init
    # Every commit below adds lines 2 and 3 of lib/a.dart.
    printf 'legacy one\nnew two\nnew three\nlegacy two\nlegacy three\n' > lib/a.dart
    git add lib/a.dart
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# report <path> [<line> <source> <message>]... — a checkstyle report on lib/a.dart.
report() {
    local out="$1"; shift
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<checkstyle version="8.0">\n<file name="lib/a.dart">\n'
        while [ $# -ge 3 ]; do
            printf ' <error line="%s" column="1" severity="error" message="%s" source="%s"/>\n' "$1" "$3" "$2"
            shift 3
        done
        printf '</file>\n</checkstyle>\n'
    } > "$out"
}

@test "a warn row with a hit prints it under the warnings heading and the commit passes" {
    report reports/warn.xml 2 avoid_print 'Avoid print.' 5 avoid_print 'Legacy print.'
    git add reports
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    [[ "$output" == *"${WARN_HEADING}"$'\n\n'"${WARN_LINE}"* ]]
    [[ "$output" != *'Legacy print.'* ]]
    [[ "$output" != *'refused'* ]]
}

@test "a warn row with no hit on an added line prints nothing" {
    report reports/warn.xml 5 avoid_print 'Legacy print.'
    git add reports
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    [[ "$output" != *'vault-guard: warnings'* ]]
}

@test "a refuse row still prints under the refusal; warn hits print beside it and the exit stays 1" {
    report reports/warn.xml 2 avoid_print 'Avoid print.'
    report reports/refuse.xml 3 compile_error 'Expected &quot;;&quot;.'
    git add reports
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'vault-guard: the staged commit was refused'* ]]
    [[ "$output" == *"${REFUSE_LINE}"* ]]
    [[ "$output" == *'vault-guard: warnings (these alone would not refuse the commit)'$'\n\n'"${WARN_LINE}"* ]]
    [[ "$output" != *"${WARN_HEADING}"* ]]
    # The refusal names only the refused row; the warning names only the warn row.
    refusal="${output#*refused}"
    [[ "$refusal" != *'lint-warn-new'* ]]
}

@test "a refuse row alone prints no warnings heading" {
    report reports/refuse.xml 3 compile_error 'Expected &quot;;&quot;.'
    git add reports
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *"${REFUSE_LINE}"* ]]
    [[ "$output" != *'vault-guard: warnings'* ]]
}
