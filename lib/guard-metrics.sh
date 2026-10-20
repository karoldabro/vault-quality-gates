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

# Built-in drivers and parsers are found from here; a caller that sourced this file directly may
# not have set it.
: "${GUARD_LIB_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# shellcheck source=qg-events.sh
. "$(dirname "${BASH_SOURCE[0]}")/qg-events.sh"
# shellcheck source=qg-row.sh
. "$(dirname "${BASH_SOURCE[0]}")/qg-row.sh"
# shellcheck source=qg-driver.sh
. "$(dirname "${BASH_SOURCE[0]}")/qg-driver.sh"
# shellcheck source=qg-refusal.sh
. "$(dirname "${BASH_SOURCE[0]}")/qg-refusal.sh"

GUARD_CHECKS_HEADER_V2=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'
GUARD_BASELINE_HEADER=$'id\tvalue\tcommit\treason'
GUARD_ACCEPT_LIMIT_DEFAULT=3

# Rows loaded by guard_load_checks, one normalised row per element.
GUARD_ROWS=()
# Results collected by guard_run_row: id|value|baseline|status|detail
GUARD_RESULTS=()

# --- float comparison --------------------------------------------------------
# awk, never bc: bc is absent from tests/Dockerfile's package list.

guard_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
guard_is_number() { awk -v v="$1" 'BEGIN { exit !(v ~ /^-?[0-9]+(\.[0-9]+)?$/) }'; }

# --- quality/checks.tsv ------------------------------------------------------

# guard_load_checks <path>
#
# Fills GUARD_ROWS with normalised rows. Line 1 is the v2 header
# (vault/architecture/guard-file-formats.md). Exit 2, naming file and line, on any other header, a
# wrong field count, or a row with a bad `on`, an unknown driver, or `why` set to `-`. A v1 header
# (`id<TAB>scope<TAB>...`) names `qg doctor --all-branches`, which lists the refs still on v1.
guard_load_checks() {
    local path="$1" line n=0 count
    local id kind command parser artifact direction threshold gate on driver args why reason

    if [ ! -r "$path" ]; then
        guard_err "guard: cannot read ${path}"
        return 2
    fi

    GUARD_ROWS=()
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        if [ "$n" -eq 1 ]; then
            case "$line" in
                "$GUARD_CHECKS_HEADER_V2") ;;
                id$'\t'scope$'\t'*)
                    guard_err "guard: quality/checks.tsv is in the v1 format, which this gate no longer reads; run qg doctor --all-branches and copy quality/ from the v2 source it names"
                    return 2 ;;
                *) guard_err "guard: ${path} line 1 is not the checks header"; return 2 ;;
            esac
            continue
        fi
        case "$line" in ''|'#'*) continue ;; esac

        count="$(awk -F'\t' '{ print NF }' <<<"$line")"
        if [ "$count" -ne 9 ]; then
            guard_err "guard: ${path} line ${n} has ${count} fields, the header has 9"
            return 2
        fi
        # `read` collapses an empty tab-separated cell and shifts every later field, so a blank cell
        # is refused before the split; an unknown kind, direction or gate is refused after it.
        if [[ $'\t'"$line"$'\t' == *$'\t\t'* ]]; then
            guard_err "guard: ${path} line ${n}: an empty cell; write - for a cell with no value"; return 2
        fi
        IFS=$'\t' read -r id on kind driver args direction threshold gate why <<<"$line"
        case "$kind" in repo|diff|absent) ;; *) guard_err "guard: ${path} line ${n}: kind \"${kind}\" is not repo, diff or absent"; return 2 ;; esac
        if [ "$kind" != absent ]; then
            case "$direction" in up|down) ;; *) guard_err "guard: ${path} line ${n}: direction \"${direction}\" is not up or down"; return 2 ;; esac
            case "$gate" in refuse|warn|record) ;; *) guard_err "guard: ${path} line ${n}: gate \"${gate}\" is not refuse, warn or record"; return 2 ;; esac
        fi
        if ! [[ "$id" =~ ^[a-z][a-z0-9-]*$ ]]; then
            guard_err "guard: ${path} line ${n}: id \"${id}\" must match [a-z][a-z0-9-]*"; return 2
        fi
        if [[ ! "$why" =~ [^[:space:]] ]] || [ "$why" = '-' ] || [[ "$why" == TODO* ]]; then
            guard_err "guard: ${path} line ${n}: row ${id} has no why; state in one sentence why this gate exists"; return 2
        fi
        if ! reason="$(qg_on_valid "$on")"; then
            guard_err "guard: ${path} line ${n}: row ${id} on: ${reason}"; return 2
        fi
        command='-' parser='-' artifact='-'
        if [ "$kind" = absent ]; then
            artifact="$why"
        elif [ "$driver" = shell ]; then
            command="$(guard_args_argv "$args")"
            parser="$(guard_args_kv "$args" parser)" || parser='-'
            artifact="$(guard_args_kv "$args" artifact)" || artifact='-'
            [ -n "$command" ] || { guard_err "guard: ${path} line ${n}: row ${id} driver shell needs args \"-- <command>\""; return 2; }
        elif ! reason="$(guard_driver_resolvable "$driver")"; then
            guard_err "guard: ${path} line ${n}: row ${id}: ${reason}"; return 2
        fi
        GUARD_ROWS+=("$(printf '%s\t' "$id" "$on" "$kind" "$driver" "$args" "$direction" "$threshold" "$gate" "$why" \
            "$command" "$parser")${artifact}")
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

# guard_baseline_diff <old baseline> <new baseline> <checks>
#
# Compares two copies of quality/baseline.tsv, each a file path; a missing old file means
# there is nothing to loosen. Prints one `id<TAB>old<TAB>new<TAB>why` line per row the new
# copy loosens and returns 1 when it printed any, 0 otherwise. A row is loosened when:
#   - its value moved in the worse direction (`direction` column of checks.tsv; down by
#     default), whatever its reason column says;
#   - its reason column changed to anything but `-` (an accepted regression is a loosening);
#   - it disappeared, or its value is not a number, while checks.tsv gives it kind repo.
# A tighter value, a cleared reason and a new row pass. The gate refuses a loosening for an
# agent; only a human override (QG_SKIP_REASON at a terminal) commits or pushes one.
guard_baseline_diff() {
    local old="$1" new="$2" checks="$3" kinds rc
    [ -r "$old" ] || return 0
    [ -r "$new" ] || new=/dev/null
    # kind and direction by name from the normalised rows, in a subshell so the caller's
    # GUARD_ROWS survive; line 1 is a placeholder the awk below skips.
    if ! ( guard_load_checks "$checks" ) >/dev/null 2>&1; then
        # Without kinds and directions nothing can be judged; refuse rather than guess "down".
        printf '%s\t-\t-\t%s\n' 'quality/checks.tsv' 'does not load, so no baseline row can be judged'
        return 1
    fi
    kinds="$(mktemp)"
    ( printf 'id\tkind\tdirection\n'
      guard_load_checks "$checks" 2>/dev/null || exit 0
      for r in "${GUARD_ROWS[@]}"; do
          printf '%s\t%s\t%s\n' "$(guard_row_field "$r" id)" "$(guard_row_field "$r" kind)" "$(guard_row_field "$r" direction)"
      done ) > "$kinds"
    rc=0
    awk -F'\t' -v OFS='\t' '
        FILENAME == ARGV[1] { if (FNR > 1 && $1 !~ /^#/) { kind[$1] = $2; dir[$1] = $3 } next }
        FILENAME == ARGV[2] { if (FNR > 1 && $1 !~ /^#/ && $1 != "") { ov[$1] = $2; orsn[$1] = ($4 == "" ? "-" : $4); order[++n] = $1 } next }
        { if (FNR > 1 && $1 !~ /^#/ && $1 != "") { nv[$1] = $2; nrsn[$1] = ($4 == "" ? "-" : $4); seen[$1] = 1 } }
        function num(v) { return v ~ /^-?[0-9]+(\.[0-9]+)?$/ }
        END {
            bad = 0
            for (i = 1; i <= n; i++) {
                id = order[i]
                if (!(id in seen)) {
                    if (kind[id] == "repo") { print id, ov[id], "-", "row removed"; bad = 1 }
                    continue
                }
                if (!num(nv[id])) {
                    if (kind[id] == "repo" || num(ov[id])) { print id, ov[id], nv[id], "value is not a number"; bad = 1 }
                    continue
                }
                if (num(ov[id])) {
                    if (dir[id] == "up" ? nv[id] + 0 < ov[id] + 0 : nv[id] + 0 > ov[id] + 0) {
                        print id, ov[id], nv[id], (dir[id] == "up" ? "lower is worse" : "higher is worse"); bad = 1; continue
                    }
                }
                if (nrsn[id] != orsn[id] && nrsn[id] != "-") { print id, ov[id], nv[id], "reason column set to \"" nrsn[id] "\""; bad = 1 }
            }
            exit bad
        }' "$kinds" "$old" "$new" || rc=$?
    rm -f "$kinds"
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

# guard_run_shell <row> <base> <files> <tmp> -> value on stdout, or exit 2 with the reason on
# stderr. The command runs in its own bash under `set -uo pipefail`, through qg_sandbox_run with
# QG_SANDBOX=0: unconfined, but with the child environment every tool gets and stdin from
# /dev/null (vault/architecture/qg-sandbox.md). Its output goes to <tmp>/output.
guard_run_shell() {
    local row="$1" base="$2" files="$3" tmp="$4" command parser artifact status=0 source
    command="$(guard_row_field "$row" command)" parser="$(guard_row_field "$row" parser)"
    artifact="$(guard_substitute "$(guard_row_field "$row" artifact)" "$base" "$files")"
    # Its own process: a `cd` or an `exit` in the command must not move the artifact path or
    # skip the parser, as it never did.
    # shellcheck disable=SC2016  # $1 is expanded by the child bash
    QG_SANDBOX=0 qg_sandbox_run -- /bin/bash -c 'set -uo pipefail; eval "$1"' qg-shell-row \
        "$(guard_substitute "$command" "$base" "$files")" > "$tmp/output" 2>&1 || status=$?
    [ -z "$QG_SANDBOX_ERROR" ] || { guard_err "$QG_SANDBOX_ERROR"; return 2; }
    # parser '-' means the command's own output is the float; every other parser reads the
    # artifact. Passing the artifact cell to '-' records the literal '-'.
    # $(cat) drops trailing newlines first, as the captured output always did, so a command
    # that ends with blank lines still yields its last printed line.
    source="$artifact"
    [ "$parser" = '-' ] && source="$(printf '%s' "$(cat "$tmp/output")" | tail -1)"
    guard_parse_row "$parser" "${source:--}" "$status"
}

# guard_run_row <row> <baseline path> <base ref> <files file>
#
# Appends one entry to GUARD_RESULTS and returns 0 clean, 1 worse, 2 unmeasurable. Prints one
# progress line on stderr per measured row, so whoever waits on a commit sees what is running.
guard_run_row() {
    local start="$SECONDS" rc=0 status
    _guard_run_row "$@" || rc=$?
    if [ "$(guard_row_field "$1" kind)" != absent ]; then
        IFS='|' read -r _ _ _ status _ <<<"${GUARD_RESULTS[-1]}"
        printf '  %-12s %s (%s, %ds)\n' "$status" "$(guard_row_field "$1" id)" "$(guard_row_field "$1" driver)" \
            $((SECONDS - start)) >&2
    fi
    return "$rc"
}

# guard_only <id> -> 0 when the run measures the row: GUARD_ONLY (set by `--only`) is empty, or
# names the id in its comma-separated list.
guard_only() { [ -z "${GUARD_ONLY:-}" ] || [[ ",${GUARD_ONLY}," == *",$1,"* ]]; }

_guard_run_row() {
    local row="$1" baseline="$2" base="$3" files="$4"
    local id kind driver direction threshold gate tmp value why rc=0
    id="$(guard_row_field "$row" id)" kind="$(guard_row_field "$row" kind)" driver="$(guard_row_field "$row" driver)"
    direction="$(guard_row_field "$row" direction)" threshold="$(guard_row_field "$row" threshold)"
    gate="$(guard_row_field "$row" gate)"

    if [ "$kind" = 'absent' ]; then
        GUARD_RESULTS+=("${id}|-|-|absent|$(guard_row_field "$row" artifact)")
        return 0
    fi

    tmp="$(mktemp -d)"
    : > "$tmp/output"
    if [ "$driver" = shell ]; then value="$(guard_run_shell "$row" "$base" "$files" "$tmp" 2>"$tmp/why")" || rc=$?
    else value="$(guard_run_driver "$row" "$base" "$files" "$tmp" 2>"$tmp/why")" || rc=$?; fi
    why="$(head -c 400 "$tmp/why" | tr '\n|' '  ')"
    if [ "$rc" -ne 0 ] || [ -z "$value" ]; then
        [ -n "$why" ] || why="$(tail -2 "$tmp/output" | tr '\n|' '  ')"
        guard_save_last "$id" "$tmp/out/result.json" "$tmp/output" "$driver" - "${why:-no value}"
        rm -rf "$tmp"
        GUARD_RESULTS+=("${id}|-|-|unmeasurable|${why}")
        return 2
    fi
    guard_save_last "$id" "$tmp/out/result.json" "$tmp/output" "$driver" "$value" -
    rm -rf "$tmp"

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
