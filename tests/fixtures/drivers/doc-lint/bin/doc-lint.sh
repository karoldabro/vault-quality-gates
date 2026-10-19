#!/usr/bin/env bash
# Fixture linter for tests/unit/qg-driver-doc-lint.bats, in the framework layout (bin/ beside lib/).
# It behaves like bin/doc-lint.sh of the vault framework where the driver depends on it:
#   - the nearest .doc-lint and VAULT.md are found walking up from each file, stopping at a .git
#   - a file whose type is persona, command, skill or output-style is skipped, and so is a file with
#     no type outside the document folders, with the framework's own awk expression
#   - DOC_LINT=off exits 0 and DOC_LINT_SKIP adds codes, so a leak of either shows in the metric
#   - output is `<path>  [..]` then `  <CODE> <L<n>|FILE|x<n>> <message>`, and exit 1 on a finding
# Findings come from marker lines in the linted file:
#   LINT:<CODE>      a finding on that line (L<n>)
#   FILELINT:<CODE>  a file-level finding (FILE)
#   DUPLINT          a DUP1 finding with location x3
#   SCOPE:<value>    INDEX3 (FILE) when <value> is not in the nearest VAULT.md indication_scopes
# Control files beside bin/: exit-code (exit with that code after printing), env.out (receives the
# environment), print-on-zero (print a finding line and still exit 0).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env > "${HERE}/env.out"
for lib in sentence-count.sh prose-match.sh doc-lint-patterns.tsv; do
    [ -r "${HERE}/lib/${lib}" ] || { printf 'fixture: missing lib/%s\n' "$lib" >&2; exit 2; }
done
[ "${DOC_LINT:-}" = off ] && exit 0

up_find() {  # up_find <file> <name> -> the nearest <name> above <file>, stopping at a .git
    local dir; dir="$(cd "$(dirname "$1")" && pwd)"
    while [ -n "$dir" ] && [ "$dir" != / ]; do
        [ -f "${dir}/$2" ] && { printf '%s' "${dir}/$2"; return 0; }
        [ -e "${dir}/.git" ] && return 1
        dir="$(dirname "$dir")"
    done
    return 1
}

is_document_folder() {
    case "$(dirname "$1")" in
        */plans|*/plans/*|*/features|*/features/*|*/decisions|*/decisions/*|*/indications|*/indications/*) return 0 ;;
    esac
    return 1
}

violations=0
for file in "$@"; do
    [ -f "$file" ] || { printf 'doc-lint: no such file: %s\n' "$file" >&2; violations=$((violations + 1)); continue; }
    skip=",${DOC_LINT_SKIP:-},"
    if f="$(up_find "$file" .doc-lint)"; then
        while read -r code _rest; do
            case "$code" in ''|'#'*) continue ;; esac
            skip="${skip}${code},"
        done < "$f"
    fi
    doc_type="$(awk 'NR==1 && $0=="---"{fm=1;next} fm && /^---/{exit} fm && /^type:[[:space:]]*/{print $2; exit}' "$file" || true)"
    if [ -z "$doc_type" ] && ! is_document_folder "$file"; then continue; fi
    case "$doc_type" in persona|command|skill|output-style) continue ;; esac
    scopes=''
    if v="$(up_find "$file" VAULT.md)"; then
        scopes=",$(sed -n 's/^indication_scopes:[[:space:]]*\[\(.*\)\][[:space:]]*$/\1/p' "$v" | tr -d ' '),"
    fi
    header=0
    emit() {  # emit <code> <location> <message>
        case "$skip" in *",$1,"*) return 0 ;; esac
        [ "$header" = 1 ] || { printf '%s  [fixture/contract, 1 lines, cap 400]\n' "$file"; header=1; }
        printf '  %-6s %-8s %s\n' "$1" "$2" "$3"
        violations=$((violations + 1))
    }
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        case "$line" in
            *LINT:*)
                code="${line##*LINT:}"; code="${code%% *}"
                case "$line" in
                    *FILELINT:*) emit "$code" FILE "fixture file-level ${code}" ;;
                    *) emit "$code" "L${n}" "fixture ${code}" ;;
                esac ;;
            *DUPLINT*) emit DUP1 x3 "repeated line" ;;
            *SCOPE:*)
                s="${line##*SCOPE:}"; s="${s%% *}"
                case "$scopes" in *",${s},"*) ;; *) emit INDEX3 FILE "undeclared scope value(s): ${s}" ;; esac ;;
        esac
    done < "$file"
done
if [ -f "${HERE}/print-on-zero" ]; then printf '%s  [fixture]\n  LONG1  L1       printed\n' "${1:-x}"; exit 0; fi
[ -f "${HERE}/exit-code" ] && exit "$(cat "${HERE}/exit-code")"
case "$PWD" in */base/*) [ -f "${HERE}/exit-code-base" ] && exit "$(cat "${HERE}/exit-code-base")" ;; esac
[ "$violations" -eq 0 ] || { printf '\ndoc-lint: %s violation(s).\n' "$violations"; exit 1; }
exit 0
