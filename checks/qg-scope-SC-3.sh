#!/usr/bin/env bash
# qg-guard-scope SC-3 — from an ungated cwd, a literal path into a gated repo brings every gate rule.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-claude-hooks.bats \
    "from an ungated cwd a literal path into a gated repo brings every gate rule"
