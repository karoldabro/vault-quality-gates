#!/usr/bin/env bash
# Counts the paths under `guard_protected_paths` (committed VAULT.md) that the target
# changes against every base. Prints one integer.
#
#   guard-protected-paths.sh [--bases "<sha>..."] [--target <commit>|:index]
#
# A merge that brings a config change an upstream parent already committed counts 0: that
# change passed the gate on its own branch. Both sides of a rename count. GUARD_LIST=1
# prints the paths instead of the count.
set -uo pipefail
export LC_ALL=C
LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)"
. "${LIB}/guard-pass.sh"
. "${LIB}/guard-diff.sh"

bases='' target=':index'
while [ $# -gt 0 ]; do
    case "$1" in
        --bases)  bases="${2:-}"; shift 2 || break ;;
        --target) target="${2:-}"; shift 2 || break ;;
        *) printf 'guard-protected-paths: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done
[ -n "$bases" ] || bases="$(guard_default_bases)"

read -ra protected <<<"$(guard_vault_key guard_protected_paths)"

declare -A seen=()
n=0
hits="$(set -f; for base in $bases; do
    [ -n "${seen[$base]:-}" ] && continue
    seen[$base]=1
    guard_touched_paths "$base" "$target" | sort -u
    printf '%s\n' '--base--'
done)"
n="$(grep -c -- '^--base--$' <<<"$hits")"
paths="$(grep -v -- '^--base--$' <<<"$hits" | awk -v n="$n" 'NF { c[$0]++ } END { for (k in c) if (c[k] == n) print k }' | sort)"

matched=()
while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ "${#protected[@]}" -gt 0 ] && guard_path_matches "$path" "${protected[@]}" && matched+=("$path")
done <<<"$paths"

if [ -n "${GUARD_LIST:-}" ]; then
    [ "${#matched[@]}" -eq 0 ] || printf '%s\n' "${matched[@]}"
else
    printf '%s\n' "${#matched[@]}"
fi
