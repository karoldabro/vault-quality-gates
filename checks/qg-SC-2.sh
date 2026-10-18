#!/usr/bin/env bash
# SC-2 — a refusal prints why, findings, reproduce, qg explain and how to pass, within 3500 characters
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-refusal.bats \
    a\ worse\ v2\ row\ prints\ its\ why \
    a\ long\ refusal\ is\ cut\ in\ the\ middle \
    a\ push\ refusal\ names\ the\ ref \
    an\ agent\ is\ told\ it\ may\ not\ override \
    -- \
    qg-driver-phpstan.bats \
    through\ the\ engine:\ a\ file-less-only\ failure\ is\ refused\ with\ its\ message
