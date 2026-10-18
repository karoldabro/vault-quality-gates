#!/usr/bin/env bash
# Shared by checks/qg-SC-*.sh: runs bats files and checks that each named case exists and passes.
#
#   qg_cases <suite> "<case>" ... [-- <suite> "<case>" ...]
#
# Exit 0 every case passes, 1 a case is failing or absent, 2 a suite could not run (no Docker),
# so "could not run" never reads as "no".
set -uo pipefail
QG_CHECKS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

qg_cases() {
    local suite='' out rc missing=0 failed=0 total=0 c
    local -A outputs=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --) suite=''; shift; continue ;;
        esac
        if [ -z "$suite" ]; then
            suite="$1"; shift
            [ -f "${QG_CHECKS_ROOT}/tests/unit/${suite}" ] || { printf '%s: suite not written yet\n' "$suite"; return 1; }
            if [ -z "${outputs[$suite]:-}" ]; then
                out="$(cd "$QG_CHECKS_ROOT" && ./tests/run.sh "tests/unit/${suite}" 2>&1)"; rc=$?
                if [ "$rc" -eq 2 ] || grep -q 'docker not found' <<<"$out"; then
                    printf '%s: suite could not run (rc=%s)\n' "$suite" "$rc"; return 2
                fi
                outputs[$suite]="$out"
            fi
            continue
        fi
        c="$1"; shift; total=$((total + 1))
        if grep -F 'not ok' <<<"${outputs[$suite]}" | grep -qF -- "$c"; then
            printf '  FAILING  %s: %s\n' "$suite" "$c"; failed=$((failed + 1))
        elif ! grep -qF -- "$c" <<<"${outputs[$suite]}"; then
            printf '  ABSENT   %s: %s\n' "$suite" "$c"; missing=$((missing + 1))
        fi
    done
    if [ $((missing + failed)) -ne 0 ]; then
        printf '%s of %s cases failing or absent\n' "$((missing + failed))" "$total"; return 1
    fi
    printf '%s of %s cases passing\n' "$total" "$total"
}
