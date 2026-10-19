#!/usr/bin/env bash
# S4 SC-6 — a staged commit-lint.sh edit runs the parent's copy and is refused; a changed tool
# version, or a package turned into a path or git package, is refused by dart-tools-changed.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
echo "qg-s4-SC-6: the dart-lock driver and commit-lint.sh cases are not written yet"
exit 2
