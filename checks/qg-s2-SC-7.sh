#!/usr/bin/env bash
# S2 SC-7 — `qg baseline --only <ids>` rewrites only those rows and writes nothing when a named row
# yields no number.
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-baseline-only.bats \
    "--only coverage rewrites only that line; every other line, the accepted reason included, is unchanged" \
    "--only adds a line for a named row that had none, and invents no line for an unnamed row" \
    "--only with one named row unmeasurable exits 2 naming it and leaves the file byte-identical" \
    "--only with an unknown id or an empty list exits 2 and writes nothing"
