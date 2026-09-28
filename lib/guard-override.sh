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

guard_override_allowed() {
    local reason="${1-${QG_SKIP_REASON-}}"
    [[ "$reason" =~ [^[:space:]] ]] || return 1
    [ -z "${CLAUDECODE+set}" ] || return 1
    [ -z "${AI_AGENT+set}" ] || return 1
    { : < /dev/tty; } 2>/dev/null || return 1
    return 0
}

_guard_override_field() {
    printf '%s' "$1" | tr '\t\n\r' '   '
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
        "$(_guard_override_field "${QG_SKIP_REASON-}")" \
        "$(_guard_override_field "${1-}")" >> "$common/guard-bypass.log"
}
