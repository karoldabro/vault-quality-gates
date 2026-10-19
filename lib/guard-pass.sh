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

# guard_baseline_base <local sha> <remote sha> -> the commit whose quality/baseline.tsv a push may
# not loosen: the remote ref's old tip when git has it, else the parent of the oldest pushed
# commit on no remote (the fork point of a new branch), else the pushed commit itself.
guard_baseline_base() {
    local oldest
    if [ -n "${2:-}" ] && [ "$2" != '0000000000000000000000000000000000000000' ] && git cat-file -e "${2}^{commit}" 2>/dev/null; then
        printf '%s' "$2"; return
    fi
    oldest="$(git rev-list --topo-order --reverse "$1" --not --remotes 2>/dev/null | head -1)"
    if [ -n "$oldest" ] && git rev-parse -q --verify "${oldest}^" >/dev/null 2>&1; then
        git rev-parse "${oldest}^"
    else
        printf '%s' "$1"
    fi
}

# Push pass record: `qg run push --ref <ref>` writes one after a full pass, and `pre-push` accepts it
# instead of measuring again. Contract: vault/architecture/guard-push-pass.md.
GUARD_PUSH_PASS_TTL=3600

# guard_engine_digest -> SHA-1 over "<path> <x|-> <blob>" of every file the engine runs from, so an
# edit, a move or a lost exec bit under bin/, lib/ or drivers/ invalidates every record.
guard_engine_digest() {
    (
        set -o pipefail
        cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
        find bin lib drivers -type f | LC_ALL=C sort | while IFS= read -r f; do
            if [ -x "$f" ]; then m=x; else m=-; fi
            printf '%s %s %s\n' "$f" "$m" "$(git hash-object --no-filters -- "$f")" || exit 2
        done | guard_sha1
    )
}

# guard_push_pass_key <remote ref> <sha> <row base> <baseline base> -> the record key.
guard_push_pass_key() {
    local digest
    digest="$(guard_engine_digest)" || return 2
    printf 'push %s %s %s %s %s' "$1" "$2" "$3" "$4" "$digest" | guard_sha1
}

guard_push_pass_dir() { printf '%s/guard-pass/push' "$(guard_common_dir)"; }

# guard_push_pass_write <key> -> writes "ok <epoch>" through a temp file, after deleting expired records.
guard_push_pass_write() {
    local dir tmp
    dir="$(guard_push_pass_dir)"
    mkdir -p "$dir" || return 1
    find "$dir" -type f -mmin +$((GUARD_PUSH_PASS_TTL / 60)) -delete 2>/dev/null
    tmp="$(mktemp "${dir}/.write.XXXXXX")" || return 1
    if printf 'ok %s\n' "$(date +%s)" > "$tmp" && mv -f "$tmp" "${dir}/$1"; then return 0; fi
    rm -f "$tmp"; return 1
}

# guard_push_pass_valid <key> -> minutes since the pass. Exit 1 when the record is absent, malformed,
# dated in the future or older than GUARD_PUSH_PASS_TTL.
guard_push_pass_valid() {
    local line epoch now
    line="$(cat "$(guard_push_pass_dir)/$1" 2>/dev/null)" || return 1
    [[ "$line" =~ ^ok\ ([0-9]{1,12})$ ]] || return 1
    epoch="${BASH_REMATCH[1]}"; now="$(date +%s)"
    [ "$epoch" -le "$now" ] && [ $((now - epoch)) -le "$GUARD_PUSH_PASS_TTL" ] || return 1
    printf '%s' "$(((now - epoch) / 60))"
}

# guard_config_show <path> -> the file as committed at GUARD_CONFIG_AT, else at HEAD; from
# the index on a first commit, when no HEAD exists. The gate never reads its configuration
# from the working tree. guard_gate sets GUARD_CONFIG_AT to GUARD_CONFIG_PIN (the caller's GUARD_CONFIG_REV) when it
# pins it (the agent factory pins its build's base commit), else to the judged commit's
# first parent, so a commit cannot loosen the configuration that judges it.
guard_config_show() {
    if [ -n "${GUARD_CONFIG_AT:-}" ]; then
        git show "${GUARD_CONFIG_AT}:$1" 2>/dev/null
    elif git rev-parse -q --verify HEAD >/dev/null 2>&1; then
        git show "HEAD:$1" 2>/dev/null
    else
        git show ":$1" 2>/dev/null
    fi
}

# shellcheck source=qg-config.sh
. "$(dirname "${BASH_SOURCE[0]}")/qg-config.sh"

# guard_vault_key <key> -> the committed value of a gate key (lib/qg-config.sh). Exit 1 when absent.
guard_vault_key() { qg_config_key "$1"; }

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
