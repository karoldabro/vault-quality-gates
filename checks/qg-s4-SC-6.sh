#!/usr/bin/env bash
# S4 SC-6 — a staged edit to quality/bin/commit-lint.sh never runs: the lint rows run the committed
# runner the engine copies from the config revision, and protected-paths-touched refuses the commit.
# A changed tool version, a package turned into a path or git package, or a changed
# dependency_overrides section is counted by dart-tools-changed.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-driver-dart-lock.bats \
    "a named package's version bump counts 1, and its sha256 changing with it is the same package" \
    "a named git package whose resolved-ref changes counts 1" \
    "a named package turned into a path package counts 1, not 2" \
    "an unnamed package turned into a path package counts 1" \
    "an unnamed package turned into a git package counts 1" \
    "a dependency_overrides section added to pubspec.yaml counts 1" \
    "under :index an unstaged working-tree edit is not read" \
    -- qg-driver-checkstyle.bats \
    "no QG_RUNNER from the engine is status error" \
    "the runner gets <tree> <cache> and an empty stdin, whatever the driver's stdin holds" \
    -- qg-checkstyle-engine.bats \
    "a staged edit to the lint runner never runs: the parent's runner judges, and protected-paths-touched refuses" \
    -- qg-migration-mobile.bats \
    "every file a v2 row reads, every Dart default config and every package override is protected"
