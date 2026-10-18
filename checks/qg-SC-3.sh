#!/usr/bin/env bash
# SC-3 — the override token passes one exact tree or sha, once, for a human at a terminal only
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-override.bats \
    the\ token\ is\ written\ only\ with\ a\ reason \
    a\ token\ passes\ the\ refused\ commit\ of\ exactly\ that\ staged\ content \
    a\ token\ for\ other\ staged\ content\ is\ ignored \
    an\ agent\'s\ commit\ never\ consumes\ a\ valid\ token \
    older\ than\ 10\ minutes,\ from\ the\ future,\ or\ malformed \
    a\ commit\ token\ never\ passes\ a\ push \
    a\ push\ token\ passes\ only\ its\ exact\ full\ sha
