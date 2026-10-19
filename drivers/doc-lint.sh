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
# environment beyond PATH and HOME, so no file or variable the commit controls silences it.
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

dl_fail() { qg_fail doc-lint findings "$1"; exit 0; }

# dl_lint <dir> <report> <path>... -> runs the linter from <dir> on ./<path>, DL_BATCH paths per call,
# appending its output to <report>. Sets DL_RC to the highest exit code.
dl_lint() {
    local dir="$1" report="$2" rc i
    shift 2
    local -a paths=("$@") batch
    DL_RC=0
    for ((i = 0; i < ${#paths[@]}; i += DL_BATCH)); do
        batch=()
        for p in "${paths[@]:i:DL_BATCH}"; do batch+=("./${p}"); done
        rc=0
        ( cd "$dir" && env -i PATH="$PATH" HOME="${HOME:-/}" LC_ALL=C "$DL_LINTER" "${batch[@]}" ) >> "$report" 2>&1 < /dev/null || rc=$?
        [ "$rc" -le "$DL_RC" ] || DL_RC="$rc"
    done
}

# dl_parse <report> -> one `<file>\t<loc>\t<code>\t<message>` line per finding, file without ./.
dl_parse() {
    awk -v re="$DL_FINDING_RE" '
        $0 !~ /^  / && index($0, "  [") > 1 { cur = substr($0, 1, index($0, "  [") - 1); sub(/^\.\//, "", cur); next }
        $0 ~ re { code = $1; loc = $2; msg = $0; sub(/^  [^ ]+ +[^ ]+ +/, "", msg); print cur "\t" loc "\t" code "\t" msg }' "$1"
}

# dl_check_rc <report> <parsed count> -> fails the row unless the exit code agrees with the output.
dl_check_rc() {
    if [ "$DL_RC" -gt 1 ] || { [ "$DL_RC" -eq 1 ] && [ "$2" -eq 0 ]; } || { [ "$DL_RC" -eq 0 ] && [ "$2" -gt 0 ]; }; then
        tail -20 "$1"
        dl_fail "doc-lint exited ${DL_RC} with ${2} parsed findings"
    fi
}

dl_type_of() { awk "$DL_TYPE_AWK" "$1" 2>/dev/null || true; }

# dl_parent <sha> <path> -> the path's name at parent <sha>, empty when that parent lacks it. Reads
# dl_run's `parent` map: a rename maps back, an added path is `-`, and a path the diff against that
# parent does not list is unchanged there under its own name.
dl_parent() {
    local v="${parent["${1}"$'\t'"${2}"]:-}"
    case "$v" in
        -) return 0 ;;
        '') git -C "$QG_REPO" cat-file -e "${1}:${2}" 2>/dev/null && printf '%s' "$2" ;;
        *) printf '%s' "$v" ;;
    esac
    return 0
}

dl_run() {
    : "${QG_OUT:?}" "${QG_TREE:?}" "${QG_REPO:?}"
    local common tree repo raw linter lib f code loc msg sha old status

    # (1) The driver rewrites skip files in the tree it measures, so that tree must be the gate's copy.
    common="$(git -C "$QG_REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || dl_fail "cannot read the git dir of ${QG_REPO}"
    common="$(cd "$common" && pwd -P)"
    tree="$(cd "$QG_TREE" 2>/dev/null && pwd -P)" || dl_fail "QG_TREE ${QG_TREE} does not exist"
    repo="$(cd "$QG_REPO" && pwd -P)"
    case "$tree/" in "${common}/guard-tree/"*) ;; *) dl_fail "QG_TREE ${QG_TREE} is not the gate's copy under ${common}/guard-tree" ;; esac
    [ "$tree" != "$repo" ] || dl_fail "QG_TREE is the repo itself"

    # (2) The linter path comes from the config revision only.
    raw="$(qg_kit_config_key guard_doc_lint)" && [ -n "$raw" ] || dl_fail 'guard_doc_lint is not set in quality/config'
    case "$raw" in /*) ;; *) dl_fail "guard_doc_lint ${raw} is not an absolute path" ;; esac
    linter="$(readlink -f "$raw")" && [ -f "$linter" ] && [ -x "$linter" ] || dl_fail "guard_doc_lint ${raw} is not an executable file"
    for lib in sentence-count.sh prose-match.sh doc-lint-patterns.tsv; do
        [ -r "$(dirname "$linter")/../lib/${lib}" ] || dl_fail "guard_doc_lint ${raw}: ../lib/${lib} is missing beside it"
    done
    DL_LINTER="$linter"

    # (3) What the commit changed, read before the tree is rewritten.
    local -a docs=() skips=()
    while IFS= read -r -d '' f; do
        case "$f" in
            .doc-lint|*/.doc-lint|VAULT.md|*/VAULT.md) skips+=("$f") ;;
        esac
        case "$f" in *.md) [ -f "${QG_TREE}/${f}" ] && docs+=("$f") ;; esac
    done < "${QG_FILES:-/dev/null}"
    if [ "${#docs[@]}" -eq 0 ] && [ "${#skips[@]}" -eq 0 ]; then
        qg_result doc-lint measured 0 findings - -; return
    fi
    # Parent path of each changed path, per parent: renames map back, an added path has none.
    local -A parent=()
    local -a bases
    read -r -a bases <<<"${QG_BASES:-${QG_BASE:-}}"
    for sha in "${bases[@]}"; do
        while IFS= read -r -d '' status; do
            IFS= read -r -d '' old || break
            case "$status" in
                R*|C*) IFS= read -r -d '' f || break; parent["${sha}"$'\t'"${f}"]="$old" ;;
                A) parent["${sha}"$'\t'"${old}"]=- ;;
                *) parent["${sha}"$'\t'"${old}"]="$old" ;;
            esac
        done < <(cd "$QG_REPO" && guard_diff "$sha" "${QG_TARGET:-:index}" --name-status -z "$GUARD_RENAME_SIMILARITY")
    done

    # (4) Only the config revision's skip files and VAULT.md apply; empty root ones stop the walk here.
    local -a cfg=()
    while IFS= read -r -d '' f; do
        case "$f" in .doc-lint|*/.doc-lint|VAULT.md|*/VAULT.md) cfg+=("$f") ;; esac
    done < <(git -C "$QG_REPO" ls-tree -r -z --name-only "${QG_CONFIG_REV:-HEAD}" 2>/dev/null)
    find "$QG_TREE" -type f \( -name .doc-lint -o -name VAULT.md \) -delete
    dl_place_config() {  # dl_place_config <dir>
        local p
        for p in "${cfg[@]}"; do
            mkdir -p "$(dirname "$1/$p")" && git -C "$QG_REPO" show "${QG_CONFIG_REV:-HEAD}:${p}" > "$1/$p"
        done
        [ -e "$1/.doc-lint" ] || : > "$1/.doc-lint"
        [ -e "$1/VAULT.md" ] || : > "$1/VAULT.md"
    }
    dl_place_config "$QG_TREE"

    local counted=0 parsed
    : > "${QG_OUT}/line.tsv"; : > "${QG_OUT}/file.tsv"; printf '[]' > "${QG_OUT}/line.json"
    if [ "${#docs[@]}" -gt 0 ]; then
        # (5) and (6) The commit's version.
        dl_lint "$QG_TREE" "${QG_OUT}/head.txt" "${docs[@]}"
        cat "${QG_OUT}/head.txt"
        dl_parse "${QG_OUT}/head.txt" > "${QG_OUT}/head.tsv"
        parsed="$(wc -l < "${QG_OUT}/head.tsv" | tr -d ' ')"
        dl_check_rc "${QG_OUT}/head.txt" "$parsed"
        awk -F'\t' '$2 ~ /^L[0-9]+$/' "${QG_OUT}/head.tsv" > "${QG_OUT}/line.tsv"
        awk -F'\t' '$2 !~ /^L[0-9]+$/' "${QG_OUT}/head.tsv" > "${QG_OUT}/file.tsv"
        jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t")
            | {ruleId: ("doc-lint." + .[2]), file: .[0], line: (.[1][1:] | tonumber), level: "error", message: .[3], doc: null}]' \
            "${QG_OUT}/line.tsv" > "${QG_OUT}/line.json"
        qg_added_only "${QG_OUT}/line.json" || dl_fail "$QG_ERROR"
        counted=$((counted + QG_COUNT))
    fi

    # (7) A file-level code counts only when no parent's version of the file has it.
    : > "${QG_OUT}/file-counted.tsv"
    if [ -s "${QG_OUT}/file.tsv" ]; then
        local -A pcodes=()
        local -a pfiles
        for sha in "${bases[@]}"; do
            local bdir="${QG_OUT}/base/${sha}"
            mkdir -p "$bdir" && : > "${bdir}/.git" && dl_place_config "$bdir"
            pfiles=()
            while IFS= read -r f; do
                old="$(dl_parent "$sha" "$f")"
                [ -n "$old" ] || continue
                mkdir -p "$(dirname "${bdir}/${old}")"
                git -C "$QG_REPO" show "${sha}:${old}" > "${bdir}/${old}" 2>/dev/null || continue
                pfiles+=("$old")
            done < <(cut -f1 "${QG_OUT}/file.tsv" | sort -u)
            [ "${#pfiles[@]}" -gt 0 ] || continue
            dl_lint "$bdir" "${bdir}.txt" "${pfiles[@]}"
            [ "$DL_RC" -le 1 ] || { tail -20 "${bdir}.txt"; dl_fail "doc-lint exited ${DL_RC} on the parent ${sha}"; }
            while IFS=$'\t' read -r old loc code msg; do
                pcodes["${sha}"$'\t'"${old}"$'\t'"${code}"]=1
            done < <(dl_parse "${bdir}.txt" | awk -F'\t' '$2 !~ /^L[0-9]+$/')
        done
        while IFS=$'\t' read -r f loc code msg; do
            local had=0
            for sha in "${bases[@]}"; do
                old="$(dl_parent "$sha" "$f")"
                [ -n "$old" ] && [ -n "${pcodes["${sha}"$'\t'"${old}"$'\t'"${code}"]:-}" ] && had=1
            done
            [ "$had" -eq 1 ] || printf '%s\t%s\t%s\n' "$f" "$code" "$msg" >> "${QG_OUT}/file-counted.tsv"
        done < "${QG_OUT}/file.tsv"
    fi

    # (8) and (9) Skip files, VAULT.md and type changes.
    : > "${QG_OUT}/extra.tsv"
    for f in "${skips[@]}"; do
        printf '%s\tSKIPFILE\t%s\n' "$f" "a commit may not change ${f##*/}; it is read from the config revision, and a human passes a change with qg override" >> "${QG_OUT}/extra.tsv"
    done
    local head_type ptype any differs
    for f in "${docs[@]}"; do
        head_type="$(dl_type_of "${QG_TREE}/${f}")"
        any=0; differs=1
        for sha in "${bases[@]}"; do
            old="$(dl_parent "$sha" "$f")"
            [ -n "$old" ] || continue
            ptype="$(git -C "$QG_REPO" show "${sha}:${old}" 2>/dev/null | awk "$DL_TYPE_AWK" || true)"
            any=1
            [ "$ptype" != "$head_type" ] || differs=0
        done
        if [ "$any" -eq 1 ]; then
            [ "$differs" -eq 0 ] || printf '%s\tTYPE\t%s\n' "$f" "the type doc-lint reads changed to '${head_type:-none}'; a human passes a type change with qg override" >> "${QG_OUT}/extra.tsv"
        else
            case "$head_type" in
                persona|command|skill|output-style)
                    printf '%s\tTYPE\t%s\n' "$f" "a new file of type ${head_type} is never linted; a human passes it with qg override" >> "${QG_OUT}/extra.tsv" ;;
            esac
        fi
    done

    cat "${QG_OUT}/file-counted.tsv" "${QG_OUT}/extra.tsv" | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t")
        | {ruleId: ("doc-lint." + .[1]), file: .[0], line: null, level: "error", message: .[2], doc: null}]' > "${QG_OUT}/rest.json"
    counted=$((counted + $(jq 'length' "${QG_OUT}/rest.json")))
    jq -c -s 'add' "${QG_OUT}/line.json" "${QG_OUT}/rest.json" > "${QG_OUT}/findings.json"
    qg_result doc-lint measured "$counted" findings "${QG_OUT}/findings.json" -
}

case "${1:-}" in
    describe)
        printf '{"name":"doc-lint","summary":"document-standard findings a commit adds to its markdown files","requires":["jq","git","awk"],"needs_tree":true}\n' ;;
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
