#!/usr/bin/env bash
# guard_hooks install|remove|status — writes the templates into .git/hooks.
#
# Every body written carries the marker lines below. Anything else in a hook file
# was written by someone else, and this refuses to overwrite it.

GUARD_MARK_START='# vault-guard-start'
GUARD_MARK_END='# vault-guard-end'

guard_hooks_dir() { printf '%s' "$(git rev-parse --git-path hooks)"; }

guard_hooks_is_ours() {
    [ -f "$1" ] && grep -qF "$GUARD_MARK_START" "$1"
}

guard_hooks_install() {
    local dir name src dst
    dir="$(guard_hooks_dir)"
    mkdir -p "$dir" || return 2

    for name in pre-commit pre-push; do
        src="${GUARD_LIB_DIR}/../templates/git-hooks/${name}"
        dst="${dir}/${name}"
        if [ -f "$dst" ] && ! guard_hooks_is_ours "$dst"; then
            guard_err "guard: ${dst} exists and was not written here — leaving it alone"
            continue
        fi
        sed "s|__GUARD_SH__|${GUARD_LIB_DIR}/../bin/guard.sh|g" "$src" > "$dst" || return 2
        chmod +x "$dst"
        printf 'installed %s\n' "$dst"
    done

    local configured; configured="$(git config core.hooksPath 2>/dev/null)"
    if [ -n "$configured" ] && [ "$configured" != "$dir" ]; then
        guard_err "guard: core.hooksPath is ${configured}, so ${dir} is not what git runs"
        return 1
    fi
}

guard_hooks_remove() {
    local dir name dst; dir="$(guard_hooks_dir)"
    for name in pre-commit pre-push; do
        dst="${dir}/${name}"
        if guard_hooks_is_ours "$dst"; then rm -f "$dst"; printf 'removed %s\n' "$dst"; fi
    done
}

guard_hooks_status() {
    local dir name dst; dir="$(guard_hooks_dir)"
    for name in pre-commit pre-push; do
        dst="${dir}/${name}"
        if guard_hooks_is_ours "$dst"; then printf '%-12s installed  %s\n' "$name" "$dst"
        elif [ -f "$dst" ];        then printf '%-12s FOREIGN    %s\n' "$name" "$dst"
        else                            printf '%-12s absent\n' "$name"; fi
    done
    printf '%-12s %s\n' 'hooksPath' "$(git config core.hooksPath || printf '(default)')"
}

guard_hooks() {
    case "${1:-status}" in
        install) guard_hooks_install ;;
        remove)  guard_hooks_remove ;;
        status)  guard_hooks_status ;;
        *) guard_err 'usage: guard.sh hooks install|remove|status'; return 2 ;;
    esac
}
