#!/usr/bin/env bash
# S6 SC-4 — the agent hook denies the names the S6 rules file lists and exported functions; a git
# hook or qg reaches the same verdict with those names, loader variables, a planted bash, env, awk
# or git on PATH, or GUARD_CONFIG_REV set; no driver or runner sees them; the human skip-reason
# form still works at a terminal.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-claude-hooks.bats \
    "BASH_FUNC_ assignments are denied beside any command and BASH_ENV, SHELLOPTS and BASHOPTS beside git, qg or a hook" \
    "GIT_REPLACE_REF_BASE, GIT_NO_REPLACE_OBJECTS, GIT_ALTERNATE_OBJECT_DIRECTORIES, GIT_OBJECT_DIRECTORY and GIT_EXTERNAL_DIFF are denied" \
    "env with a name that is no plain identifier is denied and the command after it is still checked" \
    "export -f, declare -fx and typeset -fx are denied" \
    -- guard-env.bats \
    "a git hook reaches the same verdict with BASH_ENV, BASH_FUNC_ or NODE_OPTIONS set" \
    "a git hook reaches the same verdict with LD_PRELOAD or PYTHONPATH set" \
    "a git hook reaches the same verdict with a fake bash, env, awk or git earlier on PATH" \
    "a git hook ignores GUARD_CONFIG_REV" \
    "a driver and a repo runner started by a hook see none of the caller's extra names" \
    "pre-push still reads every ref on stdin after the clean restart" \
    "the skip reason from a human at a terminal still passes one commit" \
    "the skip reason with CLAUDECODE set is refused" \
    "qg with extra names set reaches the same verdict as without them"
