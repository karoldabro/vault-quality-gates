#!/usr/bin/env bash
# S5 SC-1 — the doc-lint driver counts only what a commit adds, uses only the .doc-lint and
# VAULT.md files of the config revision, counts a skip file, a VAULT.md or a type change as a
# finding, follows renames, ignores the caller's doc-lint switches, and reads its linter path from
# quality/config at the config revision.
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
    "a file with no type: in a top-level document folder is linted" \
    "an untracked .doc-lint at the working-tree root or in .git does not change the metric" \
    "a .doc-lint the commit adds in a subfolder is ignored and counts 1 as doc-lint.SKIPFILE" \
    "a .doc-lint the commit adds at the root is ignored and counts 1 as doc-lint.SKIPFILE" \
    "a commit that edits a tracked .doc-lint is linted with the config revision's copy and counts 1 as doc-lint.SKIPFILE" \
    "a committed .doc-lint at the config revision still applies" \
    "a VAULT.md the commit edits or adds, at the root or in a subfolder, does not change INDEX3 and counts 1 as doc-lint.SKIPFILE" \
    "changing or removing an existing file's type: counts 1 as doc-lint.TYPE" \
    "type:guide with no space, and a blank line before the frontmatter, count 1 as doc-lint.TYPE" \
    "a renamed file whose type changes counts 1 as doc-lint.TYPE" \
    "a new file with an instruction type counts 1 as doc-lint.TYPE" \
    "a plain rename of a file with an old file-level finding counts 0" \
    "DOC_LINT, DOC_LINT_SKIP, DOC_LINT_PATTERNS, VAULT_FRAMEWORK_PATH, BASH_ENV, ENV and an exported function from the caller do not reach the linter" \
    "guard_doc_lint unset, relative or not executable is status error naming the key" \
    "a missing linter library in ../lib of the linter's folder is status error naming it" \
    "guard_doc_lint is read at the config revision, not from the working tree" \
    "a measured tree outside the gate's guard-tree copy is status error and deletes nothing" \
    "no changed markdown, .doc-lint or VAULT.md is metric 0 and the linter never runs" \
    "a linter exit above 1, or exit 1 with no parsed finding, is status error"
