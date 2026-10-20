#!/usr/bin/env bash
# The Dart side shared by the Dart and Flutter drivers in drivers/: pick the pinned SDK, keep the
# caller's environment away from the tools, and resolve packages offline inside the measured tree.
# Sourced after lib/qg-driver-kit.sh; defines functions only. Catalogue:
# vault/architecture/qg-dart-drivers.md.
#
# Results come back in globals the sourcing driver reads: QG_FLUTTER, QG_DART, QG_ERROR.
# shellcheck disable=SC2034

# qg_dart_config_key <key> -> the key's value at QG_CONFIG_REV (qg_kit_config_key in the kit).
qg_dart_config_key() { qg_kit_config_key "$1"; }

# qg_dart_env -> sets QG_DART to the SDK named by guard_flutter_root, by absolute path, and QG_FLUTTER
# to a private `flutter` shim that runs the SDK's tool snapshot. It puts the shim's folder first on
# PATH, exports FLUTTER_ROOT and QG_SANDBOX_SDK to the SDK, and unsets the caller's PUB_CACHE and
# XDG_CACHE_HOME. The shim exists because <sdk>/bin/flutter rewrites SDK files on every call, which
# the sandbox refuses. Returns 1 with QG_ERROR set when the key is absent, the folder is not a
# Flutter SDK, or the `flutter` on PATH is another file: a planted earlier PATH entry must never
# judge the push.
qg_dart_env() {
    local root on_path shim
    QG_ERROR=''
    unset PUB_CACHE XDG_CACHE_HOME FLUTTER_ROOT QG_SANDBOX_SDK
    [ -z "${QG_RUNNER:-}" ] || { QG_ERROR='a Dart driver runs the pinned SDK itself; runner= is not allowed'; return 1; }
    root="$(qg_dart_config_key guard_flutter_root)" && [ -n "$root" ] \
        || { QG_ERROR='guard_flutter_root is not set in quality/config at the config revision'; return 1; }
    QG_DART="${root}/bin/cache/dart-sdk/bin/dart"
    [ -x "${root}/bin/flutter" ] && [ -x "$QG_DART" ] \
        || { QG_ERROR="guard_flutter_root ${root} is not a Flutter SDK: no bin/flutter or bin/cache/dart-sdk/bin/dart"; return 1; }
    if on_path="$(command -v flutter)"; then
        [ "$(readlink -f "$on_path")" = "$(readlink -f "${root}/bin/flutter")" ] \
            || { QG_ERROR="flutter on PATH is ${on_path}, not ${root}/bin/flutter from guard_flutter_root"; return 1; }
    fi
    # One shim folder per SDK, inside the run's folder, or the gate cache when a driver runs alone.
    shim="${QG_RUN_DIR:-${QG_CACHE:?}}/qg-flutter-$(printf '%s' "$root" | cksum | cut -d' ' -f1)"
    mkdir -p "$shim" || { QG_ERROR="cannot create the flutter shim folder ${shim}"; return 1; }
    printf '#!/bin/bash\nexec %q --disable-dart-dev --packages=%q %q "$@"\n' "$QG_DART" \
        "${root}/packages/flutter_tools/.dart_tool/package_config.json" "${root}/bin/cache/flutter_tools.snapshot" \
        > "${shim}/flutter.$$" && chmod +x "${shim}/flutter.$$" && mv "${shim}/flutter.$$" "${shim}/flutter" \
        || { QG_ERROR="cannot write the flutter shim in ${shim}"; return 1; }
    QG_FLUTTER="${shim}/flutter"
    case ":${PATH}:" in *":${shim}:"*) ;; *) PATH="${shim}:${PATH}" ;; esac
    export FLUTTER_ROOT="$root" QG_SANDBOX_SDK="$root" PATH
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
        QG_ERROR="dart pub get --offline --enforce-lockfile failed: $(printf '%s' "$out" | tail -5 | tr "\n" " "); run flutter pub get, commit pubspec.lock, then retry"
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

# qg_isolated <argv...> -> runs argv, a tool that runs code the commit wrote (tests, mutation runs),
# in QG_TREE through qg_sandbox_run (lib/qg-sandbox.sh): its own session, the child environment of
# the driver contract, writes only to the declared paths and its private folder QG_PRIVATE, and its
# process group killed after it exits. A process that starts its own session is not reached.
# Returns argv's exit code, or 1 with QG_ERROR set when the sandbox never started it.
qg_isolated() {
    local rc=0
    qg_sandbox_run --cwd "$QG_TREE" -- "$@" || rc=$?
    [ -z "$QG_SANDBOX_ERROR" ] || { QG_ERROR="$QG_SANDBOX_ERROR"; return 1; }
    return "$rc"
}
