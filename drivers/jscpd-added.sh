#!/usr/bin/env bash
# jscpd driver for commits: clone sides that cover a line the commit adds. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-builtin-drivers.md.
#
# args:  [paths=<dir,dir>] [version=<jscpd version>] [min-lines=<n>] [min-tokens=<n>] [format=<f>]
#        [ignore=<glob>] [include=<ERE>] [exclude=<ERE>] [runner=<repo path>] [-- <extra jscpd argv>]
#   paths        default app; jscpd scans these directories of the measured tree
#   version      default 5.3.2, run as `pnpm dlx jscpd@<version>`
#   include, exclude  which added lines count; a commit adding none measures 0 without running jscpd
#
# metric = clone sides, each counted once, that lie in a changed file and cover an added line.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

case "${1:-}" in
    describe)
        printf '{"name":"jscpd-added","summary":"jscpd: duplicated blocks that cover lines the commit adds","requires":["jq","pnpm"],"needs_tree":true}\n' ;;
    explain)
        printf 'Finds copied blocks with jscpd and counts each copy that covers a line this commit adds. Extract the\n'
        printf 'shared code into one method, trait or class. Keys: paths version min-lines min-tokens format ignore\n'
        printf 'include exclude runner.\n' ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        qg_paths app
        inc="$(qg_kv include)" || inc=''
        exc="$(qg_kv exclude)" || exc=''
        # shellcheck disable=SC2086  # QG_BASES is a space-separated sha list
        ( cd "${QG_REPO:-.}" && "${QG_KIT_BIN}/guard-added-lines.sh" --added --bases "${QG_BASES:-${QG_BASE:-HEAD}}" \
            --target "${QG_TARGET:-:index}" ) > "${QG_OUT}/added.all" \
            || { qg_fail jscpd-added clones 'guard-added-lines.sh --added failed'; exit 0; }
        INC="$inc" EXC="$exc" PATHS="${QG_PATH_LIST[*]}" awk -F'\t' '
            BEGIN { n = split(ENVIRON["PATHS"], p, " ") }
            function under(f,   i) { for (i = 1; i <= n; i++) if (p[i] == "." || index(f, p[i] "/") == 1) return 1; return 0 }
            under($1) && (ENVIRON["INC"] == "" || $1 ~ ENVIRON["INC"]) && (ENVIRON["EXC"] == "" || $1 !~ ENVIRON["EXC"]) { print $1 "\t" $2 }
        ' "${QG_OUT}/added.all" > "${QG_OUT}/added"
        if [ ! -s "${QG_OUT}/added" ]; then qg_result jscpd-added measured 0 clones - -; exit 0; fi

        version="$(qg_kv version)" || version=5.3.2
        read -ra argv <<<"$(qg_argv)"
        opts=()
        v="$(qg_kv min-lines)" && opts+=(--min-lines "$v")
        v="$(qg_kv min-tokens)" && opts+=(--min-tokens "$v")
        v="$(qg_kv format)" && opts+=(--format "$v")
        v="$(qg_kv ignore)" && opts+=(--ignore "$v")
        if [ -z "${QG_RUNNER:-}" ]; then
            # On the host jscpd runs from an empty folder, scanning the tree by absolute path, with the
            # public npm registry: the commit's own .npmrc and .jscpd.json are never read.
            work="$(mktemp -d)"; export QG_TOOL_DIR="$work"
            scan=(); for p in "${QG_PATH_LIST[@]}"; do scan+=("${QG_TREE}/${p}"); done
            out="${work}/out"; cmd=(env npm_config_registry=https://registry.npmjs.org/ pnpm)
        else
            # A runner sees only the tree, so the report is written inside it and removed after.
            work=''; scan=("${QG_PATH_LIST[@]}"); out=".qg-jscpd-${QG_ROW:-row}"; cmd=(pnpm)
            rm -rf "${QG_TREE:?}/${out}"
        fi
        report="$out/jscpd-report.json"; [ -n "$work" ] || report="${QG_TREE}/${report}"
        cleanup() { if [ -n "$work" ]; then rm -rf "$work"; else rm -rf "${QG_TREE:?}/${out}"; fi; }
        qg_tool - 0 "${cmd[@]}" dlx "jscpd@${version}" "${scan[@]}" "${opts[@]}" \
            --reporters json --output "$out" --silent --no-colors "${argv[@]}" \
            || { cleanup; qg_fail jscpd-added clones "$QG_ERROR"; exit 0; }
        if [ ! -s "$report" ]; then cleanup; qg_fail jscpd-added clones "jscpd exited ${QG_RC} and wrote no report"; exit 0; fi
        cp "$report" "${QG_OUT}/jscpd.json"
        cleanup

        # Both sides of each clone, named relative to the tree: a single scanned directory may be
        # reported relative to itself.
        jq -r --arg t "${QG_TREE}/" --arg p "${QG_PATH_LIST[0]}" --argjson one "$([ "${#QG_PATH_LIST[@]}" -eq 1 ] && echo true || echo false)" '
            def norm: ltrimstr($t) | ltrimstr("./") | if ($one and $p != "." and (startswith($p + "/") | not)) then $p + "/" + . else . end;
            (.duplicates // [])[]
            | (.firstFile | .name |= norm) as $a | (.secondFile | .name |= norm) as $b
            | ([$a, $b], [$b, $a])
            | [.[0].name, .[0].start, .[0].end, .[1].name, .[1].start, .[1].end] | @tsv
        ' "${QG_OUT}/jscpd.json" > "${QG_OUT}/sides" 2>/dev/null \
            || { qg_fail jscpd-added clones 'jscpd wrote an unreadable report'; exit 0; }
        # A side counts once, on the first added line inside it.
        awk -F'\t' '
            NR == FNR { lines[$1] = lines[$1] " " $2; next }
            !($1 in lines) { next }
            {
                first = 0; n = split(lines[$1], l, " ")
                for (i = 1; i <= n; i++) if (l[i] + 0 >= $2 + 0 && l[i] + 0 <= $3 + 0 && (first == 0 || l[i] + 0 < first)) first = l[i] + 0
                if (first == 0 || seen[$1 "\t" $2 "\t" $3]++) next
                printf "%s\t%d\tLines %d-%d duplicate %s:%d-%d; extract the shared code into one method, trait or class.\n", $1, first, $2, $3, $4, $5, $6
            }' "${QG_OUT}/added" "${QG_OUT}/sides" \
            | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t")
                | {ruleId: "jscpd.duplicateBlock", file: .[0], line: (.[1] | tonumber), level: "error", message: .[2], doc: null}]' \
            > "${QG_OUT}/findings.json"
        qg_result jscpd-added measured "$(jq length "${QG_OUT}/findings.json")" clones "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage jscpd-added ;;
esac
