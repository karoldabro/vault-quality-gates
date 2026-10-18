#!/usr/bin/env bash
# S2 SC-1 — the driver runtime lives in lib/qg-driver.sh and the row helpers in lib/qg-row.sh, each
# function defined once, and the whole bats suite passes.
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

bad=0
check() {  # check <file> <function>...
    local home="$1" f where
    shift
    for f in "$@"; do
        where="$(grep -rlE "^${f}\(\)" lib bin drivers | tr '\n' ' ')"
        [ "$where" = "${home} " ] || { printf '  %s is defined in: %s(expected %s)\n' "$f" "${where:-nowhere }" "$home"; bad=1; }
    done
}
check lib/qg-driver.sh guard_driver_builtin guard_driver_resolvable guard_driver_path guard_driver_needs_tree \
    guard_cfg_copy guard_run_driver guard_number_line guard_save_last guard_last_dir
check lib/qg-row.sh guard_err guard_row_field guard_substitute guard_args_kv guard_args_argv
[ "$bad" -eq 0 ] || { echo 'a runtime function is not in its one home'; exit 1; }

out="$(./tests/run.sh tests/unit 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] || grep -q 'docker not found' <<<"$out"; then echo 'the bats suite could not run'; exit 2; fi
fails="$(grep -c '^not ok' <<<"$out")"
oks="$(grep -c '^ok' <<<"$out")"
[ "$fails" -eq 0 ] && [ "$rc" -eq 0 ] || { grep '^not ok' <<<"$out"; echo "${fails} of $((oks + fails)) bats tests failing"; exit 1; }
echo "functions in their homes; ${oks} of ${oks} bats tests passing"
