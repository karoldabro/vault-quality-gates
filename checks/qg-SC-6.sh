#!/usr/bin/env bash
# SC-6 — a v2 up row's lowered baseline is refused as baseline-loosened
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-v2-baseline.bats \
    commit:\ a\ lowered\ up\ row\ and\ a\ raised\ down\ row\ are\ loosened \
    push:\ a\ commit\ that\ lowers\ an\ up\ row
