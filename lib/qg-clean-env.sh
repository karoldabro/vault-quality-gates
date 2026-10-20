#!/usr/bin/env bash
# The clean start of every gate entry: templates/git-hooks/*, bin/guard.sh and bin/qg. Each starts
# `#!/bin/bash -p`, which reads no BASH_ENV and imports no function, and calls qg_clean_env first.
# Defines functions only; calls builtins and `command -p` programs only, because PATH is still
# the caller's when it runs.
#
# qg_clean_env <extra kept name>... -- <script args>... reads the names in /proc/self/environ.
# When one is outside the kept list, it re-executes the script under `env -i` with only the kept
# names, PATH set to the clean PATH and QG_CLEAN_ENV=1. A process that carries QG_CLEAN_ENV and
# still holds another name exits 2, so an entry restarts at most once; a forged QG_CLEAN_ENV can
# only turn a restart into that exit. Stdin, the working directory and the arguments pass through.

# shellcheck source=qg-toolpath.sh
. "${BASH_SOURCE[0]%/*}/qg-toolpath.sh"

QG_KEPT_NAMES='HOME USER LOGNAME LANG LC_ALL LC_CTYPE TERM SSH_AUTH_SOCK XDG_RUNTIME_DIR DISPLAY
GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_REFLOG_ACTION GIT_PUSH_OPTION_COUNT
CLAUDECODE AI_AGENT'

qg_clean_env() {
    local kv name clean extra='' marked=''
    local -a keep=() own=()
    local -A kept=()
    for name in $QG_KEPT_NAMES; do kept[$name]=1; done
    # The entry's own names pass with the value the entry holds now, which it may have just set.
    while [ $# -gt 0 ] && [ "$1" != -- ]; do kept[$1]=2; own+=("$1"); shift; done
    shift
    for name in "${own[@]}"; do [ -z "${!name+set}" ] || keep+=("${name}=${!name}"); done
    clean="$(qg_clean_path)"
    if [ ! -r /proc/self/environ ]; then
        printf 'vault-guard: /proc/self/environ is unreadable; the gate runs on Linux only\n' >&2
        exit 2
    fi
    while IFS= read -r -d '' kv; do
        name="${kv%%=*}"
        [ "${kept[$name]:-}" = 2 ] && continue
        # GITHEAD_<sha> names a merged head; git exports one per head to pre-merge-commit.
        if [ -n "${kept[$name]:-}" ] || [[ "$name" =~ ^(GIT_PUSH_OPTION_[0-9]+|GITHEAD_[0-9a-f]{40,64})$ ]]; then
            keep+=("$kv")
            continue
        fi
        case "$name" in
            PWD|OLDPWD|SHLVL|_) ;;
            QG_CLEAN_ENV) marked=1 ;;
            PATH) [ "${kv#PATH=}" = "$clean" ] || extra+=" PATH" ;;
            *) extra+=" ${name}" ;;
        esac
    done < /proc/self/environ
    if [ -z "$extra" ]; then
        unset QG_CLEAN_ENV
        export PATH="$clean"
        return 0
    fi
    if [ -n "$marked" ]; then
        printf 'vault-guard: the environment still holds%s after the clean restart; refused\n' "$extra" >&2
        exit 2
    fi
    exec /usr/bin/env -i "${keep[@]}" PATH="$clean" QG_CLEAN_ENV=1 /bin/bash -p "$0" "$@"
}
