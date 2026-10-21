#!/usr/bin/env bash
# qg-guard-scope SC-2 — in every repo the guards deny writes to the guard install and the gate's
# tools, and qg writes, with the integrity text; a gate denial never hides such a write.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-claude-hooks.bats \
    "in an ungated repo writes to the guard install and the gate's tools are denied with the integrity text" \
    "a gate denial earlier in a command never hides an integrity write later in it"
