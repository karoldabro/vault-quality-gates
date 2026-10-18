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

# guard_is_tree_row <row> -> 0 when the row measures the staged-tree copy: its command, artifact
# or args name {{tree}} or {{cache}}, or its driver's describe says needs_tree: true.
guard_is_tree_row() {
    case "$(guard_row_field "$1" command)$(guard_row_field "$1" artifact)$(guard_row_field "$1" args)" in
        *'{{tree}}'*|*'{{cache}}'*) return 0 ;;
    esac
    guard_driver_needs_tree "$(guard_row_field "$1" driver)"
}

# guard_is_commit_row <row> -> 0 when the commit gate runs the row.
guard_is_commit_row() { qg_row_runs_on "$(guard_row_field "$1" on)" commit; }

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
    local target="$1" bases="$2" cfg first rc worst=0 row id kind
    first="${bases%% *}"
    cfg="$(mktemp -d)"
    # The configuration that judges this commit: the pinned revision, else the judged
    # commit's first parent. `commit` judges the index, whose first parent is HEAD.
    if [ -n "${GUARD_CONFIG_PIN:-}" ]; then GUARD_CONFIG_AT="$GUARD_CONFIG_PIN"
    elif [ "$target" != ':index' ] && [ "$first" != "$(guard_empty_tree)" ]; then GUARD_CONFIG_AT="$first"
    else GUARD_CONFIG_AT=''; fi
    # A commit whose parent predates the gate has no rules map to be judged by, so it is not gated. The
    # decision reads the judged commit's first parent, never HEAD, so `verify` run from an old checkout
    # cannot pass a commit whose parent carries the gate. A first commit (no parent) is always gated.
    if [ "$first" != "$(guard_empty_tree)" ] && ! git cat-file -e "${first}:quality/rules.tsv" 2>/dev/null; then
        printf 'vault-guard: the parent commit has no quality/rules.tsv, so this branch predates the commit gate; not gated\n' >&2
        rm -rf "$cfg"; return 0
    fi
    guard_gate_config "$cfg" && guard_load_checks "$cfg/checks.tsv" || { rm -rf "$cfg"; return 2; }
    guard_changed_files "$first" "$target" > "$cfg/files"
    export GUARD_BASES="$bases" GUARD_TARGET="$target" GUARD_BIN_DIR
    GUARD_RESULTS=()

    GUARD_TREE_STATE=skip GUARD_TREE_WHY='no changed path matches guard_commit_paths'
    for row in "${GUARD_ROWS[@]}"; do
        [ "$(guard_row_field "$row" kind)" != absent ] && guard_is_commit_row "$row" && guard_is_tree_row "$row" || continue
        guard_commit_paths_hit "$first" "$target" && guard_gate_tree "$target"
        break
    done

    cd "$REPO_ROOT" || return 2
    for row in "${GUARD_ROWS[@]}"; do
        id="$(guard_row_field "$row" id)" kind="$(guard_row_field "$row" kind)"
        guard_is_commit_row "$row" || [ "$kind" = 'absent' ] || continue
        if [ "$kind" != 'absent' ] && guard_is_tree_row "$row" && [ "$GUARD_TREE_STATE" != ok ]; then
            if [ "$GUARD_TREE_STATE" = skip ]; then GUARD_RESULTS+=("${id}|-|-|skipped|${GUARD_TREE_WHY}")
            else GUARD_RESULTS+=("${id}|-|-|unmeasurable|${GUARD_TREE_WHY}"); worst=2; fi
            continue
        fi
        rc=0
        guard_run_row "$row" "$cfg/baseline.tsv" "$first" "$cfg/files" || rc=$?
        [ "$rc" -gt "$worst" ] && worst="$rc"
    done
    rc=0
    guard_gate_locked "$first" "$target" "$cfg" || rc=$?
    [ "$rc" -gt "$worst" ] && worst="$rc"

    guard_render_report
    # The warnings and the refusal read the reports inside the tree; the lock stays held until
    # they have.
    guard_commit_warnings "$worst" "$cfg"
    [ "$worst" -eq 0 ] || guard_commit_refusal "$target" "$cfg"
    exec 9>&-
    rm -rf "$cfg"
    return "$worst"
}

# guard_show <treeish> <path> -> the file at that tree; `:index` reads the staged copy.
guard_show() {
    if [ "$1" = ':index' ]; then git show ":$2" 2>/dev/null; else git show "$1:$2" 2>/dev/null; fi
}

# guard_gate_locked <base> <target> <config dir> -> 0, or 1 with a `worse` result. Built in,
# so no checks.tsv row can drop it: the target may not delete quality/checks.tsv or
# quality/rules.tsv, and may not loosen quality/baseline.tsv against the base
# (guard_baseline_diff). A first commit has nothing to loosen.
guard_gate_locked() {
    local base="$1" target="$2" cfg="$3" f gone='' lines rc=0 changed='' p
    [ "$base" != "$(guard_empty_tree)" ] || return 0
    # A repo driver or quality/config judges the next commit, so changing one is a human's
    # decision: refused here, passed only by a human override.
    while IFS= read -r -d '' p; do
        guard_path_matches "$p" quality/drivers quality/config && changed+="${p} "
    done < "$cfg/files"
    if [ -n "$changed" ]; then
        GUARD_RESULTS+=("gate-config-changed|1|0|worse|changes ${changed% }; only a human commits this, with an override"); rc=1
    fi
    # A staged checks.tsv that does not load would make every later commit unmeasurable.
    if guard_show "$target" quality/checks.tsv > "$cfg/checks.new"; then
        if ! ( guard_cfg_show() { guard_show "$target" "$1"; }
               guard_load_checks "$cfg/checks.new" ) 2> "$cfg/checks.err" >/dev/null; then
            GUARD_RESULTS+=("gate-config-invalid|1|0|worse|the staged quality/checks.tsv does not load: $(head -1 "$cfg/checks.err" | sed 's/^guard: //; s#[^ ]*/checks.new#quality/checks.tsv#' | tr '|' ' ')"); rc=1
        fi
    fi
    for f in quality/checks.tsv quality/rules.tsv; do
        if git cat-file -e "${base}:${f}" 2>/dev/null && ! guard_show "$target" "$f" >/dev/null; then gone+="${f} "; fi
    done
    if [ -n "$gone" ]; then
        GUARD_RESULTS+=("gate-config-deleted|1|0|worse|deletes ${gone% }"); rc=1
    fi
    if git cat-file -e "${base}:quality/baseline.tsv" 2>/dev/null; then
        git show "${base}:quality/baseline.tsv" > "$cfg/baseline.old"
        guard_show "$target" quality/baseline.tsv > "$cfg/baseline.new" || rm -f "$cfg/baseline.new"
        if [ ! -e "$cfg/baseline.new" ]; then
            GUARD_RESULTS+=("baseline-loosened|1|0|worse|deletes quality/baseline.tsv"); rc=1
        elif lines="$(guard_baseline_diff "$cfg/baseline.old" "$cfg/baseline.new" "$cfg/checks.tsv")"; then :
        else
            GUARD_RESULTS+=("baseline-loosened|$(wc -l <<<"$lines")|0|worse|$(awk -F'\t' '{ printf "%s%s %s -> %s (%s)", (NR > 1 ? "; " : ""), $1, $2, $3, $4 }' <<<"$lines")")
            rc=1
        fi
    fi
    return "$rc"
}

# guard_commit_warnings <worst> <config dir> -> prints the hits of every `warn` row above 0.
# Never changes the exit status.
guard_commit_warnings() {
    local line id value status ids='' heading='vault-guard: warnings (the commit goes through)'
    for line in "${GUARD_RESULTS[@]:-}"; do
        IFS='|' read -r id value _ status _ <<<"$line"
        [ "$status" = warn ] && guard_gt "$value" 0 && ids+="$id "
    done
    [ -n "$ids" ] || return 0
    [ "$1" -eq 0 ] || heading='vault-guard: warnings (these alone would not refuse the commit)'
    printf '\n' >&2
    "${GUARD_BIN_DIR}/guard-report-errors.sh" --rows "${ids% }" --tree "${GUARD_TREE_DIR:--}" \
        --map "$2/rules.tsv" --checks "$2/checks.tsv" --bases "$GUARD_BASES" --target "$GUARD_TARGET" \
        --heading "$heading" >&2 \
        || printf 'vault-guard: quality/rules.tsv is unreadable; warnings from %s are not printed\n' "${ids% }" >&2
    return 0
}

guard_commit_refusal() {  # guard_commit_refusal <target> <config dir>
    local cfg="$2" line id status ids='' findings='' prc=0
    for line in "${GUARD_RESULTS[@]:-}"; do
        IFS='|' read -r id _ _ status _ <<<"$line"
        case "$status" in worse|unmeasurable) [ -n "${QG_BUILTIN_WHY[$id]:-}" ] || ids+="$id " ;; esac
    done
    if [ -n "${ids// /}" ]; then
        findings="$("${GUARD_BIN_DIR}/guard-report-errors.sh" --rows "${ids% }" --tree "${GUARD_TREE_DIR:--}" \
            --map "$cfg/rules.tsv" --checks "$cfg/checks.tsv" --bases "$GUARD_BASES" --target "$GUARD_TARGET")" || prc=$?
        [ "$prc" -eq 0 ] || findings+=$'\n''vault-guard: quality/rules.tsv is unreadable; the findings carry no catalog pointer'
    fi
    qg_print_refusal commit - "$findings"
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
