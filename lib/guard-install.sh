#!/usr/bin/env bash
# guard_hooks install [--claude [--user [--config-dir <dir>]...]] | remove [--claude [--user ...]] |
# status [--user [--config-dir <dir>]...]
#
# install writes the templates into .git/hooks and, with --claude, the three guard entries into
# <repo>/.claude/settings.json. A repo's own pre-commit step (lint-staged, say) goes in
# .git/hooks/pre-commit.user, which the pre-commit template runs first and this never touches.
# install --claude --user writes the two entries into ~/.claude/settings.json and each
# <dir>/settings.json instead, pointing at the main worktree of this plugin, and writes the machine
# tool-path file (lib/qg-toolpath.sh) from QG_CALLER_PATH, which only bin/qg sets.
#
# The two entries are the hooks whose command's file name is guard-bash.sh or guard-edit.sh.
# Install replaces every such entry, whatever its folder, and drops a Stop entry for guard-stop.sh
# an older install wrote; remove --claude removes exactly those and nothing else. A settings file
# that is not valid JSON is left unchanged, exit 2.
#
# Every git hook body written carries the marker lines below. Anything else in a hook file
# was written by someone else, and this refuses to overwrite it.

GUARD_MARK_START='# vault-guard-start'
# shellcheck disable=SC2034  # the closing marker every template carries; doctor and readers match it
GUARD_MARK_END='# vault-guard-end'
GUARD_HOOK_NAMES='pre-commit pre-merge-commit pre-applypatch pre-push post-rewrite'
GUARD_CLAUDE_NAMES='guard-bash.sh guard-edit.sh'

# shellcheck source=guard-pass.sh
. "${GUARD_LIB_DIR}/guard-pass.sh"
# shellcheck source=qg-toolpath.sh
. "${GUARD_LIB_DIR}/qg-toolpath.sh"

guard_hooks_dir() { printf '%s' "$(git rev-parse --git-path hooks)"; }
guard_plugin_dir() { (cd "${GUARD_LIB_DIR}/.." && pwd -P); }

# guard_main_worktree -> the main worktree of the plugin checkout, which the user-level entries
# name: the folder holding the git common dir that also holds the tool-path file; the plugin folder
# itself when it is no git checkout.
guard_main_worktree() {
    local common
    common="$(qg_tool_path_file)" && common="${common%/qg-tool-path}"
    if [ "${common##*/}" = .git ] && [ -d "${common%/.git}" ]; then (cd -P "${common%/.git}" && pwd -P)
    else guard_plugin_dir; fi
}

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

# The jq definitions every settings edit shares. ours: a hook whose command's file name is one of
# the two guards or the retired guard-stop.sh. strip: drops those hooks, then a group they emptied, then an event list and a
# .hooks object they emptied; anything else stays as it was.
GUARD_JQ_DEFS='
def ours: ((.command? // "") | tostring | test("(^|/)guard-(bash|edit|stop)\\.sh([\\s\"'"'"']|$)"));
def strip1($k):
    if (.hooks? | type) == "object" and (.hooks[$k] | type) == "array" and (.hooks[$k] | length) > 0 then
        .hooks[$k] |= map(if type == "object" and any(.hooks[]?; ours)
                          then (.hooks |= map(select(ours | not))) | select(.hooks | length > 0) else . end)
        | if .hooks[$k] == [] then del(.hooks[$k]) else . end
    else . end;
def strip: (.hooks? // null) as $before | strip1("PreToolUse") | strip1("Stop")
    | if .hooks == {} and $before != {} then del(.hooks) else . end;
def add($bash; $edit):
    .hooks //= {} | .hooks.PreToolUse //= []
    | .hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: $bash}]},
                            {matcher: "Edit|Write|MultiEdit|NotebookEdit", hooks: [{type: "command", command: $edit}]}];
'

# guard_claude_valid <file> -> 0 when the file is absent, empty or a JSON object.
guard_claude_valid() {
    [ -s "$1" ] || return 0
    jq -e 'type == "object"' "$1" >/dev/null 2>&1
}

# guard_claude_render <install|remove> <file> <plugin> <out> -> writes the edited settings into
# <out>, touching nothing else; exit 2 when <file> is not a JSON object. An absent or empty file
# reads as {}.
guard_claude_render() {
    local how="$1" file="$2" hooks="${3}/templates/claude-hooks" out="$4" prog="${GUARD_JQ_DEFS} strip"
    command -v jq >/dev/null 2>&1 || { guard_err 'guard: --claude needs jq'; return 2; }
    guard_claude_valid "$file" || { guard_err "guard: ${file} is not valid JSON — leaving every target alone"; return 2; }
    [ "$how" = remove ] || prog+=" | add(\$bash; \$edit)"
    { if [ -s "$file" ]; then cat "$file"; else printf '{}\n'; fi; } \
        | jq --arg bash "${hooks}/guard-bash.sh" --arg edit "${hooks}/guard-edit.sh" "$prog" > "$out" || { guard_err "guard: ${file} is not valid JSON — leaving every target alone"; return 2; }
}

# guard_claude_apply <install|remove> <file> <rendered> -> writes the rendered settings over the
# file. A file whose JSON value did not change keeps its bytes; remove never creates a file.
guard_claude_apply() {
    local how="$1" file="$2" new="$3"
    if [ -s "$file" ]; then
        [ "$(jq -cS . "$new")" = "$(jq -cS . "$file")" ] || cat "$new" > "$file" || return 2
    elif [ "$how" = install ]; then
        mkdir -p "$(dirname "$file")" && cat "$new" > "$file" || return 2
    fi
    if [ "$how" = remove ]; then printf 'removed guard-bash.sh and guard-edit.sh from %s\n' "$file"
    else printf 'installed PreToolUse guard-bash.sh and guard-edit.sh into %s\n' "$file"; fi
}

# guard_claude_edit <install|remove> <plugin> <file>... -> renders every file first, then writes
# them all, so an invalid target leaves every target unchanged; exit 2 then.
guard_claude_edit() {
    local how="$1" plugin="$2" dir file i=0 rc=0
    shift 2
    dir="$(mktemp -d)"
    for file in "$@"; do
        i=$((i + 1))
        [ "$how" = install ] || [ -s "$file" ] || continue
        guard_claude_render "$how" "$file" "$plugin" "${dir}/${i}" || { rm -rf "$dir"; return 2; }
    done
    i=0
    for file in "$@"; do
        i=$((i + 1))
        [ -e "${dir}/${i}" ] || continue
        guard_claude_apply "$how" "$file" "${dir}/${i}" || rc=2
    done
    rm -rf "$dir"
    return "$rc"
}

# Repo-level entries: the hooks run in place from the plugin checkout, never copied.
guard_hooks_install_claude() { guard_claude_edit install "$(guard_plugin_dir)" "$(guard_claude_settings)"; }

# guard_user_targets <config dir>... -> ~/.claude/settings.json and <dir>/settings.json, once each.
guard_user_targets() {
    local d
    local -A seen=()
    for d in "${HOME}/.claude" "$@"; do
        d="${d%/}"
        [ -z "${seen[$d]:-}" ] || continue
        seen[$d]=1
        printf '%s/settings.json\n' "$d"
    done
}

# guard_user_linked -> 0 when the plugin checkout is a linked worktree, or no git checkout at all.
guard_user_linked() {
    local plugin dir common
    plugin="$(guard_plugin_dir)"
    dir="$(qg_toolpath_git -C "$plugin" rev-parse --path-format=absolute --git-dir)" || return 0
    common="$(qg_toolpath_git -C "$plugin" rev-parse --path-format=absolute --git-common-dir)" || return 0
    [ "$dir" != "$common" ]
}

# Renders every settings target first, writes them all, and writes the tool-path file last, so a
# refusal leaves every file as it was.
guard_hooks_install_user() {
    local tp entries
    local -a targets
    if guard_user_linked; then
        guard_err "guard: $(guard_plugin_dir) is a linked worktree or no git checkout; run qg hooks install --claude --user from the main worktree"
        return 2
    fi
    [ -n "${QG_CALLER_PATH:-}" ] || { guard_err 'guard: install --claude --user reads your PATH through qg; run qg hooks install --claude --user'; return 2; }
    tp="$(qg_tool_path_file)" || { guard_err 'guard: cannot find the git directory of the plugin checkout'; return 2; }
    mapfile -t targets < <(guard_user_targets "$@")
    guard_claude_edit install "$(guard_main_worktree)" "${targets[@]}" || return $?
    entries="$(qg_tool_path_from "$QG_CALLER_PATH")"
    if [ -n "$entries" ]; then printf '%s\n' "$entries" > "$tp"; else : > "$tp"; fi || return 2
    printf 'wrote %s:\n%s\n' "$tp" "${entries:-  (no pnpm, node, php, composer, docker or hugo on your PATH)}"
}

guard_hooks_remove_user() {
    local -a targets
    mapfile -t targets < <(guard_user_targets "$@")
    guard_claude_edit remove "$(guard_main_worktree)" "${targets[@]}"
}

# guard_claude_entry_state <settings file> <guard file name> <plugin> -> installed or absent. The
# one predicate for "the entry is installed": a PreToolUse hook whose command is exactly
# <plugin>/templates/claude-hooks/<name>, and that file exists and is executable.
guard_claude_entry_state() {
    local cmd="${3}/templates/claude-hooks/${2}" event=PreToolUse
    if [ -x "$cmd" ] && jq -e --arg c "$cmd" --arg e "$event" \
        'any(.hooks[$e][]?; any(.hooks[]?; .command == $c))' "$1" >/dev/null 2>&1; then
        printf 'installed'
    else
        printf 'absent'
    fi
}

# One line `installed|absent <entry> <file>` per entry and target: ~/.claude, ~/.claude-factory
# when it exists, and each --config-dir given.
guard_hooks_status_user() {
    local plugin file name
    local -a dirs=("$@")
    plugin="$(guard_main_worktree)"
    [ -d "${HOME}/.claude-factory" ] && dirs=("${HOME}/.claude-factory" "${dirs[@]}")
    while IFS= read -r file; do
        for name in $GUARD_CLAUDE_NAMES; do
            printf '%s %s %s\n' "$(guard_claude_entry_state "$file" "$name" "$plugin")" "$name" "$file"
        done
    done < <(guard_user_targets "${dirs[@]}")
}

guard_hooks_remove() {
    local dir name dst; dir="$(guard_hooks_dir)"
    for name in $GUARD_HOOK_NAMES; do
        dst="${dir}/${name}"
        if guard_hooks_is_ours "$dst"; then rm -f "$dst"; printf 'removed %s\n' "$dst"; fi
    done
}

guard_hooks_status() {
    local dir name dst file; dir="$(guard_hooks_dir)"
    for name in $GUARD_HOOK_NAMES; do
        dst="${dir}/${name}"
        if guard_hooks_is_ours "$dst"; then printf '%-16s installed  %s\n' "$name" "$dst"
        elif [ -f "$dst" ];        then printf '%-16s FOREIGN    %s\n' "$name" "$dst"
        else                            printf '%-16s absent\n' "$name"; fi
    done
    printf '%-16s %s\n' 'hooksPath' "$(git config core.hooksPath || printf '(default)')"
    file="$(guard_claude_settings)"
    for name in $GUARD_CLAUDE_NAMES; do
        printf '%-16s %-10s %s\n' "${name%.sh}" "$(guard_claude_entry_state "$file" "$name" "$(guard_plugin_dir)")" "$file"
    done
}

guard_hooks_usage() {
    guard_err 'usage: guard.sh hooks install [--claude [--user [--config-dir <dir>]...]] | remove [--claude [--user ...]] | status [--user ...]'
    return 2
}

guard_hooks() {
    local sub="${1:-status}" claude='' user=''
    local -a dirs=()
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --claude) claude=1; shift ;;
            --user)   user=1; shift ;;
            --config-dir) [ -n "${2:-}" ] || { guard_hooks_usage; return 2; }; dirs+=("$2"); shift 2 ;;
            *) guard_hooks_usage; return 2 ;;
        esac
    done
    if [ "${#dirs[@]}" -gt 0 ] && [ -z "$user" ]; then guard_hooks_usage; return 2; fi
    case "${sub}:${claude}:${user}" in
        install::)   guard_hooks_install ;;
        install:1:)  guard_hooks_install || return $?; guard_hooks_install_claude ;;
        install:1:1) guard_hooks_install_user "${dirs[@]}" ;;
        remove::)    guard_hooks_remove ;;
        remove:1:)   guard_claude_edit remove "$(guard_plugin_dir)" "$(guard_claude_settings)" ;;
        remove:1:1)  guard_hooks_remove_user "${dirs[@]}" ;;
        status::)    guard_hooks_status ;;
        status::1|status:1:1) guard_hooks_status_user "${dirs[@]}" ;;
        *) guard_hooks_usage ;;
    esac
}
