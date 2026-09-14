#!/usr/bin/env bash
# SC-1 — a metric worse than its baseline beyond threshold exits 1 and the refusal names the metric, both values and the tolerance
#
# Exit 1 when the cases below fail. Exit 2 when the suite could not run at all, so "I could not read
# the question" never reports as "the answer is no" (vault/indications/unreadable-is-not-no.md).
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
suite="$root/tests/unit/guard-metrics.bats"
cases=(
    "worse than baseline exits 1"
    "refusal names metric values and tolerance"
    "delta equal to threshold passes"
)

if [ ! -f "$suite" ]; then
    printf '%s: suite not written yet — cannot say\n' "$(basename "$suite")"; exit 2
fi

out=$(cd "$root" && ./tests/run.sh "tests/unit/$(basename "$suite")" 2>&1); rc=$?
if [ "$rc" -eq 2 ] || printf '%s' "$out" | grep -q 'docker not found'; then
    printf '%s: suite could not run (rc=%s)\n' "$(basename "$suite")" "$rc"; exit 2
fi

missing=0; failed=0
for c in "${cases[@]}"; do
    if printf '%s\n' "$out" | grep -qF "not ok" && printf '%s\n' "$out" | grep -F "not ok" | grep -qF "$c"; then
        printf '  FAILING  %s\n' "$c"; failed=$((failed + 1))
    elif ! printf '%s\n' "$out" | grep -qF "$c"; then
        printf '  ABSENT   %s\n' "$c"; missing=$((missing + 1))
    fi
done

if [ "$missing" -ne 0 ]; then
    printf '%s: %s of %s cases not written\n' "$(basename "$suite")" "$missing" "${#cases[@]}"; exit 1
fi
if [ "$failed" -ne 0 ]; then
    printf '%s: %s of %s cases failing\n' "$(basename "$suite")" "$failed" "${#cases[@]}"; exit 1
fi
printf '%s: %s of %s cases passing\n' "$(basename "$suite")" "${#cases[@]}" "${#cases[@]}"
