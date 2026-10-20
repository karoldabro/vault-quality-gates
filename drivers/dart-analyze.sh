#!/usr/bin/env bash
# dart analyze driver: analyzer diagnostics, the same set `flutter analyze` reports. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-dart-drivers.md.
#
# args:  [paths=<path,path>] [files=changed] [include=<ERE>] [exclude=<ERE>] [lines=added]
#        [code=<code,code>] [severity=info|warning|error] [options-allow=<repo path,repo path>]
#   paths          default .
#   code           count only these diagnostic codes, compared lower-cased
#   severity       the lowest level counted, default info: info counts everything, warning counts
#                  warnings and errors, error counts errors
#   options-allow  nested analysis_options.yaml files allowed below the repo root
#
# metric = diagnostics kept. A nested analysis_options.yaml not in options-allow= is an error: it
# would apply its own, looser rules to its folder.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"
# shellcheck source=../lib/qg-dart.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-dart.sh"

case "${1:-}" in
    describe)
        printf '{"name":"dart-analyze","summary":"dart analyze: analyzer errors, warnings and lints, as flutter analyze reports them","requires":["jq","git"],"needs_tree":true,"sandbox":true,"writes":[".dart_tool"]}\n' ;;
    explain)
        if [ -n "${2:-}" ]; then
            printf 'Analyzer diagnostic %s. Fix the code the message names; https://dart.dev/tools/diagnostics/%s explains it.\n' "$2" "$2"
            printf 'An added // ignore: comment is refused by the gate.\n'
        else
            printf 'Runs dart analyze --format=machine and counts the diagnostics. Fix each listed line.\n'
            printf 'Keys: paths files=changed include exclude lines=added code severity options-allow.\n'
        fi ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        case "$(qg_kv severity || printf info)" in
            info) levels='ERROR|WARNING|INFO' ;;
            warning) levels='ERROR|WARNING' ;;
            error) levels='ERROR' ;;
            *) qg_fail dart-analyze findings "severity=$(qg_kv severity) is not info, warning or error"; exit 0 ;;
        esac
        if [ "$(qg_kv files)" = changed ]; then
            qg_files '\.dart$'
            if [ "${#QG_FILE_LIST[@]}" -eq 0 ]; then qg_result dart-analyze measured 0 findings - -; exit 0; fi
            targets=("${QG_FILE_LIST[@]}")
        else
            qg_paths .
            targets=()
            for p in "${QG_PATH_LIST[@]}"; do p="${p#./}"; p="${p%/}"; targets+=("${p:-.}"); done
        fi
        allow=",$(qg_kv options-allow || true),"
        nested="$(cd "$QG_TREE" && find . \( -name .dart_tool -o -name build -o -name .git \) -prune -o \
            -name analysis_options.yaml -type f -print | sed 's#^\./##' | grep -vx 'analysis_options.yaml' \
            | while IFS= read -r f; do [[ "$allow" == *",${f},"* ]] || printf '%s ' "$f"; done)"
        [ -z "$nested" ] || { qg_fail dart-analyze findings "nested analysis options not in options-allow=: ${nested% }"; exit 0; }
        qg_dart_prepare dart-analyze findings || exit 0
        # dart analyze exits 1, 2 or 3 for the worst level it found; the machine lines decide the value.
        qg_tool - '0 1 2 3' "$QG_DART" analyze --format=machine -- "${targets[@]}" \
            || { qg_fail dart-analyze findings "$QG_ERROR"; exit 0; }
        # SEVERITY|TYPE|CODE|FILE|LINE|COLUMN|LENGTH|MESSAGE; a | inside a field is written \|.
        codes=",$(qg_kv code | tr '[:upper:]' '[:lower:]' || true),"
        grep -E "^(${levels})\|" "${QG_OUT}/stdout" \
            | awk -v codes="$codes" 'BEGIN { OFS = "\t" }
                { line = $0; gsub(/\\\|/, "\001", line); n = split(line, f, "|")
                  code = tolower(f[3]); if (codes != ",," && index(codes, "," code ",") == 0) next
                  msg = f[8]; for (i = 9; i <= n; i++) msg = msg "|" f[i]
                  file = f[4]; gsub(/\001/, "|", msg); gsub(/\001/, "|", file)
                  print f[1], code, file, f[5], msg }' \
            | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t")
                | {ruleId: .[1], file: .[2], line: (.[3] | tonumber? // null),
                   level: ({"ERROR": "error", "WARNING": "warning"}[.[0]] // "note"), message: .[4],
                   doc: ("https://dart.dev/tools/diagnostics/" + .[1])}]' > "${QG_OUT}/findings.json"
        if [ "$(qg_kv lines)" = added ]; then
            qg_added_only "${QG_OUT}/findings.json" || { qg_fail dart-analyze findings "$QG_ERROR"; exit 0; }
            qg_result dart-analyze measured "$QG_COUNT" findings "${QG_OUT}/findings.json" -
        else
            qg_result dart-analyze measured "$(jq length "${QG_OUT}/findings.json")" findings "${QG_OUT}/findings.json" -
        fi ;;
    *)
        qg_usage dart-analyze ;;
esac
