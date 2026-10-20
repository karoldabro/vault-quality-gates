#!/usr/bin/env bash
# The agent grant: an expiring, operator-issued permission that lets an agent run named gate-changing
# actions. Sourced by lib/guard-override.sh; defines functions only. The rules and the CLI:
# vault/architecture/qg-cli.md (qg grant).
#
# File: <git-common-dir of the plugin checkout>/qg-grant, beside qg-tool-path, which the agent guards
# deny writing. One tab-separated line:
#   v1 <issued epoch> <expiry epoch> <action,action> <user>
# A grant is live when the file is a regular file owned by this user and writable by no one else,
# the line has exactly those fields, issued <= now < expiry, expiry - issued <= QG_GRANT_MAX, and
# every action is in QG_GRANT_ACTIONS. Anything else is no grant: the agent is refused as before.
#
# Actions:
#   baseline  qg baseline
#   override  qg override --reason, and the commit hook consuming that token in an agent's commit
#   push      qg override --push <sha>, and the pre-push hook consuming that token in an agent's push

declare -F qg_tool_path_file >/dev/null || . "${BASH_SOURCE[0]%/*}/qg-toolpath.sh"

QG_GRANT_ACTIONS='baseline override push'
QG_GRANT_DEFAULT=3600
QG_GRANT_MAX=28800

# qg_grant_file -> the grant file's path; exit 1 when the plugin checkout has no readable git dir.
qg_grant_file() {
    local f; f="$(qg_tool_path_file)" || return 1
    printf '%s/qg-grant\n' "${f%/qg-tool-path}"
}

# qg_grant_read -> QG_GRANT_EXPIRES and QG_GRANT_LIST (comma-separated) of the live grant; exit 1
# when there is none.
qg_grant_read() {
    local file v issued expires actions user extra now a owner mode
    QG_GRANT_EXPIRES='' QG_GRANT_LIST=''
    file="$(qg_grant_file)" || return 1
    [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
    read -r owner mode < <(command -p stat -c '%u %a' "$file" 2>/dev/null) || return 1
    [ "$owner" = "$(command -p id -u)" ] || return 1
    # Octal mode: no write bit for group or others.
    [ $(( 8#$mode & 8#022 )) -eq 0 ] || return 1
    IFS=$'\t' read -r v issued expires actions user extra < "$file" || return 1
    [ "$v" = v1 ] && [ -z "${extra:-}" ] && [ -n "${user:-}" ] || return 1
    [[ "$issued" =~ ^[0-9]+$ ]] && [[ "$expires" =~ ^[0-9]+$ ]] || return 1
    now="$(command -p date +%s)"
    [ "$issued" -le "$now" ] && [ "$now" -lt "$expires" ] && [ $((expires - issued)) -le "$QG_GRANT_MAX" ] || return 1
    [[ "$actions" =~ ^[a-z]+(,[a-z]+)*$ ]] || return 1
    for a in ${actions//,/ }; do
        [[ " $QG_GRANT_ACTIONS " == *" $a "* ]] || return 1
    done
    QG_GRANT_EXPIRES="$expires" QG_GRANT_LIST="$actions"
}

# qg_grant_live <action> -> 0 when a live grant names the action.
qg_grant_live() {
    qg_grant_read || return 1
    [[ ",${QG_GRANT_LIST}," == *",$1,"* ]]
}

# qg_grant_use <action> <what> -> 0 when a live grant names the action, and logs the use to this
# repo's guard-bypass.log and stderr; 1 otherwise, silently.
qg_grant_use() {
    qg_grant_live "$1" || return 1
    declare -F guard_override_log >/dev/null && guard_override_log "agent grant (${1}, until $(qg_grant_when "$QG_GRANT_EXPIRES")): ${2}"
    printf 'vault-guard: %s allowed for an agent by the operator grant (%s), until %s\n' "$2" "$QG_GRANT_LIST" "$(qg_grant_when "$QG_GRANT_EXPIRES")" >&2
}

qg_grant_when() { command -p date -d "@$1" '+%Y-%m-%d %H:%M %Z'; }

# qg_grant_seconds <30m|2h|90> -> seconds; plain numbers are minutes. Exit 1 on anything else.
qg_grant_seconds() {
    case "$1" in
        *[!0-9mh]*|''|m|h) return 1 ;;
        *h) [[ "${1%h}" =~ ^[0-9]+$ ]] && printf '%s' $(( 10#${1%h} * 3600 )) ;;
        *m) [[ "${1%m}" =~ ^[0-9]+$ ]] && printf '%s' $(( 10#${1%m} * 60 )) ;;
        *)  [[ "$1" =~ ^[0-9]+$ ]] && printf '%s' $(( 10#$1 * 60 )) ;;
    esac
}

qg_grant_human() {
    guard_override_allowed "qg grant" && return 0
    printf 'qg grant: refused. Issuing, extending or revoking a grant needs a human at a terminal (/dev/tty) and no CLAUDECODE or AI_AGENT in this process or its parents; a ! command in Claude Code carries CLAUDECODE, so run it in a separate terminal.\n' >&2
    return 1
}

# qg_grant_issue [<duration>] <action,action> -> writes the grant; exit 1 with the reason on stderr.
qg_grant_issue() {
    local secs="$QG_GRANT_DEFAULT" actions a file now tmp
    if [ $# -ge 2 ]; then
        secs="$(qg_grant_seconds "$1")" || { printf 'qg grant: "%s" is no duration; use 30m, 2h or minutes\n' "$1" >&2; return 1; }
        shift
    fi
    actions="${1:-}"
    [ $# -eq 1 ] && [[ "$actions" =~ ^[a-z]+(,[a-z]+)*$ ]] || { printf 'qg grant: name the actions, comma-separated, from: %s\n' "${QG_GRANT_ACTIONS// /, }" >&2; return 1; }
    for a in ${actions//,/ }; do
        [[ " $QG_GRANT_ACTIONS " == *" $a "* ]] || { printf 'qg grant: "%s" is no grantable action; the actions are %s\n' "$a" "${QG_GRANT_ACTIONS// /, }" >&2; return 1; }
    done
    [ "$secs" -gt 0 ] && [ "$secs" -le "$QG_GRANT_MAX" ] || { printf 'qg grant: a grant lasts at most %d hours\n' $((QG_GRANT_MAX / 3600)) >&2; return 1; }
    qg_grant_human || return 1
    file="$(qg_grant_file)" || { printf 'qg grant: the plugin checkout has no readable git dir\n' >&2; return 1; }
    now="$(command -p date +%s)"
    tmp="${file}.$$"
    ( umask 077; printf 'v1\t%s\t%s\t%s\t%s\n' "$now" $((now + secs)) "$actions" "${USER:-$(command -p id -un)}" > "$tmp" ) \
        && command -p mv -f "$tmp" "$file" || { command -p rm -f "$tmp"; printf 'qg grant: cannot write %s\n' "$file" >&2; return 1; }
    printf 'qg grant: agents may run %s until %s. qg grant --revoke ends it.\n' "$actions" "$(qg_grant_when $((now + secs)))"
}

qg_grant_revoke() {
    local file
    qg_grant_human || return 1
    file="$(qg_grant_file)" || return 0
    command -p rm -f "$file"
    printf 'qg grant: revoked\n'
}

qg_grant_status() {
    local left
    if qg_grant_read; then
        left=$(( (QG_GRANT_EXPIRES - $(command -p date +%s) + 59) / 60 ))
        printf 'grant: %s until %s (%d minutes left)\n' "$QG_GRANT_LIST" "$(qg_grant_when "$QG_GRANT_EXPIRES")" "$left"
    else
        printf 'no grant\n'
    fi
}
