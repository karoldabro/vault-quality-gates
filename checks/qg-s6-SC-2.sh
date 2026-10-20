#!/usr/bin/env bash
# S6 SC-2 — a host-run test suite under a sandboxed driver runs inside bin/qg-sandbox: it cannot
# write the pub cache, the SDK outside its stamps and lockfile, guard-cache, .git or QG_OUT, and
# cannot open a Unix socket; a sandbox that cannot start is status error, never an unsandboxed run.
# A skipped case counts as absent.
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
    "a sandboxed tool cannot write guard-cache or .git of a working-tree QG_TREE" \
    "a sandboxed tool cannot write QG_OUT" \
    "a sandboxed tool cannot open a Unix socket" \
    "a sandboxed tool writes its tree and private folder" \
    "a sandbox that cannot start is status error and the tool never runs" \
    "a driver without sandbox in describe runs unsandboxed" \
    -- qg-driver-kit.bats \
    "qg_tool runs a sandbox:true driver's runner inside the sandbox" \
    -- qg-dart.bats \
    "qg_isolated runs the SDK snapshot inside the sandbox with FLUTTER_ALREADY_LOCKED" \
    "the private flutter shim on PATH runs the snapshot, never bin/flutter"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
out="$(cd "$QG_CHECKS_ROOT" && ./tests/run.sh tests/unit/qg-sandbox.bats 2>&1)"
if grep -q '# skip' <<<"$out"; then
    printf 'qg-sandbox.bats skipped cases:\n'; grep '# skip' <<<"$out"; exit 1
fi
