#!/usr/bin/env bash
# qg_sandbox_run: the one launcher of every tool a driver runs, and of a repo driver's whole run.
# It builds the child's environment, picks the write grants and starts bin/qg-sandbox, or, when
# QG_SANDBOX is exactly 0, runs the command unconfined under the same environment. Sourced by
# lib/qg-driver.sh and lib/qg-driver-kit.sh; sources nothing and defines functions only.
# Rules and limits: vault/architecture/qg-sandbox.md.
#
# Inputs, exported by guard_run_driver from the driver's describe, never read from describe here:
#   QG_SANDBOX          0 runs unsandboxed; any other value, or unset, runs sandboxed
#   QG_SANDBOX_WRITES   space-separated folders relative to QG_TREE the tool may write
#   QG_SANDBOX_SDK      a Flutter SDK root: its existing bin/cache stamps and lockfile become writable
# Results come back in globals: QG_SANDBOX_ERROR (empty unless the tool never ran) and
# QG_SANDBOX_ARMED (1 after a sandboxed run).
# shellcheck disable=SC2034

QG_SANDBOX_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/qg-sandbox"

# The QG_* names of the driver contract a tool may see; QG_SANDBOX* stay with the engine.
QG_SANDBOX_PASS=(QG_ARGS QG_OUT QG_ROW QG_BASE QG_FILES QG_BASES QG_TARGET QG_REPO QG_TREE QG_CACHE
    QG_RUNNER QG_RUN_DIR QG_CONFIG_REV)

# qg_sandbox_grant <real tree> <declared path> -> the absolute path to grant, its missing folders
# created one component at a time. Exit 1 with the reason on stdout for a path that is absolute,
# leaves the tree, names .git, is the tree itself, or lies under node_modules other than
# node_modules/.vite and node_modules/.cache, and for a component that is a symlink.
qg_sandbox_grant() {
    local tree="$1" rel="$2" c cur
    local -a parts=() comps
    case "$rel" in /*) printf 'declared path %s is absolute' "$rel"; return 1 ;; esac
    IFS=/ read -ra comps <<<"$rel"
    for c in "${comps[@]}"; do
        case "$c" in
            ''|.) ;;
            ..) [ "${#parts[@]}" -gt 0 ] || { printf 'declared path %s leaves the tree' "$rel"; return 1; }
                unset 'parts[-1]' ;;
            *) parts+=("$c") ;;
        esac
    done
    [ "${#parts[@]}" -gt 0 ] || { printf 'declared path %s is the whole tree' "$rel"; return 1; }
    for c in "${parts[@]}"; do
        [ "$c" != .git ] || { printf 'declared path %s names .git' "$rel"; return 1; }
    done
    if [ "${parts[0]}" = node_modules ]; then
        case "${parts[1]:-}" in .vite|.cache) ;; *) printf 'declared path %s lies under node_modules' "$rel"; return 1 ;; esac
    fi
    cur="$tree"
    for c in "${parts[@]}"; do
        cur="${cur}/${c}"
        [ ! -L "$cur" ] || { printf 'declared path %s passes through the symlink %s' "$rel" "$cur"; return 1; }
        if [ ! -e "$cur" ]; then
            mkdir "$cur" 2>/dev/null && [ ! -L "$cur" ] || { printf 'declared path %s cannot be created' "$rel"; return 1; }
        fi
    done
    printf '%s' "$cur"
}


# qg_sandbox_argv [--out] [--keep-session] -> fills QG_SANDBOX_ENV with the child environment and
# QG_SANDBOX_ARGV with the command prefix that starts a tool: `/usr/bin/env -i <env> bin/qg-sandbox
# --write ... --armed <marker> --` when sandboxed, `/usr/bin/env -i <env>` when QG_SANDBOX is 0. It
# creates the private folder (QG_SANDBOX_PRIVATE) and every declared folder, refusing a bad one.
# --out also grants QG_OUT; --keep-session leaves the session to a caller that already started one.
# Returns 125 with QG_SANDBOX_ERROR set when a grant is refused. Pair it with qg_sandbox_finish.
qg_sandbox_argv() {
    local out='' keep='' private tree w g v
    local -a grants=() ws
    QG_SANDBOX_ERROR='' QG_SANDBOX_ARMED='' QG_SANDBOX_PRIVATE='' QG_SANDBOX_ENV=() QG_SANDBOX_ARGV=()
    while [ "$#" -gt 0 ]; do
        case "$1" in --out) out=1 ;; --keep-session) keep=1 ;; esac
        shift
    done
    private="$(mktemp -d)" && chmod 700 "$private" && private="$(cd "$private" && pwd -P)" \
        || { QG_SANDBOX_ERROR='qg-sandbox: cannot create the private folder'; return 125; }
    QG_SANDBOX_PRIVATE="$private"
    # An unconfined run keeps the real HOME: its tools (pnpm dlx, docker compose) need their caches,
    # and a private HOME would protect nothing the run cannot already write.
    local home="$private"
    [ "${QG_SANDBOX:-}" != 0 ] || home="$HOME"
    QG_SANDBOX_ENV=("HOME=${home}" "TMPDIR=${private}" "QG_PRIVATE=${private}" "PATH=${PATH}"
        "PUB_CACHE=${HOME}/.pub-cache")
    [ -z "${LANG:-}" ] || QG_SANDBOX_ENV+=("LANG=${LANG}")
    [ -z "${LC_ALL:-}" ] || QG_SANDBOX_ENV+=("LC_ALL=${LC_ALL}")
    [ -z "${QG_SANDBOX_SDK:-}" ] || QG_SANDBOX_ENV+=("FLUTTER_ROOT=${QG_SANDBOX_SDK}" FLUTTER_ALREADY_LOCKED=true)
    for v in "${QG_SANDBOX_PASS[@]}"; do [ -z "${!v+set}" ] || QG_SANDBOX_ENV+=("${v}=${!v}"); done
    QG_SANDBOX_ARGV=(/usr/bin/env -i "${QG_SANDBOX_ENV[@]}")
    [ "${QG_SANDBOX:-}" != 0 ] || return 0

    grants=(--write "$private" --write /dev/null)
    if [ -n "${QG_SANDBOX_SDK:-}" ] && g="$(cd "$QG_SANDBOX_SDK" 2>/dev/null && pwd -P)"; then
        for w in "$g"/bin/cache/*.stamp "$g"/bin/cache/lockfile; do
            [ -f "$w" ] && [ ! -L "$w" ] && grants+=(--write "$w")
        done
    fi
    read -ra ws <<<"${QG_SANDBOX_WRITES:-}"
    if [ "${#ws[@]}" -gt 0 ]; then
        tree="$(cd "${QG_TREE:-/nonexistent}" 2>/dev/null && pwd -P)" \
            || { qg_sandbox_finish; QG_SANDBOX_ERROR='qg-sandbox: QG_TREE is not a folder, so no declared path can be granted'; return 125; }
        for w in "${ws[@]}"; do
            g="$(qg_sandbox_grant "$tree" "$w")" || { qg_sandbox_finish; QG_SANDBOX_ERROR="qg-sandbox: ${g}"; return 125; }
            grants+=(--write "$g")
        done
    fi
    if [ -n "$out" ]; then
        g="$(cd "$QG_OUT" 2>/dev/null && pwd -P)" || { qg_sandbox_finish; QG_SANDBOX_ERROR='qg-sandbox: QG_OUT is not a folder'; return 125; }
        grants+=(--write "$g")
    fi
    [ -z "$keep" ] || grants+=(--keep-session)
    QG_SANDBOX_ARGV+=("$QG_SANDBOX_BIN" "${grants[@]}" --armed "${private}/.armed" --)
}

# qg_sandbox_finish -> after a run started from qg_sandbox_argv: a sandboxed run without the armed
# marker sets QG_SANDBOX_ERROR and returns 125; an armed one sets QG_SANDBOX_ARMED and appends
# `sandbox: armed` to $QG_OUT/.qg-sandbox.log. Removes the private folder either way.
qg_sandbox_finish() {
    local rc=0
    [ -n "$QG_SANDBOX_PRIVATE" ] || return 0
    if [ "${QG_SANDBOX:-}" != 0 ] && [ "${#QG_SANDBOX_ARGV[@]}" -gt 0 ] && [ "${QG_SANDBOX_ARGV[-1]}" = -- ]; then
        if [ ! -e "${QG_SANDBOX_PRIVATE}/.armed" ]; then
            QG_SANDBOX_ERROR='qg-sandbox: the sandbox did not arm, so the tool never ran'
            rc=125
        else
            QG_SANDBOX_ARMED=1
            [ ! -d "${QG_OUT:-}" ] || printf 'sandbox: armed\n' >> "${QG_OUT}/.qg-sandbox.log"
        fi
    fi
    chmod -R u+rwX "$QG_SANDBOX_PRIVATE" 2>/dev/null
    rm -rf "$QG_SANDBOX_PRIVATE"
    QG_SANDBOX_PRIVATE=''
    return "$rc"
}

# qg_sandbox_run [--cwd <dir>] [--out] [--runner <runner> <tree> <cache>] [--] <argv...> -> runs argv
# in <dir> (default: the current folder) in its own session, stdin from /dev/null, with only the
# child environment, and kills its process group when it exits. --out also grants QG_OUT, for a repo
# driver's whole run. With --runner the runner runs outside the sandbox, under the same environment,
# as `<runner> <tree> <cache> <sandbox prefix> <argv>`: it may prepare the tree, and only the tool it
# starts is confined. With QG_SANDBOX=0 it gets `<runner> <tree> <cache> <argv>`. Returns argv's exit code, or 125 with QG_SANDBOX_ERROR set when the tool never
# ran: a refused grant, or a sandbox that did not arm.
qg_sandbox_run() {
    local cwd="$PWD" pid rc=0
    local -a pre=() runner=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --cwd) cwd="$2"; shift 2 ;;
            --out) pre+=(--out); shift ;;
            --runner) runner=("$2" "$3" "$4"); pre+=(--keep-session); shift 4 ;;
            --) shift; break ;;
            *) break ;;
        esac
    done
    qg_sandbox_argv "${pre[@]}" || return 125
    if [ "${#runner[@]}" -gt 0 ] && [ "${QG_SANDBOX:-}" = 0 ]; then
        # Unsandboxed, the runner gets the tool argv alone: a container runner passes it on as is.
        ( cd "$cwd" && exec "${QG_SANDBOX_ARGV[@]}" setsid "${runner[@]}" "$@" ) </dev/null &
    elif [ "${#runner[@]}" -gt 0 ]; then
        ( cd "$cwd" && exec /usr/bin/env -i "${QG_SANDBOX_ENV[@]}" setsid "${runner[@]}" "${QG_SANDBOX_ARGV[@]}" "$@" ) </dev/null &
    elif [ "${QG_SANDBOX:-}" != 0 ]; then
        ( cd "$cwd" && exec "${QG_SANDBOX_ARGV[@]}" "$@" ) </dev/null &
    else
        ( cd "$cwd" && exec "${QG_SANDBOX_ARGV[@]}" setsid "$@" ) </dev/null &
    fi
    pid=$!
    wait "$pid" || rc=$?
    # The sandbox and setsid run in place, so the pid names the group they lead.
    kill -KILL -- "-${pid}" 2>/dev/null
    qg_sandbox_finish || rc=125
    return "$rc"
}

# qg_sandbox_denied <stderr file> -> the first line in which the tool reports a refused write or
# socket, so the error names what the sandbox stopped. Prints nothing when there is none.
qg_sandbox_denied() {
    grep -m1 -E 'Permission denied|EACCES|Operation not permitted|EPERM|Read-only file system' "$1" 2>/dev/null | cut -c1-200
}
