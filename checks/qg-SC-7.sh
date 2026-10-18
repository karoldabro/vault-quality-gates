#!/usr/bin/env bash
# SC-7 — a repo driver runs only from the parent commit, and the commit adding one is refused
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-driver-resolution.bats \
    a\ committed\ repo\ driver\ runs \
    a\ working-tree\ edit\ to\ a\ committed\ repo\ driver\ never\ runs \
    a\ driver\ that\ exists\ only\ in\ the\ working\ tree\ never\ runs \
    a\ repo\ driver\ named\ like\ a\ built-in\ is\ refused \
    a\ commit\ that\ adds\ or\ changes\ a\ repo\ driver\ or\ quality/config\ is\ refused
