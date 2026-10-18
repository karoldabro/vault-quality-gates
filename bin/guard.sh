#!/usr/bin/env bash
# Per-repo code-quality runner. Reads quality/checks.tsv, runs the rows a subcommand
# selects, compares each number against quality/baseline.tsv, writes the report.
#
#   guard.sh commit              rows scoped commit|both, on the index git is about to
#                                commit, against every parent; config read from HEAD
#   guard.sh verify <range>      the same for each commit `git rev-list <range>` lists,
#                                against its own parents; writes its pass record
#   guard.sh release [<ref>]     rows scoped release|both, against the merge-base; checks.tsv,
#                                baseline.tsv and VAULT.md read from GUARD_SHA (else HEAD)
#   guard.sh baseline [--skip <regex>]
#                                rows scoped baseline plus every kind: repo row,
#                                then rewrites quality/baseline.tsv. --skip omits
#                                matching ids and KEEPS their existing rows, so a
#                                57-minute suite row can be refreshed on its own
#                                schedule without blocking every other measurement.
#   guard.sh report              re-render from quality-reports/
#   guard.sh accept <id> --reason "<why>"
#   guard.sh hooks install [--claude]|remove|status
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

# GUARD_SKIP and GUARD_ONLY drop rows from a run. Only `baseline --skip` and `--only` set them,
# below; a value inherited from the caller would let `GUARD_SKIP=. git push` skip every gated row.
unset GUARD_SKIP GUARD_ONLY

# git hands hooks a relative GIT_INDEX_FILE; pin it before anything changes directory.
if [ -n "${GIT_INDEX_FILE:-}" ] && [ "${GIT_INDEX_FILE#/}" = "$GIT_INDEX_FILE" ]; then
    export GIT_INDEX_FILE="${PWD}/${GIT_INDEX_FILE}"
fi

GUARD_BIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
GUARD_LIB_DIR="$(cd "${GUARD_BIN_DIR}/../lib" && pwd)"
export GUARD_LIB_DIR
# shellcheck source=../lib/guard-metrics.sh
. "${GUARD_LIB_DIR}/guard-metrics.sh"
# shellcheck source=../lib/guard-pass.sh
. "${GUARD_LIB_DIR}/guard-pass.sh"

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

# GUARD_CONFIG_REV, set by `release`, is the commit whose VAULT.md, checks.tsv and baseline.tsv
# the release gate reads, so an uncommitted edit cannot loosen the gate that judges a push.
# GUARD_CONFIG_PIN is the caller's GUARD_CONFIG_REV, read before this file reuses the name: the
# agent factory pins every run to its build's base commit, so a build cannot loosen the
# configuration that judges it. The factory sets the pin outside any agent session; under
# CLAUDECODE or AI_AGENT the pin is ignored, so an agent cannot pick an older, looser config.
GUARD_CONFIG_PIN="${GUARD_CONFIG_REV:-}"
if [ -n "${CLAUDECODE+set}" ] || [ -n "${AI_AGENT+set}" ]; then GUARD_CONFIG_PIN=''; fi
export GUARD_CONFIG_PIN
GUARD_CONFIG_REV=''

guard_accept_limit() {
    local v
    v="$(qg_config_key guard_accept_limit)"
    if guard_is_number "${v:-}"; then printf '%s' "$v"; else printf '%s' "$GUARD_ACCEPT_LIMIT_DEFAULT"; fi
}

guard_measure_worktree() {
    [ "$(qg_config_key guard_measure_worktree)" != 'false' ]
}

# guard_release_config <rev> -> points CHECKS and BASELINE at copies of the committed files.
# Exit 3 when the commit carries no quality/checks.tsv: nothing there is gated.
guard_release_config() {
    local dir
    GUARD_CONFIG_REV="$(git rev-parse -q --verify "${1}^{commit}")" || { guard_err "guard: cannot read commit ${1}"; exit 2; }
    dir="$(mktemp -d)"
    GUARD_CONFIG_DIR="$dir"
    git show "${GUARD_CONFIG_REV}:quality/checks.tsv" > "${dir}/checks.tsv" 2>/dev/null || return 3
    git show "${GUARD_CONFIG_REV}:quality/baseline.tsv" > "${dir}/baseline.tsv" 2>/dev/null || rm -f "${dir}/baseline.tsv"
    CHECKS="${dir}/checks.tsv" BASELINE="${dir}/baseline.tsv"
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
GUARD_CONFIG_DIR=''
trap 'guard_leave_tree; [ -z "$GUARD_CONFIG_DIR" ] || rm -rf "$GUARD_CONFIG_DIR"' EXIT

# guard_row_selected <row> <want> <ref> -> 0 when the run `want` (release or baseline) measures
# the row. `baseline` also runs every kind: repo row whatever its `on`: those rows are what
# quality/baseline.tsv is made of, and most run on push only.
guard_row_selected() {
    local on kind
    on="$(guard_row_field "$1" on)" kind="$(guard_row_field "$1" kind)"
    case "$2" in
        release)  qg_row_runs_on "$on" push "$3" ;;
        baseline) qg_row_runs_on "$on" baseline || [ "$kind" = 'repo' ] ;;
        *)        return 1 ;;
    esac
}

# guard_run <want> <base ref> [<pushed ref>]  ->  0 clean, 1 worse, 2 unmeasurable
guard_run() {
    local want="$1" base="$2" ref="${3:--}" row id kind rc worst=0 files
    files="$(mktemp)"
    git diff --name-only -z "$base" -- > "$files" 2>/dev/null || : > "$files"

    for row in "${GUARD_ROWS[@]}"; do
        id="$(guard_row_field "$row" id)" kind="$(guard_row_field "$row" kind)"
        if [ -n "${GUARD_SKIP:-}" ] && [[ "$id" =~ $GUARD_SKIP ]]; then
            GUARD_RESULTS+=("${id}|-|-|skipped|not measured this run, existing baseline row kept")
            continue
        fi
        if [ "$kind" = 'absent' ]; then
            guard_run_row "$row" "$BASELINE" "$base" "$files"
            continue
        fi
        guard_row_selected "$row" "$want" "$ref" && guard_only "$id" || continue
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
    local commit last; commit="$(git rev-parse --short "${GUARD_SHA:-HEAD}" 2>/dev/null)"
    # The results of this run, one `id|value|reference|status|detail` line each: `qg run --json`
    # and `qg explain` read them.
    last="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/qg-last"
    mkdir -p "$last" 2>/dev/null && printf '%s\n' "${GUARD_RESULTS[@]:-}" > "${last}/RESULTS.txt"
    printf '%s\n' "${GUARD_RESULTS[@]:-}" \
        | bash "${GUARD_LIB_DIR}/guard-report.sh" "$REPORTS" "$commit" \
               "$(guard_accept_count "$BASELINE")" "$(basename "$REPO_ROOT")"
}

guard_refusal() {
    local ref="$1" findings
    findings="Never edit quality/baseline.tsv, quality/checks.tsv, quality/config or VAULT.md to pass: the gate refuses a looser baseline."
    findings+=$'\n'"Measure again without pushing: GUARD_SHA=$(git rev-parse --short "${GUARD_SHA:-HEAD}" 2>/dev/null) ${GUARD_BIN_DIR}/guard.sh release ${ref}"
    qg_print_refusal push "$ref" "$findings"
}

# guard_release_tree_matches -> 1 with the reason when `guard_measure_worktree: false` would
# measure something other than the pushed commit: a dirty tracked file, or HEAD elsewhere.
guard_release_tree_matches() {
    [ -n "${GUARD_SHA:-}" ] && ! guard_measure_worktree || return 0
    if [ "$(git -C "$REPO_ROOT" rev-parse HEAD)" != "$(git rev-parse "${GUARD_SHA}^{commit}")" ]; then
        guard_err "vault-guard: push refused: this repo measures its working tree, and HEAD is not the pushed commit ${GUARD_SHA}."
        guard_err '  Check out the branch you are pushing, then push again.'
        return 1
    fi
    # Only paths under guard_commit_paths count: a tool that rewrites a tracked file outside them
    # (graphify-out/, say) cannot move a metric, and must not block every push.
    local prefixes dirty
    read -ra prefixes <<<"$(qg_config_key guard_commit_paths)"
    dirty="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no | cut -c4- | sed 's/.* -> //' \
        | while IFS= read -r p; do
            [ "${#prefixes[@]}" -eq 0 ] && { printf '%s\n' "$p"; continue; }
            for x in "${prefixes[@]}"; do x="${x%/}"; { [ "$p" = "$x" ] || [[ "$p" == "$x"/* ]]; } && { printf '%s\n' "$p"; break; }; done
        done)"
    if [ -n "$dirty" ]; then
        guard_err 'vault-guard: push refused: this repo measures its working tree, and these tracked files have uncommitted changes:'
        guard_err "$(printf '%s\n' "$dirty" | head -10 | sed 's/^/    /')"
        guard_err '  Commit or stash them, then push again.'
        return 1
    fi
}

# guard_release_locked <row base> -> 1 with a `worse` result when the measured baseline.tsv
# loosens the one at GUARD_BASE (the pre-push hook passes the remote ref's old sha, or the parent of the
# oldest commit on no remote), else the merge-base the rows use.
guard_release_locked() {
    local old new lines
    old="$(mktemp)" new="$(mktemp)"
    if git show "${GUARD_BASE:-$1}:quality/baseline.tsv" > "$old" 2>/dev/null; then
        [ -r "$BASELINE" ] && cp "$BASELINE" "$new" || : > "$new"
        if ! lines="$(guard_baseline_diff "$old" "$new" "$CHECKS")"; then
            GUARD_RESULTS+=("baseline-loosened|$(wc -l <<<"$lines")|0|worse|$(awk -F'\t' '{ printf "%s%s %s -> %s (%s)", (NR > 1 ? "; " : ""), $1, $2, $3, $4 }' <<<"$lines")")
            rm -f "$old" "$new"; return 1
        fi
    fi
    rm -f "$old" "$new"
}

cmd_measure() {
    local scope="$1" base="$2" ref="$3" rc=0
    guard_load_checks "$CHECKS" || exit 2
    guard_enter_tree
    guard_run "$scope" "$base" "$ref" || rc=$?
    guard_leave_tree
    if [ "$scope" = 'release' ]; then
        local lrc=0; guard_release_locked "$base" || lrc=$?
        [ "$lrc" -gt "$rc" ] && rc="$lrc"
    fi
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

# cmd_release <pushed ref | -> — the push gate for one ref. Rows are chosen by `on` before
# anything else, so a ref no row runs on is accepted without a config or tree check: a branch
# that predates the gate, a ref outside every `push:` glob, or a branch that is not checked out.
# `-` (a person measuring by hand) runs every push row.
cmd_release() {
    local ref="$1" rev base row n=0 rc=0
    rev="${GUARD_SHA:-HEAD}"
    guard_release_config "${GUARD_CONFIG_PIN:-$rev}" || rc=$?
    if [ "$rc" -eq 3 ]; then
        if [ "$ref" != '-' ]; then printf 'vault-guard: no gate row runs on %s: %s has no quality/checks.tsv\n' "$ref" "${rev:0:12}" >&2; exit 0; fi
        guard_err "guard: ${rev} has no quality/checks.tsv; the release gate reads it from the measured commit"; exit 2
    fi
    guard_load_checks "$CHECKS" || exit 2
    for row in "${GUARD_ROWS[@]}"; do
        [ "$(guard_row_field "$row" kind)" = absent ] && continue
        guard_row_selected "$row" release "$ref" && guard_only "$(guard_row_field "$row" id)" && n=$((n + 1))
    done
    if [ "$n" -eq 0 ]; then
        printf 'vault-guard: no gate row runs on %s\n' "$ref" >&2
        exit 0
    fi
    printf 'vault-guard: measuring %d rows on %s (%s); this can take several minutes\n' "$n" "$ref" "${rev:0:12}" >&2
    base="$(git merge-base "origin/$(guard_default_branch)" "$rev" 2>/dev/null \
            || git merge-base "$(guard_default_branch)" "$rev" 2>/dev/null \
            || git rev-parse "$rev")"
    guard_release_tree_matches || exit 2
    cmd_measure 'release' "$base" "$ref"
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
    if [ -n "${CLAUDECODE+set}" ] || [ -n "${AI_AGENT+set}" ]; then
        guard_err 'guard: accept is for a human at a terminal. An agent fixes the metric in code.'; exit 2
    fi
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
        [ "${2:-}" = --only ] && GUARD_ONLY="${3:-}"
        . "${GUARD_LIB_DIR}/guard-commit.sh"; guard_gate ':index' "$(guard_default_bases)" ;;
    verify)
        shift
        [ $# -gt 0 ] || { guard_err 'usage: guard.sh verify <revision range>'; exit 2; }
        . "${GUARD_LIB_DIR}/guard-commit.sh"; guard_verify "$@" ;;
    release)
        shift
        rel_ref='-'
        while [ $# -gt 0 ]; do
            case "$1" in --only) GUARD_ONLY="${2:-}"; shift 2 ;; *) rel_ref="$1"; shift ;; esac
        done
        cmd_release "$rel_ref" ;;
    baseline)
        shift
        [ "${1:-}" = '--skip' ] && { export GUARD_SKIP="${2:-}"; }
        cmd_baseline ;;
    report)   cat "${REPORTS}/REPORT.md" 2>/dev/null || { guard_err 'guard: no report yet'; exit 2; } ;;
    accept)   shift; cmd_accept "$@" ;;
    hooks)    shift; . "${GUARD_LIB_DIR}/guard-install.sh"; guard_hooks "$@" ;;
    *)        guard_err 'usage: guard.sh commit|verify|release|baseline|report|accept|hooks'; exit 2 ;;
esac
