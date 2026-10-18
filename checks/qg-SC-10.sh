#!/usr/bin/env bash
# SC-10 — the 43d7082 hook bodies reach the same verdicts with the new engine
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-old-hooks.bats \
    the\ 43d7082\ hook\ bodies\ and\ the\ new\ ones\ reach\ the\ same\ verdicts \
    -- \
    qg-push-select.bats \
    the\ 43d7082\ call\ form\ still\ works
