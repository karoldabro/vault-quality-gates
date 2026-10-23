#!/usr/bin/env bash
# Push pass record SC-2 — an agent command or edit that writes a push pass record is denied.
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-claude-hooks.bats \
    "guard-bash denies skipping or weakening the gate in a gated repo" \
    "guard-edit denies the git dir, husky and gate files in a gated repo only"
