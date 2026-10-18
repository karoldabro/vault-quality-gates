#!/usr/bin/env bash
# SC-4 — qg read commands exit 0 and print one JSON document under --json; run exits like guard.sh
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-cli.bats \
    no\ argument\ and\ help\ print\ the\ overview \
    list\ shows\ every\ row \
    run\ commit\ passes\ and\ fails\ like\ the\ hook\ would \
    explain\ works\ before\ any\ run \
    last\ prints\ the\ whole\ last\ refusal \
    drivers\ lists\ the\ built-ins \
    doctor\ reports\ missing\ hooks
