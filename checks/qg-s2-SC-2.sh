#!/usr/bin/env bash
# S2 SC-2 — a refused push and `qg explain` print driver findings through guard-report-errors.sh,
# at most 10 per row then `<id> +N more`, and a malformed rules.tsv never hides the refusal.
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-push-findings.bats \
    a\ push\ refused\ by\ a\ driver\ row\ prints\ its\ findings \
    13\ findings\ print\ 10 \
    a\ malformed\ quality/rules.tsv\ still\ prints\ the\ refusal \
    a\ repo\ with\ no\ quality/rules.tsv\ prints\ findings\ without\ pointers \
    qg\ explain\ prints\ a\ driver\ row\'s\ last\ findings\ through\ the\ printer \
    guard-report-errors\ --limit\ with\ 0\ and\ exactly\ 10\ findings
