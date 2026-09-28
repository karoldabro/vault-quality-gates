#!/usr/bin/env bash
# The commit gate: `guard.sh commit` and `guard.sh verify`. Sourced by bin/guard.sh after
# guard-metrics.sh; defines functions only.
#
# The gate reads quality/checks.tsv, quality/rules.tsv, quality/baseline.tsv and the
# VAULT.md keys from HEAD, never from the working tree, so an edit cannot loosen the gate
# that judges it. A row whose command or artifact names {{tree}} or {{cache}} measures a
# copy of the target tree at <git-common-dir>/guard-tree, held under a lock for the run.

. "${GUARD_LIB_DIR}/guard-pass.sh"
. "${GUARD_LIB_DIR}/guard-tree.sh"
. "${GUARD_LIB_DIR}/guard-diff.sh"

guard_is_tree_row() { case "$1" in *'{{tree}}'*|*'{{cache}}'*) return 0 ;; esac; return 1; }

guard_gate_config() {  # guard_gate_config <dir> -> 2 naming the file HEAD lacks
    local f
    for f in checks rules; do
        guard_config_show "quality/${f}.tsv" > "$1/${f}.tsv" || {
            guard_err "guard: HEAD has no quality/${f}.tsv; the commit gate reads its configuration from HEAD"
            return 2
        }
    done
    guard_config_show quality/baseline.tsv > "$1/baseline.tsv" || rm -f "$1/baseline.tsv"
}

# guard_commit_paths_hit <base> <target> -> 0 when a changed path matches guard_commit_paths.
# An absent or empty key gates every path.
guard_commit_paths_hit() {
    local value path prefixes
    value="$(guard_vault_key guard_commit_paths)" && [ -n "$value" ] || return 0
    read -ra prefixes <<<"$value"
    while IFS= read -r path; do
        guard_path_matches "$path" "${prefixes[@]}" && return 0
    done < <(guard_touched_paths "$1" "$2")
    return 1
}

# guard_gate_tree <target> -> sets GUARD_TREE_STATE (ok|fail) and GUARD_TREE_WHY. Takes the
# lock on fd 9, which the caller releases.
guard_gate_tree() {
    local common treeish wait="${GUARD_LOCK_WAIT:-120}"
    common="$(guard_common_dir)"
    export GUARD_TREE_DIR="${common}/guard-tree" GUARD_CACHE_DIR="${common}/guard-cache"
    GUARD_TREE_STATE=fail
    if ! command -v flock >/dev/null 2>&1; then GUARD_TREE_WHY='flock is not installed'; return; fi
    exec 9>"${common}/guard-tree.lock"
    local waited=0
    # flock -n and a poll, not flock -w: busybox flock has no -w.
    until flock -n 9 2>/dev/null; do
        [ "$waited" -lt "$wait" ] || { GUARD_TREE_WHY="guard-tree lock still held after ${wait} s"; return; }
        sleep 1; waited=$((waited + 1))
    done
    if [ "$1" = ':index' ]; then treeish="$(git write-tree 2>/dev/null)"; else treeish="$1"; fi
    if [ -z "$treeish" ] || ! guard_tree_sync "$treeish" "$GUARD_TREE_DIR"; then
        GUARD_TREE_WHY="cannot copy ${1} into ${GUARD_TREE_DIR}"; return
    fi
    GUARD_TREE_STATE=ok
}

# guard_gate <target> <bases> -> 0 clean, 1 worse, 2 unmeasurable. Prints the refusal.
guard_gate() {
    local target="$1" bases="$2" cfg first rc worst=0 row id scope kind command artifact
    first="${bases%% *}"
    cfg="$(mktemp -d)"
    guard_gate_config "$cfg" && guard_load_checks "$cfg/checks.tsv" || { rm -rf "$cfg"; return 2; }
    guard_changed_files "$first" "$target" > "$cfg/files"
    export GUARD_BASES="$bases" GUARD_TARGET="$target" GUARD_BIN_DIR
    GUARD_RESULTS=()

    GUARD_TREE_STATE=skip GUARD_TREE_WHY='no changed path matches guard_commit_paths'
    for row in "${GUARD_ROWS[@]}"; do
        IFS=$'\t' read -r _ scope _ command _ artifact _ _ _ <<<"$row"
        case "$scope" in commit|both) guard_is_tree_row "$command$artifact" || continue ;; *) continue ;; esac
        guard_commit_paths_hit "$first" "$target" && guard_gate_tree "$target"
        break
    done

    cd "$REPO_ROOT" || return 2
    for row in "${GUARD_ROWS[@]}"; do
        IFS=$'\t' read -r id scope kind command _ artifact _ _ _ <<<"$row"
        case "$scope" in commit|both) ;; *) [ "$kind" = 'absent' ] || continue ;; esac
        if [ "$kind" != 'absent' ] && guard_is_tree_row "$command$artifact" && [ "$GUARD_TREE_STATE" != ok ]; then
            if [ "$GUARD_TREE_STATE" = skip ]; then GUARD_RESULTS+=("${id}|-|-|skipped|${GUARD_TREE_WHY}")
            else GUARD_RESULTS+=("${id}|-|-|unmeasurable|${GUARD_TREE_WHY}"); worst=2; fi
            continue
        fi
        rc=0
        guard_run_row "$row" "$cfg/baseline.tsv" "$first" "$cfg/files" || rc=$?
        [ "$rc" -gt "$worst" ] && worst="$rc"
    done

    guard_render_report
    # The refusal reads the reports inside the tree; the lock stays held until it has.
    [ "$worst" -eq 0 ] || guard_commit_refusal "$target" "$cfg"
    exec 9>&-
    rm -rf "$cfg"
    return "$worst"
}

guard_commit_refusal() {  # guard_commit_refusal <target> <config dir>
    local target="$1" cfg="$2" line id value base status detail ids='' prc=0
    [ "$target" = ':index' ] && target='the staged commit'
    printf '\nvault-guard: %s refused\n\n' "$target" >&2
    for line in "${GUARD_RESULTS[@]:-}"; do
        IFS='|' read -r id value base status detail <<<"$line"
        case "$status" in
            worse)        printf '  %-20s measured %s (%s)\n' "$id" "$value" "$detail" >&2; ids+="$id " ;;
            unmeasurable) printf '  %-20s could not measure: %s\n' "$id" "$detail" >&2; ids+="$id " ;;
        esac
    done
    printf '\n' >&2
    "${GUARD_BIN_DIR}/guard-report-errors.sh" --rows "${ids% }" --tree "${GUARD_TREE_DIR:--}" \
        --map "$cfg/rules.tsv" --checks "$cfg/checks.tsv" --bases "$GUARD_BASES" --target "$GUARD_TARGET" >&2 || prc=$?
    [ "$prc" -eq 0 ] || printf 'vault-guard: quality/rules.tsv is unreadable; the lines above carry no catalog pointer\n' >&2
    printf '\nFix the code. Never bypass the hook; only a human at a terminal may override once, with QG_SKIP_REASON.\n\n' >&2
}

# guard_verify <rev-list args...> -> measures each commit against its own parents and writes
# its pass record when it passes. Exit: the worst commit's result.
guard_verify() {
    local commits c parents worst=0 rc
    commits="$(git rev-list --reverse "$@")" || { guard_err "guard: verify: bad range $*"; return 2; }
    for c in $commits; do
        parents="$(git rev-list --parents -n 1 "$c" | cut -s -d' ' -f2-)"
        rc=0
        guard_gate "$c" "${parents:-$(guard_empty_tree)}" || rc=$?
        if [ "$rc" -eq 0 ]; then
            guard_pass_write "$(guard_pass_key_of_commit "$c")" ok && printf 'verified %s\n' "$c"
        else
            printf 'refused  %s\n' "$c"
        fi
        [ "$rc" -gt "$worst" ] && worst="$rc"
    done
    return "$worst"
}
