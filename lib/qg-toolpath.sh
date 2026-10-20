#!/usr/bin/env bash
# The machine tool-path file: the folders of pnpm, node, php, composer, docker and hugo that the
# clean PATH adds after the system folders. Sourced by lib/qg-clean-env.sh, lib/guard-install.sh
# and lib/qg-doctor.sh; defines functions only.
#
# It runs before an entry has cleaned its environment, so it calls builtins and `command -p`
# programs only, and runs git under `env -i`: no caller variable, function or PATH entry reaches it.
#
# File: <git-common-dir of the plugin checkout>/qg-tool-path, one absolute folder per line. That is
# the main worktree's .git, which the agent guards deny writing. `qg hooks install --claude --user`
# writes it. An entry is valid when it is absolute, an existing folder, and outside every git work
# tree; symlinks are resolved, a trailing / is dropped, and a duplicate counts once.

QG_TOOLPATH_PLUGIN="$(cd -P "${BASH_SOURCE[0]%/*}/.." 2>/dev/null && pwd -P)"
QG_SYSTEM_PATH='/usr/local/bin:/usr/bin:/bin'

# qg_toolpath_git <arg>... -> git with an empty environment except HOME and the system PATH.
qg_toolpath_git() {
    command -p env -i HOME="${HOME:-/}" PATH="$QG_SYSTEM_PATH" git "$@" 2>/dev/null
}

# qg_tool_path_file -> the file's path; exit 1 when the plugin checkout has no readable git dir.
qg_tool_path_file() {
    local common
    common="$(qg_toolpath_git -C "${QG_TOOLPATH_PLUGIN:-/}" rev-parse --path-format=absolute --git-common-dir)" || return 1
    [ -n "$common" ] || return 1
    printf '%s/qg-tool-path\n' "$common"
}

# qg_tool_path_check <entry> -> prints the resolved folder; exit 1 with the reason on stdout.
qg_tool_path_check() {
    local e="$1" real
    [ -n "$e" ] || { printf 'empty entry'; return 1; }
    [ "${e:0:1}" = / ] || { printf 'not an absolute path'; return 1; }
    [ -e "$e" ] || { printf 'does not exist'; return 1; }
    [ -d "$e" ] || { printf 'not a folder'; return 1; }
    real="$(cd -P "$e" 2>/dev/null && pwd -P)" || { printf 'cannot be entered'; return 1; }
    if qg_toolpath_git -C "$real" rev-parse --show-toplevel >/dev/null; then
        printf 'inside a git work tree'; return 1
    fi
    printf '%s' "$real"
}

# qg_tool_path_scan <valid|bad> -> the valid folders, one per line, or `<entry>\t<reason>` per bad one.
qg_tool_path_scan() {
    local file line out
    local -A seen=()
    file="$(qg_tool_path_file)" || return 0
    [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        if out="$(qg_tool_path_check "$line")"; then
            [ -z "${seen[$out]:-}" ] || continue
            seen[$out]=1
            [ "$1" = valid ] && printf '%s\n' "$out"
        else
            [ "$1" = bad ] && printf '%s\t%s\n' "$line" "$out"
        fi
    done < "$file"
    return 0
}

qg_tool_path_entries() { qg_tool_path_scan valid; }
qg_tool_path_bad() { qg_tool_path_scan bad; }

# qg_clean_path -> the system folders followed by every valid tool-path entry.
qg_clean_path() {
    local p="$QG_SYSTEM_PATH" d
    while IFS= read -r d; do
        [ -n "$d" ] && p+=":${d}"
    done < <(qg_tool_path_entries)
    printf '%s' "$p"
}

# qg_tool_path_from <PATH value> -> the folder of the first pnpm, node, php, composer, docker and
# hugo on it, resolved, without duplicates: what `qg hooks install --claude --user` writes.
qg_tool_path_from() {
    local tool dir real
    local -a dirs
    local -A seen=()
    IFS=: read -ra dirs <<<"$1"
    for tool in pnpm node php composer docker hugo; do
        for dir in "${dirs[@]}"; do
            [ "${dir:0:1}" = / ] && [ -f "${dir}/${tool}" ] && [ -x "${dir}/${tool}" ] || continue
            real="$(cd -P "$dir" 2>/dev/null && pwd -P)" || continue
            [ -z "${seen[$real]:-}" ] && { seen[$real]=1; printf '%s\n' "$real"; }
            break
        done
    done
}
