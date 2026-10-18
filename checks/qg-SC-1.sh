#!/usr/bin/env bash
# SC-1 — a row that cannot run shows the tool's own output, once per distinct text
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-refusal.bats \
    eight\ rows\ failing\ on\ one\ environment\ error \
    -- \
    qg-row-status.bats \
    the\ error\ text\ a\ driver\ reports\ reaches\ the\ refusal \
    the\ last\ 20\ output\ lines\ and\ the\ result\ are\ kept
