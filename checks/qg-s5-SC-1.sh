#!/usr/bin/env bash
# S5 SC-1 — the doc-lint driver counts only what a commit adds, ignores the caller's doc-lint
# switches, and reads its linter path from quality/config at the config revision.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-driver-doc-lint.bats \
    "a finding on an added line counts 1" \
    "a finding on an unchanged line of a changed file is printed and not counted" \
    "a file-level finding on a file the commit creates counts 1" \
    "a file-level finding on a file the parent already has is printed and not counted" \
    "DOC_LINT=off, DOC_LINT_SKIP, DOC_LINT_PATTERNS and VAULT_FRAMEWORK_PATH from the caller do not reach the linter" \
    "guard_doc_lint unset, relative or not executable is status error naming the key" \
    "guard_doc_lint is read at the config revision, not from the working tree" \
    "no changed markdown file is metric 0 and the linter never runs" \
    "a linter exit above 1, or exit 1 with no parsed finding, is status error"
