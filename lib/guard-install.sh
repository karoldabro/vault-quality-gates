#!/usr/bin/env bash
# guard_hooks install [--claude]|remove|status — writes the templates into .git/hooks and,
# with --claude, the two PreToolUse entries into <repo>/.claude/settings.json.
#
# Every body written carries the marker lines below. Anything else in a hook file
# was written by someone else, and this refuses to overwrite it.

GUARD_MARK_START='# vault-guard-start'
GUARD_MARK_END='# vault-guard-end'
GUARD_HOOK_NAMES='pre-commit pre-merge-commit pre-applypatch pre-push post-rewrite'

# shellcheck source=guard-pass.sh
. "${GUARD_LIB_DIR}/guard-pass.sh"

guard_hooks_dir() { printf '%s' "$(git rev-parse --git-path hooks)"; }
guard_plugin_dir() { (cd "${GUARD_LIB_DIR}/.." && pwd -P); }

guard_hooks_is_ours() {
    [ -f "$1" ] && grep -qF "$GUARD_MARK_START" "$1"
}

guard_hooks_install() {
    local dir name src dst plugin
    dir="$(guard_hooks_dir)"; plugin="$(guard_plugin_dir)"
    mkdir -p "$dir" || return 2

    for name in $GUARD_HOOK_NAMES; do
        src="${plugin}/templates/git-hooks/${name}"
        dst="${dir}/${name}"
        if [ -f "$dst" ] && ! guard_hooks_is_ours "$dst"; then
            guard_err "guard: ${dst} exists and was not written here — leaving it alone"
            continue
        fi
        sed "s|__GUARD_SH__|${plugin}/bin/guard.sh|g" "$src" > "$dst" || return 2
        chmod +x "$dst"
        printf 'installed %s\n' "$dst"
    done
    guard_hooks_record_local

    # `git config` exits 1 for a key that is not set, which is the normal case here.
    local configured; configured="$(git config core.hooksPath 2>/dev/null || true)"
    if [ -n "$configured" ] && [ "$configured" != "$dir" ]; then
        guard_err "guard: core.hooksPath is ${configured}, so ${dir} is not what git runs"
        return 1
    fi
}

# Commits made before the gate existed never passed it. Recording them once at install
# keeps pre-push from refusing the whole local history.
guard_hooks_record_local() {
    local c key n=0
    for c in $(git rev-list --branches --not --remotes 2>/dev/null); do
        key="$(guard_pass_key_of_commit "$c")" || continue
        [ -f "$(guard_pass_file "$key")" ] && continue
        guard_pass_write "$key" ok && n=$((n + 1))
    done
    printf 'recorded %d local commits not on any remote\n' "$n"
}

guard_claude_settings() { printf '%s/.claude/settings.json' "$(git rev-parse --show-toplevel)"; }

# Merges the two PreToolUse entries. The hooks run in place from the plugin checkout,
# never copied. An entry already naming the same command is kept, not duplicated; every
# other entry is left as it was.
guard_hooks_install_claude() {
    local file plugin tmp
    command -v jq >/dev/null 2>&1 || { guard_err 'guard: --claude needs jq'; return 2; }
    file="$(guard_claude_settings)"; plugin="$(guard_plugin_dir)"
    mkdir -p "$(dirname "$file")" || return 2
    [ -s "$file" ] || printf '{}\n' > "$file"
    tmp="$(mktemp)"
    jq --arg bash "${plugin}/templates/claude-hooks/guard-bash.sh" \
       --arg edit "${plugin}/templates/claude-hooks/guard-edit.sh" '
        def add($matcher; $cmd):
            if any(.hooks.PreToolUse[]?; any(.hooks[]?; .command == $cmd)) then .
            else .hooks.PreToolUse += [{matcher: $matcher, hooks: [{type: "command", command: $cmd}]}] end;
        .hooks //= {} | .hooks.PreToolUse //= []
        | add("Bash"; $bash) | add("Edit|Write|MultiEdit|NotebookEdit"; $edit)' "$file" > "$tmp" \
        || { rm -f "$tmp"; guard_err "guard: ${file} is not valid JSON — leaving it alone"; return 2; }
    mv "$tmp" "$file"
    printf 'installed PreToolUse guard-bash.sh and guard-edit.sh into %s\n' "$file"
}

guard_hooks_remove() {
    local dir name dst; dir="$(guard_hooks_dir)"
    for name in $GUARD_HOOK_NAMES; do
        dst="${dir}/${name}"
        if guard_hooks_is_ours "$dst"; then rm -f "$dst"; printf 'removed %s\n' "$dst"; fi
    done
}

guard_hooks_status() {
    local dir name dst file cmd; dir="$(guard_hooks_dir)"
    for name in $GUARD_HOOK_NAMES; do
        dst="${dir}/${name}"
        if guard_hooks_is_ours "$dst"; then printf '%-16s installed  %s\n' "$name" "$dst"
        elif [ -f "$dst" ];        then printf '%-16s FOREIGN    %s\n' "$name" "$dst"
        else                            printf '%-16s absent\n' "$name"; fi
    done
    printf '%-16s %s\n' 'hooksPath' "$(git config core.hooksPath || printf '(default)')"
    file="$(guard_claude_settings)"
    for name in guard-bash guard-edit; do
        cmd="$(guard_plugin_dir)/templates/claude-hooks/${name}.sh"
        if jq -e --arg c "$cmd" 'any(.hooks.PreToolUse[]?; any(.hooks[]?; .command == $c))' "$file" >/dev/null 2>&1; then
            printf '%-16s installed  %s\n' "$name" "$file"
        else
            printf '%-16s absent     %s\n' "$name" "$file"
        fi
    done
}

guard_hooks() {
    case "${1:-status}" in
        install)
            guard_hooks_install || return $?
            [ "${2:-}" != '--claude' ] || guard_hooks_install_claude ;;
        remove)  guard_hooks_remove ;;
        status)  guard_hooks_status ;;
        *) guard_err 'usage: guard.sh hooks install [--claude]|remove|status'; return 2 ;;
    esac
}
