#!/usr/bin/env bash
# S6 SC-2 — a built-in driver not marked "sandbox": false runs its tool inside bin/qg-sandbox: it
# writes only its private folder and declared tree paths, never .git in a main or linked worktree,
# never through a symlinked grant, opens no Unix socket through either system-call entry and holds
# no descriptor above 2; a repo driver runs sandboxed whole; a sandbox that never arms is
# status error and the tool never runs.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-sandbox.bats \
    "a sandboxed tool cannot write under the caller's .pub-cache" \
    "a sandboxed tool cannot write an SDK file other than bin/cache stamps and lockfile" \
    "a sandboxed tool can rewrite an existing bin/cache stamp and lockfile" \
    "a sandboxed tool cannot write .git, .claude or .mcp.json of a main worktree" \
    "a sandboxed tool cannot write the .git file, .claude or .npmrc of a linked worktree" \
    "a sandboxed tool writes only its declared paths and report folder" \
    "a declared path that is a symlink or resolves outside the tree is refused" \
    "a declared path under node_modules other than .vite and .cache is refused" \
    "a sandboxed tool cannot write QG_OUT" \
    "a sandboxed tool cannot open a Unix socket through socket" \
    "a sandboxed tool cannot open a Unix socket through the 32-bit socketcall entry" \
    "a sandboxed tool sees no descriptor above 2" \
    "a sandboxed tool cannot signal a process outside the sandbox" \
    "a sandbox that never arms is status error and the tool never runs" \
    "a driver without sandbox in describe runs sandboxed" \
    "a driver with sandbox false runs unsandboxed" \
    -- qg-driver-resolution.bats \
    "guard_run_driver exports QG_SANDBOX and QG_SANDBOX_WRITES from describe" \
    "a repo driver's run executes inside the sandbox with QG_OUT writable" \
    -- qg-driver-kit.bats \
    "qg_tool runs a sandboxed driver's runner inside the sandbox" \
    "qg_tool refuses a shell function as the program" \
    -- qg-dart.bats \
    "qg_isolated runs the SDK snapshot inside the sandbox with FLUTTER_ALREADY_LOCKED" \
    "the private flutter shim on PATH runs the snapshot, never bin/flutter" \
    -- qg-driver-mutation-test.bats \
    "mutation-test measures through the real kit path under the sandbox" \
    -- qg-driver-dart-code-linter.bats \
    "dart-code-linter measures through the real kit path under the sandbox"
