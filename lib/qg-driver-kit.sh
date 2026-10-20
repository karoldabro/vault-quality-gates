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
# shellcheck source=qg-sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/qg-sandbox.sh"
QG_KIT_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
QG_KIT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# qg_kit_config_key <key> -> the key's value at QG_CONFIG_REV through the engine's one reader,
# lib/qg-config.sh. An empty QG_CONFIG_REV means a first commit, which reads the index.
qg_kit_config_key() (
    cd "${QG_REPO:-.}" || exit 1
    # shellcheck source=qg-config.sh
    . "${QG_KIT_LIB}/qg-config.sh"
    GUARD_CONFIG_REV="${QG_CONFIG_REV:-}"
    guard_config_show() { git show ":$1" 2>/dev/null; }
    qg_config_key "$1"
)

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
# be read, then runs <argv> through qg_sandbox_run (lib/qg-sandbox.sh), in QG_TOOL_DIR (default
# QG_TREE). With QG_RUNNER the committed runner runs outside the sandbox and is handed the sandboxed
# argv, so it may prepare the tree; only the tool it starts is confined. The folder of <report> joins the declared writes. stdout and stderr
# land in QG_OUT through descriptors this shell opened; the tool itself can never write QG_OUT.
# argv[0] is a program, never a shell function: a function would run outside the sandbox.
# Returns 1 with QG_ERROR set when the exit code is not an ok one, <report> was not written, or the
# sandbox refused to start the tool.
qg_tool() {
    local report="$1" ok="$2" a rc=0 denied name
    local QG_SANDBOX_WRITES="${QG_SANDBOX_WRITES:-}"
    shift 2
    QG_ERROR=''
    for a in "$@"; do
        case "$a" in *"${QG_OUT}"*) QG_ERROR="qg_tool: the argv names ${a}, which is outside the measured tree"; return 1 ;; esac
    done
    [ "$(type -t "$1")" != function ] || { QG_ERROR="qg_tool: $1 is a shell function; pass the program and its argv"; return 1; }
    # A `/bin/sh -c <script> <name> ...` wrapper is named by its $0.
    name="$(basename "$1")"
    [ "$1 ${2:-}" != '/bin/sh -c' ] || name="${4:-sh}"
    if [ "$report" != - ]; then
        rm -f "${QG_TREE}/${report}"
        [ "$(dirname "$report")" = . ] || QG_SANDBOX_WRITES+=" $(dirname "$report")"
    fi
    if [ -n "${QG_RUNNER:-}" ]; then qg_sandbox_run --runner "$QG_RUNNER" "$QG_TREE" "${QG_CACHE:-/tmp}" -- "$@" > "${QG_OUT}/stdout" 2> "${QG_OUT}/stderr" || rc=$?
    else qg_sandbox_run --cwd "${QG_TOOL_DIR:-$QG_TREE}" -- "$@" > "${QG_OUT}/stdout" 2> "${QG_OUT}/stderr" || rc=$?; fi
    QG_RC="$rc"
    # The tool's own error lines are what a person needs; never the report itself.
    cat "${QG_OUT}/stderr"
    if [ -n "$QG_SANDBOX_ERROR" ]; then QG_ERROR="$QG_SANDBOX_ERROR"; return 1; fi
    if [[ " $ok " != *" $rc "* ]]; then
        tail -20 "${QG_OUT}/stdout"
        QG_ERROR="${name} exited ${rc}"
        denied="$(qg_sandbox_denied "${QG_OUT}/stderr")"
        [ -z "$denied" ] || [ -z "$QG_SANDBOX_ARMED" ] || QG_ERROR+="; the sandbox refused: ${denied}"
        return 1
    fi
    if [ "$report" != - ] && [ ! -s "${QG_TREE}/${report}" ]; then
        tail -20 "${QG_OUT}/stdout"
        QG_ERROR="${name} exited ${rc} and wrote no report ${report}"; return 1
    fi
    return 0
}

# qg_shared_report <name> <producer function> [<key>...] -> $QG_OUT/<name> holds the report. Rows of
# one run that measure the same target with the same args, the listed keys aside (default: metric),
# share one tool run: the first producer's file is kept in QG_RUN_DIR, written to a temporary name and
# moved into place whole. Without QG_RUN_DIR the producer always runs. Returns the producer's status.
qg_shared_report() {
    local name="$1" producer="$2" key file args head tail='' w k skip
    shift 2
    [ "$#" -gt 0 ] || set -- metric
    # Only whole key=value words before ` -- ` are left out; the extra argv always counts.
    head="${QG_ARGS:-}"
    case "$head" in '-- '*) tail="$head"; head='' ;; *' -- '*) tail="-- ${head#* -- }"; head="${head%% -- *}" ;; esac
    args=''
    for w in $head; do
        skip=''
        for k in "$@"; do case "$w" in "$k="*) skip=1 ;; esac; done
        [ -n "$skip" ] || args+="$w "
    done
    args+="$tail"
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

# qg_clover_percent <tree path of a Clover report> -> sets QG_PCT to covered over total statements of the
# project as a percentage with two decimals. Returns 1 with QG_ERROR set when the report has no
# project totals, holds a value that is not a whole number, or counts zero statements.
qg_clover_percent() {
    local f="${QG_TREE}/$1" total covered
    [ -s "$f" ] || { QG_ERROR="coverage report $1 does not exist or is empty"; return 1; }
    total="$(xmllint --xpath 'string(/coverage/project/metrics/@statements)' "$f" 2>/dev/null)"
    covered="$(xmllint --xpath 'string(/coverage/project/metrics/@coveredstatements)' "$f" 2>/dev/null)"
    [ -n "$total" ] || { QG_ERROR="$1 has no /coverage/project/metrics"; return 1; }
    # Anyone can write the report; at most nine digits keeps the arithmetic exact.
    [[ "$total" =~ ^[0-9]{1,9}$ ]] && [[ "${covered:-0}" =~ ^[0-9]{1,9}$ ]] \
        || { QG_ERROR="$1: statements or coveredstatements is not a whole number"; return 1; }
    [ "$total" -gt 0 ] || { QG_ERROR="$1: zero statements, nothing was measured"; return 1; }
    QG_PCT="$(awk -v c="${covered:-0}" -v t="$total" 'BEGIN { printf "%.2f", c / t * 100 }')"
}

# qg_pnpm_prepare <empty work folder> -> fills QG_PNPM with the command that runs pnpm from that
# folder with no inherited configuration: no environment variable but PATH and LANG, HOME and the XDG
# config folder pointed at the work folder, empty user and global rc files, and the public registry.
# The store and the dlx cache live under QG_CACHE, which agents may not write, so a second run needs
# no network. Callers run "${QG_PNPM[@]}" through qg_tool with QG_TOOL_DIR set to the folder.
qg_pnpm_prepare() {
    local work="$1" store
    store="${QG_CACHE:-$work}/pnpm"
    mkdir -p "$store" || return 1
    : > "${work}/.empty-rc"
    printf 'registry=https://registry.npmjs.org/\nstore-dir=%s/store\ncache-dir=%s/cache\n' "$store" "$store" > "${work}/.npmrc"
    printf 'packages: []\nstoreDir: %s/store\ncacheDir: %s/cache\n' "$store" "$store" > "${work}/pnpm-workspace.yaml"
    QG_PNPM=(env -i "PATH=${PATH}" "LANG=${LANG:-C.UTF-8}" "HOME=${work}" "XDG_CONFIG_HOME=${work}"
        "npm_config_userconfig=${work}/.empty-rc" "npm_config_globalconfig=${work}/.empty-rc" pnpm)
}

# qg_jscpd_report <driver> -> $QG_OUT/jscpd.json holds jscpd's JSON report over QG_PATH_LIST (call
# qg_paths first). With bin= jscpd runs from the measured tree, through the runner when there is one.
# Without it `pnpm dlx jscpd@<version>` runs: through the runner, or on the host from an empty folder
# through qg_pnpm_prepare, scanning the tree by absolute path. Keys: bin config version min-lines
# min-tokens format ignore, then -- <argv>. Returns 1 with QG_ERROR set.
qg_jscpd_report() {
    local version bin config v work='' out report rc=0
    local -a argv opts=() scan=() cmd=()
    version="$(qg_kv version)" || version=5.3.2
    read -ra argv <<<"$(qg_argv)"
    v="$(qg_kv min-lines)" && opts+=(--min-lines "$v")
    v="$(qg_kv min-tokens)" && opts+=(--min-tokens "$v")
    v="$(qg_kv format)" && opts+=(--format "$v")
    v="$(qg_kv ignore)" && opts+=(--ignore "$v")
    config="$(qg_kv config)" || config=''
    if bin="$(qg_kv bin)"; then
        cmd=("$bin")
    elif [ -n "${QG_RUNNER:-}" ]; then
        cmd=(pnpm dlx "jscpd@${version}")
    else
        # On the host jscpd runs from an empty folder: the commit's .npmrc, .jscpd.json and package.json
        # are never read, and neither is any configuration of the person or process running the gate.
        work="$(mktemp -d)" || { QG_ERROR='cannot create a work folder'; return 1; }
        qg_pnpm_prepare "$work" || { rm -rf "$work"; QG_ERROR='cannot prepare the pnpm work folder'; return 1; }
        cmd=("${QG_PNPM[@]}" dlx "jscpd@${version}")
    fi
    if [ -n "$work" ]; then
        for v in "${QG_PATH_LIST[@]}"; do scan+=("${QG_TREE}/${v}"); done
        [ -z "$config" ] || opts+=(-c "${QG_TREE}/${config}")
        out="${work}/out"; report="${out}/jscpd-report.json"
    else
        # Run in the tree, through the runner or not: the report is written inside it and removed after.
        scan=("${QG_PATH_LIST[@]}")
        [ -z "$config" ] || opts+=(-c "$config")
        out=".qg-jscpd-${QG_ROW:-row}"; report="${QG_TREE}/${out}/jscpd-report.json"
        rm -rf "${QG_TREE:?}/${out}"
    fi
    # --absolute: with several scan roots jscpd otherwise names each file relative to its own root,
    # and app/x.ts and server/x.ts would both read x.ts.
    QG_TOOL_DIR="${work:-$QG_TREE}" qg_tool - 0 "${cmd[@]}" "${scan[@]}" "${opts[@]}" \
        --absolute --reporters json --output "$out" --silent --no-colors "${argv[@]}" || rc=1
    if [ "$rc" -eq 0 ] && [ ! -s "$report" ]; then QG_ERROR="jscpd exited ${QG_RC} and wrote no report"; rc=1; fi
    [ "$rc" -ne 0 ] || cp "$report" "${QG_OUT}/jscpd.json"
    if [ -n "$work" ]; then rm -rf "$work"; else rm -rf "${QG_TREE:?}/${out}"; fi
    return "$rc"
}

# qg_result <driver> <status> <metric json> <unit> <findings json file or -> <error text or ->
qg_result() {
    local err='null' f="${QG_OUT}/.findings.norm.json"
    # Findings travel in a file: thousands of them exceed the argument size limit of one exec.
    if [ "$5" = - ]; then printf '[]' > "$f"
    else jq -c --arg t "${QG_TREE:-}" "${QG_JQ_NORM}"' map(.file |= norm($t))' "$5" > "$f"; fi
    [ "$6" = - ] || err="$(jq -n --arg e "$6" '$e')"
    jq -n --arg d "$1" --arg s "$2" --argjson m "$3" --arg u "$4" --slurpfile f "$f" --argjson e "$err" \
        --arg r "qg run commit --only ${QG_ROW:-<id>}" \
        '{schema: "qg.result/1", driver: $d, status: $s, metric: $m, unit: $u, findings: $f[0], error: $e, reproduce: $r}' \
        > "${QG_OUT}/result.json"
    rm -f "$f"
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
