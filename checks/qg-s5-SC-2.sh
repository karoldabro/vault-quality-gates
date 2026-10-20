#!/usr/bin/env bash
# S5 SC-2 — qg init protects the gate files by exact path, so other files under quality/ stay
# editable, and the docs profile writes the linter path the doc-lint driver reads.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-init.bats \
    "init protects exactly the gate files and leaves other quality files unprotected" \
    "init --profile docs protects .doc-lint and every tracked .doc-lint and writes an absolute guard_doc_lint" \
    "init --profile docs warns when the doc-lint it names is not executable" \
    "init --profile docs --force with an existing quality/config writes nothing to it and warns naming guard_doc_lint" \
    "init prints Next as hooks install, then commit, then qg doctor" \
    "init --profile docs: with hooks installed, qg doctor names HEAD has no quality/checks.tsv before the init commit and exits 0 after it" \
    "init --profile hugo: qg doctor exits 0 after the init commit"
