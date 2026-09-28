#!/usr/bin/env bash
# Bodies of the installed git hooks. Sourced by templates/git-hooks/*; defines functions only.
# Each hook sets GUARD to the absolute bin/guard.sh before sourcing this file.

. "$(dirname "${BASH_SOURCE[0]}")/guard-pass.sh"

# guard_override_used <what> -> 0 when a human override is honoured; logs it. Missing
# lib/guard-override.sh means no override.
guard_override_used() {
    local lib; lib="$(dirname "${BASH_SOURCE[0]}")/guard-override.sh"
    [ -r "$lib" ] || return 1
    # shellcheck source=guard-override.sh
    . "$lib" || return 1
    guard_override_allowed || return 1
    guard_override_log "$1"
    printf 'vault-guard: override honoured and logged: %s\n' "${QG_SKIP_REASON}" >&2
    return 0
}

# guard_commit_hook <hook name> — pre-commit, pre-merge-commit and pre-applypatch. Runs the
# gate on the index git is about to commit. Exit 0 and a pass record on a clean gate or an
# honoured override; exit 1 otherwise, including when guard.sh is missing or exits 2.
guard_commit_hook() {
    local hook="$1" rc=0 key
    if [ ! -x "$GUARD" ]; then
        printf 'vault-guard: %s is missing or not executable; %s refused rather than passed unmeasured\n' "$GUARD" "$hook" >&2
        return 1
    fi
    "$GUARD" commit || rc=$?
    key="$(guard_pass_key_of_index)" || { printf 'vault-guard: cannot read the index tree\n' >&2; return 1; }
    if [ "$rc" -eq 0 ]; then
        guard_pass_write "$key" ok || printf 'vault-guard: pass record not written; pre-push will ask for guard.sh verify\n' >&2
        return 0
    fi
    if guard_override_used "${hook}: guard.sh commit exited ${rc}"; then
        guard_pass_write "$key" "override ${QG_SKIP_REASON}"
        return 0
    fi
    return 1
}

# guard_post_rewrite <how> — after `commit --amend`, pre-commit measured the new tree against
# the old commit, not against the new commit's own parents, so its pass proves nothing about
# the new commit. `guard.sh verify` measures each amended commit against its parents and
# writes the record only when that passes. A rebase records nothing: its commits need verify.
guard_post_rewrite() {
    local old new rest
    local -a amended=()
    if [ "${1:-}" != amend ]; then cat >/dev/null; return 0; fi
    while read -r old new rest; do
        [ -n "${new:-}" ] && amended+=("${new}^!")
    done
    [ "${#amended[@]}" -gt 0 ] || return 0
    if [ ! -x "$GUARD" ]; then
        printf 'vault-guard: %s is missing; the amended commit has no pass record until guard.sh verify\n' "$GUARD" >&2
        return 0
    fi
    "$GUARD" verify "${amended[@]}" >&2 || printf 'vault-guard: the amended commit did not pass; pre-push will refuse it\n' >&2
    return 0
}

# guard_push_unrecorded <local sha>... -> prints each commit not on any remote that has no
# pass record. Exit 2 when a sha cannot be listed.
guard_push_unrecorded() {
    local sha c list rc=0 out=''
    local -A seen=()
    for sha in "$@"; do
        [ -z "${seen[$sha]:-}" ] || continue
        seen[$sha]=1
        list="$(git rev-list "$sha" --not --remotes 2>/dev/null)" || { out+="${sha}"$'\n'; rc=2; continue; }
        for c in $list; do
            [ -f "$(guard_pass_file "$(guard_pass_key_of_commit "$c")")" ] || out+="${c}"$'\n'
        done
    done
    printf '%s' "$out" | awk 'NF && !seen[$0]++'
    return "$rc"
}

# guard_print_bypass_log — prints guard-bypass.log lines not printed by an earlier push.
guard_print_bypass_log() {
    local common log mark done_n total
    common="$(guard_common_dir)"; log="${common}/guard-bypass.log"; mark="${common}/guard-bypass.printed"
    [ -r "$log" ] || return 0
    total="$(wc -l < "$log")"; done_n="$(cat "$mark" 2>/dev/null || printf 0)"
    case "$done_n" in ''|*[!0-9]*) done_n=0 ;; esac
    [ "$total" -lt "$done_n" ] && done_n=0
    if [ "$total" -gt "$done_n" ]; then
        printf 'vault-guard: overrides logged since the last push (%s):\n' "$log" >&2
        tail -n "$((total - done_n))" "$log" | sed 's/^/  /' >&2
    fi
    printf '%s\n' "$total" > "$mark"
}
