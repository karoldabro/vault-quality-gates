#!/usr/bin/env bash
# S4 SC-3 — migrations/recycling_mobile_app/checks.tsv loads with its config, names every v1 id,
# gives each row a distinct real why, protects every file a row names, holds no `\|`, and runs the
# flutter-test and mutation-test rows last.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
echo "qg-s4-SC-3: migrations/recycling_mobile_app/checks.tsv is not written yet"
exit 2
