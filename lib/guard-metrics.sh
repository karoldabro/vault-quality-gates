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

# shellcheck source=qg-events.sh
. "$(dirname "${BASH_SOURCE[0]}")/qg-events.sh"

GUARD_CHECKS_HEADER=$'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate'
GUARD_CHECKS_HEADER_V2=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'
GUARD_BASELINE_HEADER=$'id\tvalue\tcommit\treason'
GUARD_ACCEPT_LIMIT_DEFAULT=3
GUARD_WHY_FALLBACK='(no reason recorded; run qg migrate)'

# guard_load_checks reads either header into one row shape: these fields, tab-separated, in this
# order. Every reader takes a field by name through guard_row_field, never by position.
GUARD_FIELDS=(id on kind driver args direction threshold gate why command parser artifact)
# -g: a caller may source this file inside a function, and a plain declare would be local there.
declare -gA GUARD_FIELD_AT=()
for _i in "${!GUARD_FIELDS[@]}"; do GUARD_FIELD_AT[${GUARD_FIELDS[$_i]}]=$_i; done
unset _i

# Rows loaded by guard_load_checks, one normalised row per element.
GUARD_ROWS=()
# Results collected by guard_run_row: id|value|baseline|status|detail
GUARD_RESULTS=()

guard_err() { printf '%s\n' "$*" >&2; }

# --- float comparison --------------------------------------------------------
# awk, never bc: bc is absent from tests/Dockerfile's package list.

guard_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
guard_is_number() { awk -v v="$1" 'BEGIN { exit !(v ~ /^-?[0-9]+(\.[0-9]+)?$/) }'; }

# --- quality/checks.tsv ------------------------------------------------------

# guard_row_field <row> <name> -> one field of a normalised row (GUARD_FIELDS).
guard_row_field() {
    local -a f
    IFS=$'\t' read -r -a f <<<"$1"
    printf '%s' "${f[${GUARD_FIELD_AT[$2]}]}"
}

# guard_args_kv <args> <key> -> the value of `key=value` before ` -- ` in a v2 args cell.
# guard_args_argv <args> -> the text after the first ` -- `, or nothing.
guard_args_kv() {
    local head="$1" w
    case "$head" in '-- '*) return 1 ;; *' -- '*) head="${head%% -- *}" ;; esac
    for w in $head; do
        case "$w" in "$2="*) printf '%s' "${w#*=}"; return 0 ;; esac
    done
    return 1
}
guard_args_argv() {
    case "$1" in '-- '*) printf '%s' "${1#-- }" ;; *' -- '*) printf '%s' "${1#* -- }" ;; esac
}

# guard_driver_builtin <name> -> the path of a built-in driver, when one exists.
guard_driver_builtin() {
    local file="${GUARD_LIB_DIR}/../drivers/${1}.sh"
    [ -x "$file" ] && printf '%s' "$file"
}

# guard_driver_resolvable <name> -> 0 when a built-in or the repo's committed driver exists.
# A repo driver is read at the config revision (lib/qg-config.sh); one named like a built-in is
# refused, so a repo cannot replace a shared driver.
guard_driver_resolvable() {
    [ "$1" = shell ] && return 0
    if guard_driver_builtin "$1" >/dev/null; then
        if declare -F guard_cfg_show >/dev/null && guard_cfg_show "quality/drivers/${1}.sh" >/dev/null; then
            printf 'quality/drivers/%s.sh has the name of a built-in driver' "$1"; return 1
        fi
        return 0
    fi
    declare -F guard_cfg_show >/dev/null && guard_cfg_show "quality/drivers/${1}.sh" >/dev/null && return 0
    printf 'no driver "%s": not built in, and no quality/drivers/%s.sh is committed' "$1" "$1"
    return 1
}

# guard_load_checks <path>
#
# Fills GUARD_ROWS with normalised rows. Line 1 is the v1 header or the v2 header
# (vault/architecture/guard-file-formats.md). A v1 row runs as driver `shell`, its `on` comes
# from `scope` and guard_release_pattern, and its `why` is GUARD_WHY_FALLBACK. Exit 2, naming file
# and line, on any other header, a wrong field count, or a v2 row with a bad `on`, an unknown
# driver, or `why` set to `-`.
guard_load_checks() {
    local path="$1" line n=0 version='' count pattern=''
    local id scope kind command parser artifact direction threshold gate on driver args why reason

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
                "$GUARD_CHECKS_HEADER")    version=1
                    declare -F qg_config_key >/dev/null && pattern="$(qg_config_key guard_release_pattern)" ;;
                "$GUARD_CHECKS_HEADER_V2") version=2 ;;
                *) guard_err "guard: ${path} line 1 is neither the v1 nor the v2 checks header"; return 2 ;;
            esac
            continue
        fi
        case "$line" in ''|'#'*) continue ;; esac

        count="$(awk -F'\t' '{ print NF }' <<<"$line")"
        if [ "$count" -ne 9 ]; then
            guard_err "guard: ${path} line ${n} has ${count} fields, the header has 9"
            return 2
        fi
        if [ "$version" = 1 ]; then
            IFS=$'\t' read -r id scope kind command parser artifact direction threshold gate <<<"$line"
            on="$(qg_on_from_v1 "$scope" "$pattern")"
            why="$GUARD_WHY_FALLBACK"
            [ "$kind" = absent ] && why="$artifact"
            GUARD_ROWS+=("$(printf '%s\t' "$id" "$on" "$kind" shell "parser=${parser} artifact=${artifact} -- ${command}" \
                "$direction" "$threshold" "$gate" "$why" "$command" "$parser")${artifact}")
            continue
        fi

        IFS=$'\t' read -r id on kind driver args direction threshold gate why <<<"$line"
        if ! [[ "$id" =~ ^[a-z][a-z0-9-]*$ ]]; then
            guard_err "guard: ${path} line ${n}: id \"${id}\" must match [a-z][a-z0-9-]*"; return 2
        fi
        if [ "$why" = '-' ]; then
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

# guard_substitute <command> <base ref> <files file>
#
# {{base}} becomes the base ref. {{files}} becomes the NUL-separated changed paths,
# which the command must consume with xargs -0: a newline-separated list terminates
# the command at the first path and executes the second path as a command name.
# {{tree}}, {{cache}}, {{bases}}, {{target}} and {{guard}} come from GUARD_TREE_DIR,
# GUARD_CACHE_DIR, GUARD_BASES, GUARD_TARGET and GUARD_BIN_DIR, which `guard.sh commit`
# and `verify` set; a token whose variable is unset stays as written.
guard_substitute() {
    local cmd="$1" base="$2" files="$3" token var
    cmd="${cmd//\{\{base\}\}/"$base"}"
    cmd="${cmd//\{\{files\}\}/"cat $files"}"
    for token in tree:GUARD_TREE_DIR cache:GUARD_CACHE_DIR bases:GUARD_BASES \
                 target:GUARD_TARGET guard:GUARD_BIN_DIR; do
        var="${token#*:}"
        [ -n "${!var:-}" ] || continue
        cmd="${cmd//\{\{${token%%:*}\}\}/"${!var}"}"
    done
    printf '%s' "$cmd"
}

# Lines of a row's own output the engine keeps for the refusal and `qg explain`.
GUARD_TAIL_LINES=20

# guard_last_dir <id> -> <git-common-dir>/qg-last/<id>, created; exit 1 for an id that is not a
# plain name, so a row id can never write outside qg-last/.
guard_last_dir() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != *..* ]] || return 1
    local d
    d="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/qg-last/$1" || return 1
    rm -rf "$d" && mkdir -p "$d" && printf '%s' "$d"
}

# guard_save_last <id> <result.json path or -> <output file> <driver> <value or -> <why or ->
# Writes qg-last/<id>/result.json and output.txt (the last GUARD_TAIL_LINES lines). A shell row
# has no result.json of its own; one is written from its value or its reason.
guard_save_last() {
    local d
    d="$(guard_last_dir "$1")" || return 0
    tail -n "$GUARD_TAIL_LINES" "$3" > "$d/output.txt" 2>/dev/null
    if [ "$2" != '-' ] && [ -r "$2" ]; then cp "$2" "$d/result.json"
    elif command -v jq >/dev/null 2>&1; then
        jq -n --arg d "$4" --arg v "$5" --arg e "$6" \
            '{schema: "qg.result/1", driver: $d, status: (if $v == "-" then "error" else "measured" end),
              metric: (if $v == "-" then null else ($v | tonumber) end), unit: "count", findings: [],
              error: (if $e == "-" then null else $e end), reproduce: null}' > "$d/result.json" 2>/dev/null
    fi
    return 0
}

# guard_cfg_copy <path> <dest> -> the committed file at the config revision, executable. Exit 1
# when it is absent. Never the working tree: a commit cannot install what judges it.
guard_cfg_copy() {
    declare -F guard_cfg_show >/dev/null || return 1
    guard_cfg_show "$1" > "$2" || { rm -f "$2"; return 1; }
    chmod +x "$2"
}

# guard_driver_path <name> <dir> -> the built-in driver, or the repo's committed one copied into
# <dir>. Exit 1 with the reason on stdout.
guard_driver_path() {
    local reason
    reason="$(guard_driver_resolvable "$1")" || { printf '%s' "$reason"; return 1; }
    guard_driver_builtin "$1" && return 0
    guard_cfg_copy "quality/drivers/${1}.sh" "$2/driver" && printf '%s' "$2/driver" && return 0
    printf 'quality/drivers/%s.sh could not be read at the config revision' "$1"; return 1
}

# guard_driver_needs_tree <name> -> 0 when the driver's describe says needs_tree: true. A driver
# whose describe cannot be read is treated as needing the tree, so it is never measured on the
# working tree by mistake.
declare -gA GUARD_NEEDS_TREE=()
guard_driver_needs_tree() {
    [ "$1" = shell ] && return 1
    if [ -z "${GUARD_NEEDS_TREE[$1]:-}" ]; then
        local tmp path ans=yes
        tmp="$(mktemp -d)"
        if path="$(guard_driver_path "$1" "$tmp")"; then
            [ "$("$path" describe 2>/dev/null | jq -r '.needs_tree' 2>/dev/null)" = false ] && ans=no
        fi
        rm -rf "$tmp"
        GUARD_NEEDS_TREE[$1]="$ans"
    fi
    [ "${GUARD_NEEDS_TREE[$1]}" = yes ]
}

# guard_run_shell <row> <base> <files> <tmp> -> value on stdout, or exit 2 with the reason on
# stderr. The command runs in this shell, under guard.sh's `set -uo pipefail` and LC_ALL=C;
# its output goes to <tmp>/output.
guard_run_shell() {
    local row="$1" base="$2" files="$3" tmp="$4" command parser artifact status=0 source
    command="$(guard_row_field "$row" command)" parser="$(guard_row_field "$row" parser)"
    artifact="$(guard_substitute "$(guard_row_field "$row" artifact)" "$base" "$files")"
    eval "$(guard_substitute "$command" "$base" "$files")" > "$tmp/output" 2>&1 || status=$?
    # parser '-' means the command's own output is the float; every other parser reads the
    # artifact. Passing the artifact cell to '-' records the literal '-'.
    # $(cat) drops trailing newlines first, as the captured output always did, so a command
    # that ends with blank lines still yields its last printed line.
    source="$artifact"
    [ "$parser" = '-' ] && source="$(printf '%s' "$(cat "$tmp/output")" | tail -1)"
    guard_parse_row "$parser" "${source:--}" "$status"
}

# guard_run_driver <row> <base> <files> <tmp> -> value on stdout, or exit 2 with the reason on
# stderr. Runs `<driver> run` with the environment of vault/architecture/qg-driver-contract.md
# and reads <tmp>/out/result.json. The engine alone decides pass or fail, from `metric`.
guard_run_driver() {
    local row="$1" base="$2" files="$3" tmp="$4" driver args path runner status=0 r
    driver="$(guard_row_field "$row" driver)"
    args="$(guard_substitute "$(guard_row_field "$row" args)" "$base" "$files")"
    path="$(guard_driver_path "$driver" "$tmp")" || { guard_err "$path"; return 2; }
    unset QG_RUNNER
    if runner="$(guard_args_kv "$args" runner)"; then
        guard_cfg_copy "$runner" "$tmp/runner" || { guard_err "runner ${runner} is not committed at the config revision"; return 2; }
        export QG_RUNNER="$tmp/runner"
    fi
    mkdir -p "$tmp/out"
    QG_ARGS="$args" QG_OUT="$tmp/out" QG_ROW="$(guard_row_field "$row" id)" QG_BASE="$base" QG_FILES="$files" \
    QG_BASES="${GUARD_BASES:-$base}" QG_TARGET="${GUARD_TARGET:-${GUARD_SHA:-HEAD}}" QG_REPO="$REPO_ROOT" \
    QG_TREE="${GUARD_TREE_DIR:-$PWD}" QG_CACHE="${GUARD_CACHE_DIR:-$(git rev-parse --path-format=absolute --git-common-dir)/guard-cache}" \
        "$path" run > "$tmp/output" 2>&1 || status=$?
    unset QG_RUNNER
    r="$tmp/out/result.json"
    [ "$status" -eq 0 ] || { guard_err "driver ${driver} exited ${status}"; return 2; }
    [ -s "$r" ] || { guard_err "driver ${driver} wrote no result.json"; return 2; }
    jq -e 'type == "object"' "$r" >/dev/null 2>&1 || { guard_err "driver ${driver} wrote a result.json that is not a JSON object"; return 2; }
    if [ "$(jq -r '.error // empty | tostring' "$r")" != '' ]; then
        guard_err "$(jq -r '.error | tostring' "$r")"; return 2
    fi
    [ "$(jq -r '.status' "$r")" = measured ] || { guard_err "driver ${driver} reports status $(jq -r '.status' "$r")"; return 2; }
    jq -r 'if (.metric | type) == "number" then .metric else "x" end' "$r" | guard_number_line \
        || { guard_err "driver ${driver} reports metric $(jq -c '.metric' "$r"), which is not a number"; return 2; }
}

# guard_number_line -> reads one number from stdin and prints it in plain decimal; exit 2 for
# anything else. jq prints 1e3 for 1000, which guard_is_number would refuse.
guard_number_line() {
    local v
    v="$(head -1 | tr -d '[:space:]')"
    [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] || return 2
    v="$(awk -v v="$v" 'BEGIN { s = sprintf("%.6f", v); sub(/0+$/, "", s); sub(/\.$/, "", s); print s }')"
    printf '%s' "$v"
}

# guard_run_row <row> <baseline path> <base ref> <files file>
#
# Appends one entry to GUARD_RESULTS and returns 0 clean, 1 worse, 2 unmeasurable.
guard_run_row() {
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
