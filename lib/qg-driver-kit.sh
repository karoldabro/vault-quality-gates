#!/usr/bin/env bash
# The driver side shared by the built-in drivers in drivers/: read QG_ARGS, pick the files to
# measure, run the tool through the runner, keep findings on added lines, share one report between
# rows of a run, and write result.json. Sourced by drivers/<name>.sh; defines functions only.
# Contract: vault/architecture/qg-driver-contract.md. Keys: vault/architecture/qg-builtin-drivers.md.
#
# A repo driver under quality/drivers/ cannot source this file; it copies the contract's todo.sh.
#
# Results come back in globals the sourcing driver reads: QG_FILE_LIST, QG_PATH_LIST, QG_RC,
# QG_ERROR, QG_COUNT.
# shellcheck disable=SC2034

# shellcheck source=qg-row.sh
. "$(dirname "${BASH_SOURCE[0]}")/qg-row.sh"
QG_KIT_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

# Maps a finding path to one relative to QG_TREE: a runner reports /app/<path>, a host tool the
# absolute tree path, some tools ./<path>.
QG_JQ_NORM='def norm($t): if type == "string" then (ltrimstr($t + "/") | ltrimstr("/app/") | ltrimstr("./")) else . end;'

qg_kv() { guard_args_kv "${QG_ARGS:-}" "$1"; }
qg_argv() { guard_args_argv "${QG_ARGS:-}"; }

# qg_files <path ERE> -> fills QG_FILE_LIST with the changed paths ($QG_FILES, NUL-separated) that
# match <path ERE> and the row's include=, miss its exclude=, and exist in QG_TREE.
qg_files() {
    local f inc exc
    inc="$(qg_kv include)" || inc=''
    exc="$(qg_kv exclude)" || exc=''
    QG_FILE_LIST=()
    while IFS= read -r -d '' f; do
        [[ "$f" =~ $1 ]] || continue
        [ -z "$inc" ] || [[ "$f" =~ $inc ]] || continue
        [ -z "$exc" ] || ! [[ "$f" =~ $exc ]] || continue
        [ -e "${QG_TREE}/${f}" ] && QG_FILE_LIST+=("$f")
    done < "${QG_FILES:-/dev/null}"
}

# qg_paths <default> -> fills QG_PATH_LIST from the comma-separated paths= key, else <default>.
qg_paths() {
    local p
    p="$(qg_kv paths)" || p="$1"
    IFS=',' read -r -a QG_PATH_LIST <<<"$p"
}

# qg_tool <report or -> <ok exit codes, space-separated> <argv...>
# Deletes <report> (a path relative to QG_TREE) so a crash never leaves the last run's report to
# be read, runs <argv> through QG_RUNNER, else in QG_TOOL_DIR (default QG_TREE), and keeps stdout
# and stderr in QG_OUT.
# Returns 1 with QG_ERROR set when the exit code is not an ok one or <report> was not written.
qg_tool() {
    local report="$1" ok="$2" a rc=0
    shift 2
    QG_ERROR=''
    for a in "$@"; do
        case "$a" in *"${QG_OUT}"*) QG_ERROR="qg_tool: the argv names ${a}, which is outside the measured tree"; return 1 ;; esac
    done
    [ "$report" = - ] || rm -f "${QG_TREE}/${report}"
    if [ -n "${QG_RUNNER:-}" ]; then "$QG_RUNNER" "$QG_TREE" "${QG_CACHE:-/tmp}" "$@" > "${QG_OUT}/stdout" 2> "${QG_OUT}/stderr" || rc=$?
    else ( cd "${QG_TOOL_DIR:-$QG_TREE}" && "$@" ) > "${QG_OUT}/stdout" 2> "${QG_OUT}/stderr" || rc=$?; fi
    QG_RC="$rc"
    # The tool's own error lines are what a person needs; never the report itself.
    cat "${QG_OUT}/stderr"
    if [[ " $ok " != *" $rc "* ]]; then
        tail -20 "${QG_OUT}/stdout"
        QG_ERROR="$(basename "$1") exited ${rc}"; return 1
    fi
    if [ "$report" != - ] && [ ! -s "${QG_TREE}/${report}" ]; then
        tail -20 "${QG_OUT}/stdout"
        QG_ERROR="$(basename "$1") exited ${rc} and wrote no report ${report}"; return 1
    fi
    return 0
}

# qg_shared_report <name> <producer function> -> $QG_OUT/<name> holds the report. Rows of one run
# that measure the same target with the same args (metric= aside) share one tool run: the first
# producer's file is kept in QG_RUN_DIR, written to a temporary name and moved into place whole.
# Without QG_RUN_DIR the producer always runs. Returns the producer's status.
qg_shared_report() {
    local name="$1" producer="$2" key file args
    args="$(printf '%s' "${QG_ARGS:-}" | tr ' ' '\n' | grep -v '^metric=' | tr '\n' ' ')"
    if [ -n "${QG_RUN_DIR:-}" ] && [ -d "$QG_RUN_DIR" ]; then
        key="$(printf '%s\n%s\n%s' "${QG_TARGET:-}" "${QG_TREE:-}" "$args" | cksum | cut -d' ' -f1)"
        file="${QG_RUN_DIR}/${name}-${key}"
        if [ -s "$file" ]; then cp "$file" "${QG_OUT}/${name}"; return 0; fi
    fi
    "$producer" || return
    if [ -n "${file:-}" ]; then
        cp "${QG_OUT}/${name}" "${file}.$$" && mv "${file}.$$" "$file"
    fi
    return 0
}

# qg_added_only <findings json file> -> rewrites the file to the findings a commit added: each on a
# line the commit adds (counted), or with no line in a changed file, or with no file at all (printed,
# never counted, as v1 guard-added-lines.sh --checkstyle does). Sets QG_COUNT. Returns 1 with QG_ERROR set when a path
# is not inside QG_TREE.
qg_added_only() {
    local findings="$1" added bad
    added="$(mktemp)"
    # shellcheck disable=SC2086  # QG_BASES is a space-separated sha list
    ( cd "${QG_REPO:-.}" && "${QG_KIT_BIN}/guard-added-lines.sh" --added --bases "${QG_BASES:-${QG_BASE:-HEAD}}" \
        --target "${QG_TARGET:-:index}" ) | awk -F'\t' '{ print $1 "\t" $2 }' > "$added" \
        || { rm -f "$added"; QG_ERROR='guard-added-lines.sh --added failed'; return 1; }
    jq -c --arg t "${QG_TREE:-}" "${QG_JQ_NORM}"' map(.file |= norm($t))' "$findings" > "${findings}.n"
    bad="$(jq -r '[.[] | .file | select(type == "string" and startswith("/"))] | first // empty' "${findings}.n")"
    if [ -n "$bad" ]; then rm -f "$added" "${findings}.n"; QG_ERROR="finding path ${bad} is not inside the measured tree"; return 1; fi
    jq -c --rawfile a "$added" --rawfile c <(tr '\0' '\n' < "${QG_FILES:-/dev/null}") '
        ($a | split("\n") | map(select(length > 0)) | map({key: ., value: true}) | from_entries) as $hit
        | ($c | split("\n") | map(select(length > 0)) | map({key: ., value: true}) | from_entries) as $changed
        | map(if (.file == null) then . + {counted: false}
              elif (.line != null and .line != 0) then (if $hit["\(.file)\t\(.line)"] then . + {counted: true} else empty end)
              elif $changed[.file] then . + {counted: false} else empty end)' "${findings}.n" > "$findings"
    QG_COUNT="$(jq '[.[] | select(.counted)] | length' "$findings")"
    jq -c 'map(del(.counted))' "$findings" > "${findings}.n" && mv "${findings}.n" "$findings"
    rm -f "$added"
}

# qg_result <driver> <status> <metric json> <unit> <findings json file or -> <error text or ->
qg_result() {
    local findings='[]' err='null'
    [ "$5" = - ] || findings="$(jq -c --arg t "${QG_TREE:-}" "${QG_JQ_NORM}"' map(.file |= norm($t))' "$5")"
    [ "$6" = - ] || err="$(jq -n --arg e "$6" '$e')"
    jq -n --arg d "$1" --arg s "$2" --argjson m "$3" --arg u "$4" --argjson f "$findings" --argjson e "$err" \
        --arg r "qg run commit --only ${QG_ROW:-<id>}" \
        '{schema: "qg.result/1", driver: $d, status: $s, metric: $m, unit: $u, findings: $f, error: $e, reproduce: $r}' \
        > "${QG_OUT}/result.json"
}

# qg_fail <driver> <unit> <reason> -> result.json with status error and no metric.
qg_fail() { qg_result "$1" error null "$2" - "$3"; }

# qg_need <driver> <unit> <key> -> the key's value; writes status error naming it when absent.
qg_need() {
    local v
    v="$(qg_kv "$3")" && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    qg_fail "$1" "$2" "driver $1 needs args key $3="
    return 1
}

qg_usage() { printf 'usage: %s.sh describe | explain [<ruleId>] | run\n' "$1" >&2; exit 2; }
