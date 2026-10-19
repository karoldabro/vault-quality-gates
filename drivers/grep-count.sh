#!/usr/bin/env bash
# grep-count driver: files or lines an extended regular expression matches, or lines an awk script
# prints, over fixed paths. Contract: vault/architecture/qg-driver-contract.md; keys:
# vault/architecture/qg-dart-drivers.md.
#
# args:  paths=<path,path> [count=files|lines] [name=<glob>] [exclude=<ERE>] [awk=<repo path>]
#        [-- <ERE>]
#   paths        required; each must exist and be non-empty in the measured tree. `./lib` and `lib/`
#                mean `lib`
#   count        default files: files with a match (grep -l); lines: matching lines (grep -n)
#   name         keep only files whose base name matches the glob, as grep --include and find -name
#   exclude      drop paths matching the ERE; the path is relative to the measured tree
#   awk          run `awk -f <file>` over the selected files and count the lines it prints; no pattern
#   -- <ERE>     the pattern, taken whole, spaces included; required unless awk= is set
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

# count_lines <file> -> lines in the file once trailing newlines are dropped, as `$(cmd) | wc -l`
# counts them in the v1 rows; an empty file is 0.
count_lines() {
    local out
    out="$(cat "$1")"
    if [ -z "$out" ]; then printf '0'; else printf '%s\n' "$out" | wc -l | tr -d ' '; fi
}

case "${1:-}" in
    describe)
        printf '{"name":"grep-count","summary":"counts files or lines a pattern matches, or lines an awk script prints","requires":["grep","awk","find","jq"],"needs_tree":true}\n' ;;
    explain)
        printf 'Counts what a pattern or an awk script finds in fixed paths. Each finding names the file and line;\n'
        printf 'change the code so the pattern no longer matches. The row'"'"'s why says what the pattern guards.\n'
        printf 'Keys: paths (required) count name exclude awk, then -- <pattern>.\n' ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        raw="$(qg_need grep-count findings paths)" || exit 0
        count="$(qg_kv count)" || count=files
        name="$(qg_kv name)" || name=''
        exclude="$(qg_kv exclude)" || exclude=''
        awk_file="$(qg_kv awk)" || awk_file=''
        pattern="$(qg_argv)"
        IFS=',' read -r -a given <<<"$raw"
        paths=()
        for p in "${given[@]}"; do
            p="${p#./}"; p="${p%/}"; [ -n "$p" ] || p=.
            [ -s "${QG_TREE}/${p}" ] || { qg_fail grep-count findings "path ${p} is missing or empty in the measured tree"; exit 0; }
            paths+=("$p")
        done
        cd "$QG_TREE" || { qg_fail grep-count findings "cannot enter ${QG_TREE}"; exit 0; }
        hits="${QG_OUT}/hits"
        if [ -n "$awk_file" ]; then
            # The script comes from the config revision (an empty one is a first commit: the index),
            # so a commit cannot change the rule that judges it.
            git -C "${QG_REPO:-.}" show "${QG_CONFIG_REV:-}:${awk_file}" > "${QG_OUT}/script.awk" 2>/dev/null && [ -s "${QG_OUT}/script.awk" ] \
                || { qg_fail grep-count findings "awk script ${awk_file} is not committed at the config revision"; exit 0; }
            find "${paths[@]}" -type f ${name:+-name "$name"} -print0 > "${QG_OUT}/files.all"
            : > "${QG_OUT}/files"
            while IFS= read -r -d '' f; do
                f="${f#./}"
                [ -z "$exclude" ] || ! [[ "$f" =~ $exclude ]] || continue
                printf '%s\0' "$f" >> "${QG_OUT}/files"
            done < "${QG_OUT}/files.all"
            # -r: with no file, awk would read the hook's stdin and count it.
            xargs -0 -r awk -f "${QG_OUT}/script.awk" < "${QG_OUT}/files" > "$hits" 2> "${QG_OUT}/stderr" \
                || { cat "${QG_OUT}/stderr"; qg_fail grep-count findings "awk -f ${awk_file} failed"; exit 0; }
            unit=lines
        else
            [ -n "$pattern" ] || { qg_fail grep-count findings 'grep-count needs a pattern after -- , or awk='; exit 0; }
            case "$count" in
                files) flag=-rlZ ;;
                lines) flag=-rHnZ ;;
                *) qg_fail grep-count findings "count=${count} is not files or lines"; exit 0 ;;
            esac
            rc=0
            grep "$flag" -E ${name:+--include="$name"} -e "$pattern" -- "${paths[@]}" > "${QG_OUT}/grep" 2> "${QG_OUT}/stderr" || rc=$?
            [ "$rc" -le 1 ] || { cat "${QG_OUT}/stderr"; qg_fail grep-count findings "grep exited ${rc}"; exit 0; }
            # -Z ends each path with NUL: lines mode prints <path>NUL<line>:<text>, files mode <path>NUL.
            # A path searched as `.` comes back as ./<path>; exclude= matches it without the prefix.
            if [ "$count" = files ]; then tr '\0' '\n' < "${QG_OUT}/grep" | sed 's#^\./##' > "${QG_OUT}/grep.n"
            else tr '\0' '\t' < "${QG_OUT}/grep" | sed 's#^\./##' > "${QG_OUT}/grep.n"; fi
            if [ -n "$exclude" ]; then
                while IFS= read -r line; do
                    f="${line%%$'\t'*}"
                    [[ "$f" =~ $exclude ]] || printf '%s\n' "$line"
                done < "${QG_OUT}/grep.n" > "$hits"
            else
                cp "${QG_OUT}/grep.n" "$hits"
            fi
            unit="$count"
        fi
        n="$(count_lines "$hits")"
        # One finding per hit, the first 200: <path>[TAB<line>:<text>] or awk's <path>:<line>.
        head -200 "$hits" | jq -R -s -c --arg r "grep-count.${QG_ROW:-row}" '
            [split("\n")[] | select(length > 0)
             | if test("\t") then (split("\t") as $p | ($p[1] | capture("^(?<l>[0-9]+):(?<m>.*)$")? // {l: null, m: $p[1]}) as $c
                   | {file: $p[0], line: ($c.l | if . == null then null else tonumber end), message: $c.m})
               elif test("^[^:]+:[0-9]+") then (capture("^(?<f>[^:]+):(?<l>[0-9]+):?(?<m>.*)$")
                   | {file: .f, line: (.l | tonumber), message: (if .m == "" then "matched" else .m end)})
               else {file: ., line: null, message: "matched"} end
             | {ruleId: $r, file, line, level: "error", message, doc: null}]' > "${QG_OUT}/findings.json"
        qg_result grep-count measured "$n" "$unit" "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage grep-count ;;
esac
