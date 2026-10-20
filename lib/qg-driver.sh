#!/usr/bin/env bash
# The engine side of drivers: find a driver, copy a repo driver or runner from the config revision,
# run it, read its result.json, and keep its last output under qg-last/. Sourced by
# lib/guard-metrics.sh; defines functions only. Contract: vault/architecture/qg-driver-contract.md.

# shellcheck source=qg-row.sh
. "$(dirname "${BASH_SOURCE[0]}")/qg-row.sh"
# shellcheck source=qg-sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/qg-sandbox.sh"

# Built-in drivers are found from here; a caller that sourced this file directly may not have set it.
: "${GUARD_LIB_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

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

# guard_run_driver <row> <base> <files> <tmp> -> value on stdout, or exit 2 with the reason on
# stderr. Runs `<driver> run` with the environment of vault/architecture/qg-driver-contract.md
# and reads <tmp>/out/result.json. The engine alone decides pass or fail, from `metric`.
# A built-in driver gets QG_SANDBOX and QG_SANDBOX_WRITES from its describe: only `"sandbox": false`
# opts out, and a describe that cannot be read means sandboxed. A repo driver's whole run goes
# through qg_sandbox_run with QG_OUT writable, whatever its describe says.
guard_run_driver() {
    local row="$1" base="$2" files="$3" tmp="$4" driver args path runner status=0 r desc repo=''
    driver="$(guard_row_field "$row" driver)"
    args="$(guard_substitute "$(guard_row_field "$row" args)" "$base" "$files")"
    path="$(guard_driver_path "$driver" "$tmp")" || { guard_err "$path"; return 2; }
    unset QG_RUNNER QG_SANDBOX_SDK
    export QG_SANDBOX=1 QG_SANDBOX_WRITES=''
    if guard_driver_builtin "$driver" >/dev/null; then
        desc="$("$path" describe 2>/dev/null)"
        [ "$(jq -r 'if .sandbox == false then 0 else 1 end' <<<"$desc" 2>/dev/null)" != 0 ] || QG_SANDBOX=0
        QG_SANDBOX_WRITES="$(jq -r '.writes // [] | if type == "array" then map(tostring) | join(" ") else empty end' <<<"$desc" 2>/dev/null)"
    else
        repo=1
    fi
    if runner="$(guard_args_kv "$args" runner)"; then
        guard_cfg_copy "$runner" "$tmp/runner" || { guard_err "runner ${runner} is not committed at the config revision"; return 2; }
        export QG_RUNNER="$tmp/runner"
    fi
    mkdir -p "$tmp/out"
    QG_CONFIG_REV="${GUARD_CONFIG_REV:-${GUARD_CONFIG_AT:-$(git rev-parse -q --verify HEAD 2>/dev/null)}}" \
    QG_ARGS="$args" QG_OUT="$tmp/out" QG_ROW="$(guard_row_field "$row" id)" QG_BASE="$base" QG_FILES="$files" \
    QG_BASES="${GUARD_BASES:-$base}" QG_TARGET="${GUARD_TARGET:-${GUARD_SHA:-HEAD}}" QG_REPO="$REPO_ROOT" \
    QG_TREE="${GUARD_TREE_DIR:-$PWD}" QG_CACHE="${GUARD_CACHE_DIR:-$(git rev-parse --path-format=absolute --git-common-dir)/guard-cache}" \
        guard_driver_launch "$repo" "$path" > "$tmp/output" 2>&1 || status=$?
    unset QG_RUNNER QG_SANDBOX QG_SANDBOX_WRITES
    # The row log keeps the sandbox record last, inside the tail the engine keeps.
    [ ! -s "$tmp/out/.qg-sandbox.log" ] || sort -u "$tmp/out/.qg-sandbox.log" >> "$tmp/output"
    r="$tmp/out/result.json"
    [ -z "$QG_SANDBOX_ERROR" ] || { guard_err "$QG_SANDBOX_ERROR"; return 2; }
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

# guard_driver_launch <repo driver: 1 or empty> <path> -> runs `<path> run`. A repo driver runs whole
# inside qg_sandbox_run with QG_OUT writable; a built-in runs directly, since its qg_tool calls are
# sandboxed. Sets QG_SANDBOX_ERROR when the repo driver never ran.
guard_driver_launch() {
    QG_SANDBOX_ERROR=''
    if [ -n "$1" ]; then QG_SANDBOX=1 QG_SANDBOX_WRITES='' qg_sandbox_run --out -- "$2" run
    else "$2" run; fi
}

# guard_number_line -> reads one number from stdin and prints it in plain decimal; exit 2 for
# anything else. jq prints 1e3 for 1000, which guard_is_number would refuse.
guard_number_line() {
    local v
    v="$(head -1 | tr -d '[:space:]')"
    [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] || return 2
    # A plain decimal passes through unchanged, so a baseline written at full precision compares
    # exactly; only an exponent form is rewritten.
    if [[ "$v" =~ [eE] ]]; then
        v="$(awk -v v="$v" 'BEGIN { s = sprintf("%.10f", v); sub(/0+$/, "", s); sub(/\.$/, "", s); print s }')"
    fi
    printf '%s' "$v"
}
