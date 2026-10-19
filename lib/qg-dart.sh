#!/usr/bin/env bash
# The Dart side shared by the Dart and Flutter drivers in drivers/: pick the pinned SDK, keep the
# caller's environment away from the tools, and resolve packages offline inside the measured tree.
# Sourced after lib/qg-driver-kit.sh; defines functions only. Catalogue:
# vault/architecture/qg-dart-drivers.md.
#
# Results come back in globals the sourcing driver reads: QG_FLUTTER, QG_DART, QG_ERROR.
# shellcheck disable=SC2034

# qg_dart_config_key <key> -> the key's value at the config revision (QG_CONFIG_REV, else HEAD) of
# QG_REPO: quality/config when that file exists there, else VAULT.md. Exit 1 when it is absent.
qg_dart_config_key() {
    local rev="${QG_CONFIG_REV:-HEAD}" src line
    for src in quality/config VAULT.md; do
        if git -C "${QG_REPO:-.}" cat-file -e "${rev}:${src}" 2>/dev/null; then
            line="$(git -C "${QG_REPO:-.}" show "${rev}:${src}" | grep -m1 "^${1}:")" || return 1
            line="${line#*:}"
            printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
            return 0
        fi
    done
    return 1
}

# qg_dart_env -> sets QG_FLUTTER and QG_DART to the SDK named by guard_flutter_root, by absolute path,
# exports FLUTTER_ROOT to it, and unsets the caller's PUB_CACHE and XDG_CACHE_HOME. Returns 1 with
# QG_ERROR set when the key is absent, the folder is not a Flutter SDK, or the `flutter` on PATH is
# another file: a planted earlier PATH entry must never judge the push.
qg_dart_env() {
    local root on_path
    QG_ERROR=''
    unset PUB_CACHE XDG_CACHE_HOME FLUTTER_ROOT
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
    out="$(cd "$QG_TREE" && "$QG_DART" pub get --offline 2>&1)" || {
        QG_ERROR="dart pub get --offline failed: $(printf '%s' "$out" | tail -5 | tr '\n' ' ')- run flutter pub get, then retry"
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

# qg_without_qg <argv...> -> runs argv with every QG_* variable removed, for a tool that runs code the
# commit wrote (tests, mutation runs): that code must not find the run directory or the tree's role.
qg_without_qg() {
    local -a drop=()
    local v
    for v in $(compgen -e); do case "$v" in QG_*) drop+=(-u "$v") ;; esac; done
    env "${drop[@]}" "$@"
}
