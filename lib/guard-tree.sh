#!/usr/bin/env bash
# The measured copy of a tree. guard_tree_sync makes <dir> hold exactly <tree-ish>: every
# tracked path with its content and mode, and nothing else. It uses the private index
# <dir>.index and never touches the operator's index or working tree.
# Sourced; defines functions only.

guard_tree_git() {  # guard_tree_git <dir> <git args...>
    local dir="$1" gitdir; shift
    gitdir="$(git rev-parse --path-format=absolute --git-common-dir)" || return 2
    # Run from inside <dir>: `git clean` resolves paths against the current directory,
    # and from the repo root it would list the operator's own files.
    (cd "$dir" && GIT_DIR="$gitdir" GIT_WORK_TREE="$dir" GIT_INDEX_FILE="${dir}.index" git "$@") >/dev/null 2>&1
}

# guard_tree_sync <tree-ish> <dir> -> 0 synced, 2 could not sync. Also creates the
# sibling guard-cache directory the tools keep their result caches in.
guard_tree_sync() {
    local treeish="$1" dir="$2"
    mkdir -p "$dir" "$(dirname "$dir")/guard-cache" || return 2
    dir="$(cd "$dir" && pwd -P)" || return 2
    if [ ! -f "${dir}.index" ] || ! guard_tree_git "$dir" read-tree -u --reset "$treeish"; then
        # A lost private index cannot say which files it wrote, so a deleted file would
        # survive. Wipe and rebuild instead.
        rm -rf "$dir" "${dir}.index" && mkdir -p "$dir" || return 2
        guard_tree_git "$dir" read-tree -u --reset "$treeish" || return 2
    fi
    guard_tree_git "$dir" clean -fdxq || return 2
}
