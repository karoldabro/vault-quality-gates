#!/usr/bin/env bash
# SC-9 — an agent cannot set gate variables, change the gate through qg, or write the token, drivers or config
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-env.bats \
    an\ agent\ may\ not\ set\ or\ export\ a\ gate\ variable \
    -- \
    qg-claude-hooks.bats \
    qg:\ reads\ and\ runs\ are\ allowed \
    the\ override\ token\ and\ the\ run\ records\ cannot\ be\ written \
    quality/drivers/\ and\ quality/config\ cannot\ be\ written \
    -- \
    qg-cli.bats \
    the\ commands\ that\ change\ the\ gate\ refuse\ an\ agent
