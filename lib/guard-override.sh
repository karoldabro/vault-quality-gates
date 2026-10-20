#!/usr/bin/env bash
# Human-only override of the commit gate, and its log. Sourced by the git hook templates.
#
# guard_override_allowed [reason] — 0 when the override is honoured, 1 when it is not. The reason
# defaults to QG_SKIP_REASON. Honoured only when the reason has a non-blank character, /dev/tty
# opens, and neither CLAUDECODE nor AI_AGENT is set; a variable set to an empty string counts as
# set, so an agent that blanks the marker still fails closed.
#
# guard_override_log [message] — appends one tab-separated line to
# $(git rev-parse --git-common-dir)/guard-bypass.log:
#   <UTC date> <user> <HEAD sha or (none)> <staged files, space-separated> <reason> <message>
# Tabs and newlines inside a field become spaces, so one override is always one line.
#
# The token below is also written and consumed by an agent while the operator's grant names the
# action (lib/qg-grant.sh): override for a commit token, push for a push token.

# shellcheck source=qg-grant.sh
. "${BASH_SOURCE[0]%/*}/qg-grant.sh"

guard_override_allowed() {
    local reason="${1-${QG_SKIP_REASON-}}"
    [[ "$reason" =~ [^[:space:]] ]] || return 1
    [ -z "${CLAUDECODE+set}" ] || return 1
    [ -z "${AI_AGENT+set}" ] || return 1
    { : < /dev/tty; } 2>/dev/null || return 1
    guard_override_ancestors_clean
}

# guard_override_ancestors_clean -> 1 when this process or any ancestor holds CLAUDECODE or
# AI_AGENT in /proc/<pid>/environ, or when one of those files cannot be read. An agent that starts a
# command with a fresh environment (env -i, a launcher, tmux) is still its ancestor.
#
# The walk stops at the user manager (systemd --user) or init and never reads past it. A process on
# this hook's terminal whose parent is init, the user manager or a process that has left /proc was
# orphaned: the parent it lost may have been the agent, so the walk fails closed there. A terminal
# emulator, the normal child of the user manager, holds no controlling terminal and passes.
# Builtins only: the hook's PATH is no help here.
guard_override_ancestors_clean() {
    local pid="$$" kv stat ppid tty mytty='' comm
    while :; do
        [ -r "/proc/${pid}/environ" ] || return 1
        while IFS= read -r -d '' kv; do
            case "$kv" in CLAUDECODE=*|AI_AGENT=*) return 1 ;; esac
        done < "/proc/${pid}/environ" || return 1
        # /proc/<pid>/stat: pid (comm) state ppid pgrp session tty_nr ...; comm may hold spaces.
        IFS= read -r stat < "/proc/${pid}/stat" || return 1
        read -r _ ppid _ _ tty _ <<<"${stat##*) }"
        case "$ppid$tty" in ''|*[!0-9]*) return 1 ;; esac
        [ -n "$mytty" ] || mytty="$tty"
        comm=''
        [ "$ppid" -le 1 ] || { IFS= read -r comm < "/proc/${ppid}/comm" || return 1; }
        if [ "$tty" != 0 ] && [ "$tty" = "$mytty" ] && { [ "$ppid" -le 1 ] || [ "$comm" = systemd ]; }; then
            return 1
        fi
        [ "$ppid" -gt 1 ] && [ "$comm" != systemd ] || return 0
        pid="$ppid"
    done
}

_guard_override_field() {
    printf '%s' "$1" | tr '\t\n\r' '   '
}

# --- the one-shot token `qg override` writes -----------------------------------------------
# <git-common-dir>/qg-override holds one tab-separated line:
#   <reason> <user> <epoch> <commit|push> <binding>
# binding is `git write-tree` of the index for a commit token, or the full pushed sha for a push
# token. The hook consumes it only when guard_override_allowed passes in the hook's own process,
# so a token an agent writes, or one consumed by an agent's commit, never passes unless a live
# grant names the action (qg_override_granted). It is valid
# for QG_OVERRIDE_TTL seconds and is deleted on use.
QG_OVERRIDE_TTL=600

# qg_override_granted <reason> <commit|push> -> 0 when a human at a terminal runs this, or a live
# grant names the action; the grant's use is logged.
qg_override_granted() {
    guard_override_allowed "$1" && return 0
    [[ "$1" =~ [^[:space:]] ]] || return 1
    if [ "$2" = push ]; then qg_grant_use push 'the push override token'; else qg_grant_use override 'the commit override token'; fi
}

qg_override_file() { printf '%s/qg-override' "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; }

# qg_override_write <reason> [--push <sha>] -> 0 and the token written; 1 with the reason on
# stderr when the override is not allowed here.
qg_override_write() {
    local reason="$1" kind=commit binding
    if [ "${2:-}" = --push ]; then
        kind=push
        binding="$(git rev-parse -q --verify "${3:-}^{commit}" 2>/dev/null)" || { printf 'qg override: --push needs a commit, got "%s"\n' "${3:-}" >&2; return 1; }
    else
        # The commit hook takes the tree after the repo's own pre-commit step (lint-staged, say),
        # which may reformat and re-stage files; run it here first, so the token names that tree.
        local user_step; user_step="$(git rev-parse --git-path hooks)/pre-commit.user"
        if [ -x "$user_step" ] && { guard_override_allowed "$reason" || qg_grant_live override; }; then
            "$user_step" || { printf 'qg override: %s failed; fix that first\n' "$user_step" >&2; return 1; }
        fi
        binding="$(git write-tree 2>/dev/null)" || { printf 'qg override: cannot read the index\n' >&2; return 1; }
    fi
    if ! qg_override_granted "$reason" "$kind"; then
        printf 'qg override: refused. It needs a reason, and a terminal (/dev/tty) with no CLAUDECODE or AI_AGENT in the environment, or an operator grant naming %s (qg grant --status).\n' "${kind/commit/override}" >&2
        return 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$(_guard_override_field "$reason")" "$(_guard_override_field "${USER:-$(id -un 2>/dev/null)}")" \
        "$(date +%s)" "$kind" "$binding" > "$(qg_override_file)"
    printf 'qg override: the next %s of %s goes through once, within %d minutes.\n' "$kind" "${binding:0:12}" $((QG_OVERRIDE_TTL / 60))
}

# qg_override_take <commit|push> <binding>... -> 0 and QG_OVERRIDE_REASON set when the token
# matches one binding; 1 otherwise, naming on stderr why a present token was ignored.
qg_override_take() {
    local kind="$1" file reason user epoch tkind tbind extra now b why=''
    shift
    file="$(qg_override_file)"
    [ -r "$file" ] || return 1
    IFS=$'\t' read -r reason user epoch tkind tbind extra < "$file"
    now="$(date +%s)"
    if [ -n "${extra:-}" ] || [ -z "${tbind:-}" ] || ! [[ "${epoch:-}" =~ ^[0-9]+$ ]]; then why='it is malformed'
    elif [ "$epoch" -gt "$now" ]; then why='its time is in the future'
    elif [ $((now - epoch)) -gt "$QG_OVERRIDE_TTL" ]; then why="it is older than $((QG_OVERRIDE_TTL / 60)) minutes"
    elif [ "$tkind" != "$kind" ]; then why="it was written for a ${tkind}, not a ${kind}"
    elif ! qg_override_granted "$reason" "$tkind"; then why='this run is not a human at a terminal (CLAUDECODE, AI_AGENT, or no /dev/tty), and no grant names it'
    else
        why="it names ${tbind:0:12}, which is not what is being ${kind/commit/committ}ed"
        for b in "$@"; do
            if [ "$b" = "$tbind" ]; then
                rm -f "$file"
                QG_OVERRIDE_REASON="$reason"
                return 0
            fi
        done
    fi
    case "$why" in *malformed*|*older*|*future*) rm -f "$file" ;; esac
    printf 'vault-guard: the qg override token was ignored: %s.\n' "$why" >&2
    return 1
}

guard_override_log() {
    local common head staged user
    common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
    head="$(git rev-parse -q --verify HEAD 2>/dev/null)" || head='(none)'
    staged="$(git diff --cached --name-only 2>/dev/null | tr '\n' ' ')"
    user="${USER:-$(id -un 2>/dev/null || id -u)}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(_guard_override_field "$user")" \
        "$head" \
        "$(_guard_override_field "${staged% }")" \
        "$(_guard_override_field "${QG_SKIP_REASON-${QG_OVERRIDE_REASON-}}")" \
        "$(_guard_override_field "${1-}")" >> "$common/guard-bypass.log"
}
