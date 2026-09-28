#!/usr/bin/env bash
# What a target adds against its bases. A target is `:index` (the index git is about to
# commit, honouring GIT_INDEX_FILE) or a commit. Sourced; defines functions only.
#
# Rename detection runs at 30% similarity, below git's default 50%, so a file that was
# moved and rewritten keeps its unchanged legacy lines out of the added set.

GUARD_RENAME_SIMILARITY='-M30%'

# guard_diff <base> <target> <git diff options...>
guard_diff() {
    local base="$1" target="$2"; shift 2
    if [ "$target" = ':index' ]; then
        git -c core.quotePath=false diff --cached --no-color --no-ext-diff "$@" "$base" --
    else
        git -c core.quotePath=false diff --no-color --no-ext-diff "$@" "$base" "$target" --
    fi
}

# guard_changed_files <base> <target> -> NUL-separated added, copied, modified and renamed paths.
guard_changed_files() {
    guard_diff "$1" "$2" --name-only -z --diff-filter=ACMR "$GUARD_RENAME_SIMILARITY"
}

# guard_touched_paths <base> <target> -> every path that differs, both sides of a rename, one per
# line. Read NUL-separated, never C-quoted: a newline in a name splits it, and the fragment that
# starts the path still carries its directory, so a protected prefix still matches.
guard_touched_paths() { guard_diff "$1" "$2" --name-only --no-renames -z | tr '\0' '\n'; }

# GUARD_AWK_UNQUOTE — awk function unquote(s): undoes git's C-quoting of a path ("a\"b" -> a"b).
# An unquoted path comes back unchanged.
GUARD_AWK_UNQUOTE='
function unquote(s,   out, i, c, n) {
    if (s !~ /^".*"$/) return s
    s = substr(s, 2, length(s) - 2); out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c != "\\") { out = out c; continue }
        c = substr(s, ++i, 1)
        if (c ~ /[0-7]/) { n = (c + 0) * 64 + substr(s, i + 1, 1) * 8 + substr(s, i + 2, 1); i += 2; out = out sprintf("%c", n); continue }
        out = out (c == "n" ? "\n" : c == "t" ? "\t" : c == "a" ? "\007" : c == "b" ? "\b" : c == "f" ? "\f" : c == "r" ? "\r" : c == "v" ? "\v" : c)
    }
    return out
}'

# guard_added_against <base> <target> -> "path<TAB>line<TAB>text" per added line. A tab or a
# newline inside a path prints as a space, so the path stays one field.
# A line that only gains the missing final newline is not added.
guard_added_against() {
    guard_diff "$1" "$2" -U0 "$GUARD_RENAME_SIMILARITY" --src-prefix=a/ --dst-prefix=b/ | awk "$GUARD_AWK_UNQUOTE"'
        function reset() { minus = ""; nonl = ""; last = "" }
        rem == 0 && add == 0 && /^\+\+\+ / { f = substr($0, 5); sub(/\t$/, "", f); f = unquote(f); gsub(/[\t\n]/, " ", f); sub(/^b\//, "", f); if (f == "/dev/null") f = ""; next }
        rem == 0 && add == 0 && /^@@ / {
            split($3, n, ","); ln = substr(n[1], 2) + 0; add = (n[2] == "") ? 1 : n[2] + 0
            split($2, o, ","); rem = (o[2] == "") ? 1 : o[2] + 0
            reset(); next
        }
        /^\\/ { if (last == "-") nonl = minus; next }
        rem > 0 && /^-/ { rem--; minus = substr($0, 2); last = "-"; next }
        add > 0 && /^\+/ {
            add--; t = substr($0, 2); last = "+"
            if (nonl != "" && t == nonl) { nonl = ""; ln++; next }
            if (f != "") printf "%s\t%d\t%s\n", f, ln, t
            ln++; next
        }'
}

# guard_added_lines <target> <base>... -> the lines added against EVERY base, sorted. On a
# merge, a line an upstream parent already carries is not added. Duplicate bases count once.
guard_added_lines() {
    local target="$1" base; shift
    local -a unique=()
    mapfile -t unique < <(printf '%s\n' "$@" | awk 'NF && !seen[$0]++')
    for base in "${unique[@]}"; do
        guard_added_against "$base" "$target" | sort -u
    done | awk -v n="${#unique[@]}" '{ c[$0]++ } END { for (k in c) if (c[k] == n) print k }' | sort -t$'\t' -k1,1 -k2,2n
}

# guard_strip_app <path> -> the path with one leading /app/ removed (the container mount).
guard_strip_app() { local p="${1#/app/}"; printf '%s' "${p#./}"; }

# guard_checkstyle_rows <checkstyle xml> -> "path<TAB>line<TAB>source<TAB>message" per
# <error>, the path stripped of /app/. Exit 2 when the file is not checkstyle XML.
guard_checkstyle_rows() {
    [ -r "$1" ] && grep -q '<checkstyle' "$1" || { printf 'not a checkstyle report: %s\n' "$1" >&2; return 2; }
    awk '
        function attr(s, k,   m) { return match(s, " " k "=\"[^\"]*\"") ? substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 4) : "" }
        function unxml(s) { gsub(/&quot;/, "\"", s); gsub(/&apos;|&#0?39;/, "\047", s); gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&amp;/, "\\&", s); return s }
        /<file / { f = unxml(attr($0, "name")); sub(/^\/app\//, "", f); sub(/^\.\//, "", f) }
        /<error / { printf "%s\t%d\t%s\t%s\n", f, attr($0, "line"), attr($0, "source"), unxml(attr($0, "message")) }
    ' "$1"
}
