#!/usr/bin/env bash
# qg-guard-scope SC-1 — in an ungated repo the guards allow launchers, scripts that run git, computed
# code and program names, git reads and git commit -n.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-claude-hooks.bats \
    "in an ungated repo launchers, scripts running git, computed code and programs, git reads and git commit -n are allowed"
