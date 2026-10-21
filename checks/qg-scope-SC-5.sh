#!/usr/bin/env bash
# qg-guard-scope SC-5 — a turn ends freely in a repo with no gate hook, and a failing gated.py or an
# unreadable hooks folder counts as gated.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-stop.bats \
    "a repo whose VAULT.md names the plugin but has no gate hook lets the turn end" \
    "an unreadable hooks folder or a failing gated.py counts as gated"
