#!/usr/bin/env bash
# S6 SC-6 — an agent cannot write or edit a path the S6 rules file lists as a global write denial;
# a planted json.py in the cwd changes no hook's verdict; a file in a worktree of this repo stays
# editable.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-claude-hooks.bats \
    "writes and edits under .pub-cache, a Flutter SDK or a copydetect venv folder are denied" \
    "writes and edits to a shell startup file are denied" \
    "writes under a PATH folder before /usr/bin or a tool-path folder are denied" \
    "a denied root named inside python code or as a tar, unzip, curl, wget or git clone target is denied" \
    "a planted json.py in the cwd does not change any hook's verdict" \
    "a file in a worktree of the plugin stays editable while the hook checkout is denied"
