#!/usr/bin/env bash
# S4 SC-1 — each of the eleven Dart drivers writes the v1 command's value on a recorded real tool
# output, and status error, never a number, on every error partition of its outcome table.
#
# Exit 0 every case of every driver suite passes, 1 a case fails or a suite has none, 2 a suite could
# not run (no Docker).
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITES='qg-driver-dart-analyze qg-driver-dart-format qg-driver-dart-code-linter qg-driver-layerlens
qg-driver-lakos qg-driver-flutter-test qg-driver-mutation-test qg-driver-copydetect qg-driver-grep-count
qg-driver-checkstyle qg-driver-dart-lock'
bad=0 total=0
for s in $SUITES; do
    out="$(cd "$ROOT" && ./tests/run.sh "tests/unit/${s}.bats" 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] || { printf '%s: suite could not run\n' "$s"; exit 2; }
    n="$(grep -c '^ok ' <<<"$out")"; f="$(grep -c '^not ok ' <<<"$out")"
    total=$((total + n + f))
    if [ "$n" -eq 0 ] || [ "$f" -ne 0 ]; then printf '  FAILING  %s: %s of %s cases\n' "$s" "$f" "$((n + f))"; bad=1; fi
done
[ "$bad" -eq 0 ] || exit 1
printf '%s cases passing across 11 driver suites\n' "$total"
