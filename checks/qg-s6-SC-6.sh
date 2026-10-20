#!/usr/bin/env bash
# S6 SC-6 — an agent cannot write or edit under ~/.pub-cache, a Flutter SDK or a ~/.cache venv
# folder holding copydetect-*; a file in a worktree of this repo stays editable.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-claude-hooks.bats \
    "writes and edits under .pub-cache, a Flutter SDK or a copydetect venv folder are denied" \
    "a file in a worktree of the plugin stays editable while the hook checkout is denied"
