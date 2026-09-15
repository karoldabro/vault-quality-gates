#!/usr/bin/env bash
# Per-repo code-quality runner. Reads quality/checks.tsv, runs the rows a subcommand
# selects, compares each number against quality/baseline.tsv, writes the report.
#
#   guard.sh commit              rows scoped commit|both, against HEAD~1
#   guard.sh release [<ref>]     rows scoped release|both, against the merge-base
#   guard.sh baseline [--skip <regex>]
#                                rows scoped baseline plus every kind: repo row,
#                                then rewrites quality/baseline.tsv. --skip omits
#                                matching ids and KEEPS their existing rows, so a
#                                57-minute suite row can be refreshed on its own
#                                schedule without blocking every other measurement.
#   guard.sh report              re-render from quality-reports/
#   guard.sh accept <id> --reason "<why>"
#   guard.sh hooks install|remove|status
#
# Exit 0 measured and acceptable, 1 measured and worse, 2 could not measure.
#
# GUARD_SHA pins the commit to measure, through a detached worktree, so an unrelated
# edit in the working tree cannot change what the gate reads.
#
# A repo whose toolchain is bound to the checkout path cannot be measured that way:
# a detached worktree under /tmp has no vendor/, no node_modules, and no container
# bind-mount, so every row reports unmeasurable and the push is refused for the wrong
# reason. Such a repo sets `guard_measure_worktree: false` in VAULT.md and accepts
# that uncommitted edits can move a metric.

set -uo pipefail

GUARD_BIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
GUARD_LIB_DIR="$(cd "${GUARD_BIN_DIR}/../lib" && pwd)"
export GUARD_LIB_DIR
# shellcheck source=../lib/guard-metrics.sh
. "${GUARD_LIB_DIR}/guard-metrics.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    guard_err 'guard: not a git repository'; exit 2
}
CHECKS="${REPO_ROOT}/quality/checks.tsv"
BASELINE="${REPO_ROOT}/quality/baseline.tsv"
REPORTS="${REPO_ROOT}/quality-reports"

guard_default_branch() {
    local b
    b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" \
        && printf '%s' "${b#origin/}" || printf 'master'
}

guard_accept_limit() {
    local v
    v="$(sed -n 's/^guard_accept_limit:[[:space:]]*//p' "${REPO_ROOT}/VAULT.md" 2>/dev/null | head -1)"
    if guard_is_number "${v:-}"; then printf '%s' "$v"; else printf '%s' "$GUARD_ACCEPT_LIMIT_DEFAULT"; fi
}

guard_measure_worktree() {
    local v
    v="$(sed -n 's/^guard_measure_worktree:[[:space:]]*//p' "${REPO_ROOT}/VAULT.md" 2>/dev/null | head -1)"
    [ "$v" != 'false' ]
}

GUARD_WORKTREE=''
guard_enter_tree() {
    if [ -n "${GUARD_SHA:-}" ] && ! guard_measure_worktree; then
        printf 'vault-guard: measuring the working tree; VAULT.md sets guard_measure_worktree: false\n' >&2
        cd "$REPO_ROOT" || exit 2
    elif [ -n "${GUARD_SHA:-}" ]; then
        GUARD_WORKTREE="$(mktemp -d)"
        git worktree add --detach --quiet "$GUARD_WORKTREE" "$GUARD_SHA" 2>/dev/null || {
            guard_err "guard: cannot check out ${GUARD_SHA}"; exit 2
        }
        cd "$GUARD_WORKTREE" || exit 2
    else
        cd "$REPO_ROOT" || exit 2
    fi
}
guard_leave_tree() {
    [ -n "$GUARD_WORKTREE" ] || return 0
    cd "$REPO_ROOT" || return 0
    git worktree remove --force "$GUARD_WORKTREE" >/dev/null 2>&1
    GUARD_WORKTREE=''
}
trap guard_leave_tree EXIT

# guard_run <scope> <base ref>  ->  0 clean, 1 worse, 2 unmeasurable
guard_run() {
    local want="$1" base="$2" row id scope kind rc worst=0 files
    files="$(mktemp)"
    git diff --name-only -z "$base" -- > "$files" 2>/dev/null || : > "$files"

    for row in "${GUARD_ROWS[@]}"; do
        IFS=$'\t' read -r id scope kind _ _ _ _ _ _ <<<"$row"
        if [ -n "${GUARD_SKIP:-}" ] && [[ "$id" =~ $GUARD_SKIP ]]; then
            GUARD_RESULTS+=("${id}|-|-|skipped|not measured this run, existing baseline row kept")
            continue
        fi
        if [ "$kind" = 'absent' ]; then
            guard_run_row "$row" "$BASELINE" "$base" "$files"
            continue
        fi
        # `baseline` also runs every kind: repo row whatever its scope — those rows
        # are what quality/baseline.tsv is made of, and most are scoped to release.
        case "$scope" in
            "$want"|both) ;;
            *) [ "$want" = 'baseline' ] && [ "$kind" = 'repo' ] || continue ;;
        esac
        rc=0
        guard_run_row "$row" "$BASELINE" "$base" "$files" || rc=$?
        [ "$rc" -gt "$worst" ] && worst="$rc"
    done

    rm -f "$files"
    return "$worst"
}

# status.json keeps the six category keys build-dashboard.mjs fixes; an id outside
# them lands under codeQuality.checks, which that aggregator renders as an open map.
guard_render_report() {
    mkdir -p "$REPORTS"
    local commit; commit="$(git rev-parse --short "${GUARD_SHA:-HEAD}" 2>/dev/null)"
    printf '%s\n' "${GUARD_RESULTS[@]:-}" \
        | bash "${GUARD_LIB_DIR}/guard-report.sh" "$REPORTS" "$commit" \
               "$(guard_accept_count "$BASELINE")" "$(basename "$REPO_ROOT")"
}

guard_refusal() {
    local ref="$1" line id value base status detail worse=0 bad=0
    printf '\nvault-guard: push refused to %s\n\n' "$ref" >&2
    for line in "${GUARD_RESULTS[@]:-}"; do
        [ -n "$line" ] || continue
        IFS='|' read -r id value base status detail <<<"$line"
        case "$status" in
            worse)
                printf '  %-18s %s -> %s   %s\n' "$id" "$base" "$value" "$detail" >&2
                printf '  %-18s baseline: quality/baseline.tsv\n' '' >&2
                worse=$((worse + 1)) ;;
            unmeasurable)
                printf '  %-18s could not measure\n' "$id" >&2
                printf '  %-18s %s\n' '' "$detail" >&2
                bad=$((bad + 1)) ;;
        esac
    done
    printf '\n%d worse, %d unmeasurable. quality/baseline.tsv carries %s accepted rows; the limit is %s.\n' \
        "$worse" "$bad" "$(guard_accept_count "$BASELINE")" "$(guard_accept_limit)" >&2
    printf '\nFix it, or accept it:\n' >&2
    printf '  bin/guard.sh accept <metric> --reason "<why this is acceptable>"\n' >&2
    printf '  bin/guard.sh report\n\n' >&2
}

cmd_measure() {
    local scope="$1" base="$2" ref="$3" rc=0
    guard_load_checks "$CHECKS" || exit 2
    guard_enter_tree
    guard_run "$scope" "$base" || rc=$?
    guard_leave_tree
    guard_render_report

    if [ "$ref" != '-' ]; then
        local accepted limit
        accepted="$(guard_accept_count "$BASELINE")"; limit="$(guard_accept_limit)"
        if [ "$accepted" -gt "$limit" ]; then
            guard_err "guard: ${accepted} accepted baseline rows exceeds guard_accept_limit ${limit}"
            rc=1
        fi
    fi
    if [ "$rc" -ne 0 ] && [ "$ref" != '-' ]; then guard_refusal "$ref"; fi
    return "$rc"
}

cmd_baseline() {
    guard_load_checks "$CHECKS" || exit 2
    # A skipped row keeps whatever quality/baseline.tsv already holds for it.
    declare -A kept=()
    if [ -r "$BASELINE" ]; then
        local k v c r
        while IFS=$'\t' read -r k v c r; do
            [ -n "$k" ] && [ "${k:0:1}" != '#' ] && [ "$k" != 'id' ] && kept["$k"]=$'\t'"${v}"$'\t'"${c}"$'\t'"${r}"
        done < "$BASELINE"
    fi
    guard_enter_tree
    guard_run 'baseline' "$(git rev-parse HEAD)" || true
    guard_leave_tree

    local commit tmp line id value _b status _d
    commit="$(git rev-parse --short HEAD)"
    tmp="$(mktemp)"
    printf '%s\n' "$GUARD_BASELINE_HEADER" > "$tmp"
    printf '# Written by bin/guard.sh baseline. Every reason is cleared here, so an\n' >> "$tmp"
    printf '# accepted regression expires at the next whole-repo measurement.\n' >> "$tmp"
    for line in "${GUARD_RESULTS[@]:-}"; do
        [ -n "$line" ] || continue
        IFS='|' read -r id value _b status _d <<<"$line"
        [ "$status" = 'absent' ] && continue
        if [ "$status" = 'skipped' ]; then
            [ -n "${kept[$id]:-}" ] && printf '%s%s\n' "$id" "${kept[$id]}" >> "$tmp"
            continue
        fi
        guard_is_number "$value" || continue
        printf '%s\t%s\t%s\t-\n' "$id" "$value" "$commit" >> "$tmp"
    done
    mkdir -p "$(dirname "$BASELINE")"
    mv "$tmp" "$BASELINE"
    guard_render_report
    printf 'baseline written: %s\n' "$BASELINE"
    cat "$BASELINE"
}

cmd_accept() {
    local id="${1:-}" reason=''
    shift || true
    [ "${1:-}" = '--reason' ] && reason="${2:-}"
    if [ -z "$id" ] || [ -z "$reason" ]; then
        guard_err 'usage: guard.sh accept <id> --reason "<why>"'; exit 2
    fi
    grep -q "^${id}"$'\t' "$BASELINE" || { guard_err "guard: no row '${id}' in ${BASELINE}"; exit 2; }
    awk -F'\t' -v OFS='\t' -v id="$id" -v r="$reason" \
        'NR>1 && $1==id { $4 = r } { print }' "$BASELINE" > "${BASELINE}.tmp" \
        && mv "${BASELINE}.tmp" "$BASELINE"
    printf 'accepted %s: %s\n' "$id" "$reason"
}

case "${1:-}" in
    commit)
        cmd_measure 'commit' "$(git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD)" '-' ;;
    release)
        base="$(git merge-base "origin/$(guard_default_branch)" HEAD 2>/dev/null \
                || git merge-base "$(guard_default_branch)" HEAD 2>/dev/null \
                || git rev-parse HEAD)"
        cmd_measure 'release' "$base" "${2:--}" ;;
    baseline)
        shift
        [ "${1:-}" = '--skip' ] && { export GUARD_SKIP="${2:-}"; }
        cmd_baseline ;;
    report)   cat "${REPORTS}/REPORT.md" 2>/dev/null || { guard_err 'guard: no report yet'; exit 2; } ;;
    accept)   shift; cmd_accept "$@" ;;
    hooks)    shift; . "${GUARD_LIB_DIR}/guard-install.sh"; guard_hooks "$@" ;;
    *)        guard_err 'usage: guard.sh commit|release|baseline|report|accept|hooks'; exit 2 ;;
esac
