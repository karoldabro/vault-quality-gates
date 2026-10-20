#!/usr/bin/env bash
# S6 SC-4 — the agent hook denies setting BASH_ENV, ENV, SHELLOPTS, BASHOPTS or a BASH_FUNC_* name
# and exporting a function; a git hook reaches the same verdict with those set or with awk, jq and
# git shadowed on PATH.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-claude-hooks.bats \
    "BASH_ENV, ENV, SHELLOPTS, BASHOPTS and BASH_FUNC_ assignments or exports are denied beside any command" \
    "export -f, declare -fx and typeset -fx are denied" \
    -- guard-env.bats \
    "a git hook reaches the same verdict with BASH_ENV, ENV or an exported function set" \
    "a git hook reaches the same verdict with awk, jq and git shadowed on PATH"
