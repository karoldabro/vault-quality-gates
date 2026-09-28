#!/usr/bin/env bash
# Commit identity shared by bin/guard.sh and the git hook templates: the parents of the
# commit being made, the pass-record key, and gate configuration read from HEAD.
# Sourced; defines functions only. File formats: vault/architecture/guard-file-formats.md.

guard_common_dir() { git rev-parse --path-format=absolute --git-common-dir; }

guard_empty_tree() { git hash-object -t tree /dev/null; }

# guard_commit_parents -> the parents the commit being made will get, one per line, HEAD
# first. `git merge` has not written MERGE_HEAD when it runs pre-merge-commit; it exports
# one GITHEAD_<sha> per merged head instead. Prints nothing on a first commit.
guard_commit_parents() {
    local head merge_head
    head="$(git rev-parse -q --verify HEAD 2>/dev/null)" || return 0
    merge_head="$(git rev-parse --git-path MERGE_HEAD)"
    {
        printf '%s\n' "$head"
        [ -r "$merge_head" ] && cat "$merge_head"
        compgen -e | sed -n 's/^GITHEAD_\([0-9a-f]\{40,64\}\)$/\1/p'
    } | awk 'NF && !seen[$1]++ { print $1 }'
}

# guard_default_bases -> the parents space-separated, or the empty tree on a first commit.
guard_default_bases() {
    local parents
    parents="$(guard_commit_parents | tr '\n' ' ')"
    parents="${parents% }"
    if [ -n "$parents" ]; then printf '%s' "$parents"; else guard_empty_tree; fi
}

guard_sha1() {
    if command -v sha1sum >/dev/null 2>&1; then sha1sum | cut -c1-40
    else shasum -a 1 | cut -c1-40; fi
}

# guard_pass_key <tree> [<parent>...] -> SHA-1 of "<tree> <parent> <parent>...". Parents
# are sorted, because pre-merge-commit sees merged heads in environment order.
guard_pass_key() {
    local tree="$1"; shift
    { printf '%s' "$tree"; printf '%s\n' "$@" | awk 'NF' | sort -u | awk '{ printf " %s", $1 }'; } | guard_sha1
}

guard_pass_key_of_commit() {
    local tree parents
    tree="$(git rev-parse -q --verify "${1}^{tree}")" || return 2
    parents="$(git rev-list --parents -n 1 "$1" | cut -s -d' ' -f2-)"
    # shellcheck disable=SC2086
    guard_pass_key "$tree" $parents
}

# guard_pass_key_of_index -> the key of the commit the index would become now.
guard_pass_key_of_index() {
    local tree
    tree="$(git write-tree 2>/dev/null)" || return 2
    # shellcheck disable=SC2046
    guard_pass_key "$tree" $(guard_commit_parents)
}

guard_pass_file() { printf '%s/guard-pass/%s' "$(guard_common_dir)" "$1"; }

guard_pass_write() {  # guard_pass_write <key> <content: ok | override <reason>>
    local file; file="$(guard_pass_file "$1")"
    mkdir -p "$(dirname "$file")" && printf '%s\n' "$2" > "$file"
}

guard_pass_read() { cat "$(guard_pass_file "$1")" 2>/dev/null; }

# guard_config_show <path> -> the file as committed at HEAD; from the index on a first
# commit, when no HEAD exists. The gate never reads its configuration from the working tree.
guard_config_show() {
    if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
        git show "HEAD:$1" 2>/dev/null
    else
        git show ":$1" 2>/dev/null
    fi
}

# guard_vault_key <key> -> the value of a flat `key: value` line in the committed VAULT.md.
# Exit 1 when the key is absent. Prettier escapes `*` as `\*`; the backslashes are removed.
guard_vault_key() {
    local line
    line="$(guard_config_show VAULT.md | grep -m1 "^${1}:")" || return 1
    line="${line#*:}"
    printf '%s' "${line//\\/}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# guard_path_matches <path> <prefix>... -> 0 when the path equals a prefix or lies under it.
guard_path_matches() {
    local path="$1" prefix; shift
    for prefix in "$@"; do
        prefix="${prefix%/}"
        [ -n "$prefix" ] || continue
        if [ "$path" = "$prefix" ] || [[ "$path" == "$prefix"/* ]]; then return 0; fi
    done
    return 1
}
