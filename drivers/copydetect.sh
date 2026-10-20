#!/usr/bin/env bash
# copydetect driver: pairs of files that are the same code under different names. Contract:
# vault/architecture/qg-driver-contract.md; keys: vault/architecture/qg-dart-drivers.md.
#
# args:  requirements=<repo path> [venv-root=<name>] [paths=<dir>] [ext=<extension>] [exclude=<ERE>]
#        [min-similarity=<0..1>] [min-tokens=<n>] [noise=<n>] [guarantee=<n>]
#   requirements    required: the hash-pinned requirements file the venv was built from
#   venv-root       folder under $HOME/.cache holding copydetect-<12 hex of its sha256>; default qg-tools
#   paths ext       default lib and dart
#   exclude         default: generated Dart files (.g .freezed .mocks .config and /generated/)
#   min-similarity  default 0.8, both files of a pair; min-tokens default 600; noise, guarantee 25
#
# copydetect fingerprints each file after replacing identifiers and literals, so a copy with renamed
# variables still matches. The interpreter never comes from PATH or the caller's XDG_CACHE_HOME. It runs
# in the sandbox through qg_tool, whose stdin is /dev/null, so the file list reaches it as a path.
set -uo pipefail
export LC_ALL=C
# shellcheck source=../lib/qg-driver-kit.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/qg-driver-kit.sh"

DETECT='
import sys
from copydetect import CopyDetector
ext, min_sim, min_tok, noise, guarantee = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
files = [f for f in open(sys.argv[6], encoding="utf-8").read().split("\0") if f]
if not files:
    print("no source file to compare", file=sys.stderr)
    sys.exit(2)
detector = CopyDetector(extensions=[ext], noise_t=noise, guarantee_t=guarantee,
                        display_t=min_sim, silent=True, autoopen=False)
for f in files:
    detector.add_file(f)
detector.run()
for sim_a, sim_b, a, b, _, _, tokens in detector.get_copied_code_list():
    if sim_a >= min_sim and sim_b >= min_sim and tokens >= min_tok:
        print(f"{sim_a:.2f} {sim_b:.2f} {tokens} {a} {b}")
'

case "${1:-}" in
    describe)
        printf '{"name":"copydetect","summary":"copydetect: file pairs that are the same code under different names","requires":["jq","sha256sum","find"],"needs_tree":true,"sandbox":true,"writes":[]}\n' ;;
    explain)
        printf 'Lists pairs of files that are copies of each other once names and literals are ignored. Merge the two\n'
        printf 'into one shared widget, function or class. Keys: requirements (required) venv-root paths ext exclude\n'
        printf 'min-similarity min-tokens noise guarantee.\n' ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}"
        req="$(qg_need copydetect pairs requirements)" || exit 0
        root="$(qg_kv venv-root)" || root=qg-tools
        [[ "$root" =~ ^[A-Za-z0-9._-]+$ && "$root" != *..* ]] || { qg_fail copydetect pairs "venv-root=${root} must be one plain folder name"; exit 0; }
        # The requirements come from the config revision, so a commit cannot pick another venv.
        git -C "${QG_REPO:-.}" show "${QG_CONFIG_REV:-}:${req}" > "${QG_OUT}/requirements" 2>/dev/null && [ -s "${QG_OUT}/requirements" ] \
            || { qg_fail copydetect pairs "requirements file ${req} is not committed at the config revision"; exit 0; }
        hash="$(sha256sum "${QG_OUT}/requirements" | cut -c1-12)"
        py="${HOME}/.cache/${root}/copydetect-${hash}/bin/python"
        [ -x "$py" ] || { qg_fail copydetect pairs "no copydetect venv at ${py}; build it from ${req} (mobile: make quality-tools)"; exit 0; }
        ext="$(qg_kv ext)" || ext=dart
        exclude="$(qg_kv exclude)" || exclude='\.(g|freezed|mocks|config)\.dart$|/generated/'
        qg_paths lib
        (cd "$QG_TREE" && find "${QG_PATH_LIST[@]}" -type f -name "*.${ext}" -print | sort) > "${QG_OUT}/all" \
            || { qg_fail copydetect pairs "cannot list ${QG_PATH_LIST[*]}"; exit 0; }
        # The list sits outside QG_OUT, which qg_tool keeps out of the argv; the sandbox reads it.
        list="$(mktemp)" || { qg_fail copydetect pairs 'cannot create the file list'; exit 0; }
        while IFS= read -r f; do [[ "$f" =~ $exclude ]] || printf '%s\0' "$f"; done < "${QG_OUT}/all" > "$list"
        # The venv path is resolved here, under the real HOME; the sandboxed child's HOME is private.
        qg_tool - 0 "$py" -I -c "$DETECT" "$ext" "$(qg_kv min-similarity || printf 0.8)" \
            "$(qg_kv min-tokens || printf 600)" "$(qg_kv noise || printf 25)" "$(qg_kv guarantee || printf 25)" "$list" \
            || { rm -f "$list"; qg_fail copydetect pairs "${QG_ERROR/#python /copydetect }"; exit 0; }
        rm -f "$list"
        mv "${QG_OUT}/stdout" "${QG_OUT}/pairs"
        n="$(grep -c . "${QG_OUT}/pairs")"
        head -200 "${QG_OUT}/pairs" | jq -R -s -c '[split("\n")[] | select(length > 0) | split(" ")
            | {ruleId: "copydetect.clone", file: .[3], line: null, level: "error",
               message: ("same code as \(.[4]) (similarity \(.[0])/\(.[1]), \(.[2]) tokens)"), doc: null}]' \
            > "${QG_OUT}/findings.json"
        qg_result copydetect measured "$n" pairs "${QG_OUT}/findings.json" - ;;
    *)
        qg_usage copydetect ;;
esac
