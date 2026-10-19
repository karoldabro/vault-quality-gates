#!/usr/bin/env bash
# Push pass record SC-1 — pre-push accepts a pass that qg run push --ref recorded for the same
# commit, ref, bases and engine within 60 minutes, and measures as before in every other case.
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-push-pass.bats \
    "a push that qg run push --ref recorded is accepted without measuring" \
    "an amended commit is measured although its parent was recorded" \
    "a push to another ref name is measured" \
    "a remote tip that moved after the record makes the push measure" \
    "an engine file changed after the record makes the push measure" \
    "a record older than an hour, dated in the future, or unparsable makes the push measure" \
    "qg run push with --only, a worse row, an unmeasurable row, or no --ref writes no record" \
    "qg run push --ref refuses a baseline loosened against the remote tip and records nothing" \
    "an installed pre-push without --use-pass measures although a record exists"
