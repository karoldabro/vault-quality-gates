#!/usr/bin/env bash
# S6 SC-5 — `qg hooks install --claude --user` is idempotent, keeps other settings, covers each
# --config-dir, points at the main worktree, writes the machine tool-path file and refuses from a
# linked worktree; the guards allow ordinary commands and keep every commit and push rule.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-claude-hooks.bats \
    "hooks install --claude --user twice leaves two guard entries and keeps other entries" \
    "hooks install --claude --user writes the same entries into each --config-dir" \
    "hooks install --claude --user writes commands under the main worktree" \
    "hooks install --claude --user writes the machine tool-path file from the caller's PATH" \
    "hooks install --claude --user refuses when its own checkout is a linked worktree" \
    "hooks remove --claude --user removes exactly the two guard entries" \
    -- guard-claude-hooks.bats \
    "guard-bash allows commands that neither commit nor push" \
    "guard-bash denies skipping or weakening the gate in a gated repo"
