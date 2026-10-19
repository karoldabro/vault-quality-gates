#!/usr/bin/env bash
# dart-lock driver: packages whose lock entry a commit changed that it may not change itself. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-dart-drivers.md.
#
# args:  packages=<name,name> [lock=<repo path>]
#   packages   required: the packages that judge the code, such as dart_code_linter,lakos
#   lock       default pubspec.lock; its pubspec.yaml is the file beside it
#
# metric = the most, over every base in QG_BASES, of: named packages whose version, source or url
# differ from the base, or that only one side holds; every other package that becomes a path or git
# package; and 1 when pubspec.yaml's dependency_overrides section differs from the base's. Both sides
# are read from git (the index under commit), never from the measured tree, which an earlier row's
# pub get may have rewritten. A lock missing at a base, or written in a form this parser does not
# read, is an error. A human passes a real tool upgrade with qg override.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

# entries <lock file> -> one line per package: name, source, version, url, tab-separated, sorted. A
# line under `packages:` in any other shape, or an entry with no source, prints `!bad <line>` instead.
entries() {
    awk 'function flush() { if (n != "") { if (s == "") print "!bad " n " has no source"; else printf "%s\t%s\t%s\t%s\n", n, s, v, u }; n = s = v = u = "" }
         /^packages:[[:space:]]*$/ { inp = 1; next }
         /^[^ ]/ { if (inp) flush(); inp = 0; next }
         !inp || /^[[:space:]]*$/ { next }
         /^  [A-Za-z0-9_]+:[[:space:]]*$/ { flush(); n = $1; sub(/:$/, "", n); next }
         /^    [a-z0-9_]+:/ { k = $1
                           if (k == "source:") s = $2
                           else if (k == "version:") { v = $2; gsub(/"/, "", v) }
                           else if (k != "dependency:" && k != "description:") print "!bad " $0
                           next }
         /^      [a-z0-9_-]+:/ { if ($1 == "url:") { u = $2; gsub(/"/, "", u) }; next }
         { print "!bad " $0 }
         END { flush() }' "$1" | sort
}

# overrides <pubspec.yaml> -> the dependency_overrides section, every line of it.
overrides() { awk '/^dependency_overrides:/ { on = 1; print; next } /^[^ #]/ { on = 0 } on' "$1"; }

# show <rev or empty for the index> <path> -> the file at that revision of QG_REPO.
show() { git -C "${QG_REPO:-.}" show "${1}:${2}" 2>/dev/null; }

case "${1:-}" in
    describe)
        printf '{"name":"dart-lock","summary":"pubspec.lock: changes to the packages that judge the code, and new path or git packages","requires":["jq","git","awk"],"needs_tree":false}\n' ;;
    explain)
        printf 'Refuses a commit that changes the locked version, source or url of a package that judges the code,\n'
        printf 'turns any package into a path or git package, or changes pubspec.yaml dependency_overrides. Undo\n'
        printf 'that change, or ask a human to pass a real tool upgrade with qg override. Keys: packages (required) lock.\n' ;;
    run)
        : "${QG_OUT:?}"
        raw="$(qg_need dart-lock packages packages)" || exit 0
        lock="$(qg_kv lock)" || lock=pubspec.lock
        spec="$(dirname "$lock")/pubspec.yaml"; spec="${spec#./}"
        target="${QG_TARGET:-HEAD}"; [ "$target" != ':index' ] || target=''
        show "$target" "$lock" > "${QG_OUT}/tree.lock" || { qg_fail dart-lock packages "${lock} is missing in the measured commit"; exit 0; }
        show "$target" "$spec" > "${QG_OUT}/tree.yaml" || : > "${QG_OUT}/tree.yaml"
        bases="${QG_BASES:-${QG_BASE:-}}"
        [ -n "${bases// /}" ] || { qg_fail dart-lock packages 'no base to compare the lock with'; exit 0; }
        entries "${QG_OUT}/tree.lock" > "${QG_OUT}/tree"
        bad="$(grep -m1 '^!bad ' "${QG_OUT}/tree")" && { qg_fail dart-lock packages "${lock} is not in pub's block form: ${bad#!bad }"; exit 0; }
        overrides "${QG_OUT}/tree.yaml" > "${QG_OUT}/tree.over"
        named=",${raw},"
        worst=0
        : > "${QG_OUT}/hits"
        for b in $bases; do
            show "$b" "$lock" > "${QG_OUT}/base.lock" || { qg_fail dart-lock packages "${lock} is missing at base ${b}"; exit 0; }
            entries "${QG_OUT}/base.lock" > "${QG_OUT}/base"
            bad="$(grep -m1 '^!bad ' "${QG_OUT}/base")" && { qg_fail dart-lock packages "${lock} at ${b} is not in pub's block form: ${bad#!bad }"; exit 0; }
            awk -F'\t' -v named="$named" -v base="$b" '
                NR == FNR { old[$1] = $0; os[$1] = $2; next }
                { seen[$1] = 1
                  isn = index(named, "," $1 ",") > 0
                  inold = ($1 in old)
                  if (isn && (!inold || old[$1] != $0)) print $1 "\t" (inold ? "changed from " old[$1] : "added") " at " base
                  else if (!isn && ($2 == "path" || $2 == "git") && os[$1] != $2) print $1 "\tbecomes a " $2 " package"
                }
                END { for (p in old) if (!(p in seen) && index(named, "," p ",") > 0) print p "\tremoved" }' \
                "${QG_OUT}/base" "${QG_OUT}/tree" > "${QG_OUT}/hits.b"
            { show "$b" "$spec" || true; } > "${QG_OUT}/base.yaml"
            overrides "${QG_OUT}/base.yaml" | cmp -s - "${QG_OUT}/tree.over" \
                || printf '%s\tdependency_overrides differs from %s\n' "$spec" "$b" >> "${QG_OUT}/hits.b"
            n="$(grep -c . "${QG_OUT}/hits.b")"
            if [ "$n" -gt "$worst" ]; then worst="$n"; cp "${QG_OUT}/hits.b" "${QG_OUT}/hits"; fi
        done
        jq -R -s -c --arg l "$lock" '[split("\n")[] | select(length > 0) | split("\t")
            | {ruleId: "dart-lock.tool-changed", file: $l, line: null, level: "error",
               message: (.[0] + ": " + (.[1:] | join(" "))), doc: null}]' "${QG_OUT}/hits" > "${QG_OUT}/findings.json"
        qg_result dart-lock measured "$worst" packages "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage dart-lock ;;
esac
