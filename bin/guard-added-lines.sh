#!/usr/bin/env bash
# Counts findings on the lines a commit adds. Prints one integer.
#
#   guard-added-lines.sh --checkstyle <file>  errors in a checkstyle report that sit on added lines
#   guard-added-lines.sh --grep <regex>       added lines matching an extended regex, in *.php
#                                             outside tests/PHPStan/Rules/Fixtures/
#   guard-added-lines.sh --added              every added line, "path<TAB>line<TAB>text"
#   options: --bases "<sha> <sha>..."  (default: the parents of the commit being made)
#            --target <commit>|:index  (default: :index)
#
# A line is added only when it is added against every base, so a merge does not count
# what an upstream parent already carries. A moved line is added. GUARD_LIST=1 prints the
# counted lines as "path:line text" instead of the count. Exit 2 on bad usage or an
# unreadable report.
set -uo pipefail
export LC_ALL=C
LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)"
. "${LIB}/guard-pass.sh"
. "${LIB}/guard-diff.sh"

mode='' arg='' bases='' target=':index'
while [ $# -gt 0 ]; do
    case "$1" in
        --checkstyle|--grep) mode="${1#--}"; arg="${2:-}"; shift 2 || break ;;
        --added)  mode=added; shift ;;
        --bases)  bases="${2:-}"; shift 2 || break ;;
        --target) target="${2:-}"; shift 2 || break ;;
        *) printf 'guard-added-lines: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done
[ -n "$mode" ] || { printf 'usage: guard-added-lines.sh --checkstyle <file> | --grep <regex> | --added\n' >&2; exit 2; }
[ -n "$bases" ] || bases="$(guard_default_bases)"

added="$(mktemp)"; trap 'rm -f "$added"' EXIT
# shellcheck disable=SC2086
guard_added_lines "$target" $bases > "$added" || exit 2

emit() {  # stdin "path<TAB>line<TAB>text" -> the count, or the lines under GUARD_LIST=1
    if [ -n "${GUARD_LIST:-}" ]; then awk -F'\t' '{ printf "%s:%s %s\n", $1, $2, $3 }'
    else awk 'END { print NR }'; fi
}

case "$mode" in
    added) cat "$added" ;;
    grep)
        RE="$arg" awk -F'\t' '
            $1 ~ /\.php$/ && $1 !~ /^tests\/PHPStan\/Rules\/Fixtures\// && $3 ~ ENVIRON["RE"]
        ' "$added" | emit ;;
    checkstyle)
        report="$(guard_checkstyle_rows "$arg")" || exit 2
        awk -F'\t' 'NR == FNR { hit[$1 "\t" $2] = 1; next } ($1 "\t" $2) in hit { print $1 "\t" $2 "\t" $3 " " $4 }' \
            "$added" <(printf '%s\n' "$report" | awk 'NF') | emit ;;
esac
