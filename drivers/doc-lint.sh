#!/usr/bin/env bash
# doc-lint driver: document-standard findings a commit adds to its markdown files, measured with the
# vault framework's bin/doc-lint.sh. Contract: vault/architecture/qg-driver-contract.md; counting
# rules: vault/architecture/qg-builtin-drivers.md.
#
# args: none. The linter is the absolute path in the config key guard_doc_lint.
#
# Counted, each once:
#   doc-lint.<CODE>      a finding on an added line; a file-level finding (FILE, DUP1's x<n>) whose
#                        code no parent's version of the file has, renames followed
#   doc-lint.SKIPFILE    a .doc-lint or VAULT.md the commit adds or changes, at any depth
#   doc-lint.TYPE        a file whose type, as doc-lint reads it, differs from every parent's, or a
#                        new file with an instruction type, which doc-lint never lints
# The linter sees only the config revision's .doc-lint and VAULT.md files and none of the caller's
# environment beyond PATH, HOME and LC_ALL=C, so no file or variable the commit controls silences it.
set -uo pipefail
export LC_ALL=C
DL_HOME="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=../lib/qg-driver-kit.sh
. "${DL_HOME}/../lib/qg-driver-kit.sh"
# shellcheck source=../lib/guard-diff.sh
. "${DL_HOME}/../lib/guard-diff.sh"

DL_BATCH=200
# doc-lint's own frontmatter reader (bin/doc-lint.sh, `doc_type=`), copied verbatim: the type the
# driver compares is the type the linter acts on.
DL_TYPE_AWK='NR==1 && $0=="---"{fm=1;next} fm && /^---/{exit} fm && /^type:[[:space:]]*/{print $2; exit}'
DL_FINDING_RE='^  [A-Z][A-Z0-9]* +(L[0-9]+|FILE|x[0-9]+) '
# One finding per `<file>\t<line or empty>\t<code>\t<message>` line.
DL_JQ_FINDINGS='[split("\n")[] | select(length > 0) | split("\t")
    | {ruleId: ("doc-lint." + .[2]), file: .[0], line: (if .[1] == "" then null else (.[1] | tonumber) end),
       level: "error", message: .[3], doc: null}]'

# State the steps share: the linter, the gate's tree, the changed paths, the parents and their map.
DL_LINTER='' DL_TREE='' DL_RC=0
declare -a DL_DOCS=() DL_SKIPS=() DL_BASES=() DL_CFG=()
declare -A DL_PARENT=() DL_DOCSET=() DL_RETYPED=()

dl_fail() { qg_fail doc-lint findings "$1"; exit 0; }

# dl_check_tree -> DL_TREE, the measured tree. The driver rewrites the skip files in it, so it must
# be the gate's own copy under <git-common-dir>/guard-tree, never a working tree.
dl_check_tree() {
    local common
    common="$(git -C "$QG_REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || dl_fail "cannot read the git dir of ${QG_REPO}"
    common="$(cd "$common" && pwd -P)"
    DL_TREE="$(cd "$QG_TREE" 2>/dev/null && pwd -P)" || dl_fail "QG_TREE ${QG_TREE} does not exist"
    case "$DL_TREE/" in "${common}/guard-tree/"*) ;; *) dl_fail "QG_TREE ${QG_TREE} is not the gate's copy under ${common}/guard-tree" ;; esac
}

# dl_is_skip <path> -> 0 when a component of <path> is named .doc-lint or VAULT.md.
dl_is_skip() {
    case "/$1/" in */.doc-lint/*|*/VAULT.md/*) return 0 ;; esac
    return 1
}

# dl_scan -> DL_DOCS (changed markdown to lint), DL_RETYPED (those whose file type changed, such as a
# symlink turned into a file, linted as wholly new) and DL_SKIPS (every added, changed, retyped or
# deleted path under a .doc-lint or VAULT.md name). It reads its own diff against the first parent:
# QG_FILES leaves out type changes and deletions. A VAULT.md is never linted: the rewrite replaces it.
# A path holding a newline or tab cannot be matched to the linter's report, so it refuses the row.
dl_scan() {
    local status f
    while IFS= read -r -d '' status; do
        IFS= read -r -d '' f || break
        case "$status" in R*|C*) IFS= read -r -d '' f || break ;; esac
        case "$f" in *$'\n'*|*$'\t'*) dl_fail "a changed path holds a newline or tab, which doc-lint cannot report: $(printf '%q' "$f")" ;; esac
        if dl_is_skip "$f"; then DL_SKIPS+=("$f"); continue; fi
        case "$status" in D) continue ;; esac
        case "$f" in
            *.md) [ -f "${QG_TREE}/${f}" ] || continue
                  DL_DOCS+=("$f"); DL_DOCSET["$f"]=1
                  [ "$status" != T ] || DL_RETYPED["$f"]=1 ;;
        esac
    done < <(cd "$QG_REPO" && guard_diff "${QG_BASE:-HEAD}" "${QG_TARGET:-:index}" --name-status -z "$GUARD_RENAME_SIMILARITY")
}

# dl_resolve_linter -> DL_LINTER, from guard_doc_lint at the config revision only.
dl_resolve_linter() {
    local raw linter lib
    raw="$(qg_kit_config_key guard_doc_lint)" && [ -n "$raw" ] || dl_fail 'guard_doc_lint is not set in quality/config'
    case "$raw" in /*) ;; *) dl_fail "guard_doc_lint ${raw} is not an absolute path" ;; esac
    linter="$(readlink -f "$raw")" && [ -f "$linter" ] && [ -x "$linter" ] || dl_fail "guard_doc_lint ${raw} is not an executable file"
    for lib in sentence-count.sh prose-match.sh doc-lint-patterns.tsv; do
        [ -r "$(dirname "$linter")/../lib/${lib}" ] || dl_fail "guard_doc_lint ${raw}: ../lib/${lib} is missing beside it"
    done
    DL_LINTER="$linter"
}

# dl_parent_map -> DL_BASES and DL_PARENT: per parent, each changed path's name there. A rename maps
# back, an added path is `-`.
dl_parent_map() {
    local sha status old f
    read -r -a DL_BASES <<<"${QG_BASES:-${QG_BASE:-}}"
    for sha in "${DL_BASES[@]}"; do
        while IFS= read -r -d '' status; do
            IFS= read -r -d '' old || break
            case "$status" in
                R*|C*) IFS= read -r -d '' f || break; DL_PARENT["${sha}"$'\t'"${f}"]="$old" ;;
                A) DL_PARENT["${sha}"$'\t'"${old}"]=- ;;
                *) DL_PARENT["${sha}"$'\t'"${old}"]="$old" ;;
            esac
        done < <(cd "$QG_REPO" && guard_diff "$sha" "${QG_TARGET:-:index}" --name-status -z "$GUARD_RENAME_SIMILARITY")
    done
}

# dl_parent <sha> <path> -> the path's name at parent <sha>, empty when that parent lacks it. A path
# the diff against that parent does not list is unchanged there under its own name.
dl_parent() {
    local v="${DL_PARENT["${1}"$'\t'"${2}"]:-}"
    case "$v" in
        -) return 0 ;;
        '') git -C "$QG_REPO" cat-file -e "${1}:${2}" 2>/dev/null && printf '%s' "$2" ;;
        *) printf '%s' "$v" ;;
    esac
    return 0
}

# dl_place_config <dir> -> <dir> holds exactly the config revision's .doc-lint and VAULT.md files,
# with empty root ones when that revision has none, so the linter's upward walk stops inside <dir>.
# A path whose folder resolves outside <dir> (a symlinked folder) refuses the row: writing there
# would change a file outside the measured tree.
dl_place_config() {
    local dir="$1" p parent
    # Files, links and folders alike: a folder or a link at either name also changes what is read.
    find "$dir" \( -name .doc-lint -o -name VAULT.md \) -prune -exec rm -rf {} +
    for p in "${DL_CFG[@]}" .doc-lint VAULT.md; do
        mkdir -p "$(dirname "${dir}/${p}")" 2>/dev/null || dl_fail "cannot create the folder of ${p} in the measured tree"
        parent="$(cd "$(dirname "${dir}/${p}")" && pwd -P)"
        case "${parent}/" in "${dir}/"*) ;; *) dl_fail "${p} lies under a symlinked folder that leaves the measured tree" ;; esac
        rm -rf "${dir:?}/${p}"
        if [ "$p" = .doc-lint ] || [ "$p" = VAULT.md ]; then
            git -C "$QG_REPO" show "${QG_CONFIG_REV:-HEAD}:${p}" > "${dir}/${p}" 2>/dev/null || : > "${dir}/${p}"
        else
            git -C "$QG_REPO" show "${QG_CONFIG_REV:-HEAD}:${p}" > "${dir}/${p}"
        fi
        [ -f "${dir}/${p}" ] && [ ! -L "${dir}/${p}" ] || dl_fail "${p} is not a regular file after the config revision's copy was written"
    done
}

# dl_lint <dir> <report> <path>... -> runs the linter from <dir> on ./<path>, DL_BATCH paths per call,
# appending its output to <report>, and sets DL_RC to the highest exit code. The kit's qg_tool keeps
# one call's output, and this needs batches, so each batch goes through qg_sandbox_run itself:
# unconfined (the linter is the framework's own code), with the child environment and LC_ALL=C.
dl_lint() {
    local dir="$1" report="$2" rc i p
    shift 2
    local -a paths=("$@") batch
    DL_RC=0
    for ((i = 0; i < ${#paths[@]}; i += DL_BATCH)); do
        batch=()
        for p in "${paths[@]:i:DL_BATCH}"; do batch+=("./${p}"); done
        rc=0
        QG_SANDBOX=0 LC_ALL=C qg_sandbox_run --cwd "$dir" -- "$DL_LINTER" "${batch[@]}" >> "$report" 2>&1 || rc=$?
        [ -z "$QG_SANDBOX_ERROR" ] || { printf '%s\n' "$QG_SANDBOX_ERROR" >> "$report"; rc=125; }
        [ "$rc" -le "$DL_RC" ] || DL_RC="$rc"
    done
}

# dl_parse <report> -> one `<file>\t<loc>\t<code>\t<message>` line per finding, file without ./. A
# header is `<path>  [<type>/<class>, …]`: the path is everything before the last bracket group.
dl_parse() {
    awk -v re="$DL_FINDING_RE" '
        /^doc-lint: / { next }
        $0 !~ /^  / && match($0, /  \[[^[]*\]$/) { cur = substr($0, 1, RSTART - 1); sub(/^\.\//, "", cur); next }
        $0 ~ re { code = $1; loc = $2; msg = $0; sub(/^  [^ ]+ +[^ ]+ +/, "", msg); gsub(/\t/, " ", msg)
                  print cur "\t" loc "\t" code "\t" msg }' "$1"
}

# dl_check_rc <report> <parsed count> -> fails the row unless the exit code agrees with the output.
dl_check_rc() {
    if [ "$DL_RC" -gt 1 ] || { [ "$DL_RC" -eq 1 ] && [ "$2" -eq 0 ]; } || { [ "$DL_RC" -eq 0 ] && [ "$2" -gt 0 ]; }; then
        tail -20 "$1"
        dl_fail "doc-lint exited ${DL_RC} with ${2} parsed findings"
    fi
}

# dl_file_level <head findings tsv> <out tsv> -> the file-level findings of the commit's version
# whose code no parent's version of that file has, each parent linted beside the same config.
dl_file_level() {
    local head="$1" out="$2" sha bdir f old _loc code msg had
    local -A pcodes=()
    local -a pfiles
    : > "$out"
    [ -s "$head" ] || return 0
    for sha in "${DL_BASES[@]}"; do
        bdir="${QG_OUT}/base/${sha}"
        mkdir -p "$bdir" && : > "${bdir}/.git"
        dl_place_config "$(cd "$bdir" && pwd -P)"
        pfiles=()
        while IFS= read -r f; do
            old="$(dl_parent "$sha" "$f")"
            [ -n "$old" ] || continue
            mkdir -p "$(dirname "${bdir}/${old}")"
            git -C "$QG_REPO" show "${sha}:${old}" > "${bdir}/${old}" 2>/dev/null || continue
            pfiles+=("$old")
        done < <(cut -f1 "$head" | sort -u)
        [ "${#pfiles[@]}" -gt 0 ] || continue
        dl_lint "$bdir" "${bdir}.txt" "${pfiles[@]}"
        [ "$DL_RC" -le 1 ] || { tail -20 "${bdir}.txt"; dl_fail "doc-lint exited ${DL_RC} on the parent ${sha}"; }
        while IFS=$'\t' read -r old _loc code msg; do
            pcodes["${sha}"$'\t'"${old}"$'\t'"${code}"]=1
        done < <(dl_parse "${bdir}.txt" | grep -v -P '^[^\t]*\tL[0-9]+\t')
    done
    while IFS=$'\t' read -r f _loc code msg; do
        had=0
        for sha in "${DL_BASES[@]}"; do
            old="$(dl_parent "$sha" "$f")"
            [ -n "$old" ] && [ -n "${pcodes["${sha}"$'\t'"${old}"$'\t'"${code}"]:-}" ] && had=1
        done
        [ "$had" -eq 1 ] || printf '%s\t\t%s\t%s\n' "$f" "$code" "$msg" >> "$out"
    done < "$head"
}

# dl_blob <rev or :index> <path> -> the blob id of <path> there, empty when absent.
dl_blob() {
    if [ "$1" = :index ]; then git -C "$QG_REPO" rev-parse -q --verify ":${2}" 2>/dev/null
    else git -C "$QG_REPO" rev-parse -q --verify "${1}:${2}" 2>/dev/null; fi
    return 0
}

# dl_extra <out tsv> -> SKIPFILE for each changed .doc-lint or VAULT.md no parent already holds in
# that form, and TYPE for each type change.
dl_extra() {
    local out="$1" f sha old blob head_type ptype any differs same
    : > "$out"
    for f in "${DL_SKIPS[@]}"; do
        blob="$(dl_blob "${QG_TARGET:-:index}" "$f")"
        same=0
        for sha in "${DL_BASES[@]}"; do
            old="$(dl_parent "$sha" "$f")"
            [ -n "$old" ] && [ -n "$blob" ] && [ "$(dl_blob "$sha" "$old")" = "$blob" ] && same=1
        done
        [ "$same" -eq 1 ] || printf '%s\t\tSKIPFILE\t%s\n' "$f" "a commit may not change ${f##*/}; it is read from the config revision, and a human passes a change with qg override" >> "$out"
    done
    for f in "${DL_DOCS[@]}"; do
        head_type="$(awk "$DL_TYPE_AWK" "${QG_TREE}/${f}" 2>/dev/null || true)"
        any=0; differs=1
        for sha in "${DL_BASES[@]}"; do
            old="$(dl_parent "$sha" "$f")"
            [ -n "$old" ] || continue
            ptype="$(git -C "$QG_REPO" show "${sha}:${old}" 2>/dev/null | awk "$DL_TYPE_AWK" || true)"
            any=1
            [ "$ptype" != "$head_type" ] || differs=0
        done
        if [ "$any" -eq 1 ]; then
            [ "$differs" -eq 0 ] || printf '%s\t\tTYPE\t%s\n' "$f" "the type doc-lint reads changed to '${head_type:-none}'; a human passes a type change with qg override" >> "$out"
        else
            case "$head_type" in
                persona|command|skill|output-style)
                    printf '%s\t\tTYPE\t%s\n' "$f" "a new file of type ${head_type} is never linted; a human passes it with qg override" >> "$out" ;;
            esac
        fi
    done
}

dl_run() {
    : "${QG_OUT:?}" "${QG_TREE:?}" "${QG_REPO:?}"
    local f _rest parsed counted=0
    dl_check_tree
    dl_scan
    # A commit with nothing the driver reads needs no linter.
    if [ "${#DL_DOCS[@]}" -eq 0 ] && [ "${#DL_SKIPS[@]}" -eq 0 ]; then
        qg_result doc-lint measured 0 findings - -; return
    fi
    dl_resolve_linter
    dl_parent_map
    while IFS= read -r -d '' f; do
        case "$f" in .doc-lint|*/.doc-lint|VAULT.md|*/VAULT.md) DL_CFG+=("$f") ;; esac
    done < <(git -C "$QG_REPO" ls-tree -r -z --name-only "${QG_CONFIG_REV:-HEAD}" 2>/dev/null)
    dl_place_config "$DL_TREE"

    # The commit's version: line findings count on added lines only.
    : > "${QG_OUT}/head.tsv"; printf '[]' > "${QG_OUT}/line.json"
    if [ "${#DL_DOCS[@]}" -gt 0 ]; then
        dl_lint "$QG_TREE" "${QG_OUT}/head.txt" "${DL_DOCS[@]}"
        cat "${QG_OUT}/head.txt"
        dl_parse "${QG_OUT}/head.txt" > "${QG_OUT}/head.tsv"
        parsed="$(wc -l < "${QG_OUT}/head.tsv" | tr -d ' ')"
        dl_check_rc "${QG_OUT}/head.txt" "$parsed"
        # Every finding must name a file the driver passed, or a misread header would drop it.
        while IFS=$'\t' read -r f _rest; do
            [ -n "${DL_DOCSET["$f"]:-}" ] || dl_fail "doc-lint reported a finding for ${f}, which the driver did not pass"
        done < "${QG_OUT}/head.tsv"
        grep -P '^[^\t]*\tL[0-9]+\t' "${QG_OUT}/head.tsv" | sed 's/\tL\([0-9]*\)\t/\t\1\t/' > "${QG_OUT}/line.tsv"
        # A retyped file (a link turned into a file) is new content whole: each of its line findings counts.
        : > "${QG_OUT}/added.tsv"; : > "${QG_OUT}/retyped.tsv"
        while IFS=$'\t' read -r f _rest; do
            if [ -n "${DL_RETYPED["$f"]:-}" ]; then printf '%s\t%s\n' "$f" "$_rest" >> "${QG_OUT}/retyped.tsv"
            else printf '%s\t%s\n' "$f" "$_rest" >> "${QG_OUT}/added.tsv"; fi
        done < "${QG_OUT}/line.tsv"
        jq -R -s -c "$DL_JQ_FINDINGS" < "${QG_OUT}/added.tsv" > "${QG_OUT}/line.json" || dl_fail "cannot read the linter findings"
        qg_added_only "${QG_OUT}/line.json" || dl_fail "$QG_ERROR"
        counted="$QG_COUNT"
        if [ -s "${QG_OUT}/retyped.tsv" ]; then
            jq -R -s -c "$DL_JQ_FINDINGS" < "${QG_OUT}/retyped.tsv" > "${QG_OUT}/retyped.json"
            counted=$((counted + $(jq 'length' "${QG_OUT}/retyped.json")))
            jq -c -s 'add' "${QG_OUT}/line.json" "${QG_OUT}/retyped.json" > "${QG_OUT}/line.n" && mv "${QG_OUT}/line.n" "${QG_OUT}/line.json"
        fi
    fi
    grep -v -P '^[^\t]*\tL[0-9]+\t' "${QG_OUT}/head.tsv" > "${QG_OUT}/file.tsv"
    dl_file_level "${QG_OUT}/file.tsv" "${QG_OUT}/file-counted.tsv"
    dl_extra "${QG_OUT}/extra.tsv"

    cat "${QG_OUT}/file-counted.tsv" "${QG_OUT}/extra.tsv" | jq -R -s -c "$DL_JQ_FINDINGS" > "${QG_OUT}/rest.json"
    counted=$((counted + $(jq 'length' "${QG_OUT}/rest.json")))
    jq -c -s 'add' "${QG_OUT}/line.json" "${QG_OUT}/rest.json" > "${QG_OUT}/findings.json"
    qg_result doc-lint measured "$counted" findings "${QG_OUT}/findings.json" -
}

case "${1:-}" in
    describe)
        printf '{"name":"doc-lint","summary":"document-standard findings a commit adds to its markdown files","requires":["jq","git","awk","grep"],"needs_tree":true,"sandbox":false,"writes":[]}\n' ;;
    explain)
        case "${2:-}" in
            doc-lint.SKIPFILE)
                printf 'The commit adds or changes a .doc-lint or VAULT.md. Both change what doc-lint checks, so the gate\n'
                printf 'reads them from the config revision and counts the change. Drop it from the commit, or ask the\n'
                printf 'operator to pass it with qg override.\n' ;;
            doc-lint.TYPE)
                printf 'The frontmatter type: that doc-lint reads changed, or a new file has a type doc-lint never lints\n'
                printf '(persona, command, skill, output-style). The type decides which checks run. Restore it, or ask\n'
                printf 'the operator to pass a deliberate change with qg override.\n' ;;
            doc-lint.*)
                printf 'doc-lint code %s: run the linter on the file for its message, and see the document standard\n' "${2#doc-lint.}"
                printf '(commands/_shared/document-standard.md in the vault framework). Fix the line the commit added.\n' ;;
            *)
                printf 'Lints the markdown files a commit changes with the vault framework doc-lint (guard_doc_lint).\n'
                printf 'Counts findings on added lines, file-level findings no parent had, a changed .doc-lint or\n'
                printf 'VAULT.md, and a changed document type. Fix the finding, or ask the operator for qg override.\n' ;;
        esac ;;
    run)
        dl_run ;;
    *)
        qg_usage doc-lint ;;
esac
