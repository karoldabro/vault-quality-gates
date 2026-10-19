#!/usr/bin/env bash
# The Dart side shared by the Dart and Flutter drivers in drivers/: pick the pinned SDK, keep the
# caller's environment away from the tools, and resolve packages offline inside the measured tree.
# Sourced after lib/qg-driver-kit.sh; defines functions only. Catalogue:
# vault/architecture/qg-dart-drivers.md.
#
# Results come back in globals the sourcing driver reads: QG_FLUTTER, QG_DART, QG_ERROR.
# shellcheck disable=SC2034

# qg_dart_config_key <key> -> the key's value at QG_CONFIG_REV through the engine's one reader,
# lib/qg-config.sh. An empty QG_CONFIG_REV means a first commit, which reads the index.
qg_dart_config_key() (
    cd "${QG_REPO:-.}" || exit 1
    # shellcheck source=qg-config.sh
    . "$(dirname "${BASH_SOURCE[0]}")/qg-config.sh"
    GUARD_CONFIG_REV="${QG_CONFIG_REV:-}"
    guard_config_show() { git show ":$1" 2>/dev/null; }
    qg_config_key "$1"
)

# qg_dart_env -> sets QG_FLUTTER and QG_DART to the SDK named by guard_flutter_root, by absolute path,
# exports FLUTTER_ROOT to it, and unsets the caller's PUB_CACHE and XDG_CACHE_HOME. Returns 1 with
# QG_ERROR set when the key is absent, the folder is not a Flutter SDK, or the `flutter` on PATH is
# another file: a planted earlier PATH entry must never judge the push.
qg_dart_env() {
    local root on_path
    QG_ERROR=''
    unset PUB_CACHE XDG_CACHE_HOME FLUTTER_ROOT
    [ -z "${QG_RUNNER:-}" ] || { QG_ERROR='a Dart driver runs the pinned SDK itself; runner= is not allowed'; return 1; }
    root="$(qg_dart_config_key guard_flutter_root)" && [ -n "$root" ] \
        || { QG_ERROR='guard_flutter_root is not set in quality/config at the config revision'; return 1; }
    QG_FLUTTER="${root}/bin/flutter" QG_DART="${root}/bin/cache/dart-sdk/bin/dart"
    [ -x "$QG_FLUTTER" ] && [ -x "$QG_DART" ] \
        || { QG_ERROR="guard_flutter_root ${root} is not a Flutter SDK: no bin/flutter or bin/cache/dart-sdk/bin/dart"; return 1; }
    if on_path="$(command -v flutter)"; then
        [ "$(readlink -f "$on_path")" = "$(readlink -f "$QG_FLUTTER")" ] \
            || { QG_ERROR="flutter on PATH is ${on_path}, not ${QG_FLUTTER} from guard_flutter_root"; return 1; }
    fi
    export FLUTTER_ROOT="$root"
}

# qg_dart_packages -> resolves the measured tree's packages with `dart pub get --offline` inside
# QG_TREE. Returns 1 with QG_ERROR set when the tree carries pubspec_overrides.yaml or a tracked
# .dart_tool/, either of which points a tool at code the commit chose, or when resolution fails.
qg_dart_packages() {
    local tracked out
    QG_ERROR=''
    [ ! -e "${QG_TREE}/pubspec_overrides.yaml" ] \
        || { QG_ERROR='pubspec_overrides.yaml is in the measured tree; it would replace the packages that judge it'; return 1; }
    if [ "${QG_TARGET:-:index}" = ':index' ]; then tracked="$(git -C "${QG_REPO:-.}" ls-files -- .dart_tool | head -1)"
    else tracked="$(git -C "${QG_REPO:-.}" ls-tree -r --name-only "$QG_TARGET" -- .dart_tool 2>/dev/null | head -1)"; fi
    [ -z "$tracked" ] || { QG_ERROR="${tracked} is committed; .dart_tool must never be tracked"; return 1; }
    # --enforce-lockfile: a pubspec.yaml dependency_overrides entry the lock does not record is refused.
    out="$(cd "$QG_TREE" && "$QG_DART" pub get --offline --enforce-lockfile 2>&1)" || {
        QG_ERROR="dart pub get --offline --enforce-lockfile failed: $(printf '%s' "$out" | tail -5 | tr '\n' ' ')- run flutter pub get, commit pubspec.lock, then retry"
        return 1
    }
}

# qg_dart_prepare <driver> <unit> -> qg_dart_env then qg_dart_packages; on failure writes status
# error for <driver> and returns 1.
qg_dart_prepare() {
    qg_dart_env && qg_dart_packages && return 0
    qg_fail "$1" "$2" "$QG_ERROR"
    return 1
}

# qg_isolated <private dir> <argv...> -> runs argv for a tool that runs code the commit wrote (tests,
# mutation runs): in its own session, with only HOME, PATH, LANG, FLUTTER_ROOT and TMPDIR=<private dir>
# in its environment. Its process group is killed before the caller reads its output; a process that
# starts its own session is not reached. It runs as the operator's user, so it can still read the
# gate's processes under /proc and write the pub cache, the SDK and the gate cache: only an OS sandbox
# closes that (owner: S6). Returns argv's exit code.
qg_isolated() {
    local dir="$1" pid rc=0
    shift
    set +m
    env -i HOME="$HOME" PATH="$PATH" LANG="${LANG:-C.UTF-8}" FLUTTER_ROOT="${FLUTTER_ROOT:-}" TMPDIR="$dir" \
        setsid "$@" &
    pid=$!
    wait "$pid" || rc=$?
    # Without job control setsid runs in place, so the pid names the group it leads.
    kill -KILL -- "-${pid}" 2>/dev/null
    return "$rc"
}
