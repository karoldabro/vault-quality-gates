#!/usr/bin/env bats
# drivers/mutation-test.sh — metric = 100 minus the undetected percent mutation_test prints, two
# decimals; exits 0 and 255 measure, any other exit, a missing summary line or 0 mutations is an error.
#
# The test image has no Dart: a fake SDK under $WORK/sdk is named by guard_flutter_root in the
# committed quality/config and its bin/ is first on PATH. `dart pub get` is recorded and succeeds.
# `dart run mutation_test` runs through qg_tool and qg_sandbox_run with an emptied environment, so
# the fake reads its setup from files under $WORK baked into it: out (printed) and rc (its exit code). It appends its
# argv to dart.argv and dumps its env to dart.env. The summary follows mutation_test 1.8.0
# lib/src/reports/command_line_report.dart, with the percent from asPercentString (two decimals).

load guard-helpers

DRIVER=/code/drivers/mutation-test.sh

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR QG_BASES CLAUDECODE AI_AGENT PUB_CACHE XDG_CACHE_HOME FLUTTER_ROOT
    fake_sdk "$WORK/sdk"
    export PATH="$WORK/sdk/bin:$PATH"
    new_repo "$WORK/repo"
    mkdir -p quality lib test
    printf 'guard_flutter_root: %s\n' "$WORK/sdk" > quality/config
    printf '<mutations/>\n' > quality/mutation.xml
    printf 'name: app\n' > pubspec.yaml
    printf 'int a() => 1;\n' > lib/a.dart
    commit_all init
    mkdir -p "$WORK/out"
    export QG_REPO="$WORK/repo" QG_TREE="$WORK/repo" QG_TARGET=:index QG_CONFIG_REV="$(git rev-parse HEAD)"
    export QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=mutation-row QG_FILES=/dev/null
    report 9 3 33.33 > "$WORK/out.txt"
    printf '255\n' > "$WORK/rc"
    # Cases run unsandboxed so the fake can record; the sandbox case below runs it.
    export QG_SANDBOX=0
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

fake_sdk() {
    mkdir -p "$1/bin/cache/dart-sdk/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$1/bin/flutter"
    { printf '#!/usr/bin/env bash\nW=%q\n' "$WORK"; cat <<'EOF'
if [ "${1:-}" = pub ]; then printf '%s\n' "$*" >> "$W/pub.argv"; exit 0; fi
printf '%s\n' "$*" >> "$W/dart.argv"
env > "$W/dart.env"
[ -r "$W/out.txt" ] && cat "$W/out.txt"
exit "$(cat "$W/rc" 2>/dev/null || printf 0)"
EOF
    } > "$1/bin/cache/dart-sdk/bin/dart"
    chmod +x "$1/bin/flutter" "$1/bin/cache/dart-sdk/bin/dart"
}

report() {  # report <total> <undetected> <percent> — mutation_test's command-line summary
    printf '\rlib/a.dart: %s/%s (%s%%) mutations were not detected!\n' "$2" "$1" "$3"
    printf '  --- Results ---\nTest group statistics:\n  Group : default, Found mutations: %s\n' "$(( $1 - $2 ))"
    printf '\nTotal tests: %s\nUndetected Mutations: %s (%s%%)\n' "$1" "$2" "$3"
    printf 'Timeouts: 0\nNot covered by tests: 0\nElapsed: 0:00:01.000000\nSuccess: false, Quality rating: B\n'
}

result() { jq -r "$1" "$QG_OUT/result.json"; }
measure() { QG_ARGS="$1" "$DRIVER" run > /dev/null 2>&1; }

@test "describe is JSON naming mutation-test with needs_tree true; explain names the keys" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = mutation-test ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [[ "$output" == *'rules (required)'* ]]
}

@test "a missing rules= is status error and dart is never called" {
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'rules='* ]]
    [ ! -e "$WORK/dart.argv" ]
    [ ! -e "$WORK/pub.argv" ]
}

@test "dart gets run mutation_test --rules <rules> lib, after an offline pub get" {
    measure rules=quality/mutation.xml
    [ "$(cat "$WORK/pub.argv")" = 'pub get --offline --enforce-lockfile' ]
    [ "$(cat "$WORK/dart.argv")" = 'run mutation_test --rules quality/mutation.xml lib' ]
}

@test "builtin=yes adds -b and paths= replaces lib with each listed path" {
    measure 'rules=quality/mutation.xml builtin=yes paths=lib/a.dart,lib/b'
    [ "$(cat "$WORK/dart.argv")" = 'run mutation_test --rules quality/mutation.xml -b lib/a.dart lib/b' ]
    rm -f "$WORK/dart.argv"
    measure 'rules=quality/mutation.xml builtin=no'
    [ "$(cat "$WORK/dart.argv")" = 'run mutation_test --rules quality/mutation.xml lib' ]
}

@test "3 of 9 undetected (33.33%) at exit 255 measures 66.67 percent" {
    measure rules=quality/mutation.xml
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 66.67 ]
    [ "$(result .unit)" = percent ]
}

@test "percent boundaries: 0.00% at exit 0 is 100.00, 100.00% is 0.00, 33.333% is 66.67" {
    local c
    for c in '9 0 0.00 0 100.00' '9 9 100.00 255 0.00' '3000 1000 33.333 255 66.67'; do
        set -- $c
        report "$1" "$2" "$3" > "$WORK/out.txt"; printf '%s\n' "$4" > "$WORK/rc"
        rm -f "$QG_OUT/result.json"
        measure rules=quality/mutation.xml
        [ "$(result .status)" = measured ] || { echo "not measured for $c"; return 1; }
        [ "$(result .metric)" = "$5" ] || { echo "$c gave $(result .metric)"; return 1; }
    done
}

@test "exits 1 and 2 are status error even with a summary line" {
    local rc
    for rc in 1 2; do
        printf '%s\n' "$rc" > "$WORK/rc"
        rm -f "$QG_OUT/result.json"
        measure rules=quality/mutation.xml
        [ "$(result .status)" = error ] || { echo "exit $rc measured"; return 1; }
        [ "$(result .metric)" = null ]
        [[ "$(result .error)" == *"exited ${rc}"* ]]
    done
}

@test "no Undetected Mutations line is status error, never a measured 100" {
    printf 'Could not find test command\n' > "$WORK/out.txt"; printf '0\n' > "$WORK/rc"
    measure rules=quality/mutation.xml
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'no Undetected Mutations line'* ]]
}

@test "Total tests: 0 is status error: no mutation was generated" {
    report 0 0 0.00 > "$WORK/out.txt"; printf '0\n' > "$WORK/rc"
    measure rules=quality/mutation.xml
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'generated no mutation'* ]]
}

@test "a summary with no Total tests line is status error" {
    report 9 3 33.33 | grep -v '^Total tests' > "$WORK/out.txt"
    measure rules=quality/mutation.xml
    [ "$(result .status)" = error ]
}

@test "with two summaries in the output the last one is measured" {
    { report 9 9 100.00; report 4 1 25.00; } > "$WORK/out.txt"
    measure rules=quality/mutation.xml
    [ "$(result .metric)" = 75.00 ]
}

@test "mutation-test measures through the real kit path under the sandbox" {
    unset QG_SANDBOX
    export QG_SANDBOX_WRITES="$("$DRIVER" describe | jq -r '.writes | join(" ")')"
    # The fake also mutates lib/a.dart, as mutation_test does, and tries a write outside the tree.
    { printf '#!/usr/bin/env bash\nW=%q\n' "$WORK"; cat <<'EOF'
if [ "${1:-}" = pub ]; then printf '%s\n' "$*" >> "$W/pub.argv"; exit 0; fi
printf '%s\n' "$*" >> "$W/dart.argv" 2>/dev/null
echo 'int a() => 2;' > lib/a.dart
echo x > "$W/escaped" 2>/dev/null
cat "$W/out.txt"
exit "$(cat "$W/rc")"
EOF
    } > "$WORK/sdk/bin/cache/dart-sdk/bin/dart"
    measure rules=quality/mutation.xml
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 66.67 ]
    [ "$(cat lib/a.dart)" = 'int a() => 2;' ]
    [ ! -e "$WORK/escaped" ] && [ ! -e "$WORK/dart.argv" ]
}

@test "the mutated suite sees no GUARD_* or other QG_* variable and a private TMPDIR outside the tree that is removed" {
    export GUARD_PROBE=1 QG_PROBE=1 PUB_CACHE="$WORK/pub"
    measure rules=quality/mutation.xml
    [ "$(result .status)" = measured ]
    [ -z "$(grep -E '^(QG_PROBE|QG_SANDBOX|GUARD_)' "$WORK/dart.env")" ]
    grep -qx "PUB_CACHE=$HOME/.pub-cache" "$WORK/dart.env"
    local tmp
    tmp="$(sed -n 's/^TMPDIR=//p' "$WORK/dart.env")"
    [ -n "$tmp" ]
    [[ "$tmp" != "$QG_TREE"* ]]
    [ ! -e "$tmp" ]
}

@test "a guard_flutter_root missing from quality/config is status error and dart is never called" {
    printf 'other: 1\n' > quality/config; commit_all 'drop root'
    QG_CONFIG_REV="$(git rev-parse HEAD)" measure rules=quality/mutation.xml
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'guard_flutter_root'* ]]
    [ ! -e "$WORK/dart.argv" ]
    [ ! -e "$WORK/pub.argv" ]
}
