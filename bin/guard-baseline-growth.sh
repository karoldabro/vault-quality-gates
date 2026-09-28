#!/usr/bin/env bash
# Counts tool-baseline entries that the target grew against every base. Prints one integer.
#
#   guard-baseline-growth.sh [--phpstan <neon>] [--phpmd <xml>] [--bases "<sha>..."] [--target <commit>|:index]
#
# With neither tool flag, reads phpstan-baseline.neon and quality/phpmd-baseline.xml.
# An entry is (path, identifier, message) for PHPStan and (file, rule, method) for PHPMD.
# A new entry, a higher count or a higher accepted complexity score is growth; a removed or
# lowered entry is 0, so a fixed error never pays for a new one. A cognitive-complexity
# message loses only its score from the key, so a lowered score is the same entry. A path
# renamed between base and target is the same entry. A base without the baseline file adds
# nothing: introducing a baseline is a config change, which the protected-path row judges.
# A target baseline with any line outside the generator's shape (a string entry, an inline
# map, another neon key, a hand-written XML element) exits 2 naming the line: unmeasurable.
# GUARD_LIST=1 prints the grown entries instead of the count.
set -uo pipefail
export LC_ALL=C
LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)"
. "${LIB}/guard-pass.sh"
. "${LIB}/guard-diff.sh"

phpstan='' phpmd='' bases='' target=':index'
while [ $# -gt 0 ]; do
    case "$1" in
        --phpstan) phpstan="${2:-}"; shift 2 || break ;;
        --phpmd)   phpmd="${2:-}"; shift 2 || break ;;
        --bases)   bases="${2:-}"; shift 2 || break ;;
        --target)  target="${2:-}"; shift 2 || break ;;
        *) printf 'guard-baseline-growth: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done
if [ -z "$phpstan$phpmd" ]; then phpstan='phpstan-baseline.neon'; phpmd='quality/phpmd-baseline.xml'; fi
[ -n "$bases" ] || bases="$(guard_default_bases)"

show() {  # show <rev|:index> <path>
    if [ "$1" = ':index' ]; then git show ":$2" 2>/dev/null; else git show "$1:$2" 2>/dev/null; fi
}

# entries <tool> [strict] -> "key<TAB>count<TAB>score" per entry; the formats and the strict
# shape check live in lib/guard-baseline-neon.awk and lib/guard-baseline-phpmd.awk.
entries() {
    case "$1" in
        phpstan) awk -v strict="${2:-}" -f "${LIB}/guard-baseline-neon.awk" ;;
        phpmd)   awk -v strict="${2:-}" -f "${LIB}/guard-baseline-phpmd.awk" ;;
    esac
}

# grown <tool> <path> <base> -> the target keys that grew against this base, one per line:
# a new key, a higher count, or a higher accepted complexity score.
grown() {
    local tool="$1" path="$2" base="$3" old
    old="$(show "$base" "$path")" || return 0
    local renames; renames="$(guard_diff "$base" "$target" --name-status "$GUARD_RENAME_SIMILARITY" | awk -F'\t' "$GUARD_AWK_UNQUOTE"'$1 ~ /^R/ { print unquote($2) "\t" unquote($3) }')"
    awk -F'\t' '
        FILENAME == ARGV[1] { if (NF == 2) to[$1] = $2; next }
        FILENAME == ARGV[2] {
            split($1, k, "\037"); if (k[1] in to) k[1] = to[k[1]]
            key = k[1] "\037" k[2] "\037" k[3]; was[key] += $2; seen[key] = 1
            if (!(key in score) || $3 > score[key]) score[key] = $3
            next
        }
        !($1 in seen) || $2 > was[$1] || $3 > score[$1] { print $1 }
    ' <(printf '%s\n' "$renames") <(printf '%s\n' "$old" | entries "$tool") <(show "$target" "$path" | entries "$tool")
}

total=0 listing=''
for pair in "phpstan:$phpstan" "phpmd:$phpmd"; do
    tool="${pair%%:*}" path="${pair#*:}"
    [ -n "$path" ] || continue
    if ! shape="$(entries "$tool" strict < <(show "$target" "$path"))"; then
        why="${shape%%$'\n'*}"
        msg="guard-baseline-growth: ${path} line ${why%% *}: ${why#* }; only the generator's shape is measurable"
        printf '%s\n' "$msg" >&2
        [ -z "${GUARD_LIST:-}" ] || printf '%s:%s %s\n' "$path" "${why%% *}" "${why#* }"
        exit 2
    fi
    declare -A seen=() ; n=0
    set -f
    grown_all="$(for base in $bases; do
        [ -n "${seen[$base]:-}" ] && continue
        seen[$base]=1
        grown "$tool" "$path" "$base" | sort -u
        printf '%s\n' '--base--'
    done)"
    set +f
    n="$(grep -c -- '^--base--$' <<<"$grown_all")"
    hits="$(grep -v -- '^--base--$' <<<"$grown_all" | awk -v n="$n" 'NF { c[$0]++ } END { for (k in c) if (c[k] == n) print k }')"
    [ -n "$hits" ] || continue
    total=$((total + $(printf '%s\n' "$hits" | wc -l)))
    listing+="$(printf '%s\n' "$hits" | awk -v t="$path" -F'\037' '{ printf "%s %s %s (%s)\n", $1, ($2 == "" ? "-" : $2), $3, t }')"$'\n'
done

if [ -n "${GUARD_LIST:-}" ]; then printf '%s' "$listing"; else printf '%s\n' "$total"; fi
