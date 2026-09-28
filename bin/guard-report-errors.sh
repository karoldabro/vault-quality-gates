#!/usr/bin/env bash
# Prints what a refused commit must fix: one line per new finding, each starting with the
# row id, so the committing agent never has to guess which rule fired.
#
#   guard-report-errors.sh --rows "<id> <id>" --tree <dir|-> --map <rules.tsv|-> \
#       [--checks <checks.tsv>] [--bases "<sha>..."] [--target <commit>|:index]
#
# Line: <row> <file>:<line> <identifier> <message> → quality/RULES.md "### <rule id>"
#
# Reads each row's artifact: PHPStan JSON (file-less errors[] included), PHPMD JSON, or
# checkstyle filtered to added lines (a line-less error, as Pint writes, prints for any changed
# file). An exitcode row whose artifact cell names a report prints that report. Rows that run guard-added-lines.sh --grep,
# guard-baseline-growth.sh or guard-protected-paths.sh are re-run with GUARD_LIST=1 and
# print a fixed action. A leading /app/ is stripped from every path. `--map -` and a missing
# --checks read the file from HEAD. An identifier with no map row prints without a pointer.
# Exit 2 only when the map is unreadable or malformed; otherwise 0, whatever it printed.
# Fields travel joined by US (\037), never by tab: `read` collapses empty tab-separated fields.
set -uo pipefail
export LC_ALL=C
BIN="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
GUARD_LIB_DIR="$(cd "${BIN}/../lib" && pwd)"
. "${GUARD_LIB_DIR}/guard-metrics.sh"
. "${GUARD_LIB_DIR}/guard-pass.sh"
. "${GUARD_LIB_DIR}/guard-diff.sh"

rows='' tree='-' map='-' checks='' bases='' target=':index'
while [ $# -gt 0 ]; do
    case "$1" in
        --rows) rows="${2:-}" ;; --tree) tree="${2:-}" ;; --map) map="${2:-}" ;;
        --checks) checks="${2:-}" ;; --bases) bases="${2:-}" ;; --target) target="${2:-}" ;;
        *) guard_err "guard-report-errors: unknown argument $1"; exit 2 ;;
    esac
    shift 2 || break
done
[ -n "$bases" ] || bases="$(guard_default_bases)"
first="${bases%% *}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if [ "$map" = '-' ]; then guard_config_show quality/rules.tsv > "$WORK/map" || { guard_err 'guard-report-errors: HEAD has no quality/rules.tsv'; exit 2; }
else cp "$map" "$WORK/map" 2>/dev/null || { guard_err "guard-report-errors: cannot read ${map}"; exit 2; }; fi
awk -F'\t' 'NR == 1 { if ($0 != "id\ttool\tenforced_by\temits") { print "line 1 is not the rules header"; exit 1 } next }
    /^#/ || !NF { next }
    NF != 4 { printf "line %d has %d fields, the header has 4\n", NR, NF; exit 1 }' "$WORK/map" > "$WORK/maperr" \
    || { guard_err "guard-report-errors: quality/rules.tsv $(cat "$WORK/maperr")"; exit 2; }
if [ -n "$checks" ]; then cp "$checks" "$WORK/checks" 2>/dev/null || : > "$WORK/checks"
else guard_config_show quality/checks.tsv > "$WORK/checks" || : > "$WORK/checks"; fi

cd "$(git rev-parse --show-toplevel)" || exit 2
guard_changed_files "$first" "$target" > "$WORK/files"
[ "$tree" = '-' ] || export GUARD_TREE_DIR="$tree" GUARD_CACHE_DIR="$(dirname "$tree")/guard-cache"
export GUARD_BASES="$bases" GUARD_TARGET="$target" GUARD_BIN_DIR="$BIN"

added() {  # the added lines, computed once
    # shellcheck disable=SC2086
    [ -f "$WORK/added" ] || guard_added_lines "$target" $bases > "$WORK/added"
    cat "$WORK/added"
}

show_target() {
    if [ "$target" = ':index' ]; then git show ":$1" 2>/dev/null; else git show "$target:$1" 2>/dev/null; fi
}

ranges() {  # ranges <file> -> "3-5, 9", the added line numbers of the file
    added | awk -F'\t' -v f="$1" '$1 == f { print $2 }' | awk '
        NR == 1 { s = e = $1; next } $1 == e + 1 { e = $1; next }
        { out = out sep (s == e ? s : s "-" e); sep = ", "; s = e = $1 }
        END { if (NR) print out sep (s == e ? s : s "-" e); else print "none" }'
}

# record <row> <location> <identifier> <message> <extra> <action>
record() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$WORK/records"; }

print_phpstan() {
    local row="$1" file line ident msg extra
    show_target phpstan-baseline.neon > "$WORK/neon"
    while IFS=$'\037' read -r file line ident msg; do
        file="$(guard_strip_app "$file")" extra=''
        if [ -n "$file" ] && grep -qF "path: ${file}" "$WORK/neon"; then
            extra="baseline count exceeded; your added lines are $(ranges "$file")"
        fi
        case "$msg" in *'was not matched in reported errors'*) extra='run composer stan:baseline' ;; esac
        record "$row" "${file:+${file}:${line}}" "$ident" "$msg" "$extra" ''
    done < <(jq -r '((.files // {}) | to_entries[] | .key as $f | .value.messages[]
                     | [$f, (.line // "" | tostring), (.identifier // ""), .message]),
                    ((.errors // [])[] | ["", "", "", .])
                    | map(tostring | gsub("[\t\n\u001f]"; " ")) | join("\u001f")' "$2" 2>/dev/null)
}

print_phpmd() {
    local row="$1" file line rule msg
    while IFS=$'\037' read -r file line rule msg; do
        file="$(guard_strip_app "$file")"
        record "$row" "${file}${line:+:${line}}" "$rule" "$msg" '' ''
    done < <(jq -r '((.files // [])[] | .file as $f | (.violations // [])[] | [$f, (.beginLine | tostring), .rule, .description]),
                    ((.errors // [])[] | [.fileName, "", "", ("could not parse: " + (.message // ""))])
                    | map(tostring | gsub("[\t\n\u001f]"; " ")) | join("\u001f")' "$2" 2>/dev/null)
}

print_checkstyle() {  # errors on added lines, plus line-less errors (Pint) in changed files
    local row="$1" file line src msg
    while IFS=$'\037' read -r file line src msg; do
        record "$row" "${file}${line:+:${line}}" "$src" "$msg" '' ''
    done < <(awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { hit[$1 "\t" $2] = 1; next }
                                     FILENAME == ARGV[2] { changed[$0] = 1; next }
                                     ($1 "\t" $2) in hit { print; next }
                                     $2 == 0 && $1 in changed { $2 = ""; print }' \
                 <(added) <(tr '\0' '\n' < "$WORK/files") <(guard_checkstyle_rows "$2" 2>/dev/null) | tr '\t' '\037')
}

print_listed() {  # print_listed <row> <command> <action>
    local row="$1" line loc
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        loc="${line%% *}"
        [ "$loc" = "$line" ] && { record "$row" "$line" '' '' '' "$3"; continue; }
        record "$row" "$loc" '' "${line#* }" '' "$3"
    done < <(export GUARD_LIST=1; eval "$2" 2>/dev/null)
}

: > "$WORK/records"
for id in $rows; do
    row="$(awk -F'\t' -v id="$id" 'NR > 1 && $1 == id { print; exit }' "$WORK/checks")"
    [ -n "$row" ] || continue
    IFS=$'\t' read -r _ _ _ command _ artifact _ _ _ <<<"$row"
    cmd="$(guard_substitute "$command" "$first" "$WORK/files")"
    art="$(guard_substitute "$artifact" "$first" "$WORK/files")"
    case "$command" in
        *guard-added-lines.sh*--grep*)
            print_listed "$id" "$cmd" 'remove the suppression and fix the code'; continue ;;
        *guard-baseline-growth.sh*)
            print_listed "$id" "$cmd" 'fix the code, do not regenerate the baseline to hide it'; continue ;;
        *guard-protected-paths.sh*)
            print_listed "$id" "$cmd" 'stop: a human commits this with QG_SKIP_REASON'; continue ;;
    esac
    [ -r "$art" ] || continue
    if grep -q '<checkstyle' "$art"; then print_checkstyle "$id" "$art"
    elif jq -e '.totals' "$art" >/dev/null 2>&1; then print_phpstan "$id" "$art"
    elif jq -e '.files | type == "array"' "$art" >/dev/null 2>&1; then print_phpmd "$id" "$art"
    fi
done

awk -F'\t' '
    NR == FNR { if (FNR > 1 && $0 !~ /^#/ && NF == 4 && $4 != "-") rule[$4] = $1; next }
    function lookup(x,   e, best, id) {
        if (x in rule) return rule[x]
        best = 0; id = ""
        for (e in rule) if (index(x, e ".") == 1 && length(e) > best) { best = length(e); id = rule[e] }
        return id
    }
    {
        line = $1 " " ($2 == "" ? "(no file)" : $2)
        if ($3 != "") line = line " " $3
        if ($4 != "") line = line " " $4
        if ($5 != "") line = line " (" $5 ")"
        id = ($3 == "") ? "" : lookup($3)
        if ($6 != "") line = line " → " $6
        else if (id != "") line = line " → quality/RULES.md \"### " id "\""
        print line
    }' "$WORK/map" "$WORK/records"
exit 0
