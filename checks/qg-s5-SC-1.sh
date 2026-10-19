#!/usr/bin/env bash
# S5 SC-1 — the doc-lint driver counts only what a commit adds, uses only the .doc-lint files of
# the config revision, counts a skip file or a type: change as a finding, ignores the caller's
# doc-lint switches, and reads its linter path from quality/config at the config revision.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-driver-doc-lint.bats \
    "a finding on an added line counts 1" \
    "a finding on an unchanged line of a changed file is not counted" \
    "a file-level finding on a file the commit creates counts 1" \
    "a file-level code the parent's version already has is not counted" \
    "a file-level code the parent's version lacks counts 1" \
    "a merge does not count a file-level code that any parent already has" \
    "a DUP1 x<n> finding parses as a line-null finding, not an error" \
    "an untracked .doc-lint at the working-tree root or in .git does not change the metric" \
    "a .doc-lint the commit adds in a subfolder is ignored and counts 1 as doc-lint.SKIPFILE" \
    "a committed .doc-lint at the config revision still applies" \
    "changing or removing an existing file's type: counts 1 as doc-lint.TYPE" \
    "DOC_LINT, DOC_LINT_SKIP, DOC_LINT_PATTERNS, VAULT_FRAMEWORK_PATH, BASH_ENV and ENV from the caller do not reach the linter" \
    "guard_doc_lint unset, relative or not executable is status error naming the key" \
    "a missing linter library beside guard_doc_lint is status error naming it" \
    "guard_doc_lint is read at the config revision, not from the working tree" \
    "no changed markdown file and no .doc-lint is metric 0 and the linter never runs" \
    "a linter exit above 1, or exit 1 with no parsed finding, is status error"
