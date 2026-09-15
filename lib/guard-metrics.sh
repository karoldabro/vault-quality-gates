#!/usr/bin/env bash
# Reads quality/checks.tsv, runs each row, compares the number it yields, and renders
# the result. Sourced by bin/guard.sh; defines no behaviour of its own on load.
#
# Exit codes are the same everywhere: 0 measured and acceptable, 1 measured and worse,
# 2 could not measure. A check that could not run is never recorded as passing.
#
# File formats: vault/architecture/guard-file-formats.md.

# Every number this file prints or compares must use a dot, whatever the operator's
# locale sets. awk honours LC_NUMERIC and will otherwise emit "4,04".
export LC_ALL=C

GUARD_CHECKS_HEADER=$'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate'
GUARD_BASELINE_HEADER=$'id\tvalue\tcommit\treason'
GUARD_ACCEPT_LIMIT_DEFAULT=3

# Rows loaded by guard_load_checks, one TSV line per element.
GUARD_ROWS=()
# Results collected by guard_run_row: id|value|baseline|status|detail
GUARD_RESULTS=()

guard_err() { printf '%s\n' "$*" >&2; }

# --- float comparison --------------------------------------------------------
# awk, never bc: bc is absent from tests/Dockerfile's package list.

guard_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
guard_is_number() { awk -v v="$1" 'BEGIN { exit !(v ~ /^-?[0-9]+(\.[0-9]+)?$/) }'; }

# --- quality/checks.tsv ------------------------------------------------------

# guard_load_checks <path>
#
# Fills GUARD_ROWS. Exit 2 when line 1 is not the literal header, or when any row's
# field count differs from it. A commented-out header would be skipped and every
# later row counted against nothing.
guard_load_checks() {
    local path="$1" line n=0

    if [ ! -r "$path" ]; then
        guard_err "guard: cannot read ${path}"
        return 2
    fi

    GUARD_ROWS=()
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        if [ "$n" -eq 1 ]; then
            if [ "$line" != "$GUARD_CHECKS_HEADER" ]; then
                guard_err "guard: ${path} line 1 is not the checks header"
                return 2
            fi
            continue
        fi
        case "$line" in ''|'#'*) continue ;; esac

        local count
        count="$(awk -F'\t' '{ print NF }' <<<"$line")"
        if [ "$count" -ne 9 ]; then
            guard_err "guard: ${path} line ${n} has ${count} fields, the header has 9"
            return 2
        fi
        GUARD_ROWS+=("$line")
    done < "$path"

    return 0
}

# --- quality/baseline.tsv ----------------------------------------------------

# guard_baseline_value <path> <id>  ->  the number on stdout, or empty
#
# A non-numeric value is exit 2, not zero: a row carrying no number must never
# score as clean.
guard_baseline_value() {
    local path="$1" id="$2" value
    [ -r "$path" ] || return 1
    value="$(awk -F'\t' -v id="$id" 'NR > 1 && $0 !~ /^#/ && $1 == id { print $2; exit }' "$path")"
    [ -n "$value" ] || return 1
    if ! guard_is_number "$value"; then
        guard_err "guard: ${path} row '${id}' carries a non-numeric value '${value}'"
        return 2
    fi
    printf '%s' "$value"
}

guard_baseline_reason() {
    awk -F'\t' -v id="$2" 'NR > 1 && $0 !~ /^#/ && $1 == id { print $4; exit }' "$1"
}

# guard_accept_count <baseline path>  ->  rows whose reason is not '-'
guard_accept_count() {
    [ -r "$1" ] || { printf '0'; return 0; }
    awk -F'\t' 'NR > 1 && $0 !~ /^#/ && NF >= 4 && $4 != "-" && $4 != "" { n++ } END { print n + 0 }' "$1"
}

# guard_baseline_diff <baseline path> <remote ref> <remote sha> <checks path>
#
# Refuses a row the pushed tree moved in the worse direction while its reason is
# still '-'. Without it a branch passes the gate its own file defines.
guard_baseline_diff() {
    local path="$1" remote_ref="$2" remote_sha="$3" checks="$4" remote_copy rc=0

    case "$remote_sha" in
        *[!0]*) ;;
        *)  printf 'baseline check skipped: %s does not exist on the remote\n' "$remote_ref"
            return 0 ;;
    esac

    remote_copy="$(git show "${remote_sha}:${path}" 2>/dev/null)" || {
        printf 'baseline check skipped: %s carries no %s\n' "$remote_ref" "$path"
        return 0
    }

    local id local_v remote_v direction
    while IFS=$'\t' read -r id remote_v _ _; do
        [ -n "$id" ] && [ "${id:0:1}" != '#' ] && [ "$id" != 'id' ] || continue
        guard_is_number "$remote_v" || continue

        local_v="$(guard_baseline_value "$path" "$id")" || continue
        direction="$(awk -F'\t' -v id="$id" 'NR > 1 && $1 == id { print $7; exit }' "$checks")"

        local worse=1
        if [ "$direction" = 'up' ]; then
            guard_gt "$remote_v" "$local_v" && worse=0
        else
            guard_gt "$local_v" "$remote_v" && worse=0
        fi

        if [ "$worse" -eq 0 ] && [ "$(guard_baseline_reason "$path" "$id")" = '-' ]; then
            guard_err "guard: ${path} lowers '${id}' from ${remote_v} to ${local_v} with no reason"
            rc=1
        fi
    done <<<"$remote_copy"

    return "$rc"
}

# --- running one row ---------------------------------------------------------

# guard_parse_row <parser> <artifact> <command status>  ->  one float on stdout
#
# parser '-' means the command's own stdout is the float; the caller passes it as
# the artifact. Exit 2 and print a reason on stderr when nothing parses.
guard_parse_row() {
    local parser="$1" artifact="$2" status="$3" out

    if [ "$parser" = '-' ]; then
        out="$artifact"
    else
        local script="${GUARD_LIB_DIR}/guard-parsers/${parser}.sh"
        if [ ! -x "$script" ]; then
            guard_err "no parser ${script}"
            return 2
        fi
        out="$("$script" "$artifact" "$status" 2>&1)" || {
            guard_err "$out"
            return 2
        }
    fi

    out="$(printf '%s' "$out" | tr -d '[:space:]')"
    if ! guard_is_number "$out"; then
        guard_err "parser ${parser} printed '${out}', which is not a number"
        return 2
    fi
    printf '%s' "$out"
}

# guard_substitute <command> <base ref> <files file>
#
# {{base}} becomes the base ref. {{files}} becomes the NUL-separated changed paths,
# which the command must consume with xargs -0: a newline-separated list terminates
# the command at the first path and executes the second path as a command name.
guard_substitute() {
    local cmd="$1" base="$2" files="$3"
    cmd="${cmd//\{\{base\}\}/$base}"
    cmd="${cmd//\{\{files\}\}/cat $files}"
    printf '%s' "$cmd"
}

# guard_run_row <row> <baseline path> <base ref> <files file>
#
# Appends one entry to GUARD_RESULTS and returns 0 clean, 1 worse, 2 unmeasurable.
guard_run_row() {
    local row="$1" baseline="$2" base="$3" files="$4"
    local id scope kind command parser artifact direction threshold gate
    IFS=$'\t' read -r id scope kind command parser artifact direction threshold gate <<<"$row"

    if [ "$kind" = 'absent' ]; then
        GUARD_RESULTS+=("${id}|-|-|absent|${artifact}")
        return 0
    fi

    local status=0 stdout
    stdout="$(eval "$(guard_substitute "$command" "$base" "$files")" 2>&1)" || status=$?

    # parser '-' means the command's own stdout is the float; every other parser
    # reads the artifact. Passing the artifact cell to '-' records the literal '-'.
    local source="$artifact"
    [ "$parser" = '-' ] && source="$(printf '%s' "$stdout" | tail -1)"

    local value why
    value="$(guard_parse_row "$parser" "${source:--}" "$status" 2>/tmp/guard-parse.$$)"
    if [ -z "$value" ]; then
        why="$(cat /tmp/guard-parse.$$ 2>/dev/null)"; rm -f /tmp/guard-parse.$$
        [ -n "$why" ] || why="$(printf '%s' "$stdout" | tail -2)"
        GUARD_RESULTS+=("${id}|-|-|unmeasurable|${why}")
        return 2
    fi
    rm -f /tmp/guard-parse.$$

    guard_compare "$id" "$kind" "$value" "$direction" "$threshold" "$gate" "$baseline"
}

# guard_compare <id> <kind> <value> <direction> <threshold> <gate> <baseline path>
#
# kind repo  — against quality/baseline.tsv, tolerating `threshold` of worsening.
# kind diff  — against `threshold` as an absolute floor (up) or ceiling (down).
#              Never against a baseline: each release measures a different set of
#              changed lines, so two scores describe different populations.
guard_compare() {
    local id="$1" kind="$2" value="$3" direction="$4" threshold="$5" gate="$6" baseline="$7"
    local reference worse=1 detail=''

    if [ "$kind" = 'diff' ]; then
        reference="$threshold"
        if [ "$direction" = 'up' ]; then
            guard_gt "$reference" "$value" && worse=0
        else
            guard_gt "$value" "$reference" && worse=0
        fi
        detail="floor ${reference}"
    else
        local rc=0
        reference="$(guard_baseline_value "$baseline" "$id")" || rc=$?
        if [ "$rc" -eq 2 ]; then
            GUARD_RESULTS+=("${id}|${value}|-|unmeasurable|baseline row is not a number")
            return 2
        fi
        if [ -z "$reference" ]; then
            # No row yet: record the number, judge nothing.
            GUARD_RESULTS+=("${id}|${value}|-|recorded|no baseline row")
            return 0
        fi
        local tolerance="${threshold}"
        guard_is_number "$tolerance" || tolerance=0
        if [ "$direction" = 'up' ]; then
            guard_gt "$(awk -v r="$reference" -v t="$tolerance" 'BEGIN { print r - t }')" "$value" && worse=0
        else
            guard_gt "$value" "$(awk -v r="$reference" -v t="$tolerance" 'BEGIN { print r + t }')" && worse=0
        fi
        detail="baseline ${reference}, tolerated ${tolerance}"
    fi

    if [ "$worse" -eq 0 ]; then
        case "$gate" in
            refuse) GUARD_RESULTS+=("${id}|${value}|${reference}|worse|${detail}"); return 1 ;;
            *)      GUARD_RESULTS+=("${id}|${value}|${reference}|warn|${detail}");  return 0 ;;
        esac
    fi

    GUARD_RESULTS+=("${id}|${value}|${reference}|ok|${detail}")
    return 0
}
