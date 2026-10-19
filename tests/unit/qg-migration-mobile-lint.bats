#!/usr/bin/env bats
# migrations/recycling_mobile_app/commit-lint.sh, the runner the lint rows call as `<runner> <tree>
# <cache>`: it reads the changed paths from $QG_FILES, takes the SDK from guard_flutter_root at the
# config revision, ignores the caller's package cache, and refuses what would let a commit choose its
# lint rules. Each case stops before the analyzer runs, so the fake SDK of qg-dart-helpers suffices.

load guard-helpers
load qg-dart-helpers

LINT=/code/migrations/recycling_mobile_app/commit-lint.sh

setup() {
    dart_setup
    unset GUARD_SKIP
    mkdir -p "$TREE/lib" "$TREE/tool/givore_lints/bin"
    printf 'void main() {}\n' > "$TREE/lib/a.dart"
    : > "$TREE/tool/givore_lints/bin/gate.dart"
    printf 'include: package:flutter_lints/flutter.yaml\n' > "$TREE/analysis_options.yaml"
    printf 'include: analysis_options.base.yaml\n' > "$TREE/analysis_options.commit.yaml"
    : > "$TREE/many_lints.yaml"; : > "$TREE/pubspec.lock"
    mkdir -p "$TREE/quality"; : > "$TREE/quality/rules.tsv"
    printf 'lib/a.dart\0' > "$WORK/files"
    export QG_FILES="$WORK/files"
    cd "$REPO"
}

teardown() { dart_teardown; }

lint() { "$LINT" "$TREE" "$WORK/cache" < "${1:-/dev/null}"; }

@test "the changed paths come from QG_FILES, never stdin: no Dart file there writes empty reports and runs nothing" {
    : > "$WORK/files"
    printf 'lib/a.dart\0' > "$WORK/stdin"
    run lint "$WORK/stdin"
    [ "$status" -eq 0 ]
    grep -q '<checkstyle' "$TREE/quality-reports/commit-lint-refuse.xml"
    ! grep -q '<error' "$TREE/quality-reports/commit-lint-refuse.xml"
    [ ! -s "$CALLS" ]
}

@test "without guard_flutter_root at the config revision it fails at step 2 and no SDK runs" {
    printf 'guard_protected_paths: quality\n' > quality/config
    commit_all no-root
    export QG_CONFIG_REV; QG_CONFIG_REV="$(git rev-parse HEAD)"
    run lint
    [ "$status" -eq 2 ]
    [[ "$output" == *'step 2 (sdk)'*'guard_flutter_root is not set'* ]]
    [ ! -s "$CALLS" ]
}

@test "the key is read at QG_CONFIG_REV: an uncommitted edit naming another SDK changes nothing" {
    printf 'guard_flutter_root: /nonexistent\n' > quality/config
    printf 'void main() {}\n' > "$TREE/lib/a.dart"
    run lint
    [[ "$output" != *'nonexistent'* ]]
    grep -q 'pub get' "$CALLS"
}

@test "a flutter on PATH that is not the pinned SDK fails at step 2, naming both" {
    mkdir -p "$WORK/planted"
    printf '#!/usr/bin/env bash\necho planted >> "%s/planted.log"\n' "$WORK" > "$WORK/planted/flutter"
    chmod +x "$WORK/planted/flutter"
    PATH="$WORK/planted:$PATH" run lint
    [ "$status" -eq 2 ]
    [[ "$output" == *"flutter on PATH is $WORK/planted/flutter"* ]]
    [ ! -e "$WORK/planted.log" ]
    [ ! -s "$CALLS" ]
}

@test "a pubspec_overrides.yaml in the tree fails at step 2 before pub get" {
    : > "$TREE/pubspec_overrides.yaml"
    run lint
    [ "$status" -eq 2 ]
    [[ "$output" == *'pubspec_overrides.yaml is in the tree'* ]]
    ! grep -q 'pub get' "$CALLS"
}

@test "both pub gets run offline with --enforce-lockfile inside the tree, without the caller's PUB_CACHE or XDG_CACHE_HOME" {
    PUB_CACHE="$WORK/planted-cache" XDG_CACHE_HOME="$WORK/planted-xdg" run lint
    # Step 4 resolves the tree, step 6 the runner package inside it; the fake keeps the last cwd.
    [ "$(grep -cx 'dart pub get --offline --enforce-lockfile' "$CALLS")" -eq 2 ]
    [ "$(cat "$PUB_CWD")" = "$TREE/tool/givore_lints" ]
    ! grep -q '^PUB_CACHE=' "$PUB_ENV"
    ! grep -q '^XDG_CACHE_HOME=' "$PUB_ENV"
}

@test "a failing offline pub get fails at step 4 naming the fix, and leaves no report" {
    FAKE_PUB_RC=65 FAKE_PUB_OUT='Unable to satisfy pubspec.yaml using pubspec.lock' run lint
    [ "$status" -eq 2 ]
    [[ "$output" == *'step 4'*'Unable to satisfy'*'run flutter pub get'* ]]
    [ ! -e "$TREE/quality-reports/commit-lint-refuse.xml" ]
}

@test "an analysis_options.base.yaml staged in the index fails at step 5: it would replace the rules" {
    printf 'linter: {rules: {}}\n' > analysis_options.base.yaml
    git add analysis_options.base.yaml
    cp analysis_options.base.yaml "$TREE/analysis_options.base.yaml"
    run lint
    [ "$status" -eq 2 ]
    [[ "$output" == *'step 5 (options)'*'analysis_options.base.yaml is committed'* ]]
    # Unstaged, the same file is this script's own rename target and step 5 passes.
    git rm -q --cached analysis_options.base.yaml
    rm -f "$TREE/analysis_options.base.yaml"
    run lint
    [[ "$output" != *'step 5 (options)'* ]]
}
