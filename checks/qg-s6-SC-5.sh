#!/usr/bin/env bash
# S6 SC-5 — `qg hooks install --claude --user` is idempotent, keeps other settings, covers each
# --config-dir, points at the main worktree, writes the machine tool-path file and refuses from a
# linked worktree; in an ungated repo the guards allow ordinary commands and keep every git, qg and
# write rule.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-claude-hooks.bats \
    "hooks install --claude --user twice leaves three guard entries and keeps other entries" \
    "hooks install --claude --user writes the same entries into each --config-dir" \
    "hooks install --claude --user writes commands under the main worktree" \
    "hooks install --claude --user writes the machine tool-path file from the caller's PATH" \
    "hooks install --claude --user refuses when its own checkout is a linked worktree" \
    "hooks remove --claude --user removes exactly the three guard entries" \
    -- guard-claude-hooks.bats \
    "in a repo with no quality folder an fd duplication, python backticks and an installed program naming the plugin path are allowed" \
    "python one-liners using re.compile or os.path and a file name holding ai_agent are allowed" \
    "in a repo with no quality folder every git, qg and write denial still holds"
