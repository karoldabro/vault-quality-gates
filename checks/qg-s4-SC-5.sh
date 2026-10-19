#!/usr/bin/env bash
# S4 SC-5 — no v2 row reads a report another row writes, and the suite under test changes no row
# before it. Rows that share one tool run measure the same values together and alone; the suite runs
# isolated and last.
#
# The real-clone half (each row of the migrated file alone versus a full push run) runs inside
# checks/qg-parity-recycling_mobile_app.sh, which needs the operator's Flutter toolchain.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-driver-flutter-test.bats \
    "two rows of one run, metric=failed then metric=coverage, call flutter once and both measure" \
    "the shared run is keyed by target: a second ref runs the suite again and gives 0 then 1" \
    "the suite sees no QG_* or GUARD_* variable, no caller PUB_CACHE, and a TMPDIR outside the tree that is removed" \
    "a background process the suite leaves in its process group is killed before the driver returns" \
    -- qg-dart.bats \
    "qg_isolated gives the tool only HOME, PATH, LANG, FLUTTER_ROOT and TMPDIR" \
    "qg_isolated kills the tool's process group, so a background child does not outlive the tool" \
    -- qg-migration-mobile.bats \
    "no driver row holds a table-escaped \\| and the suite rows run after every other push or baseline row"
