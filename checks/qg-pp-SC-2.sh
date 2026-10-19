#!/usr/bin/env bash
# Push pass record SC-2 — an agent command or edit that writes a push pass record is denied.
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-claude-hooks.bats \
    "an agent write into guard-pass/push is denied"
