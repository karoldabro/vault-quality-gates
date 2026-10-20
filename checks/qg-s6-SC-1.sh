#!/usr/bin/env bash
# S6 SC-1 — `qg doctor --all-branches` lists every local and remote-tracking ref whose
# quality/checks.tsv is v1, or whose v2 checks.tsv has no quality/config, and exits 1; with none it
# exits 0; it never fetches or writes.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-doctor-branches.bats \
    "a v1 checks.tsv on a remote-tracking ref is listed as upstream and exits 1" \
    "a v1 checks.tsv on a local-only branch is listed as local and exits 1" \
    "a v2 checks.tsv without quality/config on a ref is listed and exits 1" \
    "refs with v2 config or no checks.tsv exit 0 and list nothing" \
    "the symbolic origin/HEAD is not listed" \
    "--all-branches never fetches and leaves refs and the working tree unchanged" \
    "--all-branches --json prints one object per listed ref"
