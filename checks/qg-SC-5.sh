#!/usr/bin/env bash
# SC-5 — push rows run on the refs their on cell names, and a ref no row runs on is accepted at once
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-push-select.bats \
    v1:\ a\ ref\ inside\ guard_release_pattern\ runs\ the\ row \
    v2:\ push\ runs\ on\ every\ ref \
    has\ no\ quality/checks.tsv\ is\ accepted \
    guard_measure_worktree\ false:\ no\ tree\ check\ when\ no\ row\ runs \
    -- \
    qg-events.bats \
    truth\ table \
    globs\ follow \
    -- \
    guard-hooks.bats \
    every\ pushed\ ref\ reaches\ the\ engine\ once
