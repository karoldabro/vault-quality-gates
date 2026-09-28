#!/usr/bin/env bash
# Counts findings on the lines a commit adds. Prints one integer.
#
#   guard-added-lines.sh --checkstyle <file>  errors in a checkstyle report that sit on added lines
#   guard-added-lines.sh --grep <regex>       added lines matching an extended regex, in files
#                                             ending .<ext>; for php, outside tests/PHPStan/Rules/Fixtures/
#   guard-added-lines.sh --added              every added line, "path<TAB>line<TAB>text"
#   options: --bases "<sha> <sha>..."  (default: the parents of the commit being made)
#            --target <commit>|:index  (default: :index)
#            --ext <ext>               --grep only: the file extension to search (default: php)
#            --exclude <regex>         --grep only: skip paths matching this extended regex;
#                                      repeatable
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

mode='' arg='' bases='' target=':index' ext='php' excludes=''
while [ $# -gt 0 ]; do
    case "$1" in
        --checkstyle|--grep) mode="${1#--}"; arg="${2:-}"; shift 2 || break ;;
        --added)  mode=added; shift ;;
        --bases)  bases="${2:-}"; shift 2 || break ;;
        --target) target="${2:-}"; shift 2 || break ;;
        --ext)    ext="${2:-}"; shift 2 || break ;;
        --exclude) excludes+="${2:-}"$'\n'; shift 2 || break ;;
        *) printf 'guard-added-lines: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done
[ -n "$mode" ] || { printf 'usage: guard-added-lines.sh --checkstyle <file> | [--ext <ext>] [--exclude <regex>]... --grep <regex> | --added\n' >&2; exit 2; }
[ -n "$ext" ] || { printf 'guard-added-lines: --ext needs a value\n' >&2; exit 2; }
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
        # The suffix is compared as a string and the regexes arrive through ENVIRON, so no
        # pattern passes through awk string escaping and mawk matches what gawk matches.
        [ "$ext" = php ] && excludes+='^tests/PHPStan/Rules/Fixtures/'$'\n'
        RE="$arg" SFX=".${ext}" EX="$excludes" awk -F'\t' '
            BEGIN { n = split(ENVIRON["EX"], ex, "\n"); sfx = ENVIRON["SFX"] }
            function excluded(p,   i) { for (i = 1; i <= n; i++) if (ex[i] != "" && p ~ ex[i]) return 1; return 0 }
            length($1) >= length(sfx) && substr($1, length($1) - length(sfx) + 1) == sfx \
                && !excluded($1) && $3 ~ ENVIRON["RE"]
        ' "$added" | emit ;;
    checkstyle)
        report="$(guard_checkstyle_rows "$arg")" || exit 2
        awk -F'\t' 'NR == FNR { hit[$1 "\t" $2] = 1; next } ($1 "\t" $2) in hit { print $1 "\t" $2 "\t" $3 " " $4 }' \
            "$added" <(printf '%s\n' "$report" | awk 'NF') | emit ;;
esac
