#!/usr/bin/env bash
# dart-lock driver: packages whose lock entry a commit changed that it may not change itself. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-dart-drivers.md.
#
# args:  packages=<name,name> [lock=<tree path>]
#   packages   required: the packages that judge the code, such as dart_code_linter,lakos
#   lock       default pubspec.lock
#
# metric = the most, over every base in QG_BASES, of: named packages whose version, source or url
# differ from the base, or that only one side holds; plus every other package that becomes a path or
# git package. A lock missing at a base or in the tree is an error. A human passes a real tool upgrade
# with qg override.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

# entries <lock file> -> one line per package: name, source, version, url, tab-separated.
entries() {
    awk 'function flush() { if (n != "") printf "%s\t%s\t%s\t%s\n", n, s, v, u; n = s = v = u = "" }
         /^packages:/ { inp = 1; next }
         /^[^ ]/ { if (inp) flush(); inp = 0; next }
         !inp { next }
         /^  [^ ].*:[[:space:]]*$/ { flush(); n = $1; sub(/:$/, "", n); gsub(/"/, "", n); next }
         /^    source:/ { s = $2 }
         /^    version:/ { v = $2; gsub(/"/, "", v) }
         /^      url:/ { u = $2; gsub(/"/, "", u) }
         END { flush() }' "$1" | sort
}

case "${1:-}" in
    describe)
        printf '{"name":"dart-lock","summary":"pubspec.lock: changes to the packages that judge the code, and new path or git packages","requires":["git","awk"],"needs_tree":true}\n' ;;
    explain)
        printf 'Refuses a commit that changes the locked version, source or url of a package that judges the code,\n'
        printf 'or turns any package into a path or git package. Undo that change in pubspec.lock, or ask a human\n'
        printf 'to pass a real tool upgrade with qg override. Keys: packages (required) lock.\n' ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        raw="$(qg_need dart-lock packages packages)" || exit 0
        lock="$(qg_kv lock)" || lock=pubspec.lock
        [ -s "${QG_TREE}/${lock}" ] || { qg_fail dart-lock packages "${lock} is missing in the measured tree"; exit 0; }
        bases="${QG_BASES:-${QG_BASE:-}}"
        [ -n "${bases// /}" ] || { qg_fail dart-lock packages 'no base to compare the lock with'; exit 0; }
        entries "${QG_TREE}/${lock}" > "${QG_OUT}/tree"
        named=",${raw},"
        worst=0
        : > "${QG_OUT}/hits"
        for b in $bases; do
            git -C "${QG_REPO:-.}" show "${b}:${lock}" > "${QG_OUT}/base.lock" 2>/dev/null \
                || { qg_fail dart-lock packages "${lock} is missing at base ${b}"; exit 0; }
            entries "${QG_OUT}/base.lock" > "${QG_OUT}/base"
            awk -F'\t' -v named="$named" -v base="$b" '
                NR == FNR { old[$1] = $0; os[$1] = $2; next }
                { seen[$1] = 1
                  isn = index(named, "," $1 ",") > 0
                  if (isn && old[$1] != $0) print $1 "\t" (($1 in old) ? "changed from " old[$1] : "added") " at " base
                  else if (!isn && ($2 == "path" || $2 == "git") && os[$1] != $2) print $1 "\tbecomes a " $2 " package"
                }
                END { for (p in old) if (!(p in seen) && index(named, "," p ",") > 0) print p "\tremoved" }' \
                "${QG_OUT}/base" "${QG_OUT}/tree" > "${QG_OUT}/hits.${worst}"
            n="$(grep -c . "${QG_OUT}/hits.${worst}")"
            if [ "$n" -gt "$worst" ] || [ ! -s "${QG_OUT}/hits" ]; then cp "${QG_OUT}/hits.${worst}" "${QG_OUT}/hits"; fi
            [ "$n" -le "$worst" ] || worst="$n"
        done
        jq -R -s -c --arg l "$lock" '[split("\n")[] | select(length > 0) | split("\t")
            | {ruleId: "dart-lock.tool-changed", file: $l, line: null, level: "error",
               message: (.[0] + ": " + (.[1] | gsub("\t"; " "))), doc: null}]' "${QG_OUT}/hits" > "${QG_OUT}/findings.json"
        qg_result dart-lock measured "$worst" packages "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage dart-lock ;;
esac
