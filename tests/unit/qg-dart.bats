#!/usr/bin/env bats
# lib/qg-dart.sh — qg_dart_config_key, qg_dart_env, qg_dart_packages, qg_dart_prepare and qg_isolated.
# The functions are sourced into the test shell; driver-level cases run drivers/lakos.sh, the
# smallest driver that calls qg_dart_prepare. The fake SDK and repo come from qg-dart-helpers.

load guard-helpers
load qg-dart-helpers

ROOT=/code
FIX=/code/tests/fixtures/drivers/dart

setup() {
    dart_setup
    # shellcheck source=/dev/null
    . "$ROOT/lib/qg-driver-kit.sh"
    # shellcheck source=/dev/null
    . "$ROOT/lib/qg-dart.sh"
}

teardown() { dart_teardown; }

commit_config() {  # commit_config <quality/config text> -> QG_CONFIG_REV is the new commit
    printf '%s' "$1" > "$REPO/quality/config"
    ( cd "$REPO" && commit_all "config $RANDOM" )
    QG_CONFIG_REV="$(git -C "$REPO" rev-parse HEAD)"
}

@test "qg_dart_config_key reads guard_flutter_root at QG_CONFIG_REV, never the working tree or the index" {
    printf 'guard_flutter_root: /staged\n' > "$REPO/quality/config"
    git -C "$REPO" add quality/config
    printf 'guard_flutter_root: /worktree\n' > "$REPO/quality/config"
    run qg_dart_config_key guard_flutter_root
    [ "$status" -eq 0 ]
    [ "$output" = "$SDK" ]
}

@test "qg_dart_config_key with an empty QG_CONFIG_REV reads the index, as on a first commit" {
    new_repo "$WORK/first"
    mkdir -p quality
    printf 'guard_flutter_root: /from-index\n' > quality/config
    git add quality/config
    printf 'guard_flutter_root: /from-worktree\n' > quality/config
    QG_REPO="$WORK/first" QG_CONFIG_REV='' run qg_dart_config_key guard_flutter_root
    [ "$status" -eq 0 ]
    [ "$output" = /from-index ]
}

@test "qg_dart_env without guard_flutter_root is an error naming the key, and no tool path is set" {
    commit_config $'other_key: x\n'
    QG_DART='' QG_FLUTTER=''
    run qg_dart_env
    [ "$status" -eq 1 ]
    qg_dart_env || true
    [[ "$QG_ERROR" == *'guard_flutter_root is not set'* ]]
    [ -z "$QG_DART" ]
}

@test "qg_dart_env with an empty guard_flutter_root is an error naming the key" {
    commit_config $'guard_flutter_root:   \n'
    qg_dart_env && return 1
    [[ "$QG_ERROR" == *'guard_flutter_root is not set'* ]]
}

@test "qg_dart_env on a folder without bin/cache/dart-sdk/bin/dart, or with it not executable, is not a Flutter SDK" {
    chmod -x "$SDK/bin/cache/dart-sdk/bin/dart"
    qg_dart_env && return 1
    [[ "$QG_ERROR" == *"guard_flutter_root ${SDK} is not a Flutter SDK"* ]]
    rm "$SDK/bin/cache/dart-sdk/bin/dart"
    qg_dart_env && return 1
    [[ "$QG_ERROR" == *'is not a Flutter SDK'* ]]
}

@test "qg_dart_env on a folder without bin/flutter is not a Flutter SDK" {
    rm "$SDK/bin/flutter"
    PATH="${PATH#"$SDK/bin:"}"
    qg_dart_env && return 1
    [[ "$QG_ERROR" == *'is not a Flutter SDK'* ]]
}

@test "qg_dart_env pins QG_FLUTTER and QG_DART by absolute path, exports FLUTTER_ROOT and drops PUB_CACHE and XDG_CACHE_HOME" {
    export PUB_CACHE="$WORK/caller-pub" XDG_CACHE_HOME="$WORK/caller-xdg" FLUTTER_ROOT="$WORK/caller-flutter"
    qg_dart_env
    # QG_FLUTTER is the private shim: first on PATH, outside the tree, running the SDK's own dart.
    [[ "$QG_FLUTTER" == "$QG_CACHE"/qg-flutter-*/flutter ]] && [ -x "$QG_FLUTTER" ]
    [ "$(command -v flutter)" = "$QG_FLUTTER" ]
    grep -qF "$SDK/bin/cache/flutter_tools.snapshot" "$QG_FLUTTER"
    [ "$QG_DART" = "$SDK/bin/cache/dart-sdk/bin/dart" ]
    [ "$FLUTTER_ROOT" = "$SDK" ]
    [ "$(bash -c 'printf %s "$FLUTTER_ROOT|$QG_SANDBOX_SDK"')" = "$SDK|$SDK" ]
    [ -z "${PUB_CACHE+set}" ]
    [ -z "${XDG_CACHE_HOME+set}" ]
    [ -z "$QG_ERROR" ]
}

@test "qg_dart_env with no flutter on PATH runs the pinned SDK" {
    PATH="${PATH#"$SDK/bin:"}"
    ! command -v flutter || return 1
    qg_dart_env
    [ "$QG_DART" = "$SDK/bin/cache/dart-sdk/bin/dart" ]
}

@test "qg_dart_env refuses a flutter on PATH that is another file, naming both" {
    mkdir -p "$WORK/planted"
    printf '%s\n' '#!/usr/bin/env bash' "touch '$WORK/planted-ran'" > "$WORK/planted/flutter"
    chmod +x "$WORK/planted/flutter"
    PATH="$WORK/planted:$PATH"
    qg_dart_env && return 1
    [[ "$QG_ERROR" == *"flutter on PATH is $WORK/planted/flutter, not $SDK/bin/flutter"* ]]
    [ ! -e "$WORK/planted-ran" ]
}

@test "qg_dart_env accepts a symlink on PATH that resolves to the pinned flutter" {
    mkdir -p "$WORK/links"
    ln -s "$SDK/bin/flutter" "$WORK/links/flutter"
    PATH="$WORK/links:${PATH#"$SDK/bin:"}"
    qg_dart_env
    [ -z "$QG_ERROR" ]
}

@test "qg_dart_env refuses runner=, because a Dart driver runs the pinned SDK itself" {
    QG_RUNNER="$WORK/runner"
    qg_dart_env && return 1
    [[ "$QG_ERROR" == *'runner= is not allowed'* ]]
}

@test "a planted earlier flutter on PATH makes a Dart driver status error, and neither it nor the pinned dart runs" {
    mkdir -p "$WORK/planted"
    printf '%s\n' '#!/usr/bin/env bash' "touch '$WORK/planted-ran'" > "$WORK/planted/flutter"
    chmod +x "$WORK/planted/flutter"
    cp "$WORK/planted/flutter" "$WORK/planted/dart"
    PATH="$WORK/planted:$PATH" run "$ROOT/drivers/lakos.sh" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'flutter on PATH is'* ]]
    [ ! -e "$WORK/planted-ran" ]
    [ ! -e "$CALLS" ]
}

@test "qg_dart_packages refuses a pubspec_overrides.yaml in the tree before pub get runs" {
    qg_dart_env
    : > "$TREE/pubspec_overrides.yaml"
    qg_dart_packages && return 1
    [[ "$QG_ERROR" == *'pubspec_overrides.yaml is in the measured tree'* ]]
    [ "$(calls_of 'pub get')" = 0 ]
}

@test "qg_dart_packages under :index refuses a .dart_tool path staged in the index, before pub get" {
    qg_dart_env
    mkdir -p "$REPO/.dart_tool"; printf '{}\n' > "$REPO/.dart_tool/package_config.json"
    git -C "$REPO" add -f .dart_tool/package_config.json
    QG_TARGET=:index
    qg_dart_packages && return 1
    [[ "$QG_ERROR" == *'.dart_tool/package_config.json is committed'* ]]
    [ "$(calls_of 'pub get')" = 0 ]
}

@test "qg_dart_packages with a commit QG_TARGET reads that commit's tree for .dart_tool, not the index" {
    qg_dart_env
    local clean
    clean="$(git -C "$REPO" rev-parse HEAD)"
    mkdir -p "$REPO/.dart_tool"; printf '{}\n' > "$REPO/.dart_tool/package_config.json"
    ( cd "$REPO" && git add -f .dart_tool/package_config.json && commit_all dart_tool )
    QG_TARGET="$(git -C "$REPO" rev-parse HEAD)"
    qg_dart_packages && return 1
    [[ "$QG_ERROR" == *'.dart_tool/package_config.json is committed'* ]]
    QG_TARGET="$clean"
    qg_dart_packages
    [ "$(calls_of 'pub get')" = 1 ]
}

@test "qg_dart_prepare runs dart pub get --offline --enforce-lockfile inside QG_TREE without the caller's PUB_CACHE, XDG_CACHE_HOME or FLUTTER_ROOT" {
    export PUB_CACHE="$WORK/caller-pub" XDG_CACHE_HOME="$WORK/caller-xdg" FLUTTER_ROOT="$WORK/caller-flutter"
    qg_dart_prepare lakos ratio
    [ "$(cat "$CALLS")" = 'dart pub get --offline --enforce-lockfile' ]
    [ "$(cat "$PUB_CWD")" = "$TREE" ]
    ! grep -q '^PUB_CACHE=' "$PUB_ENV" || return 1
    ! grep -q '^XDG_CACHE_HOME=' "$PUB_ENV" || return 1
    grep -qx "FLUTTER_ROOT=$SDK" "$PUB_ENV"
    [ ! -e "$QG_OUT/result.json" ]
}

@test "an offline pub get failure is an error naming the step, its last 5 lines and the fix" {
    qg_dart_env
    export FAKE_PUB_RC=69 FAKE_PUB_OUT=$'line-1\nline-2\nline-3\nline-4\nline-5\nline-6\nline-7'
    qg_dart_packages && return 1
    [[ "$QG_ERROR" == 'dart pub get --offline --enforce-lockfile failed: '* ]]
    [[ "$QG_ERROR" == *'line-3 line-4 line-5 line-6 line-7'* ]]
    [[ "$QG_ERROR" != *'line-2'* ]]
    [[ "$QG_ERROR" == *'run flutter pub get'* ]]
}

@test "qg_dart_prepare on a failed step writes status error with metric null and the reason" {
    export FAKE_PUB_RC=1 FAKE_PUB_OUT='Because givore depends on lakos 2.0.7 which is not in the cache'
    run qg_dart_prepare lakos ratio
    [ "$status" -eq 1 ]
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [ "$(result .driver)" = lakos ]
    [ "$(result .unit)" = ratio ]
    [[ "$(result .error)" == *'lakos 2.0.7 which is not in the cache'* ]]
}

@test "a Dart driver's tool runs without the caller's PUB_CACHE and XDG_CACHE_HOME, with FLUTTER_ROOT the pinned SDK" {
    export PUB_CACHE="$WORK/caller-pub" XDG_CACHE_HOME="$WORK/caller-xdg" FLUTTER_ROOT="$WORK/caller-flutter"
    export FAKE_OUT="$FIX/lakos.json"
    "$ROOT/drivers/lakos.sh" run > /dev/null
    [ "$(result .status)" = measured ]
    # The child's PUB_CACHE is always the real home's, never the caller's.
    grep -qx "PUB_CACHE=$HOME/.pub-cache" "$TOOL_ENV"
    ! grep -q '^XDG_CACHE_HOME=' "$TOOL_ENV" || return 1
    grep -qx "FLUTTER_ROOT=$SDK" "$TOOL_ENV"
}

@test "qg_isolated gives the tool only the sandbox child environment" {
    export SECRET_TOKEN=leak LANG=C.UTF-8
    qg_dart_env
    run qg_isolated env
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | cut -d= -f1 | grep -v '^QG_' | sort | tr '\n' ' ')" = \
        'FLUTTER_ALREADY_LOCKED FLUTTER_ROOT HOME LANG LC_ALL PATH PUB_CACHE TMPDIR ' ]
    [[ "$output" == *"FLUTTER_ROOT=$SDK"* ]]
    [[ "$output" != *"TMPDIR=$TREE"* ]]
}

@test "qg_isolated returns the tool's exit code" {
    run qg_isolated bash -c 'exit 7'
    [ "$status" -eq 7 ]
    run qg_isolated true
    [ "$status" -eq 0 ]
}

@test "qg_isolated kills the tool's process group, so a background child does not outlive the tool" {
    cat > "$WORK/tool" <<EOF
#!/usr/bin/env bash
sleep 300 &
printf '%s' "\$!" > '$WORK/child.pid'
exit 0
EOF
    chmod +x "$WORK/tool"
    qg_isolated "$WORK/tool"
    local pid state i
    pid="$(cat "$WORK/child.pid")"
    for i in $(seq 1 40); do
        state="$(awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || true)"
        [ -z "$state" ] || [ "$state" = Z ] && break
        sleep 0.05
    done
    kill -KILL "$pid" 2>/dev/null || true
    [ -z "$state" ] || [ "$state" = Z ]
}

# snapshot_sdk — the fake SDK gains the tool snapshot files, and its dart prints what it was asked
# to run, its lock and root variables, and whether it could write outside its grants.
snapshot_sdk() {
    mkdir -p "$SDK/packages/flutter_tools/.dart_tool"
    : > "$SDK/packages/flutter_tools/.dart_tool/package_config.json"; : > "$SDK/bin/cache/flutter_tools.snapshot"
    : > "$SDK/bin/cache/engine.stamp"
    { printf '#!/usr/bin/env bash\n'
      printf 'echo "argv: $*"\necho "locked=${FLUTTER_ALREADY_LOCKED-unset} root=${FLUTTER_ROOT-unset}"\n'
      printf 'echo x > %q 2>/dev/null && echo "escape written" || echo "escape refused"\n' "$WORK/escape"
      printf 'echo x >> "$FLUTTER_ROOT/bin/cache/engine.stamp" && echo "stamp written"\n'
    } > "$SDK/bin/cache/dart-sdk/bin/dart"
    printf '#!/usr/bin/env bash\necho "REAL BIN FLUTTER"\n' > "$SDK/bin/flutter"
}

@test "qg_isolated runs the SDK snapshot inside the sandbox with FLUTTER_ALREADY_LOCKED" {
    unset QG_SANDBOX
    snapshot_sdk
    qg_dart_env
    run qg_isolated "$QG_FLUTTER" test --machine
    [ "$status" -eq 0 ]
    [[ "$output" == *"argv: --disable-dart-dev --packages=$SDK/packages/flutter_tools/.dart_tool/package_config.json $SDK/bin/cache/flutter_tools.snapshot test --machine"* ]]
    [[ "$output" == *"locked=true root=$SDK"* ]]
    [[ "$output" == *'escape refused'* ]] && [[ "$output" == *'stamp written'* ]]
    [ ! -e "$WORK/escape" ]
}

@test "the private flutter shim on PATH runs the snapshot, never bin/flutter" {
    unset QG_SANDBOX
    snapshot_sdk
    qg_dart_env
    run qg_isolated sh -c 'flutter test'
    [ "$status" -eq 0 ]
    [[ "$output" == *"$SDK/bin/cache/flutter_tools.snapshot test"* ]]
    [[ "$output" != *'REAL BIN FLUTTER'* ]]
}
